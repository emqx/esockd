.PHONY: test

REBAR=./rebar

all: get-deps compile xref

get-deps:
	@$(REBAR) get-deps

compile:
	@$(REBAR) compile

xref:
	@$(REBAR) xref skip_deps=true

clean:
	@$(REBAR) clean

eunit:
	@$(REBAR) eunit

test:
	@$(REBAR) skip_deps=true eunit

edoc:
	@$(REBAR) doc

