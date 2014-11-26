# Supervisor Tree

```

esockd_sup 
	-> esockd_listener_sup 
		-> esockd_listener
		-> esockd_acceptor_sup 
			-> esockd_acceptor
			-> esockd_acceptor
			-> ......
		-> esockd_client_sup
			-> esockd_client
			-> esockd_client
			-> ......

```

