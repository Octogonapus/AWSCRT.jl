@testset "connect with lifecycle callbacks does not throw UndefVarError" begin
    client = MQTTClient(nothing)
    connection = MQTTConnection(client)
    try
        task = connect(
            connection,
            "127.0.0.1",
            1,
            "awscrt-connect-callback-test";
            on_connection_interrupted = (conn, error_code) -> nothing,
            on_connection_resumed = (conn, return_code, session_present) -> nothing,
        )
        @test task isa Task
        @test count(k -> k isa AWSCRT._OnConnectionInterruptedUserData, keys(AWSCRT._C_IDS)) >= 1
        @test count(k -> k isa AWSCRT._OnConnectionResumedUserData, keys(AWSCRT._C_IDS)) >= 1
    finally
        try
            fetch(disconnect(connection))
        catch
        end
    end
end
