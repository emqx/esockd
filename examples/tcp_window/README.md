
## TCP Window Full

Send Function                           | Socket Options           | TCP Window full
----------------------------------------|--------------------------|-------------------------------------------
gen_tcp:send(Socket, Data)              | {send_timeout, infinity} | Block forever.
port_command(Socket, Data)              | {send_timeout, infinity} | Block forever.
port_command(Socket, Data, [force])     | {send_timeout, infinity} | Return true always. Write to TCP Stack.
port_command(Socket, Data, [nosuspend]) | {send_timeout, infinity} | Return false always. Drop the packets silently.
gen_tcp:send(Socket, Data)              | {send_timeout, 5000}     | Return {error, timeout}.
port_command(Socket, Data)              | {send_timeout, 5000}     | Return true always. Pause 5 seconds and Drop packets silently.
port_command(Socket, Data, [force])     | {send_timeout, 5000}     | Return true always. Write to TCP Stack.
port_command(Socket, Data, [nosuspend]) | {send_timeout, 5000}     | Return false first, and true after timeout. Drop the packets silently.

## Conclusions

1. Should set the `send_timeout` option if using `gen_tcp:send`
2. Should not set the `nosuspend` option if using `port_command`, for the busy sock will be killed at once.

