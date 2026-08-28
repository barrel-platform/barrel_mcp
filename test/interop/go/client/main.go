// A Go MCP client driving a barrel_mcp server, one subcommand per
// direction. Invoked by barrel_mcp_go_interop_SUITE. Prints OK and
// exits 0 on success, or one "FAIL: <reason>" line and exits 1.
//
// The Go SDK is auto-mode and cannot be pinned to a revision from
// outside: it probes server/discover and falls back to initialize
// when the server refuses. Which era a subcommand lands in is
// therefore decided by the server it is pointed at, and each
// subcommand asserts the era it expects.
package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	modernVersion = "2026-07-28"
	legacyVersion = "2025-11-25"
	sseVersion    = "2024-11-05"
	elicitedName  = "ada"
)

func fail(format string, args ...any) {
	fmt.Printf("FAIL: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 3 {
		fail("usage: client <streamable-modern|streamable-legacy|sse|stdio> <url|command...>")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	switch os.Args[1] {
	case "streamable-modern":
		streamable(ctx, os.Args[2], modernVersion)
	case "streamable-legacy":
		streamable(ctx, os.Args[2], legacyVersion)
	case "sse":
		sse(ctx, os.Args[2])
	case "stdio":
		stdio(ctx, os.Args[2], os.Args[3:])
	default:
		fail("unknown direction %q", os.Args[1])
	}
	fmt.Println("OK")
}

// elicit answers the server's elicitation from inside the SDK's MRTR
// retry loop. Setting it on ClientOptions is what declares the
// capability.
func elicit(_ context.Context, _ *mcp.ElicitRequest) (*mcp.ElicitResult, error) {
	return &mcp.ElicitResult{Action: "accept", Content: map[string]any{"name": elicitedName}}, nil
}

func newClient() *mcp.Client {
	return mcp.NewClient(
		&mcp.Implementation{Name: "barrel-go-interop", Version: "0"},
		&mcp.ClientOptions{ElicitationHandler: elicit},
	)
}

func connect(ctx context.Context, t mcp.Transport) *mcp.ClientSession {
	cs, err := newClient().Connect(ctx, t, nil)
	if err != nil {
		fail("connect: %v", err)
	}
	return cs
}

// catalogue is what every direction proves: the three listings and a
// call, read, and render through them.
func catalogue(ctx context.Context, cs *mcp.ClientSession) {
	tools, err := cs.ListTools(ctx, nil)
	if err != nil {
		fail("tools/list: %v", err)
	}
	names := make([]string, 0, len(tools.Tools))
	for _, t := range tools.Tools {
		names = append(names, t.Name)
	}
	if !contains(names, "echo") {
		fail("tools/list missing echo: %v", names)
	}

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"text": "from go"}})
	if err != nil {
		fail("tools/call echo: %v", err)
	}
	if got := text(res); got != "from go" {
		fail("echo returned %q", got)
	}

	read, err := cs.ReadResource(ctx, &mcp.ReadResourceParams{URI: "mem://greeting"})
	if err != nil {
		fail("resources/read: %v", err)
	}
	if len(read.Contents) == 0 || read.Contents[0].Text != "hello, world" {
		fail("resources/read returned %+v", read.Contents)
	}

	prompt, err := cs.GetPrompt(ctx, &mcp.GetPromptParams{Name: "hello_prompt", Arguments: map[string]string{"who": "go"}})
	if err != nil {
		fail("prompts/get: %v", err)
	}
	if len(prompt.Messages) == 0 {
		fail("prompts/get returned no messages")
	}
	if tc, ok := prompt.Messages[0].Content.(*mcp.TextContent); !ok || tc.Text != "hello, go" {
		fail("prompts/get returned %+v", prompt.Messages[0].Content)
	}
}

// multiRoundTrip is one CallTool from here and two requests on the
// wire: the server asks, the SDK answers via the handler and retries,
// and the sealed requestState survives a client that treats it as opaque.
func multiRoundTrip(ctx context.Context, cs *mcp.ClientSession) {
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "confirm", Arguments: map[string]any{}})
	if err != nil {
		fail("MRTR tools/call: %v", err)
	}
	want := "hello " + elicitedName + " (seed)"
	if got := text(res); got != want {
		fail("MRTR returned %q, wanted %q", got, want)
	}
}

func assertVersion(cs *mcp.ClientSession, want string) {
	init := cs.InitializeResult()
	if init == nil {
		fail("no initialize/discover result")
	}
	if init.ProtocolVersion != want {
		fail("negotiated %q, wanted %q", init.ProtocolVersion, want)
	}
	if init.ServerInfo == nil || init.ServerInfo.Name != "barrel" {
		fail("server did not identify as barrel: %+v", init.ServerInfo)
	}
}

func streamable(ctx context.Context, url, wantVersion string) {
	cs := connect(ctx, &mcp.StreamableClientTransport{Endpoint: url})
	defer cs.Close()
	assertVersion(cs, wantVersion)
	catalogue(ctx, cs)
	if wantVersion == modernVersion {
		multiRoundTrip(ctx, cs)
	}
}

// The deprecated 2024-11-05 pair: a GET stream whose first event names
// the POST endpoint. Nothing here knows that endpoint in advance.
func sse(ctx context.Context, url string) {
	cs := connect(ctx, &mcp.SSEClientTransport{Endpoint: url})
	defer cs.Close()
	init := cs.InitializeResult()
	if init == nil || init.ProtocolVersion == modernVersion {
		fail("SSE pair negotiated %+v; it predates the modern era", init)
	}
	catalogue(ctx, cs)
}

// Our stdio server as a child process the SDK owns: framing over a
// real pipe is the only contract between the two ends.
func stdio(ctx context.Context, command string, args []string) {
	cmd := exec.Command(command, args...)
	cmd.Stderr = os.Stderr
	cs := connect(ctx, &mcp.CommandTransport{Command: cmd})
	defer cs.Close()
	tools, err := cs.ListTools(ctx, nil)
	if err != nil {
		fail("stdio tools/list: %v", err)
	}
	var names []string
	for _, t := range tools.Tools {
		names = append(names, t.Name)
	}
	if !contains(names, "echo") {
		fail("stdio tools/list missing echo: %v", names)
	}
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"input": "over stdio"}})
	if err != nil {
		fail("stdio tools/call: %v", err)
	}
	if got := text(res); got != "Echo: over stdio" {
		fail("stdio echo returned %q", got)
	}
	// Larger than one pipe buffer: the framing has to survive a write
	// the OS splits.
	big := strings.Repeat("x", 200_000)
	res, err = cs.CallTool(ctx, &mcp.CallToolParams{Name: "echo", Arguments: map[string]any{"input": big}})
	if err != nil {
		fail("stdio large echo: %v", err)
	}
	if got := text(res); got != "Echo: "+big {
		fail("stdio large echo came back %d bytes", len(got))
	}
}

func text(res *mcp.CallToolResult) string {
	if res == nil || len(res.Content) == 0 {
		return ""
	}
	if tc, ok := res.Content[0].(*mcp.TextContent); ok {
		return tc.Text
	}
	return ""
}

func contains(xs []string, x string) bool {
	for _, s := range xs {
		if s == x {
			return true
		}
	}
	return false
}
