%%%-------------------------------------------------------------------
%%% @doc Behaviour for handling server-initiated MCP messages.
%%%
%%% A host application implements this module to react to requests
%%% the server sends *to* the client (per the declared client
%%% capabilities) and to notifications the server emits.
%%%
%%% Capabilities and the matching callbacks:
%%% <ul>
%%%   <li>`sampling' — server may call `sampling/createMessage' to ask
%%%       the host to run an LLM completion.</li>
%%%   <li>`roots'    — server may call `roots/list' to enumerate the
%%%       filesystem boundaries the host exposes.</li>
%%%   <li>`elicitation' — server may call `elicitation/create' to
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
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_handler).

-export_type([state/0, async_tag/0]).

-type state() :: term().
-type async_tag() :: term().

-callback init(Args :: term()) -> {ok, state()} | {error, term()}.

-callback handle_request(Method :: binary(),
                         Params :: map(),
                         State :: state()) ->
    {reply, Result :: term(), state()} |
    {error, Code :: integer(), Message :: binary(), state()} |
    {async, async_tag(), state()}.

-callback handle_notification(Method :: binary(),
                              Params :: map(),
                              State :: state()) -> {ok, state()}.

-callback terminate(Reason :: term(), State :: state()) -> any().

-optional_callbacks([terminate/2]).
