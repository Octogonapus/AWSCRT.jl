const subscribe_callback_docs = "Callback invoked when a message is received. See [`OnMessage`](@ref) for the required signature."
const subscribe_qos_docs = "Maximum requested QoS that the server may use when sending messages to the client. The server may grant a lower QoS in the SUBACK (see returned task)."
const subscribe_return_docs = """Returns a task and the ID of the SUBSCRIBE packet.
The task completes when a SUBACK is received from the server.

If successful, the task will contain a dict with the following members:
- `:packet_id (Int)`: ID of the SUBSCRIBE packet being acknowledged.
- `:topic (String)`: Topic filter of the SUBSCRIBE packet being acknowledged.
- `:qos (aws_mqtt_qos)`: Maximum QoS that was granted by the server. This may be lower than the requested QoS.

If unsuccessful, the task contains an exception.

If there is no MQTT connection or network connection, the task may wait forever."""

"""
    MQTTClient(
        tls_ctx::Union{ClientTLSContext,Nothing},
        bootstrap::ClientBootstrap = get_or_create_default_client_bootstrap(),
    )

MQTT client.

Arguments:

  - `tls_ctx (Union{ClientTLSContext,Nothing})`: TLS context for secure socket connections. If `nothing`, an unencrypted connection is used.
  - `bootstrap (ClientBootstrap) (default=get_or_create_default_client_bootstrap())`: Client bootstrap to use when initiating new socket connections. Uses the singleton by default.
"""
mutable struct MQTTClient
    ptr::Ptr{aws_mqtt_client}
    tls_ctx::Union{ClientTLSContext,Nothing}

    function MQTTClient(
        tls_ctx::Union{ClientTLSContext,Nothing},
        bootstrap::ClientBootstrap = get_or_create_default_client_bootstrap(),
    )
        client = aws_mqtt_client_new(_AWSCRT_ALLOCATOR[], bootstrap.ptr)
        if client == C_NULL
            error("Failed to create client")
        end

        out = new(client, tls_ctx)
        return finalizer(out) do x
            aws_mqtt_client_release(x.ptr)
        end
    end
end

"""
    on_connection_interrupted(
        connection::MQTTConnection,
        error_code::Int,
    )

A callback invoked whenever the MQTT connection is lost.
The MQTT client will automatically attempt to reconnect.

Arguments:

  - `connection (MQTTConnection)`: The connection.
  - `error_code (Int)`: Error which caused connection loss.
"""
const OnConnectionInterrupted = Function

"""
    on_connection_resumed(
        connection::MQTTConnection,
        return_code::aws_mqtt_connect_return_code,
        session_present::Bool,
    )

A callback invoked whenever the MQTT connection is automatically resumed.

Arguments:

  - `connection (MQTTConnection)`: The connection.
  - `return_code (aws_mqtt_connect_return_code)`: Connect return code received from the server.
  - `session_present (Bool)`: `true` if resuming existing session. `false` if new session. Note that the server has forgotten all previous subscriptions if this is `false`. Subscriptions can be re-established via [`resubscribe_existing_topics`](@ref).
"""
const OnConnectionResumed = Function

"""
    on_message(
        topic::String,
        payload::String,
        dup::Bool,
        qos::aws_mqtt_qos,
        retain::Bool,
    )

A callback invoked when a message is received.

Arguments:
- `topic (String)`: Topic receiving message.
- `payload (String)`: Payload of message.
- `dup (Bool)`: DUP flag. If True, this might be re-delivery of an earlier attempt to send the message.
- `qos (aws_mqtt_qos)`: $subscribe_qos_docs
- `retain (Bool)`: Retain flag. If `true`, the message was sent as a result of a new subscription being made by the client.

Returns `nothing`.
"""
const OnMessage = Function

macro _con_preserve(connection, ref)
    return quote
        lock($(esc(connection)).connection_lifetime_refs_lock) do
            push!($(esc(connection)).connection_lifetime_refs, $(esc(ref)))
        end
    end
end

"""
    MQTTConnection(client::MQTTClient)

MQTT client connection.

Arguments:

  - `client ([MQTTClient](@ref))`: MQTT client to spawn connection from.
"""
mutable struct MQTTConnection
    ptr::Ptr{aws_mqtt_client_connection}
    client::MQTTClient
    on_connection_complete_refs::Vector{Ref}

    on_subscribe_complete_refs_lock::ReentrantLock
    on_subscribe_complete_refs::Dict{String,Vector{Ref}}

    on_resubscribe_complete_refs::Vector{Ref}

    subscribe_refs_lock::ReentrantLock
    subscribe_refs::Dict{String,Vector{Ref}}

    on_message_refs_lock::ReentrantLock
    on_message_refs::Vector{Ref}

    on_publish_complete_refs_lock::ReentrantLock
    on_publish_complete_refs::Dict{String,Vector{Ref}}

    connection_lifetime_refs_lock::ReentrantLock
    connection_lifetime_refs::Vector{Ref} # refs that must be live until this connection object is dead

    function MQTTConnection(client::MQTTClient)
        ptr = aws_mqtt_client_connection_new(client.ptr)
        if ptr == C_NULL
            error("Failed to create connection")
        end

        out = new(
            ptr,
            client,
            Ref[],
            ReentrantLock(),
            Dict{String,Vector{Ref}}(),
            Ref[],
            ReentrantLock(),
            Dict{String,Vector{Ref}}(),
            ReentrantLock(),
            Ref[],
            ReentrantLock(),
            Dict{String,Vector{Ref}}(),
            ReentrantLock(),
            Ref[],
        )
        return finalizer(out) do x
            aws_mqtt_client_connection_release(x.ptr)
        end
    end
