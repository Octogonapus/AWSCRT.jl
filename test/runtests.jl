ENV["AWS_CRT_MEMORY_TRACING"] = "1"
ENV["AWS_CRT_LOG_LEVEL"] = "6"
ENV["AWS_CRT_LOG_PATH"] = joinpath(@__DIR__, "log.txt")

using Test, AWSCRT, AWS.LibAWSCRT
import Random

const client_id = Random.randstring(48)

@testset "AWSCRT" begin
    @testset "MQTT pub/sub integration test" begin
        topic1 = "test-topic"
        payload1 = Random.randstring(48)
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
end
