const _AWSCRT_ALLOCATOR = Ref{Union{Ptr{aws_allocator},Nothing}}(nothing)

function __init__()
    _AWSCRT_ALLOCATOR[] = let level = get(ENV, "AWS_CRT_MEMORY_TRACING", "")
        if !isempty(level)
            level = parse(Int, strip(level))
            level_enum = if level == 0
                AWS_MEMTRACE_NONE
            elseif level == 1
                AWS_MEMTRACE_BYTES
            elseif level == 2
                AWS_MEMTRACE_STACKS
            else
                error(
                    "Invalid value for env var AWS_CRT_MEMORY_TRACING. Valid values are 0 (AWS_MEMTRACE_NONE), 1 (AWS_MEMTRACE_BYTES), or 2 (AWS_MEMTRACE_STACKS).",
                )
            end

            frames_per_stack = parse(Int, strip(get(ENV, "AWS_CRT_MEMORY_TRACING_FRAMES_PER_STACK", "0")))
            aws_mem_tracer_new(aws_default_allocator(), C_NULL, level_enum, frames_per_stack)
        else
            aws_default_allocator()
        end
    end
    # TODO config logger here
    aws_io_library_init(_AWSCRT_ALLOCATOR[])
    # TODO try cleanup using this approach https://github.com/JuliaLang/julia/pull/20124/files
end

mutable struct EventLoopGroup
    ptr::Ptr{aws_event_loop_group}

    function EventLoopGroup(num_threads::Union{Int,Nothing} = nothing, cpu_group::Union{Int,Nothing} = nothing)
        if num_threads === nothing
            num_threads = 0
        end

        is_pinned = !isnothing(cpu_group)
        if cpu_group === nothing
            cpu_group = 0
        end

        ptr = if is_pinned
            aws_event_loop_group_new_default_pinned_to_cpu_group(_AWSCRT_ALLOCATOR[], num_threads, cpu_group, C_NULL)
        else
            aws_event_loop_group_new_default(_AWSCRT_ALLOCATOR[], num_threads, C_NULL)
        end
        if ptr == C_NULL
            error("Failed to create EventLoopGroup.")
        end

        out = new(ptr)
        return finalizer(out) do x
            aws_event_loop_group_release(x.ptr)
        end
    end
end

mutable struct HostResolver
    ptr::Ptr{aws_host_resolver}

    function HostResolver(el_group::EventLoopGroup, max_hosts::Int = 16)
        if max_hosts <= 0
            error("max_hosts must be greater than 0, got $max_hosts")
        end
        options = Ref(aws_host_resolver_default_options(max_hosts, el_group.ptr, C_NULL, C_NULL))
        ptr = aws_host_resolver_new_default(_AWSCRT_ALLOCATOR[], options)
        if ptr == C_NULL
            error("Failed to create host resolver")
        end
        out = new(ptr)
        return finalize(out) do x
            aws_host_resolver_release(x.ptr)
        end
    end
end

mutable struct ClientBootstrap
    ptr::Ptr{aws_client_bootstrap}

    function ClientBootstrap(
        el_group::EventLoopGroup,
        host_resolver::HostResolver,
    )
        options = Ref(aws_client_bootstrap_options(el_group.ptr, host_resolver.ptr, C_NULL, C_NULL, C_NULL))
        ptr = aws_client_bootstrap_new(_AWSCRT_ALLOCATOR[], options)
        if ptr == C_NULL
            error("Failed to create client bootstrap")
        end
        out = new(ptr)
        return finalize(out) do x
            aws_client_bootstrap_release(x.ptr)
        end
    end
end

mutable struct TLSContextOptions
end
