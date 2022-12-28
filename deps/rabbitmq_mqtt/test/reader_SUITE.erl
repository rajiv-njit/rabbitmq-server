%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2023 VMware, Inc. or its affiliates.  All rights reserved.
%%
-module(reader_SUITE).
-compile([export_all,
          nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-import(rabbit_ct_broker_helpers, [rpc/5]).
-import(rabbit_ct_helpers, [consistently/1,
                            eventually/3]).
-import(util, [all_connection_pids/1,
               publish_qos1_timeout/4,
               expect_publishes/2,
               connect/2,
               connect/3]).

all() ->
    [
      {group, non_parallel_tests}
    ].

groups() ->
    [
     {non_parallel_tests, [],
      [
       block,
       block_connack_timeout,
       handle_invalid_packets,
       login_timeout,
       keepalive,
       keepalive_turned_off,
       stats,
       will,
       clean_session_disconnect_client,
       clean_session_kill_node,
       quorum_clean_session_false,
       quorum_clean_session_true,
       classic_clean_session_true,
       classic_clean_session_false
      ]}
    ].

suite() ->
    [{timetrap, {seconds, 60}}].

%% -------------------------------------------------------------------
%% Testsuite setup/teardown.
%% -------------------------------------------------------------------

merge_app_env(Config) ->
    rabbit_ct_helpers:merge_app_env(Config,
                                    {rabbit, [
                                              {collect_statistics, basic},
                                              {collect_statistics_interval, 100}
                                             ]}).

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_nodename_suffix, ?MODULE},
        {rmq_extra_tcp_ports, [tcp_port_mqtt_extra,
                               tcp_port_mqtt_tls_extra]}
      ]),
    rabbit_ct_helpers:run_setup_steps(Config1,
      [ fun merge_app_env/1 ] ++
      rabbit_ct_broker_helpers:setup_steps() ++
      rabbit_ct_client_helpers:setup_steps()).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config,
      rabbit_ct_client_helpers:teardown_steps() ++
      rabbit_ct_broker_helpers:teardown_steps()).

init_per_group(_, Config) ->
    Config.

end_per_group(_, Config) ->
    Config.

init_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_started(Config, Testcase).

end_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_finished(Config, Testcase).


%% -------------------------------------------------------------------
%% Testsuite cases
%% -------------------------------------------------------------------

block(Config) ->
    C = connect(?FUNCTION_NAME, Config),

    %% Only here to ensure the connection is really up
    {ok, _, _} = emqtt:subscribe(C, <<"TopicA">>),
    ok = emqtt:publish(C, <<"TopicA">>, <<"Payload">>),
    ok = expect_publishes(<<"TopicA">>, [<<"Payload">>]),
    {ok, _, _} = emqtt:unsubscribe(C, <<"TopicA">>),

    {ok, _, _} = emqtt:subscribe(C, <<"Topic1">>),
    {ok, _} = emqtt:publish(C, <<"Topic1">>, <<"Not blocked yet">>, [{qos, 1}]),

    ok = rpc(Config, vm_memory_monitor, set_vm_memory_high_watermark, [0.00000001]),
    % %% Let it block
    timer:sleep(100),

    %% Blocked, but still will publish when unblocked
    puback_timeout = publish_qos1_timeout(C, <<"Topic1">>, <<"Now blocked">>, 1000),
    puback_timeout = publish_qos1_timeout(C, <<"Topic1">>, <<"Still blocked">>, 1000),

    %% Unblock
    rpc(Config, vm_memory_monitor, set_vm_memory_high_watermark, [0.4]),
    ok = expect_publishes(<<"Topic1">>, [<<"Not blocked yet">>,
                                         <<"Now blocked">>,
                                         <<"Still blocked">>]),
    ok = emqtt:disconnect(C).