end

"""
    Will(
        topic::String,
        qos::aws_mqtt_qos,
        payload::String,
        retain::Bool,
    )

A Will message is published by the server if a client is lost unexpectedly.

The Will message is stored on the server when a client connects.
It is published if the client connection is lost without the server receiving a DISCONNECT packet.

[MQTT-3.1.2-8]

Arguments:

  - `topic (String)`: Topic to publish Will message on.
  - `qos (aws_mqtt_qos)`: QoS used when publishing the Will message.
  - `payload (String)`: Content of Will message.
  - `retain (Bool)`: Whether the Will message is to be retained when it is published.
"""
struct Will
    topic::String
    qos::aws_mqtt_qos
    payload::String
    retain::Bool
end

mutable struct _OnConnectionInterruptedUserData # mutable so it has a stable address
    connection::MQTTConnection
    callback::OnConnectionInterrupted
end

function _c_on_connection_interrupted(
    connection::Ptr{aws_mqtt_client_connection},
    error_code::Cint,
    userdata::Ptr{Cvoid},
)
    data = Base.unsafe_pointer_to_objref(userdata)::Ref{_OnConnectionResumedUserData}
    data[].callback(data[].connection, error_code)
    return nothing
end

mutable struct _OnConnectionResumedUserData # mutable so it has a stable address
    connection::MQTTConnection
    callback::OnConnectionResumed
end

function _c_on_connection_resumed(
    connection::Ptr{aws_mqtt_client_connection},
    return_code::Cint,
    session_present::Cint,
    userdata::Ptr{Cvoid},
)
    data = Base.unsafe_pointer_to_objref(userdata)::Ref{_OnConnectionResumedUserData}
    data[].callback(data[].connection, aws_mqtt_connect_return_code(return_code), session_present != 0)
    return nothing
end

mutable struct _OnConnectionCompleteUserData # mutable so it has a stable address
    ch::Channel{Any}
end

function _c_on_connection_complete(
    connection::Ptr{aws_mqtt_client_connection},
    error_code::Cint,
    return_code::Cint,
    session_present::Cuchar,
    userdata::Ptr{Cvoid},
)
    result = if return_code != AWS_MQTT_CONNECT_ACCEPTED
        ErrorException("Connection failed. $(aws_err_string(return_code))")
    elseif error_code != AWS_ERROR_SUCCESS
        ErrorException("Connection failed. $(aws_err_string(error_code))")
    else
        Dict(:session_present => session_present != 0)
    end
    data = Base.unsafe_pointer_to_objref(userdata)::Ref{_OnConnectionCompleteUserData}
    put!(data[].ch, result)
    return nothing
end

