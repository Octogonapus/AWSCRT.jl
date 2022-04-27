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
            error("Failed to create EventLoopGroup. $(aws_err_string())")
        end

        out = new(ptr)
        return finalizer(out) do x
            aws_event_loop_group_release(x.ptr)
        end
    end
end

const event_loop_group_default_lock = ReentrantLock()
const event_loop_group_default = Ref{Union{EventLoopGroup,Nothing}}(nothing)
get_or_create_default_event_loop_group() =
    lock(event_loop_group_default_lock) do
        event_loop_group_default[] === nothing ? event_loop_group_default[] = EventLoopGroup() :
        event_loop_group_default[]
    end
release_default_event_loop_group() =
    lock(event_loop_group_default_lock) do
        event_loop_group_default[] = nothing
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
            error("Failed to create host resolver. $(aws_err_string())")
        end
        out = new(ptr)
        return finalizer(out) do x
            aws_host_resolver_release(x.ptr)
        end
    end
end

const host_resolver_default_lock = ReentrantLock()
const host_resolver_default = Ref{Union{HostResolver,Nothing}}(nothing)
get_or_create_default_host_resolver() =
    lock(host_resolver_default_lock) do
        host_resolver_default[] === nothing ?
        host_resolver_default[] = HostResolver(get_or_create_default_event_loop_group()) : host_resolver_default[]
    end
release_default_host_resolver() =
    lock(host_resolver_default_lock) do
        host_resolver_default[] = nothing
    end

mutable struct ClientBootstrap
    ptr::Ptr{aws_client_bootstrap}

    function ClientBootstrap(el_group::EventLoopGroup, host_resolver::HostResolver)
        options = Ref(aws_client_bootstrap_options(el_group.ptr, host_resolver.ptr, C_NULL, C_NULL, C_NULL))
        ptr = aws_client_bootstrap_new(_AWSCRT_ALLOCATOR[], options)
        if ptr == C_NULL
            error("Failed to create client bootstrap. $(aws_err_string())")
        end
        out = new(ptr)
        return finalizer(out) do x
            aws_client_bootstrap_release(x.ptr)
        end
    end
end

const client_bootstrap_default_lock = ReentrantLock()
const client_bootstrap_default = Ref{Union{ClientBootstrap,Nothing}}(nothing)
get_or_create_default_client_bootstrap() =
    lock(client_bootstrap_default_lock) do
        client_bootstrap_default[] === nothing ?
        client_bootstrap_default[] =
            ClientBootstrap(get_or_create_default_event_loop_group(), get_or_create_default_host_resolver()) :
        client_bootstrap_default[]
    end
release_default_client_bootstrap() =
    lock(client_bootstrap_default_lock) do
        client_bootstrap_default[] = nothing
    end

mutable struct TLSContextOptions
    min_tls_version::aws_tls_versions
    ca_dirpath::Union{String,Nothing}
    ca_filepath::Union{String,Nothing}
    ca_data::Union{String,Nothing}
    alpn_list::Union{Vector{String},Nothing}
    cert_data::Union{String,Nothing}
    pk_data::Union{String,Nothing}
    verify_peer::Bool
    # TODO pkcs11
    # TODO pkcs12
    # TODO windows cert store

    function TLSContextOptions(;
        min_tls_version::aws_tls_versions = AWS_IO_TLS_VER_SYS_DEFAULTS,
        ca_dirpath::Union{String,Nothing} = nothing,
        ca_filepath::Union{String,Nothing} = nothing,
        ca_data::Union{String,Nothing} = nothing,
        alpn_list::Union{Vector{String},Nothing} = nothing,
        cert_data::Union{String,Nothing} = nothing,
        pk_data::Union{String,Nothing} = nothing,
        verify_peer::Bool = true,
    )
        new(min_tls_version, ca_dirpath, ca_filepath, ca_data, alpn_list, cert_data, pk_data, verify_peer)
    end
end

