# DTLS Echo Server

## listen

listen on port 5000.

## build

```
make
```

## run

```
./run
```

## client

```
openssl s_client -dtls1 -connect 127.0.0.1:5000 -debug

```
