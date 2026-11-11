#!/bin/sh
# The fixture as a standalone Streamable HTTP server, for the MCP
# project's SDK runner. Listens on MCP_CONFORMANCE_PORT (default 3000).
# Needs `rebar3 as test compile' first.
root=$(cd "$(dirname "$0")/../.." && pwd)
exec erl -noshell -boot no_dot_erlang \
    -kernel logger '[{handler,default,logger_std_h,#{config=>#{type=>standard_error}}}]' \
    -pa "$root"/_build/test/lib/*/ebin "$root"/_build/test/lib/barrel_mcp/test \
    -eval 'barrel_mcp_conformance_server:main()'
