"""
    mutable struct EventLoopGroup
        ptr::Ptr{aws_event_loop_group}
    end

A collection of event-loops.
An event-loop is a thread for doing async work, such as I/O.

$advanced_use_note
"""
mutable struct EventLoopGroup
    ptr::Ptr{aws_event_loop_group}
end

"""
    EventLoopGroup(num_threads::Union{Int,Nothing} = nothing, cpu_group::Union{Int,Nothing} = nothing)

A collection of event-loops.
An event-loop is a thread for doing async work, such as I/O.

Arguments:

  - `num_threads (Union{Int,Nothing}) (default=nothing)`: Maximum number of event-loops to create. If unspecified, one is created for each processor on the machine.
  - `cpu_group (Union{Int,Nothing}) (default=nothing)`: Optional processor group to which all threads will be pinned. Useful for systems with non-uniform memory access (NUMA) nodes. If specified, the number of threads will be capped at the number of processors in the group.
"""
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

    out = EventLoopGroup(ptr)
    return finalizer(out) do x
        aws_event_loop_group_release(x.ptr)
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

"""
    mutable struct HostResolver
        ptr::Ptr{aws_host_resolver}
    end

Default DNS host resolver.

$advanced_use_note
"""
mutable struct HostResolver
    ptr::Ptr{aws_host_resolver}
end

"""
    HostResolver(el_group::EventLoopGroup, max_hosts::Int = 16)

Default DNS host resolver.

Arguments:

  - `el_group (EventLoopGroup)`: EventLoopGroup to use.
  - `max_hosts (Int) (default=16)`: Max host names to cache.
"""
function HostResolver(el_group::EventLoopGroup, max_hosts::Int = 16)
    if max_hosts <= 0
        error("max_hosts must be greater than 0, got $max_hosts")
    end
    options = Ref(aws_host_resolver_default_options(max_hosts, el_group.ptr, C_NULL, C_NULL))
    ptr = aws_host_resolver_new_default(_AWSCRT_ALLOCATOR[], options)
    if ptr == C_NULL
        error("Failed to create host resolver. $(aws_err_string())")
    end
    out = HostResolver(ptr)
    return finalizer(out) do x
        aws_host_resolver_release(x.ptr)
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

"""
    mutable struct ClientBootstrap
        ptr::Ptr{aws_client_bootstrap}
    end

Handles creation and setup of client socket connections.

$advanced_use_note
"""
mutable struct ClientBootstrap
    ptr::Ptr{aws_client_bootstrap}
end

"""
    ClientBootstrap(el_group::EventLoopGroup, host_resolver::HostResolver)

Handles creation and setup of client socket connections.

Arguments:

  - `el_group (EventLoopGroup)`: EventLoopGroup to use.
  - `host_resolver (HostResolver)`: DNS host resolver to use.
"""
function ClientBootstrap(el_group::EventLoopGroup, host_resolver::HostResolver)
    options = Ref(aws_client_bootstrap_options(el_group.ptr, host_resolver.ptr, C_NULL, C_NULL, C_NULL))
    ptr = aws_client_bootstrap_new(_AWSCRT_ALLOCATOR[], options)
    if ptr == C_NULL
        error("Failed to create client bootstrap. $(aws_err_string())")
    end
    out = ClientBootstrap(ptr)
    return finalizer(out) do x
        aws_client_bootstrap_release(x.ptr)
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

const extra_tls_kwargs_docs = """
- `ca_dirpath (Union{String,Nothing}) (default=nothing)`: Path to directory containing trusted certificates, which will overrides the default trust store. Only supported on Unix.
- `ca_filepath (Union{String,Nothing}) (default=nothing)`: Path to file containing PEM armored chain of trusted CA certificates.
- `ca_data (Union{String,Nothing}) (default=nothing)`: PEM armored chain of trusted CA certificates.
- `alpn_list (Union{Vector{String},Nothing}) (default=nothing)`: If set, names to use in Application Layer Protocol Negotiation (ALPN). ALPN is not supported on all systems, see [`aws_tls_is_alpn_available`](https://octogonapus.github.io/LibAWSCRT.jl/dev/#LibAWSCRT.aws_tls_is_alpn_available-Tuple{}). This can be customized per connection; see [`TLSConnectionOptions`](@ref).
"""

