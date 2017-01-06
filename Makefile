PROJECT = esockd
PROJECT_DESCRIPTION = Erlang General Non-blocking TCP/SSL Server
PROJECT_VERSION = 4.1.1

DEPS = gen_logger
dep_gen_logger = git https://github.com/emqtt/gen_logger.git

BUILD_DEPS = hexer_mk
dep_hexer_mk = git https://github.com/inaka/hexer.mk.git 1.1.0
DEP_PLUGINS = hexer_mk

EUNIT_OPTS = verbose

CT_SUITES = esockd

ERLC_OPTS += +'{parse_transform, lager_transform}'

#COVER = true

include erlang.mk

app:: rebar.config
