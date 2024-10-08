include("testheader.jl")

# Inject some chaos into the tests to help expose memory bugs
Base.errormonitor(Threads.@spawn begin
    while true
        GC.gc(true)
        try
            sleep(1)
        catch ex
            if !(ex isa EOFError)
                rethrow()
            end
        end
    end
end)

@testset "AWSCRT" begin
    if !parallel
        doctest(AWSCRT)
        @testset "Aqua" begin
            # TODO: see how this issue resolves and update https://github.com/JuliaTesting/Aqua.jl/issues/77#issuecomment-1166304846
            Aqua.test_all(AWSCRT, ambiguities = false)
            Aqua.test_ambiguities(AWSCRT)
        end
        @testset "interrupt_connection.jl" begin
            # running this in parallel will kill the connections used by other tests so don't do that
            @info "Starting interrupt_connection.jl"
            include("interrupt_connection.jl")
        end
    end
    @testset "mqtt_test.jl" begin
        @info "Starting mqtt_test.jl"
        include("mqtt_test.jl")
    end
    @testset "shadow_client_test.jl" begin
        @info "Starting shadow_client_test.jl"
        include("shadow_client_test.jl")
    end
    @testset "shadow_framework_test.jl" begin
        @info "Starting shadow_framework_test.jl"
        include("shadow_framework_test.jl")
    end
    @testset "shadow_framework_integ_test.jl" begin
        @info "Starting shadow_framework_integ_test.jl"
        include("shadow_framework_integ_test.jl")
    end
end
