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
from mcp.types import (
    CallToolResult,
    CreateMessageResult,
    ElicitResult,
    ListRootsResult,
    Root,
    TextContent,
)
from pydantic import FileUrl


EXPECTED_TOOL = "echo"
EXPECTED_RESOURCE_URI = "mem://greeting"
EXPECTED_PROMPT = "hello_prompt"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


SAMPLED_REPLY = "the canned answer"
ELICITED_COLOUR = "blue"
ROOT_NAME = "interop-root"
ROOT_URI = "file:///tmp/interop"


async def sampling_callback(_context, _params):
    """Server-to-client sampling/createMessage handler. Returns a
    canned reply so the round-trip is deterministic in CI."""
    return CreateMessageResult(
        role="assistant",
        content=TextContent(type="text", text=SAMPLED_REPLY),
        model="canned-test-model",
    )


async def elicitation_callback(_context, _params):
    """Server-to-client elicitation/create handler. Always accepts
    with a fixed colour so the round-trip is deterministic."""
    return ElicitResult(action="accept", content={"colour": ELICITED_COLOUR})


async def list_roots_callback(_context):
    """Server-to-client roots/list handler. Returns one fixed root."""
    return ListRootsResult(
        roots=[Root(uri=FileUrl(ROOT_URI), name=ROOT_NAME)]
    )


