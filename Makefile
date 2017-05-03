PROJECT = esockd
PROJECT_DESCRIPTION = Erlang General Non-blocking TCP/SSL Server
PROJECT_VERSION = 5.0

DEPS = gen_logger
dep_gen_logger = git https://github.com/emqtt/gen_logger.git

EUNIT_OPTS = verbose

CT_SUITES = esockd

ERLC_OPTS += +debug_info
ERLC_OPTS += +'{parse_transform, lager_transform}'

COVER = true

include erlang.mk

app:: rebar.config