"""
    TLSContextOptions(;
        min_tls_version::aws_tls_versions = AWS_IO_TLS_VER_SYS_DEFAULTS,
        ca_dirpath::Union{String,Nothing} = nothing,
        ca_filepath::Union{String,Nothing} = nothing,
        ca_data::Union{String,Nothing} = nothing,
        alpn_list::Union{Vector{String},Nothing} = nothing,
        cert_data::Union{String,Nothing} = nothing,
        pk_data::Union{String,Nothing} = nothing,
        verify_peer::Bool = true,
    )

Options to create a TLS context.

Arguments:
- `min_tls_version (aws_tls_versions) (default=AWS_IO_TLS_VER_SYS_DEFAULTS)`: Minimum TLS version to use. System defaults are used by default.
$extra_tls_kwargs_docs
- `cert_data (Union{String,Nothing}) (default=nothing)`: Certificate contents. Treated as PKCS #7 PEM armored.
- `pk_data (Union{String,Nothing}) (default=nothing)`: Private key contents. Treated as PKCS #7 PEM armored.
- `verify_peer (Bool) (default=true)`: Whether to validate the peer's x.509 certificate.
"""
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

"""
    create_client_with_mtls_from_path(cert_filepath, pk_filepath; kwargs...)

Create options configured for use with mutual TLS in client mode.
Both files are treated as PKCS #7 PEM armored.
They are loaded from disk and stored in buffers internally.

Arguments:
- `cert_filepath (String)`: Path to certificate file.
- `pk_filepath (String)`: Path to private key file.
$extra_tls_kwargs_docs
"""
create_client_with_mtls_from_path(cert_filepath, pk_filepath; kwargs...) =
    create_client_with_mtls(read(cert_filepath, String), read(pk_filepath, String); kwargs...)

"""
    create_client_with_mtls(cert_data, pk_data; kwargs...)

Create options configured for use with mutual TLS in client mode.
Both buffers are treated as PKCS #7 PEM armored.

Arguments:
- `cert_data (String)`: Certificate contents
- `pk_data (String)`: Private key contents.
$extra_tls_kwargs_docs
"""
create_client_with_mtls(cert_data, pk_data; kwargs...) = TLSContextOptions(; cert_data, pk_data, kwargs...)

# TODO create_client_with_mtls_pkcs11
# TODO create_client_with_mtls_pkcs12
# TODO create_client_with_mtls_windows_cert_store_path

"""
    create_server_from_path(cert_filepath, pk_filepath; kwargs...)

Create options configured for use in server mode.
Both files are treated as PKCS #7 PEM armored.
They are loaded from disk and stored in buffers internally.

Arguments:
- `cert_filepath (String)`: Path to certificate file.
- `pk_filepath (String)`: Path to private key file.
$extra_tls_kwargs_docs
"""
create_server_from_path(cert_filepath, pk_filepath; kwargs...) =
    create_server(read(cert_filepath, String), read(pk_filepath, String); kwargs...)

"""
    create_server(cert_data, pk_data; kwargs...)

Create options configured for use in server mode.
Both buffers are treated as PKCS #7 PEM armored.

Arguments:
- `cert_data (String)`: Certificate contents
- `pk_data (String)`: Private key contents.
$extra_tls_kwargs_docs
"""
create_server(cert_data, pk_data; kwargs...) = TLSContextOptions(; cert_data, pk_data, verify_peer = false, kwargs...)

# TODO create_server_pkcs12

"""
    mutable struct ClientTLSContext
        ptr::Ptr{aws_tls_ctx}
    end

Client TLS context.
A context is expensive, but can be used for the lifetime of the application by all outgoing connections that wish to
use the same TLS configuration.

$advanced_use_note
"""
mutable struct ClientTLSContext
    ptr::Ptr{aws_tls_ctx}
end

const NULL_AWS_TLS_CTX_OPTIONS = aws_tls_ctx_options(
    C_NULL,
    AWS_IO_TLS_VER_SYS_DEFAULTS,
    AWS_IO_TLS_CIPHER_PREF_SYSTEM_DEFAULT,
    aws_byte_buf(0, C_NULL, 0, C_NULL),
    C_NULL,
    C_NULL,
    aws_byte_buf(0, C_NULL, 0, C_NULL),
    aws_byte_buf(0, C_NULL, 0, C_NULL),
    0,
    false,
    C_NULL,
    C_NULL,
)

