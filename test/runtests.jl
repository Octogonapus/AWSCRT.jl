ENV["AWS_CRT_MEMORY_TRACING"] = "1"
ENV["AWS_CRT_LOG_LEVEL"] = "6"
ENV["AWS_CRT_LOG_PATH"] = joinpath(@__DIR__, "log.txt")

using Test
using AWSCRT, LibAWSCRT

@testset "AWSCRT" begin
    topic = "test-topic"
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
        will = Will(topic, AWS_MQTT_QOS_AT_LEAST_ONCE, "The client has gone offline!", false),
    )
    @show fetch(task)
end
