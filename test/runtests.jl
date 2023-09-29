rm(joinpath(@__DIR__, "log.txt"); force = true)

ENV["AWS_CRT_MEMORY_TRACING"] = "1"
ENV["AWS_CRT_LOG_LEVEL"] = "6"
ENV["AWS_CRT_LOG_PATH"] = joinpath(@__DIR__, "log.txt")
ENV["JULIA_DEBUG"] = "AWSCRT"

using Test, AWSCRT, AWSCRT.LibAWSCRT, JSON, CountDownLatches, Random

include("util.jl")

@testset "AWSCRT" begin
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
