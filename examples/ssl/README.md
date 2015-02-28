# SSL Echo Server

## listen

listen on port 5000.

## build

```
rebar compile
```

## run

```
./run
```

## client

```
openssl s_client -connect 127.0.0.1:5000 -tls1

```
