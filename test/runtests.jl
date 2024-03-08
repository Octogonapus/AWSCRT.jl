include("testheader.jl")

Base.errormonitor(Threads.@spawn begin
    while true
        GC.gc(true)
        sleep(1)
    end
end)

@testset "AWSCRT" begin
    doctest(AWSCRT)
    @testset "Aqua" begin
        # TODO: see how this issue resolves and update https://github.com/JuliaTesting/Aqua.jl/issues/77#issuecomment-1166304846
        Aqua.test_all(AWSCRT, ambiguities = false)
        Aqua.test_ambiguities(AWSCRT)
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
