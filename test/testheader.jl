rm(joinpath(@__DIR__, "log.txt"); force = true)

ENV["AWS_CRT_MEMORY_TRACING"] = "1"
ENV["AWS_CRT_LOG_LEVEL"] = "6"
ENV["AWS_CRT_LOG_PATH"] = joinpath(@__DIR__, "log.txt")
ENV["JULIA_DEBUG"] = "AWSCRT"

using Test, AWSCRT, LibAWSCRT, JSON, CountDownLatches, Random, Documenter, Aqua

include("util.jl")
