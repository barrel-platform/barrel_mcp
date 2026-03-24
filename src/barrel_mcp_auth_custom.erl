%%%-------------------------------------------------------------------
%%% @doc Custom authentication provider for barrel_mcp.
%%%
%%% Allows using a custom module for authentication without implementing
%%% the full barrel_mcp_auth behaviour. The custom module only needs to
%%% export two functions:
%%%
%%% <ul>
%%%   <li>`init(Opts) -> {ok, State}' - Initialize auth state</li>
%%%   <li>`authenticate(Token, State) -> {ok, AuthInfo, NewState} | {error, Reason, NewState}'</li>
%%% </ul>
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
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_auth_custom).

-behaviour(barrel_mcp_auth).

-export([init/1, authenticate/2, challenge/2]).

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
authenticate(Request, #{module := Module, module_state := ModuleState} = State) ->
    Headers = maps:get(headers, Request, #{}),
    case extract_token(Headers) of
        {ok, Token} ->
            case Module:authenticate(Token, ModuleState) of
                {ok, AuthInfo, NewModuleState} ->
                    %% Store updated state (though HTTP is stateless per-request)
                    put(barrel_mcp_auth_custom_state, State#{module_state => NewModuleState}),
                    {ok, normalize_auth_info(AuthInfo)};
                {error, Reason, _NewModuleState} ->
                    {error, Reason}
            end;
        {error, _} ->
            {error, unauthorized}
    end.

%% @doc Generate challenge response for failed authentication.
-spec challenge(term(), map()) -> {integer(), map(), binary()}.
challenge(_Reason, _State) ->
    {401, #{<<"www-authenticate">> => <<"Bearer realm=\"mcp\"">>}, <<>>}.

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
    };
normalize_auth_info(_) ->
    #{subject => <<"unknown">>, scopes => [], claims => #{}}.
