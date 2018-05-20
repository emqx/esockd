PROJECT = esockd
PROJECT_DESCRIPTION = General Non-blocking TCP/SSL Server
PROJECT_VERSION = 5.3

EUNIT_OPTS = verbose

CT_SUITES = esockd

ERLC_OPTS += +debug_info

EUNIT_OPTS = verbose

COVER = true

PLT_APPS = sasl asn1 syntax_tools runtime_tools crypto public_key ssl
DIALYZER_DIRS := ebin/
DIALYZER_OPTS := --verbose --statistics -Werror_handling \
                 -Wrace_conditions #-Wunmatched_returns

include erlang.mk

app:: rebar.config
