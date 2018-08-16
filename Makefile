PROJECT = esockd
PROJECT_DESCRIPTION = General Non-blocking TCP/SSL Server
PROJECT_VERSION = 5.2

DEPS = gen_logger
dep_gen_logger = git https://github.com/emqtt/gen_logger.git

EUNIT_OPTS = verbose

CT_SUITES = esockd

ERLC_OPTS += +debug_info
ERLC_OPTS += +'{parse_transform, lager_transform}'

COVER = true

PLT_APPS = sasl asn1 syntax_tools runtime_tools crypto public_key ssl
DIALYZER_DIRS := ebin/
DIALYZER_OPTS := --verbose --statistics -Werror_handling -Wrace_conditions

include erlang.mk

app:: rebar.config
