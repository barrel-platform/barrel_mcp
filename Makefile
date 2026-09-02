.PHONY: all compile test ct eunit dialyzer docs examples-setup examples-test interop-setup interop-test interop-python conformance-setup conformance clean

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

# The examples have no lock of their own: they inherit this project's
# dependency ranges through `_checkouts', so an in-range bump here
# leaves whatever they already unpacked in place. Build them fresh.
examples-test: examples-setup
	@for ex in examples/*/; do \
	    echo "==> $$ex"; \
	    rm -rf "$$ex"_build; \
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

# Official MCP conformance runner and reference server, pinned in
# test/conformance/package.json. `conformance-setup' is idempotent.
conformance-setup:
	cd test/conformance && npm install --no-audit --no-fund
	node test/conformance/patch-runner.js

conformance: conformance-setup
	INTEROP_CONFORMANCE=$(CURDIR)/test/conformance/node_modules/@modelcontextprotocol/conformance/dist/index.js \
	INTEROP_SERVER_EVERYTHING=$(CURDIR)/test/conformance/node_modules/@modelcontextprotocol/server-everything/dist/index.js \
	    rebar3 ct --suite=test/barrel_mcp_conformance_SUITE

interop-test: interop-python conformance

clean:
	rebar3 clean
	rm -rf examples/*/_build examples/*/_checkouts test/interop/.venv \
	    test/interop/.venv-modern test/conformance/node_modules