"""
    ClientTLSContext(options::TLSContextOptions)

Client TLS context.
A context is expensive, but can be used for the lifetime of the application by all outgoing connections that wish to
use the same TLS configuration.

Arguments:

  - `options (TLSContextOptions)`: Configuration options.
"""
function ClientTLSContext(options::TLSContextOptions)
    tls_ctx_opt = Ref(NULL_AWS_TLS_CTX_OPTIONS)
    GC.@preserve tls_ctx_opt begin
        # TODO pkcs11
        # TODO pkcs12
        # TODO windows cert store
        if options.cert_data !== nothing
            # mTLS with certificate and private key
            cert = Ref(aws_byte_cursor_from_c_str(options.cert_data))
            key = Ref(aws_byte_cursor_from_c_str(options.pk_data))
            if aws_tls_ctx_options_init_client_mtls(tls_ctx_opt, _AWSCRT_ALLOCATOR[], cert, key) != AWS_OP_SUCCESS
                error("Failed to create client TLS context. $(aws_err_string())")
            end
        else
            # no mTLS
            aws_tls_ctx_options_init_default_client(tls_ctx_opt, _AWSCRT_ALLOCATOR[])
        end

        tls_ctx_opt[].minimum_tls_version = options.min_tls_version

        try
            if options.ca_dirpath !== nothing || options.ca_filepath !== nothing
                if aws_tls_ctx_options_override_default_trust_store_from_path(
                    tls_ctx_opt,
                    options.ca_dirpath === nothing ? C_NULL : options.ca_dirpath,
                    options.ca_filepath === nothing ? C_NULL : options.ca_filepath,
                ) != AWS_OP_SUCCESS
                    error("Failed to override trust store from path. $(aws_err_string())")
                end
            end

            if options.ca_data !== nothing
                ca = Ref(aws_byte_cursor_from_c_str(options.ca_data))
                if aws_tls_ctx_options_override_default_trust_store(tls_ctx_opt, ca) != AWS_OP_SUCCESS
                    error("Failed to override trust store. $(aws_err_string())")
                end
            end

            if options.alpn_list !== nothing
                alpn_list_string = join(options.alpn_list, ';')
                if aws_tls_ctx_options_set_alpn_list(tls_ctx_opt, alpn_list_string) != AWS_OP_SUCCESS
                    error("Failed to set ALPN list. $(aws_err_string())")
                end
            end

            tls_ctx_opt[].verify_peer = options.verify_peer

            tls_ctx = aws_tls_client_ctx_new(_AWSCRT_ALLOCATOR[], tls_ctx_opt)
            if tls_ctx == C_NULL
                error("Failed to create TLS context. $(aws_err_string())")
            end

            out = ClientTLSContext(tls_ctx)
            return finalizer(out) do x
                aws_tls_ctx_release(x.ptr)
            end
        catch
            aws_tls_ctx_options_clean_up(tls_ctx_opt)
            rethrow()
        end
    end
end

"""
    mutable struct TLSConnectionOptions
        ptr::Ref{aws_tls_connection_options}
    end

Connection-specific TLS options.
Note that while a TLS context is an expensive object, this object is cheap.

$advanced_use_note
"""
mutable struct TLSConnectionOptions
    ptr::Ref{aws_tls_connection_options}
end

"""
    TLSConnectionOptions(
        client_tls_context::ClientTLSContext,
        alpn_list::Union{Vector{String},Nothing} = nothing,
        server_name::Union{String,Nothing} = nothing,
    )

Connection-specific TLS options.
Note that while a TLS context is an expensive object, this object is cheap.

Arguments:

  - `client_tls_context (ClientTLSContext)`: TLS context. A context can be shared by many connections.
  - `alpn_list (Union{Vector{String},Nothing}) (default=nothing)`: Connection-specific Application Layer Protocol Negotiation (ALPN) list. This overrides any ALPN list on the TLS context in the client this connection was made with. ALPN is not supported on all systems, see [`aws_tls_is_alpn_available`](https://octogonapus.github.io/LibAWSCRT.jl/dev/#LibAWSCRT.aws_tls_is_alpn_available-Tuple%7B%7D).
  - `server_name (Union{String,Nothing}) (default=nothing)`: Name for TLS Server Name Indication (SNI). Also used for x.509 validation.
"""
function TLSConnectionOptions(
    client_tls_context::ClientTLSContext,
    alpn_list::Union{Vector{String},Nothing} = nothing,
    server_name::Union{String,Nothing} = nothing,
)
    tls_connection_options =
        Ref(aws_tls_connection_options(C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, false, 0))
    aws_tls_connection_options_init_from_ctx(tls_connection_options, client_tls_context.ptr)

    try
        if alpn_list !== nothing
            alpn_list_string = join(alpn_list, ';')
            if aws_tls_connection_options_set_alpn_list(
                tls_connection_options,
                _AWSCRT_ALLOCATOR[],
                alpn_list_string,
            ) != AWS_OP_SUCCESS
                error("Failed to set ALPN list. $(aws_err_string())")
            end
        end

        if server_name !== nothing
            server_name_cur = Ref(aws_byte_cursor_from_c_str(server_name))
            if aws_tls_connection_options_set_server_name(
                tls_connection_options,
                _AWSCRT_ALLOCATOR[],
                server_name_cur,
            ) != AWS_OP_SUCCESS
                error("Failed to set server name. $(aws_err_string())")
            end
        end

        out = TLSConnectionOptions(tls_connection_options)
        return finalizer(out) do x
            aws_tls_connection_options_clean_up(x.ptr)
        end
    catch
        aws_tls_connection_options_clean_up(tls_connection_options)
        rethrow()
    end
end