block_connack_timeout(Config) ->
    P = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_mqtt),
    Ports0 = rpc(Config, erlang, ports, []),

    ok = rpc(Config, vm_memory_monitor, set_vm_memory_high_watermark, [0.00000001]),
    %% Let connection block.
    timer:sleep(100),

    %% We can still connect via TCP, but CONNECT packet will not be processed on the server.
    {ok, Client} = emqtt:start_link([{host, "localhost"},
                                     {port, P},
                                     {clientid, atom_to_binary(?FUNCTION_NAME)},
                                     {proto_ver, v4},
                                     {connect_timeout, 1}]),
    unlink(Client),
    ClientMRef = monitor(process, Client),
    {error, connack_timeout} = emqtt:connect(Client),
    receive
        {'DOWN', ClientMRef, process, Client, connack_timeout} ->
            ok
    after 200 ->
              ct:fail("missing connack_timeout in client")
    end,

    Ports = rpc(Config, erlang, ports, []),
    %% Server creates 1 new port to handle our MQTT connection.
    [NewPort] = Ports -- Ports0,
    {connected, MqttReader} = rpc(Config, erlang, port_info, [NewPort, connected]),
    MqttReaderMRef = monitor(process, MqttReader),

    %% Unblock connection. CONNECT packet will be processed on the server.
    rpc(Config, vm_memory_monitor, set_vm_memory_high_watermark, [0.4]),

    receive
        {'DOWN', MqttReaderMRef, process, MqttReader, {shutdown, {socket_ends, einval}}} ->
            %% We expect that MQTT reader process exits (without crashing)
            %% because our client already disconnected.
            ok
    after 2000 ->
              ct:fail("missing peername_not_known from server")
    end,
    %% Ensure that our client is not registered.
    ?assertEqual([], all_connection_pids(Config)),
    ok.

handle_invalid_packets(Config) ->
    N = rpc(Config, ets, info, [connection_metrics, size]),
    P = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_mqtt),
    {ok, C} = gen_tcp:connect("localhost", P, []),
    Bin = <<"GET / HTTP/1.1\r\nHost: www.rabbitmq.com\r\nUser-Agent: curl/7.43.0\r\nAccept: */*">>,
    gen_tcp:send(C, Bin),
    gen_tcp:close(C),
    %% Wait for stats being emitted (every 100ms)
    timer:sleep(300),
    %% No new stats entries should be inserted as connection never got to initialize
    ?assertEqual(N, rpc(Config, ets, info, [connection_metrics, size])).

login_timeout(Config) ->
    rpc(Config, application, set_env, [rabbitmq_mqtt, login_timeout, 400]),
    P = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_mqtt),
    {ok, C} = gen_tcp:connect("localhost", P, [{active, false}]),

    try
        {error, closed} = gen_tcp:recv(C, 0, 500)
    after
        rpc(Config, application, unset_env, [rabbitmq_mqtt, login_timeout])
    end.

keepalive(Config) ->
    KeepaliveSecs = 1,
    KeepaliveMs = timer:seconds(KeepaliveSecs),
    ProtoVer = v4,
    C = connect(?FUNCTION_NAME, Config, [{keepalive, KeepaliveSecs},
                                         {proto_ver, ProtoVer}]),
    ok = emqtt:publish(C, <<"ignored">>, <<"msg">>),

    %% Connection should stay up when client sends PING requests.
    timer:sleep(KeepaliveMs),
    ?assertMatch(#{publishers := 1},
                 util:get_global_counters(Config, ProtoVer)),

    %% Mock the server socket to not have received any bytes.
    rabbit_ct_broker_helpers:setup_meck(Config),
    Mod = rabbit_net,
    ok = rpc(Config, 0, meck, new, [Mod, [no_link, passthrough]]),
    ok = rpc(Config, 0, meck, expect, [Mod, getstat, 2, {ok, [{recv_oct, 999}]} ]),
    process_flag(trap_exit, true),

    %% We expect the server to respect the keepalive closing the connection.
    eventually(?_assertMatch(#{publishers := 0},
                             util:get_global_counters(Config, ProtoVer)),
               KeepaliveMs, 3 * KeepaliveSecs),

    true = rpc(Config, 0, meck, validate, [Mod]),
    ok = rpc(Config, 0, meck, unload, [Mod]).

