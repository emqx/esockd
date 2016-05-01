PROJECT = esockd
PROJECT_DESCRIPTION = Erlang General Non-blocking TCP/SSL Server
PROJECT_VERSION = 4.0

DEPS = gen_logger
dep_gen_logger = git https://github.com/emqtt/gen_logger.git

ERLC_OPTS += +'{parse_transform, lager_transform}'

COVER = true

include erlang.mk

app:: rebar.config
