# Supervisor Tree

```

esockd_sup 
	-> esockd_listener_sup 
		-> esockd_listener
		-> esockd_acceptor_sup 
			-> esockd_acceptor
			-> esockd_acceptor
			-> ......
		-> esockd_connection_sup
			-> esockd_connection
			-> esockd_connection
			-> ......

```

