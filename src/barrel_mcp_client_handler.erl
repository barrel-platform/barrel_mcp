%%%-------------------------------------------------------------------
%%% @doc Behaviour for handling server-initiated MCP messages.
%%%
%%% A host application implements this module to react to requests
%%% the server sends *to* the client (per the declared client
%%% capabilities) and to notifications the server emits.
%%%
%%% Capabilities and the matching callbacks:
%%% <ul>
%%%   <li>`sampling': server may call `sampling/createMessage' to ask
%%%       the host to run an LLM completion.</li>
%%%   <li>`roots': server may call `roots/list' to enumerate the
%%%       filesystem boundaries the host exposes.</li>
%%%   <li>`elicitation': server may call `elicitation/create' to
%%%       prompt the user for a value.</li>
%%% </ul>
%%%
%%% Notifications cover the rest of the spec: `notifications/cancelled',
%%% `notifications/progress', `notifications/resources/updated',
%%% `notifications/resources/list_changed', `notifications/tools/list_changed',
%%% `notifications/prompts/list_changed', `notifications/message'.
%%%
%%% A default implementation in `barrel_mcp_client_handler_default'
%%% returns `method_not_found' for every request and ignores every
%%% notification, so a host only writes callbacks for capabilities it
%%% actually declares.
%%%
%%% Async replies: when answering a request requires a long-running
%%% operation (e.g. an HTTP call to an LLM provider), return
%%% `{async, Tag, State}' from `handle_request/3' and later send
%%% `barrel_mcp_client:reply_async(ClientPid, Tag, Result)' from any
%%% process. The client's state machine will not block while the
%%% handler is computing.
%%%
%%% == Example ==
%%%
%%% A handler that answers `sampling/createMessage' synchronously:
%%%
%%% ```
%%% -module(my_sampler).
%%% -behaviour(barrel_mcp_client_handler).
%%% -export([init/1, handle_request/3, handle_notification/3,
%%%          terminate/2]).
%%%
%%% init(Args) -> {ok, Args}.
%%%
%%% handle_request(<<"sampling/createMessage">>, Params, S) ->
%%%     Reply = call_my_llm(Params),  %% your provider integration
%%%     Result = #{<<"content">> => #{<<"type">> => <<"text">>,
%%%                                    <<"text">> => Reply},
%%%                <<"model">> => <<"my-model">>,
%%%                <<"role">> => <<"assistant">>},
%%%     {reply, Result, S};
%%% handle_request(Method, _Params, S) ->
%%%     {error, -32601, <<"Method not found: ", Method/binary>>, S}.
%%%
%%% handle_notification(_Method, _Params, S) -> {ok, S}.
%%% terminate(_Reason, _State) -> ok.
%%% '''
%%%
%%% Wire the handler in via the connect spec:
%%% `#{handler => {my_sampler, []}}'.
%%%
%%% See `examples/sampling_host/' for a runnable end-to-end version.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_handler).

-export_type([state/0, async_tag/0, url_elicitation/0]).

-type state() :: term().
-type async_tag() :: term().

%% `url' is the full URL, which MUST be shown to the user before
%% consent; `host' is it reduced to its domain, for display and logging.
-type url_elicitation() :: #{
    url := binary(),
    host := binary(),
    message := binary(),
    %% 2025-11-25 only.
    elicitation_id => binary()
}.

-callback init(Args :: term()) -> {ok, state()} | {error, term()}.

-callback handle_request(
    Method :: binary(),
    Params :: map(),
    State :: state()
) ->
    {reply, Result :: term(), state()}
    | {error, Code :: integer(), Message :: binary(), state()}
    | {async, async_tag(), state()}.

-callback handle_notification(
    Method :: binary(),
    Params :: map(),
    State :: state()
) -> {ok, state()}.

%% URL-mode elicitation, which never reaches `handle_request/3': form
%% mode collects data, this sends the user to a page the client must not
%% see, and one must not be answered as the other.
%%
%% The client "MUST NOT open the URL without explicit consent from the
%% user", "MUST show the full URL to the user for examination before
%% consent", and "MUST NOT automatically pre-fetch the URL or any of its
%% metadata" (2025-11-25/client/elicitation.mdx:726). Returning `accept'
%% asserts a user agreed; opening the URL is the host's job.
%%
%% Not implementing this declines every URL elicitation.
-callback handle_elicitation_url(
    Request :: url_elicitation(),
    State :: state()
) ->
    {accept, state()}
    | {decline, state()}
    | {cancel, state()}
    | {async, async_tag(), state()}.

-callback terminate(Reason :: term(), State :: state()) -> any().

-optional_callbacks([terminate/2, handle_elicitation_url/2]).
