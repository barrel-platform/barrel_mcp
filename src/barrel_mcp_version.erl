%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Protocol revision comparison.
%%%
%%% Revisions are an enumerated set, not an ordered scalar. Today's
%%% identifiers are date-shaped and so happen to sort lexicographically,
%%% but a future one need not be, and a string from a peer we do not
%%% recognise must not accidentally compare as newer than everything we
%%% know. `<<"zzz">> > <<"2025-11-25">>' is true and meaningless.
%%%
%%% Every ordering question therefore goes through the registry in
%%% `barrel_mcp.hrl' rather than through term comparison. An unknown
%%% revision is treated conservatively: it satisfies no minimum.
%%%
%%% This mirrors the reference Python SDK's version module, which
%%% reaches the same conclusion for the same reason.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_version).

-include("barrel_mcp.hrl").

-export([is_known/1, is_at_least/2, era/1, all/0, feature/2]).

%% @doc Whether this is a revision the library knows about at all.
-spec is_known(binary()) -> boolean().
is_known(Version) when is_binary(Version) ->
    lists:member(Version, ?MCP_KNOWN_VERSIONS);
is_known(_Version) ->
    false.

%% @doc Whether `Version' is a known revision at least as new as
%% `Minimum'. Use this to gate anything on a revision rather than
%% comparing the binaries.
%%
%% An unknown `Version' returns `false': we cannot place it, so we do
%% not assume it is new enough. An unknown `Minimum' is a bug in the
%% caller, not a runtime condition, so it raises.
-spec is_at_least(binary(), binary()) -> boolean().
is_at_least(Version, Minimum) ->
    case lists:member(Minimum, ?MCP_KNOWN_VERSIONS) of
        false ->
            error({unknown_minimum_version, Minimum});
        true ->
            index_of(Version) >= index_of(Minimum)
    end.

%% @doc Which era a revision belongs to, or `unknown'.
-spec era(binary()) -> legacy | modern | unknown.
era(Version) when is_binary(Version) ->
    case
        {
            lists:member(Version, ?MCP_MODERN_VERSIONS),
            lists:member(Version, ?MCP_LEGACY_VERSIONS)
        }
    of
        {true, _} -> modern;
        {_, true} -> legacy;
        _ -> unknown
    end;
era(_Version) ->
    unknown.

%% @doc Every revision this library speaks, newest first.
-spec all() -> [binary()].
all() ->
    ?MCP_ALL_VERSIONS.

%% Position in the oldest-to-newest registry; -1 places an unknown
%% revision before everything, so it satisfies no minimum.
index_of(Version) ->
    index_of(Version, ?MCP_KNOWN_VERSIONS, 0).

index_of(Version, [Version | _Rest], N) -> N;
index_of(Version, [_Other | Rest], N) -> index_of(Version, Rest, N + 1);
index_of(_Version, [], _N) -> -1.

%%====================================================================
%% Feature gating
%%====================================================================

%% @doc Whether a revision has a feature.
%%
%% Not every feature is monotonic, so this cannot be a threshold on
%% `is_at_least/2'. Batching is required at 2025-03-26 and removed at
%% 2025-06-18; tasks move from the core protocol into an extension.
%% A table states each one exactly.
%%
%% `compatibility' means the revision does not require the feature and
%% does not forbid it either, and we choose to accept it. `undefined'
%% for a revision that has not been negotiated yet answers `disabled':
%% we cannot know what the peer speaks, and guessing wrong on the
%% permissive side is what a limit exists to prevent.
-spec feature(atom(), binary() | undefined) -> enabled | compatibility | disabled.
feature(_Feature, undefined) ->
    disabled;
%% JSON-RPC batches. 2024-11-05 says nothing about them, so accepting
%% them there is our choice rather than a requirement.
feature(batch_receive, <<"2024-11-05">>) ->
    compatibility;
feature(batch_receive, <<"2025-03-26">>) ->
    enabled;
feature(batch_receive, _Revision) ->
    disabled;
feature(_Feature, _Revision) ->
    disabled.
