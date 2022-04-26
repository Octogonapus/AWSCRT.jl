"""
Environment variables:
- `AWS_CRT_MEMORY_TRACING`: Set to `0`, `1`, or `2` to enable memory tracing. Default is off. See [`aws_mem_trace_level`](@ref).
- `AWS_CRT_MEMORY_TRACING_FRAMES_PER_STACK`: Set the number of frames per stack for memory tracing. Default is the AWS library's default.
"""
module AWSCRT

using LibAWSCRT

include("AWSIO.jl")
export EventLoopGroup

include("AWSMQTT.jl")

end
