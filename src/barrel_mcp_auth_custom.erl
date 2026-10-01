%%%-------------------------------------------------------------------
%%% @doc Custom authentication provider for barrel_mcp.
%%%
%%% Allows using a custom module for authentication without implementing
%%% the full barrel_mcp_auth behaviour. The custom module only needs to
%%% export two functions:
%%%
%%% <ul>
%%%   <li>`init(Opts) -> {ok, State}' - Initialize auth state</li>
%%%   <li>`authenticate(Token, State) -> {ok, AuthInfo, State} | {error, Reason, State}'</li>
%%% </ul>
%%%
%%% It may also export `visible(Kind, {Name, Handler}, AuthInfo, State)
%%% -> boolean()' to choose which registry entries a caller sees in list
%%% responses; see `barrel_mcp_auth:visible/4'. And
%%% `authorize_subscribe(AuthInfo, Uri, State) -> boolean()' to decide
%%% which resources a caller may subscribe to; see
%%% `barrel_mcp_auth:authorize_subscribe/3'.
%%%
%%% == Usage ==
%%%
%%% ```
%%% barrel_mcp:start_http(#{
%%%     port => 9090,
%%%     auth => #{
%%%         provider => barrel_mcp_auth_custom,
%%%         provider_opts => #{
%%%             module => my_auth_module
%%%         }
%%%     }
%%% }).
%%% '''
%%%
%%% The custom module:
%%%
%%% ```
%%% -module(my_auth_module).
%%% -export([init/1, authenticate/2]).
%%%
%%% init(_Opts) ->
%%%     {ok, #{}}.
%%%
%%% authenticate(Token, State) ->
%%%     case validate_token(Token) of
%%%         {ok, Info} -> {ok, Info, State};
%%%         error -> {error, invalid_token, State}
%%%     end.
%%% '''
%%%
%%% The state returned by `authenticate/2' is discarded: the provider
%%% is called with the state `init/1' produced on every request, so
%%% anything that has to persist across requests belongs in a process
%%% or table of the module's own.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_auth_custom).

-behaviour(barrel_mcp_auth).

-export([init/1, authenticate/2, challenge/2, visible/4, authorize_subscribe/3]).

%%====================================================================
%% barrel_mcp_auth callbacks
%%====================================================================

%% @doc Initialize the custom auth provider.
%% Expects `module' key in Opts pointing to the custom auth module.
-spec init(map()) -> {ok, map()}.
init(#{module := Module} = Opts) ->
    ModuleOpts = maps:get(module_opts, Opts, #{}),
    case Module:init(ModuleOpts) of
        {ok, ModuleState} ->
            {ok, #{module => Module, module_state => ModuleState}};
        {error, Reason} ->
            {error, Reason}
    end;
init(_Opts) ->
    {error, missing_module}.

%% @doc Authenticate request by extracting token and calling custom module.
-spec authenticate(map(), map()) -> {ok, map()} | {error, term()}.
authenticate(Request, #{module := Module, module_state := ModuleState}) ->
    Headers = maps:get(headers, Request, #{}),
    case extract_token(Headers) of
        {ok, Token} ->
            case Module:authenticate(Token, ModuleState) of
                {ok, AuthInfo, _} when is_map(AuthInfo) ->
                    {ok, normalize_auth_info(AuthInfo)};
                {error, Reason, _} ->
                    {error, Reason};
                Other ->
                    %% A shape the contract does not name is a failure,
                    %% not a pass with an unknown subject.
                    {error, {invalid_auth_result, Other}}
            end;
        {error, _} ->
            {error, unauthorized}
    end.

%% @doc Generate challenge response for failed authentication.
-spec challenge(term(), map()) -> {integer(), map(), binary()}.
challenge(_Reason, _State) ->
    {401, #{<<"www-authenticate">> => <<"Bearer realm=\"mcp\"">>}, <<>>}.

%% @doc Ask the custom module whether this caller sees a registry entry,
%% when it exports `visible/4'. Every entry is visible otherwise.
-spec visible(atom(), {binary(), map()}, map(), map()) -> boolean().
visible(Kind, Entry, AuthInfo, #{module := Module, module_state := ModuleState}) ->
    _ = code:ensure_loaded(Module),
    case erlang:function_exported(Module, visible, 4) of
        true -> Module:visible(Kind, Entry, AuthInfo, ModuleState);
        false -> true
    end.

%% @doc Ask the custom module whether this caller may subscribe to
%% `Uri', when it exports `authorize_subscribe/3'. Every subscription
%% is accepted otherwise.
-spec authorize_subscribe(map(), binary(), map()) -> boolean().
authorize_subscribe(AuthInfo, Uri, #{module := Module, module_state := ModuleState}) ->
    _ = code:ensure_loaded(Module),
    case erlang:function_exported(Module, authorize_subscribe, 3) of
        true -> Module:authorize_subscribe(AuthInfo, Uri, ModuleState);
        false -> true
    end.

%%====================================================================
%% Internal functions
%%====================================================================

%% Extract token from headers (Bearer or X-API-Key)
extract_token(Headers) ->
    case barrel_mcp_auth:extract_bearer_token(Headers) of
        {ok, Token} ->
            {ok, Token};
        {error, no_token} ->
            barrel_mcp_auth:extract_api_key(Headers, #{})
    end.

%% Normalize auth info to expected format
normalize_auth_info(AuthInfo) when is_map(AuthInfo) ->
    #{
        subject => maps:get(subject, AuthInfo, maps:get(<<"subject">>, AuthInfo, <<"unknown">>)),
        scopes => maps:get(scopes, AuthInfo, maps:get(<<"scopes">>, AuthInfo, [])),
        claims => AuthInfo
    }.
