import Base: ==, isequal

const thing1_name = "AWSCRT_Test1"

abstract type Comparable end

==(a::T, b::T) where {T<:Comparable} = isequal(a, b)

function isequal(a::T, b::T) where {T<:Comparable}
    f = fieldnames(T)
    isequal(getfield.(Ref(a), f), getfield.(Ref(b), f))
end

function wait_for(predicate, timeout = Timer(5))
    while !predicate() && isopen(timeout)
        sleep(0.1)
    end

    if !isopen(timeout)
        error("wait_for timeout")
    end
end

sort_pairs(it) = sort(it; by = x -> x[begin])

function new_tls_ctx()
    tls_ctx_options = create_client_with_mtls(
        (@something get(ENV, "CERT_STRING", nothing) read(get(ENV, "CERT_PATH", nothing), String)),
        (@something get(ENV, "PRI_KEY_STRING", nothing) read(get(ENV, "PRI_KEY_PATH", nothing), String)),
        ca_filepath = joinpath(@__DIR__, "certs", "AmazonRootCA1.pem"),
    )
    return ClientTLSContext(tls_ctx_options)
end

function new_mqtt_connection()
    client = MQTTClient(new_tls_ctx())
    connection = MQTTConnection(client)
    client_id = random_client_id()
    @show client_id
    task = connect(connection, ENV["ENDPOINT"], 8883, client_id)
    @test fetch(task) == Dict(:session_present => false)
    return connection
end

"""
Generates a test-independently-random client ID. Reusing the same client ID in multiple tests creates many problems.
"""
random_client_id() = randstring(MersenneTwister(), 48)

random_shadow_name() = "shadow-$(randstring(MersenneTwister(), 6))"
