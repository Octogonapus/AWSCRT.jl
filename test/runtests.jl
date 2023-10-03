rm(joinpath(@__DIR__, "log.txt"); force = true)

ENV["AWS_CRT_MEMORY_TRACING"] = "1"
ENV["AWS_CRT_LOG_LEVEL"] = "6"
ENV["AWS_CRT_LOG_PATH"] = joinpath(@__DIR__, "log.txt")
ENV["JULIA_DEBUG"] = "AWSCRT"

using Test, AWSCRT, LibAWSCRT, JSON, CountDownLatches, Random, Documenter, Aqua

include("util.jl")

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
