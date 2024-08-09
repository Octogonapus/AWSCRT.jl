@testset "interrupt and resume connection" begin
    topic1 = "test-topic-$(Random.randstring(6))"
    payload1 = Random.randstring(48)
    client_id1 = random_client_id()
    @show topic1 payload1 client_id1

    client = MQTTClient(new_tls_ctx())
    connection = MQTTConnection(client)

    interruptions = Threads.Atomic{Int}(0)
    resumes = Threads.Atomic{Int}(0)

    task = connect(
        connection,
        ENV["ENDPOINT"],
        8883,
        client_id1;
        will = Will(topic1, AWS_MQTT_QOS_AT_LEAST_ONCE, "The client has gone offline!", false),
        on_connection_interrupted = (conn, error_code) -> begin
            Threads.atomic_add!(interruptions, 1)
            @warn "connection interrupted" error_code
        end,
        on_connection_resumed = (conn, return_code, session_present) -> begin
            Threads.atomic_add!(resumes, 1)
            @info "connection resumed" return_code session_present
        end,
    )
    @test fetch(task) == Dict(:session_present => false)

    # kill the MQTT connection
    run(`sudo ss -K dport = 8883`)

    wait_for(() -> resumes[] > 0, Timer(30))
    @test interruptions[] == 1
    @test resumes[] == 1

    disconnect(connection)
end
