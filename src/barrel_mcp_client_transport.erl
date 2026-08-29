%%%-------------------------------------------------------------------
%%% @doc Transport behaviour for `barrel_mcp_client'.
%%%
%%% A transport owns the underlying socket/port/process and forwards
%%% inbound JSON-RPC messages to the owning client gen_statem. The
%%% client never reads the wire directly; it only sends/closes through
%%% this behaviour and consumes asynchronous messages of the form:
%%%
%%% <ul>
%%%   <li>`{mcp_in: TransportPid, JsonBinary}', one decoded JSON-RPC
%%%       envelope arrived from the peer.</li>
%%%   <li>`{mcp_closed: TransportPid, Reason}', the transport ended
%%%       (peer hung up, port exited, etc.).</li>
%%% </ul>
%%%
%%% Transports MUST deliver one envelope per `mcp_in' message; framing
%%% (line splitting, SSE parsing) is the transport's responsibility.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_transport).

-export([send/2, close/1, cancel_request/2]).

-type t() :: {module(), pid()}.
-export_type([t/0]).

%% Open a transport. `Owner' will receive `mcp_in' / `mcp_closed'
%% messages from the spawned transport process.
-callback connect(Owner :: pid(), Opts :: map()) ->
    {ok, pid()} | {error, term()}.

%% Send a fully-encoded JSON-RPC envelope (binary JSON) to the peer.
%% Implementations may add transport framing (newline, SSE) but must
%% not modify the JSON content.
-callback send(TransportPid :: pid(), JsonBinary :: iodata()) ->
    ok | {error, term()}.

%% Close the transport.
-callback close(TransportPid :: pid()) -> ok.

%% Cancel one in-flight request by tearing down its channel. Streamable
%% HTTP has one; stdio does not, and sends `notifications/cancelled'
%% instead (2026-07-28/basic/patterns/cancellation.mdx:38).
-callback cancel_request(
    TransportPid :: pid(),
    RequestId :: integer() | binary()
) -> ok.

-optional_callbacks([cancel_request/2]).

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Convenience wrapper to send through any transport handle.
-spec send(t(), iodata()) -> ok | {error, term()}.
send({Mod, Pid}, Body) ->
    Mod:send(Pid, Body).

%% @doc Convenience wrapper to close any transport handle.
-spec close(t()) -> ok.
close({Mod, Pid}) ->
    Mod:close(Pid).

%% @doc Ask the transport to cancel one request. `unsupported' when it
%% has no per-request channel; the caller then sends the notification.
-spec cancel_request(t(), integer() | binary()) -> ok | unsupported.
cancel_request({Mod, Pid}, RequestId) ->
    _ = code:ensure_loaded(Mod),
    case erlang:function_exported(Mod, cancel_request, 2) of
        true ->
            Mod:cancel_request(Pid, RequestId),
            ok;
        false ->
            unsupported
    end.
