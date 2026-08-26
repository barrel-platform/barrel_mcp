%%%-------------------------------------------------------------------
%%% @doc JSON Schema validation for MCP tool inputs and outputs.
%%%
%%% A thin name over {@link barrel_mcp_jsonschema}, which implements the
%%% 2020-12 dialect MCP uses. Kept because it is what the registry and
%%% every caller already name.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_schema).

-export([validate/2]).

-type error() :: barrel_mcp_jsonschema:error().

-export_type([error/0]).

%% @doc Validate `Value' against `Schema'. Returns `ok' or
%% `{error, [Error]}' where each error is `{Path, Reason}'.
-spec validate(term(), map()) -> ok | {error, [error()]}.
validate(Value, Schema) when is_map(Schema) ->
    barrel_mcp_jsonschema:validate(Value, Schema);
validate(_Value, _Schema) ->
    {error, [{[], invalid_schema}]}.
