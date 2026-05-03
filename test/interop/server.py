"""Direction B — Python FastMCP server over stdio.

Spawned by `barrel_mcp_python_interop_SUITE:erlang_client_against_python_server/1`.
Registers a single ``echo`` tool. The Erlang client connects
over stdio, calls the tool, and verifies the round-trip.
"""

from __future__ import annotations

from mcp.server.fastmcp import FastMCP


mcp = FastMCP("barrel-mcp-interop")


@mcp.tool()
def echo(text: str) -> str:
    """Echo the input text back unchanged."""
    return text


if __name__ == "__main__":
    mcp.run(transport="stdio")
