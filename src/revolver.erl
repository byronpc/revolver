-module (revolver).

-behaviour (gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([balance/2, balance/3, balance/4, map/2, start_link/4, pid/1, connect/1]).

-define(DEFAULTMINALIVERATIO, 1.0).
-define(DEFAULRECONNECTDELAY, 1000). % ms

-type sup_ref()  :: {atom(), atom()}.

-record(state, {
    connected :: boolean(),
    supervisor :: sup_ref(),
    pid_table :: atom(),
    last_pid :: pid(),
    pids_count_original :: integer(),
    min_alive_ratio :: float(),
    reconnect_delay :: integer()
    }).

start_link(Supervisor, ServerName, MinAliveRatio, ReconnectDelay) ->
    gen_server:start_link({local, ServerName}, ?MODULE, {Supervisor, MinAliveRatio, ReconnectDelay}, []).

balance(Supervisor, BalancerName) ->
    revolver_sup:start_link(Supervisor, BalancerName, ?DEFAULTMINALIVERATIO, ?DEFAULRECONNECTDELAY).

balance(Supervisor, BalancerName, MinAliveRatio) ->
    revolver_sup:start_link(Supervisor, BalancerName, MinAliveRatio, ?DEFAULRECONNECTDELAY).

balance(Supervisor, BalancerName, MinAliveRatio, ReconnectDelay) ->
    revolver_sup:start_link(Supervisor, BalancerName, MinAliveRatio, ReconnectDelay).

pid(PoolName) ->
    gen_server:call(revolver_utils:revolver_name(PoolName), pid).

map(ServerName, Fun) ->
    gen_server:call(ServerName, {map, Fun}).

connect(PoolName) ->
    gen_server:call(revolver_utils:revolver_name(PoolName), connect).

init({Supervisor, MinAliveRatio, ReconnectDelay}) ->
  init({Supervisor, MinAliveRatio, ReconnectDelay, true});
init({Supervisor, MinAliveRatio, ReconnectDelay, ConnectAtStart}) ->
    PidTable = ets:new(pid_table, [private, duplicate_bag]),

    State = #state{
        connected           = false,
        supervisor          = Supervisor,
        pids_count_original = undefined,
        min_alive_ratio     = MinAliveRatio,
        pid_table           = PidTable,
        last_pid            = undefined,
        reconnect_delay     = ReconnectDelay
    },
    maybe_connect(ConnectAtStart),
    {ok, State}.

maybe_connect(true) ->
  self() ! connect;
maybe_connect(_) ->
  noop.

handle_call(pid, _From, State = #state{connected = false}) ->
    {reply, {error, disconnected}, State};
handle_call(pid, _From, State = #state{last_pid = LastPid, pid_table = PidTable}) ->
    Pid = case ets:next(PidTable, LastPid) of
        '$end_of_table' ->
            ets:first(PidTable);
        Value ->
            Value
    end,
    {reply, Pid, State#state{last_pid = Pid}};

handle_call({map, Fun}, _From, State = #state{pid_table = PidTable}) ->
    % we are reconnecting here to make sure we
    % have an up to date version of the pids
    StateNew = connect_internal(State),
    Pids     = ets:foldl(fun({Pid, _}, Acc) -> [Pid|Acc] end, [], PidTable),
    Reply    = lists:map(Fun, Pids),
    {reply, Reply, StateNew};

handle_call(connect, _From, State) ->
    NewSate = connect_internal(State),
    Reply =
    case NewSate#state.connected of
        true ->
            ok;
        false ->
            {error, not_connected}
    end,
    {reply, Reply, NewSate}.

handle_cast(_, State) ->
    throw("not implemented"),
    {noreply, State}.

handle_info(connect, State) ->
    {noreply, connect_internal(State)};

handle_info({'DOWN', _, _, Pid, _}, State = #state{supervisor = Supervisor, pid_table = PidTable, pids_count_original = PidsCountOriginal, min_alive_ratio = MinAliveRatio}) ->
    error_logger:info_msg("~p: The process ~p (child of ~p) died.\n", [?MODULE, Pid, Supervisor]),
    ets:delete(PidTable, Pid),
    StateNew =
    case too_few_pids(PidTable, PidsCountOriginal, MinAliveRatio) of
        true ->
            error_logger:warning_msg("~p: Reloading children from supervisor ~p.\n", [?MODULE, Supervisor]),
            connect_internal(State);
        false ->
            State
    end,
    {noreply, StateNew}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

too_few_pids(PidTable, PidsCountOriginal, MinAliveRatio) ->
    table_size(PidTable) / PidsCountOriginal < MinAliveRatio.

connect_internal(State = #state{ supervisor = Supervisor, pid_table = PidTable, reconnect_delay = ReconnectDelay }) ->
    case revolver_utils:child_pids(Supervisor) of
        {error, supervisor_not_running} ->
            ets:delete_all_objects(PidTable),
            schedule_reconnect(ReconnectDelay),
            State#state{ connected = false };
        Pids ->
            PidsNew      = lists:filter(fun(E) -> ets:lookup(PidTable, E) =:= [] end, Pids),
            PidsWithRefs = [{Pid, revolver_utils:monitor(Pid)}|| Pid <- PidsNew],
            true         = ets:insert(PidTable, PidsWithRefs),
            StateNew     = State#state{ last_pid =  ets:first(PidTable), pids_count_original = table_size(PidTable) },
            case table_size(PidTable) of
                0 ->
                    error_logger:error_msg(
                        "~p zero PIDs for ~p, disconnected.\n",
                        [?MODULE, Supervisor]),
                    schedule_reconnect(ReconnectDelay),
                    StateNew#state{ connected = false };
                _ ->
                    StateNew#state{ connected = true }
            end
    end.

schedule_reconnect(Delay) ->
    error_logger:error_msg("~p trying to reconnect in ~p ms.\n", [?MODULE, Delay]),
    erlang:send_after(Delay, self(), connect).


table_size(Table) ->
        {size, Count} = proplists:lookup(size, ets:info(Table)),
        Count.
