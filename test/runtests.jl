ENV["AWS_CRT_MEMORY_TRACING"] = "1"
ENV["AWS_CRT_LOG_LEVEL"] = "6"
ENV["AWS_CRT_LOG_PATH"] = joinpath(@__DIR__, "log.txt")

using Test, AWSCRT, AWSCRT.LibAWSCRT, JSON
import Random

function wait_for(predicate, timeout = Timer(5))
    while !predicate() && isopen(timeout)
        sleep(0.1)
    end

    if !isopen(timeout)
        error("wait_for timeout")
    end
end

@testset "AWSCRT" begin
    @testset "MQTT pub/sub integration test" begin
        topic1 = "test-topic"
        payload1 = Random.randstring(48)
        client_id = Random.randstring(48)
        @show topic1 payload1 client_id
        tls_ctx_options = create_client_with_mtls(
            ENV["CERT_STRING"],
            ENV["PRI_KEY_STRING"],
            ca_filepath = joinpath(@__DIR__, "certs", "AmazonRootCA1.pem"),
        )
        tls_ctx = ClientTLSContext(tls_ctx_options)
        client = MQTTClient(tls_ctx)
        connection = MQTTConnection(client)

        any_msg = Channel(1)
        sub_msg = Channel(1)

        on_message(
            connection,
            (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) -> begin
                put!(any_msg, (; topic, payload, qos, retain))
            end,
        )

        task = connect(
            connection,
            ENV["ENDPOINT"],
            8883,
            client_id;
            will = Will(topic1, AWS_MQTT_QOS_AT_LEAST_ONCE, "The client has gone offline!", false),
            on_connection_interrupted = (conn, error_code) -> begin
                @warn "connection interrupted" error_code
            end,
            on_connection_resumed = (conn, return_code, session_present) -> begin
                @info "connection resumed" return_code session_present
            end,
        )
        @test fetch(task) == Dict(:session_present => false)

        # Subscribe, publish a message, and test we get it on both callbacks
        task, id = subscribe(
            connection,
            topic1,
            AWS_MQTT_QOS_AT_LEAST_ONCE,
            (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) -> begin
                put!(sub_msg, (; topic, payload, qos, retain))
            end,
        )
        d = fetch(task)
        @test d[:packet_id] == id
        @test d[:topic] == topic1
        @test d[:qos] == AWS_MQTT_QOS_AT_LEAST_ONCE

        task, id = resubscribe_existing_topics(connection)
        d = fetch(task)
        @test d[:packet_id] == id
        @test d[:topics] == [(topic1, AWS_MQTT_QOS_AT_LEAST_ONCE)]

        task, id = publish(connection, topic1, payload1, AWS_MQTT_QOS_AT_LEAST_ONCE)
        @test fetch(task) == Dict(:packet_id => id)

        msg = take!(sub_msg)
        @test msg.topic == topic1
        @test msg.payload == payload1
        @test msg.qos == AWS_MQTT_QOS_AT_LEAST_ONCE
        @test !msg.retain

        msg = take!(any_msg)
        @test msg.topic == topic1
        @test msg.payload == payload1
        @test msg.qos == AWS_MQTT_QOS_AT_LEAST_ONCE
        @test !msg.retain

        # Unsubscribe, publish, and test we get nothing
        task, id = unsubscribe(connection, topic1)
        @test fetch(task) == Dict(:packet_id => id)

        task, id = publish(connection, topic1, payload1, AWS_MQTT_QOS_AT_LEAST_ONCE)
        @test fetch(task) == Dict(:packet_id => id)

        sleep(0.5)
        @test !isready(sub_msg)
        @test !isready(any_msg)

        # Disconnect, clear the on_message callback, and go around again
        task = disconnect(connection)
        @test fetch(task) === nothing

        on_message(connection, nothing)

        task = connect(
            connection,
            ENV["ENDPOINT"],
            8883,
            "test-client-id2";
            will = Will(topic1, AWS_MQTT_QOS_AT_LEAST_ONCE, "The client has gone offline!", false),
        )
        @test fetch(task) == Dict(:session_present => false)

        # Subscribe, publish a message, and test we only get it on the subscribe callback
        task, id = subscribe(
            connection,
            topic1,
            AWS_MQTT_QOS_AT_LEAST_ONCE,
            (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) -> begin
                put!(sub_msg, (; topic, payload, qos, retain))
            end,
        )
        d = fetch(task)
        @test d[:packet_id] == id
        @test d[:topic] == topic1
        @test d[:qos] == AWS_MQTT_QOS_AT_LEAST_ONCE

        task, id = publish(connection, topic1, payload1, AWS_MQTT_QOS_AT_LEAST_ONCE)
        @test fetch(task) == Dict(:packet_id => id)

        msg = take!(sub_msg)
        @test msg.topic == topic1
        @test msg.payload == payload1
        @test msg.qos == AWS_MQTT_QOS_AT_LEAST_ONCE
        @test !msg.retain

        sleep(0.5)
        @test !isready(any_msg)

        # Shut down
        task, id = unsubscribe(connection, topic1)
        @test fetch(task) == Dict(:packet_id => id)

        task = disconnect(connection)
        @test fetch(task) === nothing
    end

    @testset "unnamed shadow document" begin
        tls_ctx_options = create_client_with_mtls(
            ENV["CERT_STRING"],
            ENV["PRI_KEY_STRING"],
            ca_filepath = joinpath(@__DIR__, "certs", "AmazonRootCA1.pem"),
        )
        tls_ctx = ClientTLSContext(tls_ctx_options)
        client = MQTTClient(tls_ctx)
        connection = MQTTConnection(client)
        task = connect(connection, ENV["ENDPOINT"], 8883, Random.randstring(48))
        @test fetch(task) == Dict(:session_present => false)
        shadow = ShadowClient(connection)

        msgs = []
        function shadow_callback(
            shadow_client::ShadowClient,
            topic::String,
            payload::String,
            dup::Bool,
            qos::aws_mqtt_qos,
            retain::Bool,
        )
            push!(msgs, (; shadow_client, topic, payload, dup, qos, retain))
        end

        thing_name = "AWSCRT_test_thing_1"

        try
            subscribe(shadow, thing_name, nothing, AWS_MQTT_QOS_AT_LEAST_ONCE, shadow_callback)

            publish(shadow, "/get", "", AWS_MQTT_QOS_AT_LEAST_ONCE)
            wait_for(() -> !isempty(msgs))
            @test msgs[1][:shadow_client] === shadow
            @test msgs[1][:topic] == "\$aws/things/$thing_name/shadow/get/rejected"
            @test msgs[1][:payload] ==
                  "{\"code\":404,\"message\":\"No shadow exists with name: 'AWSCRT_test_thing_1'\"}"
            empty!(msgs)

            publish(
                shadow,
                "/update",
                json(Dict("state" => Dict("reported" => Dict("foo" => 1)))),
                AWS_MQTT_QOS_AT_LEAST_ONCE,
            )
            wait_for(() -> length(msgs) >= 2)
            @test findfirst(it -> it[:topic] == "\$aws/things/$thing_name/shadow/update/accepted", msgs) !== nothing
            @test findfirst(it -> it[:topic] == "\$aws/things/$thing_name/shadow/update/documents", msgs) !== nothing
            empty!(msgs)

            publish(
                shadow,
                "/update",
                json(Dict("state" => Dict("desired" => Dict("foo" => 2)))),
                AWS_MQTT_QOS_AT_LEAST_ONCE,
            )
            wait_for(() -> length(msgs) >= 3)
            @test findfirst(it -> it[:topic] == "\$aws/things/$thing_name/shadow/update/accepted", msgs) !== nothing
            @test findfirst(it -> it[:topic] == "\$aws/things/$thing_name/shadow/update/documents", msgs) !== nothing
            let msg = msgs[findfirst(it -> it[:topic] == "\$aws/things/$thing_name/shadow/update/delta", msgs)]
                payload = JSON.parse(msg[:payload])
                @test payload["state"]["foo"] == 2
            end
            empty!(msgs)

            publish(
                shadow,
                "/update",
                json(Dict("state" => Dict("reported" => Dict("foo" => 2)))),
                AWS_MQTT_QOS_AT_LEAST_ONCE,
            )
            wait_for(() -> length(msgs) >= 2)
            @test findfirst(it -> it[:topic] == "\$aws/things/$thing_name/shadow/update/accepted", msgs) !== nothing
            @test findfirst(it -> it[:topic] == "\$aws/things/$thing_name/shadow/update/documents", msgs) !== nothing
            @test findfirst(it -> it[:topic] == "\$aws/things/$thing_name/shadow/update/delta", msgs) === nothing
            empty!(msgs)

            publish(
                shadow,
                "/update",
                json(Dict("state" => Dict("desired" => Dict("foo" => nothing)))),
                AWS_MQTT_QOS_AT_LEAST_ONCE,
            )
            wait_for(() -> length(msgs) >= 2)
            @test findfirst(it -> it[:topic] == "\$aws/things/$thing_name/shadow/update/accepted", msgs) !== nothing
            let msg = msgs[findfirst(it -> it[:topic] == "\$aws/things/$thing_name/shadow/update/documents", msgs)]
                payload = JSON.parse(msg[:payload])
                @test !haskey(payload["current"]["state"], "desired")
                @test haskey(payload["current"]["state"], "reported")
            end
            empty!(msgs)

            publish(shadow, "/delete", "", AWS_MQTT_QOS_AT_LEAST_ONCE)
            wait_for(() -> length(msgs) >= 1)
            @test findfirst(it -> it[:topic] == "\$aws/things/$thing_name/shadow/delete/accepted", msgs) !== nothing
            empty!(msgs)
        finally
            fetch(publish(shadow, "/delete", "", AWS_MQTT_QOS_AT_LEAST_ONCE))
        end
    end
end
