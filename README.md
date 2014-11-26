# esockd

Erlang General Non-blocking TCP Server

## build

```
	make
```

## usage

test/esockd_test.erl:

```erlang
    esockd:start(),
    esockd:listen(5000, ?TCP_OPTIONS, {echo_server, start_link, []}).
```

