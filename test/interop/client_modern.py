"""Direction A (modern era): Python MCP SDK v2 client against a barrel_mcp server.

Invoked by
`barrel_mcp_python_interop_SUITE:modern_python_client_against_erlang_server/1`.
The CT case starts a Streamable HTTP listener, registers a small
fixture, then runs this script with the URL as argv[1]. We exit 0 on
success and print a single ``FAIL: <reason>`` line + exit non-zero
otherwise.

This is the 2026-07-28 era: no `initialize`, no session id, per-request
`_meta`. The point is that the reference SDK drives our server through
`server/discover` and multi round-trip requests without knowing anything
about us.
"""

from __future__ import annotations

import faulthandler
import ssl
import sys
import traceback

import anyio
import httpx2
from mcp import InputRequiredRoundsExceededError, MCPError, types
from mcp.client import Client
from mcp.client.streamable_http import streamable_http_client
from mcp.client.subscriptions import ResourceUpdated
from mcp.types.version import LATEST_MODERN_VERSION


#: Set by main(): {"http2": bool, "cacert": str | None}.
HTTP: dict = {"http2": False, "cacert": None}
#: Every HTTP version a response arrived over, for the --http2 check.
SEEN_VERSIONS: set[str] = set()


async def note_version(response: httpx2.Response) -> None:
    SEEN_VERSIONS.add(response.http_version)


def http_client() -> httpx2.AsyncClient:
    verify: ssl.SSLContext | bool = True
    if HTTP["cacert"]:
        verify = ssl.create_default_context(cafile=HTTP["cacert"])
        verify.check_hostname = False
        # Python 3.13 verifies strictly by default and then wants an
        # Authority Key Identifier the minted test chain does not carry.
        verify.verify_flags &= ~ssl.VERIFY_X509_STRICT
    return httpx2.AsyncClient(
        timeout=httpx2.Timeout(30.0, read=300.0),
        follow_redirects=True,
        http2=HTTP["http2"],
        verify=verify,
        event_hooks={"response": [note_version]},
    )


def server(url: str):
    """What `Client` connects to: the bare URL, or a transport over an
    HTTP client configured for TLS and HTTP/2 when the flags ask."""
    if not HTTP["http2"] and not HTTP["cacert"]:
        return url
    return streamable_http_client(url, http_client=http_client())


EXPECTED_TOOL = "echo"
EXPECTED_RESOURCE_URI = "mem://greeting"
EXPECTED_PROMPT = "hello_prompt"
ELICITED_NAME = "ada"

#: MissingRequiredClientCapability (2026-07-28).
MISSING_CLIENT_CAPABILITY = -32021


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


async def elicit(context, params: types.ElicitRequestParams):
    """Answer the server's elicitation from inside the MRTR retry loop."""
    return types.ElicitResult(action="accept", content={"name": ELICITED_NAME})


async def probe(url: str) -> None:
    """`auto` must land on the modern era via server/discover."""
    async with Client(server(url), mode="auto") as client:
        if client.protocol_version != LATEST_MODERN_VERSION:
            fail(f"probe negotiated {client.protocol_version!r}")
        if client.server_info is None:
            fail("server did not identify itself in the _meta serverInfo stamp")
        if client.server_info.name != "barrel":
            fail(f"unexpected server name {client.server_info.name!r}")
        if "tools" not in client.server_capabilities.model_dump(exclude_none=True):
            fail("server/discover did not advertise the tools capability")


async def catalogue(client: Client) -> None:
    tools = await client.list_tools()
    names = [t.name for t in tools.tools]
    if EXPECTED_TOOL not in names:
        fail(f"tools/list missing {EXPECTED_TOOL}: {names}")

    prompts = await client.list_prompts()
    prompt_names = [p.name for p in prompts.prompts]
    if EXPECTED_PROMPT not in prompt_names:
        fail(f"prompts/list missing {EXPECTED_PROMPT}: {prompt_names}")

    prompt = await client.get_prompt(EXPECTED_PROMPT, {"who": "interop"})
    text = prompt.messages[0].content.text
    if text != "hello, interop":
        fail(f"prompts/get returned {text!r}")


async def results_are_stamped(client: Client) -> None:
    """Every modern result carries resultType, and cacheable ones carry hints."""
    result = await client.call_tool(EXPECTED_TOOL, {"text": "from python"})
    if result.result_type != "complete":
        fail(f"tools/call resultType was {result.result_type!r}")
    if result.content[0].text != "from python":
        fail(f"tools/call echoed {result.content[0].text!r}")

    read = await client.read_resource(EXPECTED_RESOURCE_URI)
    if read.contents[0].text != "hello, world":
        fail(f"resources/read returned {read.contents[0].text!r}")
    if read.ttl_ms is None or read.cache_scope is None:
        fail(f"resources/read carried no freshness hints: {read.ttl_ms}, {read.cache_scope}")


