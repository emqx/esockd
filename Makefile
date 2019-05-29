PROJECT = esockd
PROJECT_DESCRIPTION = General Non-blocking TCP/SSL Server
PROJECT_VERSION = 5.5.0
PROJECT_REGISTERED = esockd_server

LOCAL_DEPS = ssl

ERLC_OPTS += +debug_info
ERLC_OPTS += +warnings_as_errors +warn_export_all +warn_unused_import

EUNIT_OPTS = verbose

CT_SUITES = esockd esockd_rate_limiter

COVER = true

PLT_APPS = sasl asn1 syntax_tools runtime_tools crypto public_key ssl
DIALYZER_DIRS := ebin/
DIALYZER_OPTS := --verbose --statistics -Werror_handling -Wrace_conditions

$(shell [ -f erlang.mk ] || curl -s -o erlang.mk https://raw.githubusercontent.com/emqx/erlmk/master/erlang.mk)

include erlang.mk

app:: rebar.config