async def run(url: str) -> None:
    update_event = asyncio.Event()
    tools_list_changed_event = asyncio.Event()
    task_status_seen: list[str] = []

    async def on_message(message):
        # ClientSession dispatches inbound notifications to this
        # handler. Capture the ones we want to assert on.
        from mcp.types import (
            ServerNotification,
            ResourceUpdatedNotification,
            ToolListChangedNotification,
        )
        try:
            from mcp.types import TaskStatusNotification
        except ImportError:
            TaskStatusNotification = None  # SDK below 1.27
        if isinstance(message, ServerNotification):
            inner = message.root
            if isinstance(inner, ResourceUpdatedNotification):
                if str(inner.params.uri) == EXPECTED_RESOURCE_URI:
                    update_event.set()
            elif isinstance(inner, ToolListChangedNotification):
                tools_list_changed_event.set()
            elif (
                TaskStatusNotification is not None
                and isinstance(inner, TaskStatusNotification)
            ):
                task_status_seen.append(inner.params.status)

    async with streamable_http_client(url) as (read, write, _):
        async with ClientSession(
            read, write,
            message_handler=on_message,
            sampling_callback=sampling_callback,
            elicitation_callback=elicitation_callback,
            list_roots_callback=list_roots_callback,
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

            # ping round-trip — trivial but exercises the wire end
            # to end.
            await session.send_ping()

            # prompts/get with arguments — verifies the prompt
            # template renders and returns the spec-shaped messages
            # array.
            prompt_result = await session.get_prompt(
                EXPECTED_PROMPT, arguments={"who": "interop"}
            )
            if not prompt_result.messages:
                fail(f"get_prompt returned no messages: {prompt_result}")

            # resources/templates/list — registered fixture has one
            # template (`file:///{path}`).
            templates = await session.list_resource_templates()
            template_uris = [
                t.uriTemplate for t in templates.resourceTemplates
            ]
            if "file:///{path}" not in template_uris:
                fail(f"resource template missing: {template_uris}")

            # completion/complete — registered for prompt
            # `hello_prompt` argument `who`.
            comp = await session.complete(
                ref={"type": "ref/prompt", "name": EXPECTED_PROMPT},
                argument={"name": "who", "value": "wo"},
            )
            if not comp.completion.values:
                fail(f"completion returned no values: {comp}")

            # Tool returning structuredContent.
            structured_result = await session.call_tool(
                "structured", arguments={}
            )
            if structured_result.structuredContent is None:
                fail(f"no structuredContent: {structured_result}")
            if structured_result.structuredContent.get("answer") != 42:
                fail(f"structured payload mismatch: {structured_result}")

            # Tool returning isError: true.
            err_result = await session.call_tool(
                "erroring", arguments={}
            )
            if not err_result.isError:
                fail(f"isError flag missing: {err_result}")

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

            # Server-to-client elicitation/create round-trip.
            elicit_result = await session.call_tool(
                "ask_user", arguments={}
            )
            text_blocks = [
                b for b in elicit_result.content
                if getattr(b, "text", None)
            ]
            if not text_blocks or text_blocks[0].text != ELICITED_COLOUR:
                fail(f"elicitation round-trip failed: {elicit_result}")

            # Server-to-client roots/list round-trip.
            roots_result = await session.call_tool(
                "list_roots", arguments={}
            )
            text_blocks = [
                b for b in roots_result.content
                if getattr(b, "text", None)
            ]
            if not text_blocks or text_blocks[0].text != ROOT_NAME:
                fail(f"roots round-trip failed: {roots_result}")

            # Long-running tool round-trip via experimental.call_tool_as_task.
            # Validates the CreateTaskResult immediate response shape,
            # the Task model returned by tasks/get, and that
            # tasks/result decodes as a CallToolResult.
            create_result = await session.experimental.call_tool_as_task(
                "slow_echo", arguments={"text": "from-task"}
            )
            task_id = create_result.task.taskId

            # Poll until terminal — slow_echo sleeps 100ms server-side.
            final = None
            for _ in range(50):
                final = await session.experimental.get_task(task_id)
                if final.status in ("completed", "failed", "cancelled"):
                    break
                await asyncio.sleep(0.05)
            if final is None or final.status != "completed":
                fail(f"task did not reach completed: {final}")

            payload = await session.experimental.get_task_result(
                task_id, CallToolResult
            )
            payload_text = [
                b.text for b in payload.content if getattr(b, "text", None)
            ]
            if not payload_text or "from-task" not in payload_text[0]:
                fail(f"tasks/result payload mismatch: {payload}")

            # Progress notifications round-trip. The server-side
            # progress_echo tool emits three events; the Python SDK
            # auto-attaches a progress token on call_tool and routes
            # the inbound notifications/progress to our callback.
            progress_seen = []

            async def progress_cb(progress, total, _message):
                progress_seen.append((progress, total))

            await session.call_tool(
                "progress_echo", arguments={},
                progress_callback=progress_cb,
            )
            # Progress events arrive on the GET SSE channel
            # asynchronously. call_tool returns when the POST
            # response lands, which can race with the last few
            # progress notifications. Wait briefly for the SSE pid
            # to drain.
            for _ in range(20):
                if len(progress_seen) >= 3:
                    break
                await asyncio.sleep(0.05)
            if not progress_seen:
                fail("no progress events received")
            if progress_seen[-1] != (3, 3):
                fail(f"unexpected progress sequence: {progress_seen}")

            # notifications/tools/list_changed: the churn_registry
            # tool registers + unregisters another tool, which the
            # registry auto-broadcasts as list_changed.
            await session.call_tool("churn_registry", arguments={})
            try:
                await asyncio.wait_for(
                    tools_list_changed_event.wait(), timeout=5.0
                )
            except asyncio.TimeoutError:
                fail("did not receive notifications/tools/list_changed")

            # notifications/cancelled flow. Start a long-running
            # cancellable tool and cancel it mid-flight.
            cancel_task_pending: asyncio.Task = asyncio.create_task(
                session.experimental.call_tool_as_task(
                    "cancellable", arguments={}
                )
            )
            await asyncio.sleep(0.1)
            # Use the public list_tasks to find the running task,
            # then cancel it. We could also use the create-task
            # response's taskId once it lands, but that lands after
            # the task is recorded in the store, which is after a
            # tiny delay.
            tasks_now = await session.experimental.list_tasks()
            running = [t for t in tasks_now.tasks if t.status == "working"]
            if not running:
                cancel_task_pending.cancel()
                fail("expected at least one working task to cancel")
            cancel_id = running[0].taskId
            cancel_result = await session.experimental.cancel_task(
                cancel_id
            )
            if cancel_result.status not in ("cancelled", "failed"):
                fail(
                    "cancel_task returned non-terminal status: "
                    f"{cancel_result.status}"
                )
            try:
                await asyncio.wait_for(cancel_task_pending, timeout=5.0)
            except asyncio.TimeoutError:
                fail("cancellable tool did not return after cancel")
            except Exception:
                # The cancelled call may surface as an error result;
                # that's acceptable for this assertion.
                pass

            # notifications/tasks/status: by now we've run a few
            # tasks; assert at least one transition was observed.
            if not task_status_seen:
                fail("no notifications/tasks/status observed")

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