"""
    connect(
        connection::MQTTConnection,
        server_name::String,
        port::Integer,
        client_id::String;
        clean_session::Bool = true,
        on_connection_interrupted::Union{OnConnectionInterrupted,Nothing} = nothing,
        on_connection_resumed::Union{OnConnectionResumed,Nothing} = nothing,
        reconnect_min_timeout_secs::Integer = 5,
        reconnect_max_timeout_secs::Integer = 60,
        keep_alive_secs::Integer = 1200,
        ping_timeout_ms::Integer = 3000,
        protocol_operation_timeout_ms::Integer = 0,
        will::Union{Will,Nothing} = nothing,
        username::Union{String,Nothing} = nothing,
        password::Union{String,Nothing} = nothing,
        socket_options = Ref(aws_socket_options(AWS_SOCKET_STREAM, AWS_SOCKET_IPV6, 5000, 0, 0, 0, false)),
        alpn_list::Union{Vector{String},Nothing} = nothing,
        use_websockets::Bool = false,
        websocket_handshake_transform = nothing, # TODO union type
        proxy_options = nothing, # TODO union type
    )

Open the actual connection to the server (async).

Arguments:

  - `connection (MQTTConnection)`: Connection to use.
  - `server_name (String)`: Server name to connect to.
  - `port (Integer)`: Server port to connect to.
  - `client_id (String)`: ID to place in CONNECT packet. Must be unique across all devices/clients. If an ID is already in use, the other client will be disconnected.
  - `clean_session (Bool) (default=true)`: Whether or not to start a clean session with each reconnect. If `true`, the server will forget all subscriptions with each reconnect. Set `false` to request that the server resume an existing session or start a new session that may be resumed after a connection loss. The `session_present` bool in the connection callback informs whether an existing session was successfully resumed. If an existing session is resumed, the server remembers previous subscriptions and sends mesages (with QoS level 1 or higher) that were published while the client was offline.
  - `on_connection_interrupted (Union{OnConnectionInterrupted,Nothing}) (default=nothing)`: Optional callback invoked whenever the MQTT connection is lost. The MQTT client will automatically attempt to reconnect. See [`OnConnectionInterrupted`](@ref).
  - `on_connection_resumed (Union{OnConnectionResumed,Nothing}) (default=nothing)`: Optional callback invoked whenever the MQTT connection is automatically resumed. See [`OnConnectionResumed`](@ref).
  - `reconnect_min_timeout_secs (Integer) (default=5)`: Minimum time to wait between reconnect attempts. Must be <= `reconnect_max_timeout_secs`. Wait starts at min and doubles with each attempt until max is reached.
  - `reconnect_max_timeout_secs (Integer) (default=60)`: Maximum time to wait between reconnect attempts. Must be >= `reconnect_min_timeout_secs`. Wait starts at min and doubles with each attempt until max is reached.
  - `keep_alive_secs (Integer) (default=1200)`: The keep alive value (seconds) to send in CONNECT packet. A PING will automatically be sent at this interval. The server will assume the connection is lost if no PING is received after 1.5X this value. This duration must be longer than `ping_timeout_ms`.
  - `ping_timeout_ms (Integer) (default=3000)`: Milliseconds to wait for ping response before client assumes the connection is invalid and attempts to reconnect. This duration must be shorter than `keep_alive_secs`.
  - `protocol_operation_timeout_ms (Integer) (default=0)`: Milliseconds to wait for a response to an operation that requires a response by the server. Set to zero to disable timeout. Otherwise, the operation will fail if no response is received within this amount of time after the packet is written to the socket. This works with PUBLISH (if QoS level > 0) and UNSUBSCRIBE.
  - `will (Union{Will,Nothing}) (default=nothing)`: Will to send with CONNECT packet. The will is published by the server when its connection to the client is unexpectedly lost.
  - `username (Union{String,Nothing}) (default=nothing)`: Username to connect with.
  - `password (Union{String,Nothing}) (default=nothing)`: Password to connect with.
  - `socket_options (Ref(aws_socket_options}) (default=Ref(aws_socket_options(AWS_SOCKET_STREAM, AWS_SOCKET_IPV6, 5000, 0, 0, 0, false)))`: Optional socket options.
  - `alpn_list (Union{Vector{String},Nothing}) (default=nothing)`: Connection-specific Application Layer Protocol Negotiation (ALPN) list. This overrides any ALPN list on the TLS context in the client this connection was made with. ALPN is not supported on all systems, see [`aws_tls_is_alpn_available`](https://octogonapus.github.io/LibAWSCRT.jl/dev/#LibAWSCRT.aws_tls_is_alpn_available-Tuple%7B%7D).
  - `use_websockets (Bool) (default=false)`: # TODO
  - `websocket_handshake_transform (nothing) (default=nothing)`: # TODO
  - `proxy_options (nothing) (default=nothing)`: # TODO

Returns a task which completes when the connection succeeds or fails.

If the connection succeeds, the task will contain a dict containing the following keys:

  - `:session_present`: `true` if resuming an existing session, `false` if new session

If the connection fails, the task will throw an exception.
"""
function connect(
    connection::MQTTConnection,
    server_name::String,
    port::Integer,
    client_id::String;
    clean_session::Bool = true,
    on_connection_interrupted::Union{OnConnectionInterrupted,Nothing} = nothing,
    on_connection_resumed::Union{OnConnectionResumed,Nothing} = nothing,
    reconnect_min_timeout_secs::Integer = 5,
    reconnect_max_timeout_secs::Integer = 60,
    keep_alive_secs::Integer = 1200,
    ping_timeout_ms::Integer = 3000,
    protocol_operation_timeout_ms::Integer = 0,
    will::Union{Will,Nothing} = nothing,
    username::Union{String,Nothing} = nothing,
    password::Union{String,Nothing} = nothing,
    socket_options = Ref(aws_socket_options(AWS_SOCKET_STREAM, AWS_SOCKET_IPV6, 5000, 0, 0, 0, false)),
    alpn_list::Union{Vector{String},Nothing} = nothing,
    use_websockets::Bool = false,
    websocket_handshake_transform = nothing, # TODO union type
    proxy_options = nothing, # TODO union type
)
    if reconnect_min_timeout_secs > reconnect_max_timeout_secs
        error(
            "reconnect_min_timeout_secs ($reconnect_min_timeout_secs) cannot exceed reconnect_max_timeout_secs ($reconnect_max_timeout_secs)",
        )
    end

    if keep_alive_secs * 1000 <= ping_timeout_ms
        error(
            "keep_alive_secs ($(keep_alive_secs * 1000) ms) duration must be longer than ping_timeout_ms ($ping_timeout_ms ms)",
        )
    end

    on_connection_interrupted_user_data = if on_connection_interrupted !== nothing
        ud = Ref(_OnConnectionInterruptedUserData(connection, on_connection_interrupted))
        # The user data must be live until the connection is dead because the callback can run and use it
        @_con_preserve connection ud
        ud
    else
        C_NULL
    end

    on_connection_resumed_user_data = if on_connection_resumed !== nothing
        ud = Ref(_OnConnectionResumedUserData(connection, on_connection_resumed))
        # The user data must be live until the connection is dead because the callback can run and use it
        @_con_preserve connection ud
        ud
    else
        C_NULL
    end

    aws_mqtt_client_connection_set_connection_interruption_handlers(
        connection.ptr,
        on_connection_interrupted === nothing ? C_NULL : _C_ON_CONNECTION_INTERRUPTED[],
        on_connection_interrupted === nothing ? C_NULL : Base.pointer_from_objref(on_connection_interrupted_user_data),
        on_connection_resumed === nothing ? C_NULL : _C_ON_CONNECTION_RESUMED[],
        on_connection_resumed === nothing ? C_NULL : Base.pointer_from_objref(on_connection_resumed_user_data),
    )

    # TODO aws_mqtt_client_connection_use_websockets

    if aws_mqtt_client_connection_set_reconnect_timeout(
        connection.ptr,
        reconnect_min_timeout_secs,
        reconnect_max_timeout_secs,
    ) != AWS_OP_SUCCESS
        error("Failed to set the reconnect timeout. $(aws_err_string())")
    end

    if will !== nothing
        topic_cur = Ref(aws_byte_cursor_from_c_str(will.topic))
        payload_cur = Ref(aws_byte_cursor_from_c_str(will.payload))
        if aws_mqtt_client_connection_set_will(connection.ptr, topic_cur, will.qos, will.retain, payload_cur) !=
           AWS_OP_SUCCESS
            error("Failed to set the will. $(aws_err_string())")
        end
    end

    if username !== nothing
        username_cur = Ref(aws_byte_cursor_from_c_str(username))
        password_cur = if password !== nothing
            Ref(aws_byte_cursor_from_c_str(password))
        else
            nothing
        end
        if aws_mqtt_client_connection_set_login(connection.ptr, username_cur, password_cur) != AWS_OP_SUCCESS
            error("Failed to set login. $(aws_err_string())")
        end
    end

    # TODO proxy_options

    tls_connection_options = if connection.client.tls_ctx !== nothing
        TLSConnectionOptions(connection.client.tls_ctx, alpn_list, server_name)
    else
        nothing
    end

    try
        server_name_cur = Ref(aws_byte_cursor_from_c_str(server_name))
        client_id_cur = Ref(aws_byte_cursor_from_c_str(client_id))

        out_ch = Channel(1)
        on_connection_complete_user_data = Ref(_OnConnectionCompleteUserData(out_ch))
        # The user data must be live until the connection is dead because the callback can run and use it
        @_con_preserve connection on_connection_complete_user_data

        GC.@preserve server_name_cur socket_options tls_connection_options client_id_cur out_ch begin
            conn_options = Ref(
                aws_mqtt_connection_options(
                    server_name_cur[],
                    port,
                    Base.unsafe_convert(Ptr{aws_socket_options}, socket_options),
                    tls_connection_options === nothing ? C_NULL :
                    Base.unsafe_convert(Ptr{aws_tls_connection_options}, tls_connection_options.ptr),
                    client_id_cur[],
                    keep_alive_secs,
                    ping_timeout_ms,
                    protocol_operation_timeout_ms,
                    _C_ON_CONNECTION_COMPLETE[],
                    Base.pointer_from_objref(on_connection_complete_user_data),
                    clean_session,
                ),
            )

            if aws_mqtt_client_connection_connect(connection.ptr, conn_options) != AWS_OP_SUCCESS
                error("Failed to connect. $(aws_err_string())")
            end

            return Threads.@spawn begin
                GC.@preserve connection conn_options begin
                    result = take!(out_ch)
                    if result isa Exception
                        throw(result)
                    else
                        return result
                    end
                end
            end
        end
    finally
        tls_connection_options !== nothing && aws_tls_connection_options_clean_up(tls_connection_options.ptr)
    end
