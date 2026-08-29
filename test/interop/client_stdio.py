"""Direction A (stdio): Python MCP SDK v1 against the barrel_mcp stdio server.

Invoked by `barrel_mcp_python_interop_SUITE:stdio_python_client_against_erlang_server/1`.
The CT case passes the command that boots `barrel_mcp_stdio_child` as
argv[1:]. We exit 0 on success and print a single ``FAIL: <reason>``
line + exit non-zero otherwise.

Framing is the thing under test: newline-delimited JSON over a real OS
pipe, in both directions, with a server-initiated notification arriving
while the client is idle.
"""

from __future__ import annotations

import os
import sys
import traceback

import anyio
import mcp.types as types
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from pydantic import AnyUrl

WATCHED = "file:///watched"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


async def run(command: str, args: list[str]) -> None:
    updates = anyio.Event()

    async def on_message(message) -> None:
        root = getattr(message, "root", None)
        if isinstance(root, types.ResourceUpdatedNotification):
            if str(root.params.uri) == WATCHED:
                updates.set()

    params = StdioServerParameters(command=command, args=args, env=dict(os.environ))
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write, message_handler=on_message) as session:
            init = await session.initialize()
            if init.protocolVersion != types.LATEST_PROTOCOL_VERSION:
                fail(f"negotiated {init.protocolVersion!r}")
            if init.serverInfo.name != "barrel":
                fail(f"unexpected server name {init.serverInfo.name!r}")

            tools = await session.list_tools()
            names = sorted(t.name for t in tools.tools)
            if names != ["echo", "touch"]:
                fail(f"tools/list returned {names}")

            result = await session.call_tool("echo", {"input": "over stdio"})
            if result.content[0].text != "Echo: over stdio":
                fail(f"tools/call echoed {result.content[0].text!r}")

            # A payload larger than one pipe buffer: the framing has to
            # survive a write the OS splits.
            big = "x" * 200_000
            result = await session.call_tool("echo", {"input": big})
            if result.content[0].text != f"Echo: {big}":
                fail(f"large echo came back {len(result.content[0].text)} bytes")

            resource = await session.read_resource(AnyUrl(WATCHED))
            if resource.contents[0].text != "body":
                fail(f"resources/read returned {resource.contents[0].text!r}")

            await session.subscribe_resource(AnyUrl(WATCHED))
            await session.call_tool("touch", {})
            with anyio.fail_after(10):
                await updates.wait()

            await session.unsubscribe_resource(AnyUrl(WATCHED))

    print("OK")


def main() -> None:
    if len(sys.argv) < 2:
        fail("usage: client_stdio.py <command> [args...]")
    try:
        anyio.run(run, sys.argv[1], sys.argv[2:])
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc()
        fail("unhandled exception")


if __name__ == "__main__":
    main()
