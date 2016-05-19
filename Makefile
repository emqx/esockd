PROJECT = esockd
PROJECT_DESCRIPTION = Erlang General Non-blocking TCP/SSL Server
PROJECT_VERSION = 4.0

DEPS = gen_logger
dep_gen_logger = git https://github.com/emqtt/gen_logger.git

EUNIT_OPTS = verbose

CT_SUITES = esockd
COVER = true

include erlang.mk
