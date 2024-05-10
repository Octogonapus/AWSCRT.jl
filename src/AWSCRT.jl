"""
Environment variables:

  - `AWS_CRT_MEMORY_TRACING`: Set to `0`, `1`, or `2` to enable memory tracing. Default is off. See `aws_mem_trace_level`.
  - `AWS_CRT_MEMORY_TRACING_FRAMES_PER_STACK`: Set the number of frames per stack for memory tracing. Default is the AWS library's default.
  - `AWS_CRT_LOG_LEVEL`: Set to `0` through `6` to enable logging. Default is off. See [`aws_log_level`](https://juliaservices.github.io/LibAwsCommon.jl/dev/#LibAwsCommon.aws_log_level).
  - `AWS_CRT_LOG_PATH`: Set to the log file path. Must be set if `AWS_CRT_LOG_LEVEL` is set.

Note: all the symbols in this package that begin with underscores are private and are not part of this package's published interface. Please don't use them.
"""
module AWSCRT

using CountDownLatches, JSON, LibAwsCommon, LibAwsIO, LibAwsMqtt
import Base: lock, unlock
export lock, unlock

const _C_IDS_LOCK = ReentrantLock()
const _C_IDS = IdDict{Any,Any}()

const _C_ON_ANY_MESSAGE_IDS_LOCK = ReentrantLock()
const _C_ON_ANY_MESSAGE_IDS = IdDict{Any,Any}()

# set during __init__
const _LIB_COMMON_PTR = Ref{Ptr{Cvoid}}(Ptr{Cvoid}(0))
const _AWSCRT_ALLOCATOR = Ref{Union{Ptr{aws_allocator},Nothing}}(nothing)

# cfunctions set during __init__
const _C_ON_CONNECTION_INTERRUPTED = Ref{Ptr{Cvoid}}(C_NULL)
const _C_ON_CONNECTION_RESUMED = Ref{Ptr{Cvoid}}(C_NULL)
const _C_ON_CONNECTION_COMPLETE = Ref{Ptr{Cvoid}}(C_NULL)
const _C_ON_DISCONNECT_COMPLETE = Ref{Ptr{Cvoid}}(C_NULL)
const _C_ON_SUBSCRIBE_MESSAGE = Ref{Ptr{Cvoid}}(C_NULL)
const _C_ON_ANY_MESSAGE = Ref{Ptr{Cvoid}}(C_NULL)
const _C_ON_SUBSCRIBE_COMPLETE = Ref{Ptr{Cvoid}}(C_NULL)
const _C_ON_UNSUBSCRIBE_COMPLETE = Ref{Ptr{Cvoid}}(C_NULL)
const _C_ON_RESUBSCRIBE_COMPLETE = Ref{Ptr{Cvoid}}(C_NULL)
const _C_ON_PUBLISH_COMPLETE = Ref{Ptr{Cvoid}}(C_NULL)

function _release(; include_mem_tracer = isempty(get(ENV, "AWS_CRT_MEMORY_TRACING", "")))
    aws_thread_set_managed_join_timeout_ns(5e8) # 0.5 seconds

    lock(_C_IDS_LOCK) do
        logger = findfirst(x -> x isa Ref{aws_logger}, keys(_C_IDS))
        if logger !== nothing
            aws_logger_clean_up(logger)
        end

        aws_mqtt_library_clean_up() # also does io and http
        empty!(_C_IDS)
        if include_mem_tracer
            aws_mem_tracer_destroy(_AWSCRT_ALLOCATOR[])
        end
        return nothing
    end
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
export OnShadowMessage

include("ShadowFramework.jl")
export ShadowFramework
export ShadowDocumentPropertyUpdateCallback
export ShadowDocumentPreUpdateCallback
export ShadowDocumentPostUpdateCallback
export shadow_client
export publish_current_state
export wait_until_synced

function __init__()
    _LIB_COMMON_PTR[] = Libc.Libdl.dlopen(LibAwsCommon.libaws_c_common)

    _C_ON_CONNECTION_INTERRUPTED[] =
        @cfunction(_c_on_connection_interrupted, Cvoid, (Ptr{aws_mqtt_client_connection}, Cint, Ptr{Cvoid}))
    _C_ON_CONNECTION_RESUMED[] =
        @cfunction(_c_on_connection_resumed, Cvoid, (Ptr{aws_mqtt_client_connection}, Cint, Cint, Ptr{Cvoid}))
    _C_ON_CONNECTION_COMPLETE[] =
        @cfunction(_c_on_connection_complete, Cvoid, (Ptr{aws_mqtt_client_connection}, Cint, Cint, Cuchar, Ptr{Cvoid}))
    _C_ON_DISCONNECT_COMPLETE[] =
        @cfunction(_c_on_disconnect_complete, Cvoid, (Ptr{aws_mqtt_client_connection}, Ptr{Cvoid}))
    _C_ON_SUBSCRIBE_MESSAGE[] = @cfunction(
        _c_on_subscribe_message,
        Cvoid,
        (Ptr{aws_mqtt_client_connection}, Ptr{aws_byte_cursor}, Ptr{aws_byte_cursor}, Cuchar, Cint, Cuchar, Ptr{Cvoid})
    )
    _C_ON_ANY_MESSAGE[] = @cfunction(
        _c_on_any_message,
        Cvoid,
        (Ptr{aws_mqtt_client_connection}, Ptr{aws_byte_cursor}, Ptr{aws_byte_cursor}, Cuchar, Cint, Cuchar, Ptr{Cvoid})
    )
    _C_ON_SUBSCRIBE_COMPLETE[] = @cfunction(
        _c_on_subscribe_complete,
        Cvoid,
        (Ptr{aws_mqtt_client_connection}, Cuint, Ptr{aws_byte_cursor}, Cint, Cint, Ptr{Cvoid})
    )
    _C_ON_UNSUBSCRIBE_COMPLETE[] =
        @cfunction(_c_on_unsubscribe_complete, Cvoid, (Ptr{aws_mqtt_client_connection}, Cuint, Cint, Ptr{Cvoid}))
    _C_ON_RESUBSCRIBE_COMPLETE[] = @cfunction(
        _c_on_resubscribe_complete,
        Cvoid,
        (Ptr{aws_mqtt_client_connection}, Cuint, Ptr{aws_array_list}, Cint, Ptr{Cvoid})
    )
    _C_ON_PUBLISH_COMPLETE[] =
        @cfunction(_c_on_publish_complete, Cvoid, (Ptr{aws_mqtt_client_connection}, Cuint, Cint, Ptr{Cvoid}))

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
            logger = Ref(aws_logger(C_NULL, C_NULL, C_NULL))
            logger_options =
                Ref(aws_logger_standard_options(log_level, Base.unsafe_convert(Ptr{Cchar}, log_path[]), C_NULL))

            lock(_C_IDS_LOCK) do
                _C_IDS[log_path] = nothing
                _C_IDS[logger] = nothing
                _C_IDS[logger_options] = nothing
            end

            aws_logger_init_standard(logger, _AWSCRT_ALLOCATOR[], logger_options)
            aws_logger_set(logger)
        end
    end

    aws_mqtt_library_init(_AWSCRT_ALLOCATOR[]) # also does io and http

    # TODO try cleanup using this approach https://github.com/JuliaLang/julia/pull/20124/files
end

end