async def multi_round_trip(client: Client) -> None:
    """The server answers with what it needs; the SDK answers and retries.

    One call_tool from here, two requests on the wire, and the sealed
    requestState has to survive the round trip through a client that
    treats it as opaque.
    """
    result = await client.call_tool("confirm", {})
    if result.result_type != "complete":
        fail(f"MRTR settled as {result.result_type!r}")
    expected = f"hello {ELICITED_NAME} (seed)"
    if result.content[0].text != expected:
        fail(f"MRTR returned {result.content[0].text!r}, wanted {expected!r}")


def find_mcp_error(exc: BaseException) -> MCPError | None:
    """anyio nests failures in ExceptionGroups; dig the MCPError out."""
    if isinstance(exc, MCPError):
        return exc
    for inner in getattr(exc, "exceptions", ()):
        found = find_mcp_error(inner)
        if found is not None:
            return found
    return None


async def undeclared_capability_is_refused(url: str) -> None:
    """A server must not ask for a capability the client never declared.

    Without an elicitation_callback the SDK declares no elicitation, so
    the same tool has to fail with MissingRequiredClientCapability
    rather than reach a client that cannot answer.
    """
    async with Client(server(url), mode="auto", raise_exceptions=True) as client:
        try:
            await client.call_tool("confirm", {})
        except BaseException as exc:  # noqa: BLE001 - group-wrapped by anyio
            error = find_mcp_error(exc)
            if error is None:
                fail(f"undeclared elicitation raised {exc!r}, not an MCPError")
            if error.code != MISSING_CLIENT_CAPABILITY:
                fail(f"undeclared elicitation returned code {error.code}")
            # A ClientCapabilities object, not a list of names: the
            # reference server builds one in
            # mcp/server/mcpserver/resolve.py.
            required = (error.data or {}).get("requiredCapabilities")
            if not isinstance(required, dict) or "elicitation" not in required:
                fail(f"error named requiredCapabilities {required!r}")
            return
    fail("server asked for elicitation from a client that never declared it")


async def subscription_stream(client: Client) -> None:
    """The modern replacement for the GET stream and resources/subscribe.

    Entering waits for the server's acknowledgment, so `honored` is what
    it actually agreed to rather than what we asked for.
    """
    uri = EXPECTED_RESOURCE_URI
    async with client.listen(resource_subscriptions=[uri]) as sub:
        if list(sub.honored.resource_subscriptions or []) != [uri]:
            fail(f"server honored {sub.honored.resource_subscriptions!r}")
        # A second request on the same connection, while the stream is held open.
        await client.call_tool("touch", {})
        with anyio.fail_after(10):
            async for event in sub:
                if isinstance(event, ResourceUpdated):
                    if event.uri != uri:
                        fail(f"update named {event.uri!r}")
                    return
    fail("subscription closed before the update arrived")


async def unsubscribed_types_stay_quiet(client: Client) -> None:
    """Opting into one kind must not deliver another.

    Silence is the assertion, so the timeout is the only acceptable way
    out: a stream that closed early would otherwise look like a pass.
    """
    async with client.listen(tools_list_changed=True) as sub:
        if sub.honored.resource_subscriptions:
            fail("server invented a resource subscription we never asked for")
        await client.call_tool("touch", {})
        try:
            with anyio.fail_after(2):
                async for event in sub:
                    fail(f"received {type(event).__name__} without subscribing to it")
        except TimeoutError:
            return
        fail("the subscription ended instead of staying quiet")


async def mirrored_header_round_trip(client: Client) -> None:
    """The server rejects a header that disagrees with the body (-32020).

    So a call that succeeds is the assertion: both ends encoded the
    mirrored argument the same way, byte for byte.
    """
    for region in ("eu-west-1", "eu-wöst-1", "  padded  ", "=?base64?x?="):
        result = await client.call_tool("regional", {"region": region})
        if result.content[0].text != region:
            fail(f"regional echoed {result.content[0].text!r} for {region!r}")


async def input_rounds_are_capped(url: str) -> None:
    """A server that keeps asking has to be stopped by the client."""
    async with Client(
        server(url),
        mode="auto",
        elicitation_callback=elicit,
        input_required_max_rounds=3,
        raise_exceptions=True,
    ) as client:
        try:
            await client.call_tool("insatiable", {})
        except BaseException as exc:  # noqa: BLE001 - group-wrapped by anyio
            if find_input_rounds_error(exc) is None:
                fail(f"insatiable tool raised {exc!r}")
            return
    fail("a tool that always asks was allowed to run forever")