keepalive_turned_off(Config) ->
    %% "A Keep Alive value of zero (0) has the effect of turning off the keep alive mechanism."
    KeepaliveSecs = 0,
    C = connect(?FUNCTION_NAME, Config, [{keepalive, KeepaliveSecs}]),
    ok = emqtt:publish(C, <<"TopicB">>, <<"Payload">>),

    %% Mock the server socket to not have received any bytes.
    rabbit_ct_broker_helpers:setup_meck(Config),
    Mod = rabbit_net,
    ok = rpc(Config, 0, meck, new, [Mod, [no_link, passthrough]]),
    ok = rpc(Config, 0, meck, expect, [Mod, getstat, 2, {ok, [{recv_oct, 999}]} ]),

    consistently(?_assert(erlang:is_process_alive(C))),

    true = rpc(Config, 0, meck, validate, [Mod]),
    ok = rpc(Config, 0, meck, unload, [Mod]),
    ok = emqtt:disconnect(C).

stats(Config) ->
    C = connect(?FUNCTION_NAME, Config),
    %% Wait for stats being emitted (every 100ms)
    timer:sleep(300),
    %% Retrieve the connection Pid
    [Pid] = all_connection_pids(Config),
    [{pid, Pid}] = rpc(Config, rabbit_mqtt_reader, info, [Pid, [pid]]),
    %% Verify the content of the metrics, garbage_collection must be present
    [{Pid, Props}] = rpc(Config, ets, lookup, [connection_metrics, Pid]),
    true = proplists:is_defined(garbage_collection, Props),
    %% If the coarse entry is present, stats were successfully emitted
    [{Pid, _, _, _, _}] = rpc(Config, ets, lookup,
                              [connection_coarse_metrics, Pid]),
    ok = emqtt:disconnect(C).

get_durable_queue_type(Server, QNameBin) ->
    QName = rabbit_misc:r(<<"/">>, queue, QNameBin),
    {ok, Q} = rpc:call(Server, rabbit_amqqueue, lookup, [QName]),
    amqqueue:get_type(Q).

set_env(QueueType) ->
    application:set_env(rabbitmq_mqtt, durable_queue_type, QueueType).

get_env() ->
    rabbit_mqtt_util:env(durable_queue_type).

validate_durable_queue_type(Config, ClientName, CleanSession, ExpectedQueueType) ->
    Server = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    C = connect(ClientName, Config, [{clean_start, CleanSession}]),
    {ok, _, _} = emqtt:subscribe(C, <<"TopicB">>, qos1),
    ok = emqtt:publish(C, <<"TopicB">>, <<"Payload">>),
    ok = expect_publishes(<<"TopicB">>, [<<"Payload">>]),
    {ok, _, _} = emqtt:unsubscribe(C, <<"TopicB">>),
    Prefix = <<"mqtt-subscription-">>,
    Suffix = <<"qos1">>,
    QNameBin = <<Prefix/binary, ClientName/binary, Suffix/binary>>,
    ?assertEqual(ExpectedQueueType, get_durable_queue_type(Server, QNameBin)),
    ok = emqtt:disconnect(C).