end

mutable struct _OnDisconnectCompleteUserData # mutable so it has a stable address
    latch::CountDownLatch
end

function _c_on_disconnect_complete(connection::Ptr{aws_mqtt_client_connection}, userdata::Ptr{Cvoid})
    data = Base.unsafe_pointer_to_objref(userdata)::Ref{_OnDisconnectCompleteUserData}
    count_down(data[].latch)
    return nothing
end

"""
    disconnect(connection::MQTTConnection)

Close the connection to the server (async).
Returns a task which completes when the connection is closed.
If there is no MQTT connection or network connection, the task completes.
The task will contain nothing.
"""
function disconnect(connection::MQTTConnection)
    latch = CountDownLatch(1)
    userdata = Ref(_OnDisconnectCompleteUserData(latch))
    @_con_preserve connection userdata

    GC.@preserve connection begin
        aws_mqtt_client_connection_disconnect(
            connection.ptr,
            _C_ON_DISCONNECT_COMPLETE[],
            Base.pointer_from_objref(userdata),
        )
        return @async begin
            GC.@preserve connection begin
                await(latch)
                return nothing
            end
        end
    end
end

mutable struct _OnMessageUserData # mutable so it has a stable address
    callback::OnMessage
end

function _c_on_message(
    connection::Ptr{aws_mqtt_client_connection},
    topic::Ptr{aws_byte_cursor},
    payload::Ptr{aws_byte_cursor},
    dup::Cuchar,
    qos::Cint,
    retain::Cuchar,
    userdata::Ptr{Cvoid},
)
    # Make a copy because topic is freed when this function returns
    topic_obj = Base.unsafe_load(topic)
    topic_copy = ccall(:calloc, Ptr{Cvoid}, (Csize_t, Csize_t), topic_obj.len, 1)
    ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), topic_copy, topic_obj.ptr, topic_obj.len)

    # Make a copy because payload is freed when this function returns
    payload_obj = Base.unsafe_load(payload)
    payload_copy = ccall(:calloc, Ptr{Cvoid}, (Csize_t, Csize_t), payload_obj.len, 1)
    ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), payload_copy, payload_obj.ptr, payload_obj.len)

    data = Base.unsafe_pointer_to_objref(userdata)::Ref{_OnMessageUserData}
    data[].callback(
        String(Base.unsafe_wrap(Array, Base.unsafe_convert(Ptr{Cuchar}, topic_copy), topic_obj.len, own = true)),
        String(Base.unsafe_wrap(Array, Base.unsafe_convert(Ptr{Cuchar}, payload_copy), payload_obj.len, own = true)),
        dup != 0,
        aws_mqtt_qos(qos),
        retain != 0,
    )
    return nothing
