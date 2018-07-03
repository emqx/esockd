PROJECT = esockd
PROJECT_DESCRIPTION = Erlang General Non-blocking TCP/SSL Server
PROJECT_VERSION = 5.4

EUNIT_OPTS = verbose

CT_SUITES = esockd

ERLC_OPTS += +warnings_as_errors +warn_export_all +warn_unused_import

EUNIT_OPTS = verbose

COVER = true

PLT_APPS = sasl asn1 syntax_tools runtime_tools crypto public_key ssl
DIALYZER_DIRS := ebin/
DIALYZER_OPTS := --verbose --statistics -Werror_handling \
                 -Wrace_conditions #-Wunmatched_returns

include erlang.mk

app:: rebar.config