mutable struct ClientTLSContext
    ptr::Ptr{aws_tls_ctx}

    function ClientTLSContext(options::TLSContextOptions)
        tls_ctx_opt = Ref(aws_tls_ctx_options(ntuple(_ -> UInt8(0), 200)))
        GC.@preserve tls_ctx_opt begin
            tls_ctx_opt_ptr = Base.unsafe_convert(Ptr{aws_tls_ctx_options}, tls_ctx_opt)

            # TODO pkcs11
            # TODO pkcs12
            # TODO windows cert store
            if options.cert_data !== nothing
                # mTLS with certificate and private key
                cert = Ref(aws_byte_cursor_from_c_str(options.cert_data))
                key = Ref(aws_byte_cursor_from_c_str(options.pk_data))
                if aws_tls_ctx_options_init_client_mtls(tls_ctx_opt_ptr, _AWSCRT_ALLOCATOR[], cert, key) != AWS_OP_SUCCESS
                    error("Failed to create client TLS context. $(aws_err_string())")
                end
            else
                # no mTLS
                aws_tls_ctx_options_init_default_client(tls_ctx_opt_ptr, _AWSCRT_ALLOCATOR[])
            end

            tls_ctx_opt_ptr.minimum_tls_version = options.min_tls_version

            try
                if options.ca_dirpath !== nothing || options.ca_filepath !== nothing
                    if aws_tls_ctx_options_override_default_trust_store_from_path(
                        tls_ctx_opt_ptr,
                        options.ca_dirpath === nothing ? C_NULL : options.ca_dirpath,
                        options.ca_filepath === nothing ? C_NULL : options.ca_filepath,
                    ) != AWS_OP_SUCCESS
                        error("Failed to override trust store from path. $(aws_err_string())")
                    end
                end

                if options.ca_data !== nothing
                    ca = Ref(aws_byte_cursor_from_c_str(options.ca_data))
                    if aws_tls_ctx_options_override_default_trust_store(tls_ctx_opt_ptr, ca) !== AWS_OP_SUCCESS
                        error("Failed to override trust store. $(aws_err_string())")
                    end
                end

                if options.alpn_list !== nothing
                    alpn_list_string = join(options.alpn_list, ';')
                    if aws_tls_ctx_options_set_alpn_list(tls_ctx_opt_ptr, alpn_list_string) != AWS_OP_SUCCESS
                        error("Failed to set ALPN list. $(aws_err_string())")
                    end
                end

                tls_ctx_opt_ptr.verify_peer = options.verify_peer

                tls_ctx = aws_tls_client_ctx_new(_AWSCRT_ALLOCATOR[], tls_ctx_opt_ptr)
                if tls_ctx == C_NULL
                    error("Failed to create TLS context. $(aws_err_string())")
                end

                out = new(tls_ctx)
                return finalizer(out) do x
                    aws_tls_ctx_release(x.ptr)
                end
            catch
                aws_tls_ctx_options_clean_up(tls_ctx_opt_ptr)
                rethrow()
            end
        end
    end
end

mutable struct TLSConnectionOptions
    ptr::Ref{aws_tls_connection_options}

    function TLSConnectionOptions(
        client_tls_context::ClientTLSContext,
        alpn_list::Union{Vector{String},Nothing} = nothing,
        server_name::Union{String,Nothing} = nothing,
    )
        tls_connection_options = Ref(aws_tls_connection_options(C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, false, 0))
        aws_tls_connection_options_init_from_ctx(tls_connection_options, client_tls_context.ptr)

        try
            if alpn_list !== nothing
                alpn_list_string = join(alpn_list, ';')
                if aws_tls_connection_options_set_alpn_list(tls_connection_options, _AWSCRT_ALLOCATOR[], alpn_list_string) != AWS_OP_SUCCESS
                    error("Failed to set ALPN list. $(aws_err_string())")
                end
            end
    
            if server_name !== nothing
                server_name_cur = Ref(aws_byte_cursor_from_c_str(server_name))
                if aws_tls_connection_options_set_server_name(tls_connection_options, _AWSCRT_ALLOCATOR[], server_name_cur) != AWS_OP_SUCCESS
                    error("Failed to set server name. $(aws_err_string())")
                end
            end

            out = new(tls_connection_options)
            return finalizer(out) do x
                aws_tls_connection_options_clean_up(x.ptr)
            end
        catch
            aws_tls_connection_options_clean_up(tls_connection_options)
            rethrow()
        end
    end
end
