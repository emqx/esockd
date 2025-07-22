REBAR := rebar3

.PHONY: all
all: compile

compile:
	$(REBAR) compile

.PHONY: clean
clean: distclean

.PHONY: distclean
distclean:
	@rm -rf _build erl_crash.dump rebar3.crashdump rebar.lock

.PHONY: xref
xref:
	$(REBAR) xref

.PHONY: eunit
eunit: compile
	$(REBAR) eunit --verbose

.PHONY: ct
ct: compile
	$(REBAR) as test ct -v

COMPOSE := docker compose -f test/docker-compose.yml
COMPOSE_CT_SUITES := test/esockd_socket_SUITE.erl

.PHONY: ct-compose
ct-compose:
	$(COMPOSE) up --build --quiet-pull -d
	sleep 5
	$(COMPOSE) exec esockd rebar3 ct -v --suite $(COMPOSE_CT_SUITES) || $(COMPOSE) logs
	$(COMPOSE) logs tcptest
	$(COMPOSE) logs tc
	$(COMPOSE) down -t1

cover:
	$(REBAR) cover

.PHONY: coveralls
coveralls:
	@rebar3 as test coveralls send

.PHONY: dialyzer
dialyzer:
	$(REBAR) dialyzer

