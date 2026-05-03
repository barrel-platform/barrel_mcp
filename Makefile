.PHONY: all compile test ct eunit dialyzer docs examples-setup examples-test clean

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

clean:
	rebar3 clean
	rm -rf examples/*/_build examples/*/_checkouts
