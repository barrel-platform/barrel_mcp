"""Direction B (modern era): Python MCP SDK v2 server over stdio.

Spawned by
`barrel_mcp_python_interop_SUITE:modern_erlang_client_against_python_server/1`.
`barrel_mcp_client` connects with `protocol_version => auto`, which
probes `server/discover` here rather than sending `initialize`.

v2 replaced FastMCP with MCPServer, so this cannot share `server.py`
with the handshake-era direction.
"""

from __future__ import annotations

from mcp import types
from mcp.server.mcpserver import Context, MCPServer


server = MCPServer("barrel-mcp-interop-modern")


@server.tool()
def echo(text: str) -> str:
    """Echo the input text back unchanged."""
    return text


@server.resource("mem://greeting")
def greeting() -> str:
    """Sample text resource."""
    return "hello, world"


@server.prompt()
def hello_prompt(who: str = "world") -> str:
    """Greet someone."""
    return f"hello, {who}"


@server.tool()
async def greet(ctx: Context) -> types.CallToolResult | types.InputRequiredResult:
    """Ask who to greet, then greet them.

    A multi round-trip request built by the reference implementation, so
    the Erlang client's retry loop is driven by an envelope it had no
    hand in producing. `ctx.elicit()` is deliberately not used: it wants
    a back-channel, and a modern connection has none.
    """
    who = (ctx.input_responses or {}).get("who")
    if who is None:
        return types.InputRequiredResult(
            input_requests={
                "who": types.ElicitRequest(
                    method="elicitation/create",
                    params=types.ElicitRequestFormParams(
                        message="Who should I greet?",
                        requestedSchema={
                            "type": "object",
                            "properties": {"name": {"type": "string"}},
                        },
                    ),
                )
            },
            requestState="hello",
        )
    name = (getattr(who, "content", None) or {}).get("name", "nobody")
    return types.CallToolResult(
        content=[types.TextContent(type="text", text=f"{ctx.request_state}, {name}")]
    )


if __name__ == "__main__":
    server.run(transport="stdio")
