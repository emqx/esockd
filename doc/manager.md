esockd_manager

1. control max_clients

case count_children(CSup) of
    Count when Count =< Max ->
     {{ok, accept}, State};
    {{reject, busy}, State}

2.  block, unblock