end

mutable struct _OnSubcribeCompleteUserData # mutable so it has a stable address
    ch::Channel{Any}
end

function _c_on_subscribe_complete(
    connection::Ptr{aws_mqtt_client_connection},
    packet_id::Cuint,
    topic::Ptr{aws_byte_cursor},
    qos::Cint,
    error_code::Cint,
    userdata::Ptr{Cvoid},
)
    # Make a copy because topic is freed when this function returns
    topic_obj = Base.unsafe_load(topic)
    topic_copy = ccall(:calloc, Ptr{Cvoid}, (Csize_t, Csize_t), topic_obj.len, 1)
    ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), topic_copy, topic_obj.ptr, topic_obj.len)

    result = if error_code != AWS_ERROR_SUCCESS
        ErrorException("Subscribe failed. $(aws_err_string(error_code))")
    else
        Dict(
            :packet_id => UInt(packet_id),
            :topic => String(
                Base.unsafe_wrap(Array, Base.unsafe_convert(Ptr{Cuchar}, topic_copy), topic_obj.len, own = true),
            ),
            :qos => aws_mqtt_qos(qos),
        )
    end

    data = Base.unsafe_pointer_to_objref(userdata)::Ref{_OnSubcribeCompleteUserData}
    put!(data[].ch, result)
    return nothing
end

"""
    subscribe(connection::MQTTConnection, topic::String, qos::aws_mqtt_qos, callback::OnMessage)

Subsribe to a topic filter (async).
The client sends a SUBSCRIBE packet and the server responds with a SUBACK.
This function may be called while the device is offline, though the async operation cannot complete
successfully until the connection resumes.
Once subscribed, `callback` is invoked each time a message matching the `topic` is received. It is
possible for such messages to arrive before the SUBACK is received.

Arguments:
- `connection (MQTTConnection)`: Connection to use.
- `topic (String)`: Subscribe to this topic filter, which may include wildcards.
- `qos (aws_mqtt_qos)`: $subscribe_qos_docs
- `callback (OnMessage)`: $subscribe_callback_docs

$subscribe_return_docs
"""
function subscribe(connection::MQTTConnection, topic::String, qos::aws_mqtt_qos, callback::OnMessage)
    on_message_user_data = Ref(_OnMessageUserData(callback))
    # The user data must be live until the subscription for this topic is gone.
    # Also we can't clear the old refs, if any, until we set the new user data.
    lock(connection.subscribe_refs_lock) do
        if haskey(connection.subscribe_refs, topic)
            push!(connection.subscribe_refs[topic], on_message_user_data)
        else
            connection.subscribe_refs[topic] = [on_message_user_data]
        end
    end

    out_ch = Channel(1)
    on_subscribe_complete_user_data = Ref(_OnSubcribeCompleteUserData(out_ch))
    # The lifetime of the on_subscribe_complete FCB and its token is from SUBSCRIBE to SUBACK so we can preserve it
    # until the task returned from this function has finished, as it finishes when a SUBACK is received.
    # We also preserve it on the connection in case we get a stray SUBACK.
    # Also we can't clear the old refs, if any, until we set the new user data.
    lock(connection.on_subscribe_complete_refs_lock) do
        if haskey(connection.on_subscribe_complete_refs, topic)
            push!(connection.on_subscribe_complete_refs[topic], on_subscribe_complete_user_data)
        else
            connection.on_subscribe_complete_refs[topic] = [on_subscribe_complete_user_data]
        end
    end

    topic_cur = Ref(aws_byte_cursor_from_c_str(topic))
    GC.@preserve connection topic_cur out_ch begin
        packet_id = aws_mqtt_client_connection_subscribe(
            connection.ptr,
            topic_cur,
            qos,
            _C_ON_MESSAGE[],
            Base.pointer_from_objref(on_message_user_data),
            C_NULL, # called when a subscription is removed
            _C_ON_SUBSCRIBE_COMPLETE[],
            Base.pointer_from_objref(on_subscribe_complete_user_data),
        )

        # Now that we set the new user data we can remove the ref to the old user data, if there was any
        lock(connection.subscribe_refs_lock) do
            connection.subscribe_refs[topic] = [on_message_user_data]
        end
        lock(connection.on_subscribe_complete_refs_lock) do
            connection.on_subscribe_complete_refs[topic] = [on_subscribe_complete_user_data]
        end

        return (@async begin
            GC.@preserve connection topic_cur begin
                result = take!(out_ch)
                if result isa Exception
                    throw(result)
                else
                    return result
                end
            end
        end), packet_id
    end
