"""Direction A (HTTP+SSE): Python MCP SDK v1 over the deprecated transport.

Invoked by `barrel_mcp_python_interop_SUITE:sse_python_client_against_erlang_server/1`.
The CT case starts a listener with the two deprecated routes configured
and runs this script with the SSE URL as argv[1]. We exit 0 on success
and print a single ``FAIL: <reason>`` line + exit non-zero otherwise.

This is the transport Streamable HTTP replaced: the client opens a GET
stream, the server's first event names a POST endpoint, and every answer
comes back on the stream. Nothing here knows the endpoint in advance,
which is the point. Transport and revision are separate axes, so the
SDK still negotiates its own latest here.
"""

from __future__ import annotations

import sys
import traceback

import anyio
from mcp import ClientSession
from mcp.client.sse import sse_client

EXPECTED_TOOL = "echo"
EXPECTED_RESOURCE_URI = "mem://greeting"

#: What the v1 SDK asks for; the deprecated transport must not change it.
EXPECTED_VERSION = "2025-11-25"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


async def run(url: str) -> None:
    async with sse_client(url) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()

            if init.protocolVersion != EXPECTED_VERSION:
                fail(f"negotiated {init.protocolVersion!r}, wanted {EXPECTED_VERSION}")

            caps = init.capabilities.model_dump(exclude_none=True)
            if "tools" not in caps:
                fail(f"server did not advertise tools: {sorted(caps)}")

            names = []
            pages = 0
            cursor = None
            while True:
                page = await session.list_tools(cursor=cursor)
                names.extend(t.name for t in page.tools)
                pages += 1
                cursor = page.nextCursor
                if cursor is None:
                    break
            if pages < 2:
                fail(f"the fixture paginates, but tools/list came back in {pages} page")
            if EXPECTED_TOOL not in names:
                fail(f"tools/list missing {EXPECTED_TOOL}: {names}")

            result = await session.call_tool(EXPECTED_TOOL, {"text": "over sse"})
            if result.content[0].text != "over sse":
                fail(f"tools/call echoed {result.content[0].text!r}")

            read_result = await session.read_resource(EXPECTED_RESOURCE_URI)
            if read_result.contents[0].text != "hello, world":
                fail(f"resources/read returned {read_result.contents[0].text!r}")

            prompt = await session.get_prompt("hello_prompt", {"who": "sse"})
            if prompt.messages[0].content.text != "hello, sse":
                fail(f"prompts/get returned {prompt.messages[0].content.text!r}")

            # A second exchange proves the stream stayed usable rather
            # than being consumed by the first answer.
            again = await session.call_tool(EXPECTED_TOOL, {"text": "again"})
            if again.content[0].text != "again":
                fail(f"second call echoed {again.content[0].text!r}")

    print("OK")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: client_sse.py <sse-url>")
    try:
        anyio.run(run, sys.argv[1])
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc()
        fail("unhandled exception")


if __name__ == "__main__":
    main()
