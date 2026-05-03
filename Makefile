.PHONY: all compile test ct eunit dialyzer docs examples-setup examples-test interop-setup interop-test clean

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

interop-test: interop-setup
	INTEROP_PYTHON=$(CURDIR)/test/interop/.venv/bin/python \
	    rebar3 ct --suite=test/barrel_mcp_python_interop_SUITE

clean:
	rebar3 clean
	rm -rf examples/*/_build examples/*/_checkouts test/interop/.venv