end

const _on_message_error = "Failed to set on_message. Did you try to set the publish handler while connected?"

"""
    on_message(connection::MQTTConnection, callback::Union{OnMessage,Nothing})

Set callback to be invoked when ANY message is received.

Arguments:

  - `connection (MQTTConnection)`: Connection to use.
  - `callback (Union{OnMessage,Nothing})`: Optional callback invoked when message received. See [`OnMessage`](@ref) for the required signature. Set to `nothing` to clear this callback.

Returns nothing.
"""
function on_message(connection::MQTTConnection, callback::Union{OnMessage,Nothing})
    if callback === nothing
        if aws_mqtt_client_connection_set_on_any_publish_handler(connection.ptr, C_NULL, C_NULL) != AWS_OP_SUCCESS
            error("$_on_message_error $(aws_err_string())")
        end

        # Clear any refs from a prior callback so they can be GC'd
        lock(connection.on_message_refs_lock) do
            connection.on_message_refs = []
        end

        return nothing
    else
        userdata = Ref(_OnMessageUserData(callback))
        # We can't clear the old refs, if any, until we set the new user data.
        lock(connection.on_message_refs_lock) do
            push!(connection.on_message_refs, userdata)
        end

        if aws_mqtt_client_connection_set_on_any_publish_handler(
            connection.ptr,
            _C_ON_MESSAGE[],
            Base.pointer_from_objref(userdata),
        ) != AWS_OP_SUCCESS
            error("$_on_message_error $(aws_err_string())")
        end

        # Now that we set the new user data we can remove the ref to the old user data, if there was any
        lock(connection.on_message_refs_lock) do
            connection.on_message_refs = [userdata]
        end

        return nothing
    end
end

mutable struct OnUnsubscribeCompleteUserData # mutable so it has a stable address
    ch::Channel{Any}
end

function _c_on_unsubscribe_complete(
    connection::Ptr{aws_mqtt_client_connection},
    packet_id::Cuint,
    error_code::Cint,
    userdata::Ptr{Cvoid},
)
    result = if error_code != AWS_ERROR_SUCCESS
        ErrorException("Unsubscribe failed. $(aws_err_string(error_code))")
    else
        Dict(:packet_id => UInt(packet_id))
    end

    data = Base.unsafe_pointer_to_objref(userdata)::Ref{OnUnsubscribeCompleteUserData}
    put!(data[].ch, result)

    return nothing
end

const unsubscribe_return_docs = """Returns a task and the ID of the UNSUBSCRIBE packet.
The task completes when an UNSUBACK is received from the server.

If successful, the task will contain a dict with the following members:
- `:packet_id (Int)`: ID of the UNSUBSCRIBE packet being acknowledged.

If unsuccessful, the task will throw an exception.

If there is no MQTT connection or network connection, the task may wait forever."""

"""
    unsubscribe(connection::MQTTConnection, topic::String)

Unsubscribe from a topic filter (async).
The client sends an UNSUBSCRIBE packet, and the server responds with an UNSUBACK.

Arguments:
- `connection (MQTTConnection)`: Connection to use.
- `topic (String)`: Unsubscribe from this topic filter.

$unsubscribe_return_docs
"""
function unsubscribe(connection::MQTTConnection, topic::String)
    out_ch = Channel(1)
    userdata = Ref(OnUnsubscribeCompleteUserData(out_ch))
    # It's not documented, but it seems like the lifetime of the on_unsubscribe_complete FCB and its token is
    # from UNSUBSCRIBE to UNSUBACK so we can preserve it until the task returned from this function has finished,
    # as it finishes when an UNSUBACK is received.
    # That said, I am also scared about a stray UNSUBACK so I will preserve it for the connection lifetime to be safe.
    @_con_preserve connection userdata

    topic_cur = Ref(aws_byte_cursor_from_c_str(topic))
    GC.@preserve connection topic_cur out_ch begin
        packet_id = aws_mqtt_client_connection_unsubscribe(
            connection.ptr,
            topic_cur,
            _C_ON_UNSUBSCRIBE_COMPLETE[],
            Base.pointer_from_objref(userdata),
        )
        return (@async begin
            GC.@preserve connection topic_cur begin
                result = take!(out_ch)
                if result isa Exception
                    throw(result)
                else
                    # Now that the subscription is done, we can GC its callbacks
                    connection.subscribe_refs[topic] = Ref[]
                    connection.on_subscribe_complete_refs[topic] = Ref[]
                    return result
                end
            end
        end), packet_id
    end
