.PHONY: all compile test ct eunit dialyzer docs examples-setup examples-test interop-setup interop-test interop-python interop-go-setup interop-go clean

all: compile

compile:
	rebar3 compile

test: eunit ct

eunit:
	rebar3 eunit

ct:
	rebar3 ct

dialyzer:
	rebar3 dialyzer

docs:
	rebar3 ex_doc

# Set up `_checkouts' symlinks so each example resolves `barrel_mcp'
# to the parent repo without fetching from hex/git.
examples-setup:
	@for ex in examples/*/; do \
	    mkdir -p "$$ex/_checkouts"; \
	    ln -snf ../../.. "$$ex/_checkouts/barrel_mcp"; \
	done

examples-test: examples-setup
	@for ex in examples/*/; do \
	    echo "==> $$ex"; \
	    (cd "$$ex" && rebar3 ct) || exit 1; \
	done

# Python MCP SDK interop. `interop-setup' is idempotent. The CT
# suite skips when INTEROP_PYTHON is unset, so plain `rebar3 ct'
# remains independent of Python.
interop-setup:
	python3 -m venv test/interop/.venv
	./test/interop/.venv/bin/pip install --upgrade pip
	./test/interop/.venv/bin/pip install -r test/interop/requirements.txt
	python3 -m venv test/interop/.venv-modern
	./test/interop/.venv-modern/bin/pip install --upgrade pip
	./test/interop/.venv-modern/bin/pip install -r test/interop/requirements-modern.txt

interop-python: interop-setup
	INTEROP_PYTHON=$(CURDIR)/test/interop/.venv/bin/python \
	INTEROP_PYTHON_MODERN=$(CURDIR)/test/interop/.venv-modern/bin/python \
	    rebar3 ct --suite=test/barrel_mcp_python_interop_SUITE

# Go MCP SDK interop. `interop-go-setup' builds both binaries and is
# idempotent. The CT suite skips when the two env vars are unset.
interop-go-setup:
	cd test/interop/go && go build -o bin/client ./client && go build -o bin/server ./server

interop-go: interop-go-setup
	INTEROP_GO_CLIENT=$(CURDIR)/test/interop/go/bin/client \
	INTEROP_GO_SERVER=$(CURDIR)/test/interop/go/bin/server \
	    rebar3 ct --suite=test/barrel_mcp_go_interop_SUITE

interop-test: interop-python interop-go

clean:
	rebar3 clean
	rm -rf examples/*/_build examples/*/_checkouts test/interop/.venv \
	    test/interop/.venv-modern test/interop/go/bin
