%% Copyright (c) 2011 Jacob Vorreuter <jacob.vorreuter@gmail.com>
%% 
%% Permission is hereby granted, free of charge, to any person
%% obtaining a copy of this software and associated documentation
%% files (the "Software"), to deal in the Software without
%% restriction, including without limitation the rights to use,
%% copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following
%% conditions:
%% 
%% The above copyright notice and this permission notice shall be
%% included in all copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
%% OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
%% HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
%% WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
%% OTHER DEALINGS IN THE SOFTWARE.
-module(nsync).
-behaviour(gen_server).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% API
-export([start_link/0, start_link/1, tid/0, tid/1]).

-include("nsync.hrl").

-record(state, {callback, caller_pid, socket, opts, 
                state, buffer, rdb_state, map}).

-define(TIMEOUT, 30000).
-define(CALLBACK_MODS, [nsync_string,
                        nsync_list,
                        nsync_set,
                        nsync_zset,
                        nsync_hash,
                        nsync_pubsub]).

%%====================================================================
%% API functions
%%====================================================================
start_link() ->
    start_link([]).

start_link(Opts) ->
    Timeout = proplists:get_value(timeout, Opts, 1000 * 60 * 6),
    case proplists:get_value(block, Opts) of
        true ->
            case gen_server:start_link(?MODULE, [Opts, self()], []) of
                {ok, Pid} ->
                    receive
                        {Pid, load_complete} ->
                            {ok, Pid}
                    after Timeout ->
                        {error, timeout}
                    end;
                Err ->
                    Err
            end;
        _ ->
            gen_server:start_link(?MODULE, [Opts, undefined], [])
    end.

tid() ->
    tid(?MODULE).

tid(Name) ->
    nsync_utils:lookup_read_tid(nsync_tids, Name).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Opts, CallerPid]) ->
    ets:new(nsync_tids, [named_table, protected, set]),
    case init_state(Opts, CallerPid) of
        {ok, State} ->
            {ok, State};
        Error ->
            {stop, Error}
    end.

handle_call(_Request, _From, State) ->
    {reply, ignore, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp, Socket, Data}, #state{callback=Callback,
                                        caller_pid=CallerPid,
                                        socket=Socket,
                                        map=Map,
                                        state=loading,
                                        rdb_state=RdbState}=State) ->
    NewState =
        case rdb_load:packet(RdbState, Data, Callback) of
            {eof, Rest} ->
                nsync_utils:failover_tids(nsync_tids),
                case CallerPid of
                    undefined -> ok;
                    _ -> CallerPid ! {self(), load_complete}
                end,
                nsync_utils:do_callback(Callback, [{load, eof}]),
                {ok, Rest1} = redis_text_proto:parse_commands(Rest, Callback, Map),
                State#state{state=up, buffer=Rest1};
            {error, <<"-LOADING", _/binary>> = Msg} ->
                error_logger:info_report([?MODULE, Msg]), 
                timer:sleep(1000),
                init_sync(Socket),
                State;
            RdbState1 ->
                State#state{rdb_state=RdbState1}
        end,
    inet:setopts(Socket, [{active, once}]),
    {noreply, NewState};

handle_info({tcp, Socket, Data}, #state{callback=Callback,
                                        socket=Socket,
                                        buffer=Buffer,
                                        map=Map}=State) ->
    {ok, Rest} = redis_text_proto:parse_commands(<<Buffer/binary, Data/binary>>, Callback, Map),
    inet:setopts(Socket, [{active, once}]),
    {noreply, State#state{buffer=Rest}};

handle_info({tcp_closed, _}, #state{callback=Callback,
                                    opts=Opts,
                                    socket=Socket}=State) ->
    catch gen_tcp:close(Socket),
    nsync_utils:do_callback(Callback, [{error, closed}]),
    nsync_utils:reset_write_tids(nsync_tids),
    case reconnect(Opts) of
        {ok, State1} ->
            {noreply, State1};
        Error ->
            {stop, Error, State}
    end;

handle_info({tcp_error, _ ,_}, #state{callback=Callback,
                                      opts=Opts,
                                      socket=Socket}=State) ->
    catch gen_tcp:close(Socket),
    nsync_utils:do_callback(Callback, [{error, closed}]),
    nsync_utils:reset_write_tids(nsync_tids),
    case reconnect(Opts) of    
        {ok, State1} ->
            {noreply, State1};
        Error ->
            {stop, Error, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% internal functions
%%====================================================================
reconnect(Opts) ->
    case init_state(Opts, undefined) of
        {ok, State} ->
            {ok, State};
        {error, Err} when Err == econnrefused; Err == closed ->
            timer:sleep(250),
            reconnect(Opts);
        Err ->
            Err
    end.

init_state(Opts, CallerPid) ->
    Host = proplists:get_value(ip, Opts, "localhost"),
    Port = proplists:get_value(port, Opts, 6379),
    Auth = proplists:get_value(pass, Opts),
    Callback =
        case proplists:get_value(callback, Opts) of
            undefined -> default_callback();
            Cb -> Cb
        end,
    case open_socket(Host, Port) of
        {ok, Socket} ->
            case authenticate(Socket, Auth) of
                ok ->
                    Map = init_map(),
                    init_sync(Socket),
                    inet:setopts(Socket, [{active, once}]),
                    {ok, #state{
                        callback=Callback,
                        caller_pid=CallerPid,
                        socket=Socket,
                        opts=Opts,
                        state=loading,
                        buffer = <<>>,
                        map=Map
                    }};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

open_socket(Host, Port) when is_list(Host), is_integer(Port) ->
    gen_tcp:connect(Host, Port, [binary, {packet, raw}, {active, false}]);

open_socket(_Host, _Port) ->
    {error, invalid_host_or_port}.

authenticate(_Socket, undefined) ->
    ok;

authenticate(Socket, Auth) ->
    case gen_tcp:send(Socket, [<<"AUTH ">>, Auth, <<"\r\n">>]) of
        ok ->
            case gen_tcp:recv(Socket, 0, ?TIMEOUT) of
                {ok, <<"OK\r\n">>} ->
                    ok;
                {ok, <<"+OK\r\n">>} ->
                    ok;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

default_callback() ->
    fun({load, _K, _V}) ->
          ?MODULE;
       ({load, eof}) ->
          error_logger:info_report([?MODULE, {load, eof}]);
       ({error, Error}) ->
          error_logger:error_report([?MODULE, {error, Error}]);
       ({cmd, _Cmd, _Args}) ->
          ?MODULE;
       (_) ->
          undefined
    end.

init_map() ->
    lists:foldl(fun(Mod, Acc) ->
        lists:foldl(fun(Cmd, Acc1) ->
            dict:store(Cmd, Mod, Acc1)
        end, Acc, Mod:command_hooks())
    end, dict:new(), ?CALLBACK_MODS).

init_sync(Socket) ->
    gen_tcp:send(Socket, <<"SYNC\r\n">>).