end

mutable struct _OnResubcribeCompleteUD # mutable so it has a stable address
    ch::Channel{Any}
    aws_array_list_length_ptr::Ptr{Cvoid}
    aws_array_list_get_at_ptr::Ptr{Cvoid}
end

function _c_on_resubscribe_complete(
    connection::Ptr{aws_mqtt_client_connection},
    packet_id::Cuint,
    topic_subacks::Ptr{aws_array_list},
    error_code::Cint,
    userdata::Ptr{Cvoid},
)
    ud = Base.unsafe_pointer_to_objref(userdata)::Ref{_OnResubcribeCompleteUD}

    # topic_subacks is an array list with eltype (struct aws_mqtt_topic_subscription *)
    # We are lent topic_subacks only inside this function. It will be freed as soon as this function returns.
    # Therefore we need to copy it. This list also contains byte cursors, which will also be freed, so we need to
    # deeply copy the topic strings.

    num_topics = ccall(ud[].aws_array_list_length_ptr, Csize_t, (Ptr{aws_array_list},), topic_subacks)

    # alloc space to hold the eltype of the list (struct aws_mqtt_topic_subscription *)
    sub_i_ptr = Libc.malloc(sizeof(Ptr{Cvoid}))
    if sub_i_ptr == C_NULL
        exit(Libc.errno())
    end

    # alloc space to hold the copied topics (this is an array of strings)
    topics = Base.unsafe_convert(Ptr{Ptr{UInt8}}, Libc.calloc(num_topics, sizeof(Ptr{Ptr{Cvoid}})))
    # alloc space to hold the copies QoSs (this is an array of ints)
    qoss = Base.unsafe_convert(Ptr{aws_mqtt_qos}, Libc.calloc(num_topics, sizeof(Cint)))

    # copy each topic in the list
    for i = 1:num_topics
        # call aws_array_list_get_at to load an element into *sub_i_ptr
        ccall(
            ud[].aws_array_list_get_at_ptr,
            Cint,
            (Ptr{aws_array_list}, Ptr{Cvoid}, Csize_t),
            topic_subacks,
            sub_i_ptr,
            i - 1,
        )
        # load the pointer put into *sub_i_ptr
        sub_i = Base.unsafe_load(Base.unsafe_convert(Ptr{Ptr{aws_mqtt_topic_subscription}}, sub_i_ptr))
        # load the struct to get at its fields
        sub_i_obj = Base.unsafe_load(Base.unsafe_convert(Ptr{aws_mqtt_topic_subscription}, sub_i))

        # deep copy the topic string as it will be freed when this function returns
        topic_copy = ccall(:calloc, Ptr{Cvoid}, (Csize_t, Csize_t), sub_i_obj.topic.len, 1)
        if topic_copy == C_NULL
            exit(Libc.errno())
        end
        ccall(
            :memcpy,
            Ptr{Cvoid},
            (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t),
            topic_copy,
            sub_i_obj.topic.ptr,
            sub_i_obj.topic.len,
        )

        Base.unsafe_store!(topics, Base.unsafe_convert(Ptr{UInt8}, topic_copy), i)
        Base.unsafe_store!(qoss, sub_i_obj.qos, i) # the QoS is just an int so we can just push its value to copy it
    end
    Libc.free(sub_i_ptr)

    result = if error_code != AWS_ERROR_SUCCESS
        ErrorException("Resubscribe failed. $(aws_err_string(error_code))")
    else
        topics_and_qoss = []

        tptr = Base.unsafe_convert(Ptr{Ptr{UInt8}}, topics)
        qptr = Base.unsafe_convert(Ptr{aws_mqtt_qos}, qoss)
        try
            for i = 1:num_topics
                try
                    # make a copy of the topic before we free it
                    topic = Base.unsafe_string(Base.unsafe_load(tptr, i))
                    # also make ac opy of the qos (which is just an int)
                    qos = Base.unsafe_load(qptr, i)
                    push!(topics_and_qoss, (topic, qos))
                finally
                    Libc.free(Base.unsafe_load(tptr, i))
                end
            end
        finally
            tptr = nothing
            qptr = nothing
            Libc.free(topics)
            Libc.free(qoss)
        end

        Dict(:packet_id => UInt(packet_id), :topics => topics_and_qoss)
    end

    put!(ud[].ch, result)

    return nothing
end

