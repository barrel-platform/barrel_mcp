"""Direction B — Python FastMCP server over stdio.

Spawned by `barrel_mcp_python_interop_SUITE:erlang_client_against_python_server/1`.
Exposes a tool, a resource, and a prompt so the Erlang client can
exercise tools/call, resources/read, prompts/get, and ping in one
round-trip.
"""

from __future__ import annotations

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.prompts import base


mcp = FastMCP("barrel-mcp-interop")


@mcp.tool()
def echo(text: str) -> str:
    """Echo the input text back unchanged."""
    return text


@mcp.resource("mem://greeting")
def greeting() -> str:
    """Sample text resource."""
    return "hello, world"


@mcp.prompt()
def hello_prompt(who: str = "world") -> list[base.Message]:
    """Greet someone."""
    return [base.UserMessage(f"hello, {who}")]


if __name__ == "__main__":
    mcp.run(transport="stdio")
