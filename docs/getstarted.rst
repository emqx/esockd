
.. _getstarted:

===========
Get Started
===========

--------
Overview
--------

--------
Features
--------

-----
Usage
-----

---
SSL
---

How to support SSLSocket?

connect to ssl_echo_server

openssl s_client -connect 127.0.0.1:5000 -ssl3

openssl s_client -connect 127.0.0.1:5000 -tls1

## SSL Handshake?


--------------
Access Control
--------------

## Allow and Deny

192.168.0.*:allow
211.121.13.13:deny

当hosts.allow和 host.deny相冲突时，以hosts.allow设置为准。

## Nginx 

deny IP;
deny subnet;
allow IP;
allow subnet;
# block all ips
deny    all;
# allow all ips
allow    all;

deny 1.2.3.4;
deny 91.212.45.0/24;
deny 91.212.65.0/24;

allow  192.168.1.0/24;



