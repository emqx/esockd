PROJECT = esockd
PROJECT_DESCRIPTION = General Non-blocking TCP/SSL Server
PROJECT_VERSION = 5.3

EUNIT_OPTS = verbose

CT_SUITES = esockd

ERLC_OPTS += +debug_info

COVER = true

include erlang.mk

app:: rebar.config