def find_input_rounds_error(exc: BaseException) -> BaseException | None:
    if isinstance(exc, InputRequiredRoundsExceededError):
        return exc
    for inner in getattr(exc, "exceptions", ()):
        found = find_input_rounds_error(inner)
        if found is not None:
            return found
    return None


async def prompt_and_resource_ask_too(client: Client) -> None:
    """MRTR is not a tools-only pattern: the SDK drives the same loop
    for prompts/get and resources/read."""
    prompt = await client.get_prompt("gated", {})
    text = prompt.messages[0].content.text
    if text != f"hello, {ELICITED_NAME}":
        fail(f"gated prompt returned {text!r}")

    read = await client.read_resource("mem://gated")
    if read.contents[0].text != f"hello/{ELICITED_NAME}":
        fail(f"gated resource returned {read.contents[0].text!r}")


async def pages_are_walked(client: Client) -> None:
    """A cursor the client treats as opaque has to carry across pages."""
    names: list[str] = []
    pages = 0
    cursor = None
    while True:
        page = await client.list_tools(cursor=cursor)
        names.extend(t.name for t in page.tools)
        pages += 1
        cursor = page.next_cursor
        if cursor is None:
            break
    if pages < 2:
        fail(f"the fixture paginates, but tools/list came back in {pages} page")
    if len(names) != len(set(names)):
        fail("a tool appeared on more than one page")
    for expected in (EXPECTED_TOOL, "confirm", "regional"):
        if expected not in names:
            fail(f"walking the cursor missed {expected}")


async def progress_reaches_the_caller(client: Client) -> None:
    seen: list[tuple[float, float | None]] = []

    async def on_progress(progress: float, total: float | None, message: str | None) -> None:
        seen.append((progress, total))

    result = await client.call_tool("progress", {}, progress_callback=on_progress)
    if result.content[0].text != "progressed":
        fail(f"progress tool returned {result.content[0].text!r}")
    if [p for p, _ in seen] != [1, 2, 3]:
        fail(f"progress notifications arrived as {seen}")


async def logs_are_opt_in(url: str) -> None:
    """Modern logging is per-request: no `logLevel` in `_meta`, no logs.

    The same tool is called twice, once by a client that opted in at
    info and once by one that did not, so silence is measured against a
    run that is known to produce output.
    """
    quiet: list[str] = []
    loud: list[str] = []

    def collect(into: list[str]):
        async def handler(params: types.LoggingMessageNotificationParams) -> None:
            into.append(params.level)

        return handler

    async with Client(server(url), mode="auto", logging_callback=collect(quiet)) as client:
        await client.call_tool("noisy", {})
    if quiet:
        fail(f"a client that never opted in received {quiet}")

    async with Client(
        server(url), mode="auto", log_level="info", logging_callback=collect(loud)
    ) as client:
        await client.call_tool("noisy", {})
    # `debug` is below the level we asked for.
    if loud != ["info"]:
        fail(f"opting in at info delivered {loud}")


async def run(url: str) -> None:
    await probe(url)
    async with Client(server(url), mode="auto", elicitation_callback=elicit) as client:
        await catalogue(client)
        await pages_are_walked(client)
        await results_are_stamped(client)
        await multi_round_trip(client)
        await prompt_and_resource_ask_too(client)
        await mirrored_header_round_trip(client)
        await progress_reaches_the_caller(client)
        await subscription_stream(client)
        await unsubscribed_types_stay_quiet(client)
    await logs_are_opt_in(url)
    await undeclared_capability_is_refused(url)
    await input_rounds_are_capped(url)
    print("OK")


def main() -> None:
    # A silent hang is the worst failure to debug from CT: dump every
    # task's stack and exit before the suite's own timeout hits.
    faulthandler.dump_traceback_later(45, exit=True)
    argv = sys.argv[1:]
    if "--cacert" in argv:
        i = argv.index("--cacert")
        HTTP["cacert"] = argv[i + 1]
        del argv[i : i + 2]
    HTTP["http2"] = "--http2" in argv
    args = [a for a in argv if a != "--http2"]
    if len(args) != 1:
        fail("usage: client_modern.py <server-url> [--http2] [--cacert FILE]")
    try:
        anyio.run(run, args[0])
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc()
        fail("unhandled exception")
    if HTTP["http2"] and SEEN_VERSIONS != {"HTTP/2"}:
        fail(f"expected every response over HTTP/2, saw {sorted(SEEN_VERSIONS)}")


if __name__ == "__main__":
    main()
