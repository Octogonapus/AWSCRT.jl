module Foo

using AWSCRT
using Random
using Test

function start()
    if ENV["MQTT_ENABLED"] == "true"
        tls_ctx_options = create_client_with_mtls(
            ENV["CERT_STRING"],
            ENV["PRI_KEY_STRING"],
            ca_filepath = joinpath(dirname(dirname(@__DIR__)), "test", "certs", "AmazonRootCA1.pem"),
        )
        tls_ctx = ClientTLSContext(tls_ctx_options)
        client = MQTTClient(tls_ctx)
        connection = MQTTConnection(client)
        client_id = "unknown-client-id-$(Random.randstring(6))"
        @show client_id
        task = connect(
            connection,
            ENV["ENDPOINT"],
            8883,
            client_id;
            on_connection_interrupted = (conn, error_code) -> begin
                @warn "connection interrupted" error_code
            end,
            on_connection_resumed = (conn, return_code, session_present) -> begin
                @info "connection resumed" return_code session_present
            end,
        )
        resp = fetch(task)
        @show resp
        if resp != Dict(:session_present => false)
            error("connect returned bad response: $resp")
        end
    end
    return nothing
end

end
