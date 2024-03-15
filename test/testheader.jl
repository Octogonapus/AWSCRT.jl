parallel = false
if get(ENV, "AWSCRT_TESTS_PARALLEL", "false") == "true"
    @info "Configuring tests to run in parallel. Note not all tests will be ran."
    parallel = true
end

if !parallel
    rm(joinpath(@__DIR__, "log.txt"); force = true)
    ENV["AWS_CRT_MEMORY_TRACING"] = "1"
    ENV["AWS_CRT_LOG_LEVEL"] = "6"
    ENV["AWS_CRT_LOG_PATH"] = joinpath(@__DIR__, "log.txt")
end

ENV["JULIA_DEBUG"] = "AWSCRT"

using Test, AWSCRT, LibAWSCRT, JSON, CountDownLatches, Random, Documenter, Aqua, Dates, AWS
@service DynamoDB

include("util.jl")
