#!/bin/sh

if [ $# -ne 3 ]; then
	echo "echo_client Host Port Num"
	exit 1
fi

erl -pa ebin -pa ../../ebin -pa ../../deps/*/ebin -smp true +P 200000 -env ERL_MAX_PORTS 100000 -env ERTS_MAX_PORTS 100000 -s echo_client start $1 $2 $3

