"""
Environment variables:

  - `AWS_CRT_MEMORY_TRACING`: Set to `0`, `1`, or `2` to enable memory tracing. Default is off. See [`aws_mem_trace_level`](@ref).
  - `AWS_CRT_MEMORY_TRACING_FRAMES_PER_STACK`: Set the number of frames per stack for memory tracing. Default is the AWS library's default.
  - `AWS_CRT_LOG_LEVEL`: Set to `0` through `6` to enable logging. Default is off. See [`aws_log_level`](@ref).
  - `AWS_CRT_LOG_PATH`: Set to the log file path. Must be set if `AWS_CRT_LOG_LEVEL` is set.

Note: all the symbols in this package that begin with underscores are private and are not part of this package's published interface. Please don't use them.
"""
module AWSCRT

using LibAWSCRT, ForeignCallbacks, CountDownLatches, CEnum, JSON
import Base: lock, unlock

const _AWSCRT_ALLOCATOR = Ref{Union{Ptr{aws_allocator},Nothing}}(nothing)
const _GLOBAL_REFS = Vector{Ref}()
const _LIBPTR = Ref{Ptr{Cvoid}}(Ptr{Cvoid}(0))

function __init__()
    _LIBPTR[] = Libc.Libdl.dlopen(LibAWSCRT.libawscrt)

    _AWSCRT_ALLOCATOR[] = let level = get(ENV, "AWS_CRT_MEMORY_TRACING", "")
        if !isempty(level)
            level = parse(Int, strip(level))
            level = aws_mem_trace_level(level)
            if Symbol(level) == :UnknownMember
                error(
                    "Invalid value for env var AWS_CRT_MEMORY_TRACING. " *
                    "See aws_mem_trace_level docs for valid values.",
                )
            end
            frames_per_stack = parse(Int, strip(get(ENV, "AWS_CRT_MEMORY_TRACING_FRAMES_PER_STACK", "0")))
            aws_mem_tracer_new(aws_default_allocator(), C_NULL, level, frames_per_stack)
        else
            aws_default_allocator()
        end
    end

    let log_level = get(ENV, "AWS_CRT_LOG_LEVEL", "")
        if !isempty(log_level)
            log_level = parse(Int, strip(log_level))
            log_level = aws_log_level(log_level)
            if Symbol(log_level) == :UnknownMember
                error("Invalid value for env var AWS_CRT_LOG_LEVEL. See aws_log_level docs for valid values.")
            end

            log_path = get(ENV, "AWS_CRT_LOG_PATH", "")
            if isempty(log_path)
                error("Env var AWS_CRT_LOG_PATH must be set to the path at which to save the log file.")
            end
            log_path = Ref(deepcopy(log_path))
            push!(_GLOBAL_REFS, log_path)

            logger = Ref(aws_logger(C_NULL, C_NULL, C_NULL))
            push!(_GLOBAL_REFS, logger)

            logger_options =
                Ref(aws_logger_standard_options(log_level, Base.unsafe_convert(Ptr{Cchar}, log_path[]), C_NULL))
            push!(_GLOBAL_REFS, logger_options)

            aws_logger_init_standard(logger, _AWSCRT_ALLOCATOR[], logger_options)
            aws_logger_set(logger)
        end
    end

    aws_mqtt_library_init(_AWSCRT_ALLOCATOR[]) # also does io and http

    # TODO try cleanup using this approach https://github.com/JuliaLang/julia/pull/20124/files
end

function _release(; include_mem_tracer = isempty(get(ENV, "AWS_CRT_MEMORY_TRACING", "")))
    aws_thread_set_managed_join_timeout_ns(5e8) # 0.5 seconds

    i = findfirst(x -> x isa Ref{aws_logger}, _GLOBAL_REFS)
    if i !== nothing
        aws_logger_clean_up(_GLOBAL_REFS[i])
    end

    aws_mqtt_library_clean_up() # also does io and http
    empty!(_GLOBAL_REFS)
    if include_mem_tracer
        aws_mem_tracer_destroy(_AWSCRT_ALLOCATOR[])
    end
    return nothing
end

aws_err_string(code = aws_last_error()) = "AWS Error $code: " * Base.unsafe_string(aws_error_debug_str(code))

const advanced_use_note =
    "Note on advanced use: the internal constructor on this struct has been left at its " *
    "default so that you can bring your own native data if you need to. However, you are then responsible for the " *
    "memory management of that data."

include("AWSIO.jl")
export EventLoopGroup
export get_or_create_default_event_loop_group
export HostResolver
export get_or_create_default_host_resolver
export ClientBootstrap
export get_or_create_default_client_bootstrap
export create_client_with_mtls_from_path
export create_client_with_mtls
export create_server_from_path
export create_server
export ClientTLSContext
export TLSConnectionOptions

include("AWSMQTT.jl")
export MQTTClient
export OnConnectionInterrupted
export OnConnectionResumed
export OnMessage
export MQTTConnection
export Will
export connect
export disconnect
export subscribe
export on_message
export unsubscribe
export resubscribe_existing_topics
export publish

include("IOTShadow.jl")
export ShadowClient

include("ShadowFramework.jl")
export ShadowFramework
export shadow_client

end