"""
    resubscribe_existing_topics(connection::MQTTConnection)

Subscribe again to all current topics.
This is to help when resuming a connection with a clean session.

Returns a task and the ID of the SUBSCRIBE packet.
The task completes when a SUBACK is received from the server.

If successful, the task will contain a dict with the following members:

  - `:packet_id (Int)`: ID of the SUBSCRIBE packet being acknowledged.
  - `:topics (Vector{Tuple{Union{String,Nothing},aws_mqtt_qos}})`: Topic filter of the SUBSCRIBE packet being acknowledged and its QoS level. The topic will be `nothing` if the topic failed to resubscribe. The vector will be empty if there were no topics to resubscribe.

If unsuccessful, the task contains an exception.
"""
function resubscribe_existing_topics(connection::MQTTConnection)
    out_ch = Channel(1)
    udata = Ref(
        _OnResubcribeCompleteUD(
            out_ch,
            Libc.Libdl.dlsym(_LIBPTR[], :aws_array_list_length),
            Libc.Libdl.dlsym(_LIBPTR[], :aws_array_list_get_at),
        ),
    )
    @_con_preserve connection udata

    GC.@preserve connection out_ch begin
        packet_id = aws_mqtt_resubscribe_existing_topics(
            connection.ptr,
            _C_ON_RESUBSCRIBE_COMPLETE[],
            Base.pointer_from_objref(udata),
        )
        return (@async begin
            GC.@preserve connection begin
                result = take!(out_ch)
                if result isa Exception
                    throw(result)
                else
                    return result
                end
            end
        end), packet_id
    end
end

mutable struct _OnPublishCompleteUD # mutable so it has a stable address
    ch::Channel{Any}
end

function _c_on_publish_complete(
    connection::Ptr{aws_mqtt_client_connection},
    packet_id::Cuint,
    error_code::Cint,
    userdata::Ptr{Cvoid},
)
    result = if error_code != AWS_ERROR_SUCCESS
        ErrorException("Publish failed. $(aws_err_string(error_code))")
    else
        Dict(:packet_id => UInt(packet_id))
    end
    ud = Base.unsafe_pointer_to_objref(userdata)::Ref{_OnPublishCompleteUD}
    put!(ud[].ch, result)
    return nothing
end

const publish_return_docs = """
Returns a task and the ID of the PUBLISH packet.
The QoS determines when the task completes:
- For QoS 0, completes as soon as the packet is sent.
- For QoS 1, completes when PUBACK is received.
- For QoS 2, completes when PUBCOMP is received.

If successful, the task will contain a dict with the following members:
- `:packet_id (Int)`: ID of the PUBLISH packet that is complete.

If unsuccessful, the task will throw an exception.

If there is no MQTT connection or network connection, the task may wait forever."""

"""
    publish(connection::MQTTConnection, topic::String, payload::String, qos::aws_mqtt_qos, retain::Bool = false)

Publish message (async).
If the device is offline, the PUBLISH packet will be sent once the connection resumes.

Arguments:
- `connection (MQTTConnection)`: Connection to use.
- `topic (String)`: Topic name.
- `payload (String)`: Contents of message.
- `qos (aws_mqtt_qos)`: $subscribe_qos_docs
- `retain (Bool)`: If `true`, the server will store the message and its QoS so that it can be delivered to future subscribers whose subscriptions match its topic name.

$publish_return_docs
"""
function publish(connection::MQTTConnection, topic::String, payload::String, qos::aws_mqtt_qos, retain::Bool = false)
    out_ch = Channel(1)
    userdata = Ref(_OnPublishCompleteUD(out_ch))

    # It's not documented, but it seems like the lifetime of the on_publish_complete FCB and its token is
    # from PUBLISH to either packet send, PUBACK, or PUBCOMP depending on QoS level, so we can preserve it until
    # the task returned from this function has finished, as it finishes when the correct event is received.
    # We also preserve it on the connection in case we get a stray PUBACK or PUBCOMP, depending on QoS level.
    # Also we can't clear the old refs, if any, until we set the new user data.
    lock(connection.on_publish_complete_refs_lock) do
        if haskey(connection.on_publish_complete_refs, topic)
            push!(connection.on_publish_complete_refs[topic], userdata)
        else
            connection.on_publish_complete_refs[topic] = [userdata]
        end
    end

    topic_cur = Ref(aws_byte_cursor_from_c_str(topic))
    payload_cur = Ref(aws_byte_cursor_from_c_str(payload))
    GC.@preserve connection topic_cur payload_cur out_ch begin
        packet_id = aws_mqtt_client_connection_publish(
            connection.ptr,
            topic_cur,
            qos,
            retain,
            payload_cur,
            _C_ON_PUBLISH_COMPLETE[],
            Base.pointer_from_objref(userdata),
        )
        @debug "publish" packet_id topic payload qos retain

        # Now that we set the new user data we can remove the ref to the old user data, if there was any
        lock(connection.on_publish_complete_refs_lock) do
            connection.on_publish_complete_refs[topic] = [userdata]
        end

        return (@async begin
            GC.@preserve connection topic_cur payload_cur begin
                result = take!(out_ch)
                @debug "publish finished" packet_id result
                if result isa Exception
                    throw(result)
                else
                    return result
                end
            end
        end), packet_id
    end
end
