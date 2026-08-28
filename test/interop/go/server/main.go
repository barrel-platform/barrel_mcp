// A Go MCP server over stdio for barrel_mcp_client to drive. Invoked
// by barrel_mcp_go_interop_SUITE. Speaks the SDK's latest revision, so
// our client's probe, fallback and catalogue are exercised against a
// foreign implementation.
package main

import (
	"context"
	"log"
	"os"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type echoIn struct {
	Text string `json:"text" jsonschema:"the text to echo"`
}

type echoOut struct {
	Text string `json:"text"`
}

func echo(_ context.Context, _ *mcp.CallToolRequest, in echoIn) (*mcp.CallToolResult, echoOut, error) {
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: in.Text}},
	}, echoOut{Text: in.Text}, nil
}

func main() {
	// stdout is the wire; logging goes to stderr.
	log.SetOutput(os.Stderr)
	s := mcp.NewServer(&mcp.Implementation{Name: "barrel-go-server", Version: "0"}, nil)
	mcp.AddTool(s, &mcp.Tool{Name: "echo", Description: "Echo a string"}, echo)
	s.AddResource(
		&mcp.Resource{URI: "mem://greeting", Name: "Greeting", MIMEType: "text/plain"},
		func(_ context.Context, _ *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
			return &mcp.ReadResourceResult{
				Contents: []*mcp.ResourceContents{{URI: "mem://greeting", MIMEType: "text/plain", Text: "hello, world"}},
			}, nil
		},
	)
	if err := s.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
