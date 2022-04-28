ENV["AWS_CRT_MEMORY_TRACING"] = "1"
ENV["AWS_CRT_LOG_LEVEL"] = "6"
ENV["AWS_CRT_LOG_PATH"] = joinpath(@__DIR__, "log.txt")

using Test
using AWSCRT, LibAWSCRT
import Random

@testset "AWSCRT" begin
    topic1 = "test-topic"
    payload1 = Random.randstring(48)
    tls_ctx_options = TLSContextOptions(;
        ca_filepath = joinpath(@__DIR__, "certs", "AmazonRootCA1.pem"),
        cert_data = ENV["CERT_STRING"],
        pk_data = ENV["PRI_KEY_STRING"],
        alpn_list = ["x-amzn-mqtt-ca"],
    )
    tls_ctx = ClientTLSContext(tls_ctx_options)
    client = Client(; tls_ctx)
    connection = Connection(client)
    task = connect(
        connection,
        ENV["ENDPOINT"],
        8883,
        "test-client-id2";
        will = Will(topic1, AWS_MQTT_QOS_AT_LEAST_ONCE, "The client has gone offline!", false),
    )
    @test fetch(task) == Dict(:session_present => false)

    sub_msg = Channel(1)
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

    task, id = unsubscribe(connection, topic1)
    @test fetch(task) == Dict(:packet_id => id)

    task = disconnect(connection)
    @test fetch(task) === nothing
end
