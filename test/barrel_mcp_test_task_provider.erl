%%%-------------------------------------------------------------------
%%% @doc A task provider over an ETS table the test owns, standing in
%%% for a host that journals its work. The table is held by a process
%%% outside the application, so its tasks survive a restart of
%%% `barrel_mcp'.
%%%
%%% Also the `hosted' tool's handler: `mode' picks what it hands back.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_test_task_provider).

-behaviour(barrel_mcp_task_provider).

-export([get/2, cancel/2, update/3, list/1]).
-export([start_table/0, stop_table/1, new/2, set/2, updates/1, hosted/2]).

-define(TAB, barrel_mcp_test_task_provider_tab).

%%====================================================================
%% Table
%%====================================================================

start_table() ->
    Self = self(),
    Pid = spawn(fun() ->
        _ = ets:new(?TAB, [named_table, public, set]),
        Self ! {table_ready, self()},
        receive
            stop -> ok
        end
    end),
    receive
        {table_ready, Pid} -> Pid
    end.

stop_table(Pid) ->
    Pid ! stop,
    ok.

new(Owner, Fields) ->
    Id = <<"exec_", (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary>>,
    Now = erlang:system_time(millisecond),
    Task = maps:merge(
        #{
            id => Id,
            status => working,
            created_at => Now,
            updated_at => Now,
            ttl_ms => 60000,
            poll_interval_ms => 250
        },
        Fields
    ),
    true = ets:insert(?TAB, {Id, barrel_mcp_tasks:principal(Owner), Owner, Task, #{}}),
    Id.

%% @doc Change a task the way the host would, and announce it.
set(Id, Fields) ->
    [{Id, P, Owner, Task, Extra}] = ets:lookup(?TAB, Id),
    Updated = maps:merge(Task, Fields#{updated_at => erlang:system_time(millisecond)}),
    true = ets:insert(?TAB, {Id, P, Owner, Updated, Extra}),
    barrel_mcp_tasks:changed(?MODULE, Owner, Id).

%% @doc Every `inputResponses' map `update/3' received, oldest first.
updates(Id) ->
    [{Id, _, _, _, Extra}] = ets:lookup(?TAB, Id),
    lists:reverse(maps:get(updates, Extra, [])).

%%====================================================================
%% Provider
%%====================================================================

get(Owner, Id) ->
    case held(Owner, Id) of
        {ok, _Owner, Task, _Extra} -> {ok, Task};
        not_found -> {error, not_found}
    end.

%% Cooperative: a task asked to finish on cancel still completes.
cancel(Owner, Id) ->
    case held(Owner, Id) of
        {ok, _, #{on_cancel := completed}, _} ->
            spawn(fun() ->
                set(Id, #{status => completed, result => text(<<"finished anyway">>)})
            end),
            ok;
        {ok, _, _, _} ->
            set(Id, #{status => cancelled});
        not_found ->
            {error, not_found}
    end.

%% The host decides when the task leaves input_required: here, as soon
%% as the one question it asked is answered.
update(Owner, Id, Responses) ->
    case held(Owner, Id) of
        {ok, O, Task, Extra} ->
            P = barrel_mcp_tasks:principal(O),
            Seen = [Responses | maps:get(updates, Extra, [])],
            true = ets:insert(?TAB, {Id, P, O, Task, Extra#{updates => Seen}}),
            case maps:find(<<"who">>, Responses) of
                {ok, #{<<"content">> := #{<<"name">> := Name}}} ->
                    spawn(fun() ->
                        set(Id, #{
                            status => completed,
                            result => text(<<"hello ", Name/binary>>),
                            input_requests => #{}
                        })
                    end),
                    ok;
                _ ->
                    ok
            end;
        not_found ->
            {error, not_found}
    end.

list(Owner) ->
    P = barrel_mcp_tasks:principal(Owner),
    [T || {_, TP, _, T, _} <- ets:tab2list(?TAB), TP =:= P].

held(Owner, Id) ->
    P = barrel_mcp_tasks:principal(Owner),
    case ets:lookup(?TAB, Id) of
        [{Id, P, O, Task, Extra}] -> {ok, O, Task, Extra};
        _ -> not_found
    end.

%%====================================================================
%% The tool
%%====================================================================

hosted(Args, Ctx) ->
    Owner = barrel_mcp:task_owner(Ctx),
    case maps:get(<<"mode">>, Args, <<"working">>) of
        <<"plain">> ->
            <<"plain">>;
        <<"auto">> ->
            case barrel_mcp:task_allowed(Ctx) of
                true -> {task, new(Owner, #{})};
                false -> <<"no task">>
            end;
        <<"force">> ->
            {task, new(Owner, #{})};
        <<"working">> ->
            {task, new(Owner, #{})};
        <<"done">> ->
            {task, new(Owner, #{status => completed, result => text(<<"done">>)})};
        <<"cancel_completes">> ->
            {task, new(Owner, #{on_cancel => completed})};
        <<"input">> ->
            {task,
                new(Owner, #{
                    status => input_required,
                    input_requests => #{
                        <<"who">> => #{
                            <<"method">> => <<"elicitation/create">>,
                            <<"params">> => #{<<"message">> => <<"Your name?">>}
                        }
                    }
                })}
    end.

text(T) ->
    #{<<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => T}]}.
