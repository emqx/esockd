all: compile

compile: get-deps
	./rebar compile

get-deps:
	./rebar get-deps

clean:
	./rebar clean
