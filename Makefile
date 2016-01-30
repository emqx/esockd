PROJECT = esockd
DEPS = gen_logger
dep_gen_logger = git https://github.com/emqtt/gen_logger.git
include erlang.mk
