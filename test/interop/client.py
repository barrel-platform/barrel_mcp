"""Direction A — Python MCP client against a barrel_mcp server.

Invoked by `barrel_mcp_python_interop_SUITE:python_client_against_erlang_server/1`.
The CT case starts a Streamable HTTP server, registers a known
fixture (echo tool, sample resource, sample prompt), then runs
this script with the URL as argv[1]. We exit 0 on success and
print a single ``FAIL: <reason>`` line + exit non-zero otherwise.
"""

from __future__ import annotations

import asyncio
import sys
import traceback

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from mcp.types import CreateMessageResult, TextContent


EXPECTED_TOOL = "echo"
EXPECTED_RESOURCE_URI = "mem://greeting"
EXPECTED_PROMPT = "hello_prompt"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


SAMPLED_REPLY = "the canned answer"


async def sampling_callback(_context, _params):
    """Server-to-client sampling/createMessage handler. Returns a
    canned reply so the round-trip is deterministic in CI."""
    return CreateMessageResult(
        role="assistant",
        content=TextContent(type="text", text=SAMPLED_REPLY),
        model="canned-test-model",
    )


async def run(url: str) -> None:
    update_event = asyncio.Event()

    async def on_message(message):
        # ClientSession dispatches inbound notifications to this
        # handler. We only care about the resources/updated stream
        # for the subscribe round-trip.
        from mcp.types import (
            ServerNotification,
            ResourceUpdatedNotification,
        )
        if isinstance(message, ServerNotification):
            inner = message.root
            if isinstance(inner, ResourceUpdatedNotification):
                if str(inner.params.uri) == EXPECTED_RESOURCE_URI:
                    update_event.set()

    async with streamable_http_client(url) as (read, write, _):
        async with ClientSession(
            read, write,
            message_handler=on_message,
            sampling_callback=sampling_callback,
        ) as session:
            await session.initialize()

            tools = await session.list_tools()
            names = [t.name for t in tools.tools]
            if EXPECTED_TOOL not in names:
                fail(f"echo tool missing from list_tools: {names}")

            result = await session.call_tool(
                EXPECTED_TOOL, arguments={"text": "hello"}
            )
            text_blocks = [b for b in result.content if getattr(b, "text", None)]
            if not text_blocks:
                fail(f"call_tool returned no text content: {result.content}")
            if text_blocks[0].text != "hello":
                fail(f"echo did not round-trip: {text_blocks[0].text!r}")

            resources = await session.list_resources()
            uris = [str(r.uri) for r in resources.resources]
            if EXPECTED_RESOURCE_URI not in uris:
                fail(f"sample resource missing from list_resources: {uris}")

            read_result = await session.read_resource(EXPECTED_RESOURCE_URI)
            if not read_result.contents:
                fail("read_resource returned empty contents")

            prompts = await session.list_prompts()
            prompt_names = [p.name for p in prompts.prompts]
            if EXPECTED_PROMPT not in prompt_names:
                fail(f"sample prompt missing from list_prompts: {prompt_names}")

            await session.set_logging_level("warning")

            # Tasks: list_tasks and get_task validate the wire shape
            # (taskId, status, createdAt, lastUpdatedAt, ttl) against
            # the reference pydantic models, even if the registry is
            # empty.
            tasks_list = await session.experimental.list_tasks()
            if not isinstance(tasks_list.tasks, list):
                fail(f"list_tasks did not return a list: {tasks_list}")

            # Subscribe / notifications/resources/updated round-trip.
            # subscribe -> trigger -> wait for the notification.
            await session.subscribe_resource(EXPECTED_RESOURCE_URI)
            await session.call_tool("trigger_update", arguments={})
            try:
                await asyncio.wait_for(update_event.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                fail("did not receive notifications/resources/updated")
            await session.unsubscribe_resource(EXPECTED_RESOURCE_URI)

            # Server-to-client sampling round-trip. The server's
            # ask_llm tool sends sampling/createMessage to us; our
            # sampling_callback returns SAMPLED_REPLY; the tool
            # surfaces that text as its result.
            sampling_result = await session.call_tool(
                "ask_llm", arguments={}
            )
            text_blocks = [
                b for b in sampling_result.content
                if getattr(b, "text", None)
            ]
            if not text_blocks or text_blocks[0].text != SAMPLED_REPLY:
                fail(f"sampling round-trip failed: {sampling_result}")

    print("OK")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: client.py <server-url>")
    url = sys.argv[1]
    try:
        asyncio.run(run(url))
    except Exception:
        traceback.print_exc()
        fail("unhandled exception")


if __name__ == "__main__":
    main()