clean_session_disconnect_client(Config) ->
    C = connect(?FUNCTION_NAME, Config),
    {ok, _, _} = emqtt:subscribe(C, <<"topic0">>, qos0),
    {ok, _, _} = emqtt:subscribe(C, <<"topic1">>, qos1),
    QsQos0 = rpc(Config, rabbit_amqqueue, list_by_type, [rabbit_mqtt_qos0_queue]),
    QsClassic = rpc(Config, rabbit_amqqueue, list_by_type, [rabbit_classic_queue]),
    case rabbit_ct_helpers:is_mixed_versions(Config) of
        false ->
            ?assertEqual(1, length(QsQos0)),
            ?assertEqual(1, length(QsClassic));
        true ->
            ?assertEqual(0, length(QsQos0)),
            ?assertEqual(2, length(QsClassic))
    end,

    ok = emqtt:disconnect(C),
    %% After terminating a clean session, we expect any session state to be cleaned up on the server.
    timer:sleep(200), %% Give some time to clean up exclusive classic queue.
    L = rpc(Config, rabbit_amqqueue, list, []),
    ?assertEqual(0, length(L)).

clean_session_kill_node(Config) ->
    C = connect(?FUNCTION_NAME, Config),
    {ok, _, _} = emqtt:subscribe(C, <<"topic0">>, qos0),
    {ok, _, _} = emqtt:subscribe(C, <<"topic1">>, qos1),
    QsQos0 = rpc(Config, rabbit_amqqueue, list_by_type, [rabbit_mqtt_qos0_queue]),
    QsClassic = rpc(Config, rabbit_amqqueue, list_by_type, [rabbit_classic_queue]),
    case rabbit_ct_helpers:is_mixed_versions(Config) of
        false ->
            ?assertEqual(1, length(QsQos0)),
            ?assertEqual(1, length(QsClassic));
        true ->
            ?assertEqual(0, length(QsQos0)),
            ?assertEqual(2, length(QsClassic))
    end,
    ?assertEqual(2, rpc(Config, ets, info, [rabbit_durable_queue, size])),

    process_flag(trap_exit, true),
    ok = rabbit_ct_broker_helpers:kill_node(Config, 0),
    ok = rabbit_ct_broker_helpers:start_node(Config, 0),

    %% After terminating a clean session by a node crash, we expect any session
    %% state to be cleaned up on the server once the server comes back up.
    ?assertEqual(0, rpc(Config, ets, info, [rabbit_durable_queue, size])).

quorum_clean_session_false(Config) ->
    Default = rpc(Config, reader_SUITE, get_env, []),
    rpc(Config, reader_SUITE, set_env, [quorum]),
    validate_durable_queue_type(Config, <<"quorumCleanSessionFalse">>, false, rabbit_quorum_queue),
    rpc(Config, reader_SUITE, set_env, [Default]).

quorum_clean_session_true(Config) ->
    Default = rpc(Config, reader_SUITE, get_env, []),
    rpc(Config, reader_SUITE, set_env, [quorum]),
    %% Since we use a clean session and quorum queues cannot be auto-delete or exclusive,
    %% we expect a classic queue.
    validate_durable_queue_type(Config, <<"quorumCleanSessionTrue">>, true, rabbit_classic_queue),
    rpc(Config, reader_SUITE, set_env, [Default]).

classic_clean_session_true(Config) ->
    validate_durable_queue_type(Config, <<"classicCleanSessionTrue">>, true, rabbit_classic_queue).

classic_clean_session_false(Config) ->
    validate_durable_queue_type(Config, <<"classicCleanSessionFalse">>, false, rabbit_classic_queue).

will(Config) ->
    Topic = <<"will/topic">>,
    Msg = <<"will msg">>,
    Publisher = connect(<<"will-publisher">>, Config, [{will_topic, Topic},
                                                       {will_payload, Msg},
                                                       {will_qos, qos0},
                                                       {will_retain, false}]),
    timer:sleep(100),
    [ServerPublisherPid] = all_connection_pids(Config),

    Subscriber = connect(<<"will-subscriber">>, Config),
    {ok, _, _} = emqtt:subscribe(Subscriber, Topic, qos0),

    true = unlink(Publisher),
    erlang:exit(ServerPublisherPid, test_will),
    ok = expect_publishes(Topic, [Msg]),

    ok = emqtt:disconnect(Subscriber).

rpc(Config, M, F, A) ->
    rpc(Config, 0, M, F, A).
