mutable struct Client
    ptr::Ptr{aws_mqtt_client}
    tls_ctx::Union{ClientTLSContext,Nothing}

    """
    MQTT client.
    # TODO docs
    """
    function Client(;
        bootstrap::ClientBootstrap = get_or_create_default_client_bootstrap(),
        tls_ctx::Union{ClientTLSContext,Nothing} = nothing,
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
# TODO docs
on_connection_interrupted(
    connection::Connection,
    error::, # TODO type
)
"""
const OnConnectionInterrupted = Function

"""
# TODO docs
on_connection_resumed(
    connection::Connection,
    return_code::, # TODO type
    session_present::Bool,
)
"""
const OnConnectionResumed = Function

"""
# TODO docs
on_message(
    topic::String,
    payload::String,
    dup::Bool,
    qos::aws_mqtt_qos,
    retain::Bool,
)
"""
const OnMessage = Function

mutable struct Connection
    ptr::Ptr{aws_mqtt_client_connection}
    client::Client

    """
    MQTT client connection.
    # TODO docs
    """
    function Connection(client::Client)
        ptr = aws_mqtt_client_connection_new(client.ptr)
        if ptr == C_NULL
            error("Failed to create connection")
        end

        out = new(ptr, client)
        return finalizer(out) do x
            aws_mqtt_client_connection_release(x.ptr)
        end
    end
end

struct Will
    topic::String
    qos::aws_mqtt_qos
    payload::String
    retain::Bool
end

struct OnConnectionCompleteMsg
    error_code::Cint
    return_code::Cint
    session_present::Cuchar
end

function on_connection_complete(
    connection::Ptr{aws_mqtt_client_connection},
    error_code::Cint,
    return_code::Cint,
    session_present::Cuchar,
    userdata::Ptr{Cvoid},
)
    # This is a native function and may not interact with the Julia runtime
    token = Base.unsafe_load(Base.unsafe_convert(Ptr{ForeignCallbacks.ForeignToken}, userdata))
    ForeignCallbacks.notify!(token, OnConnectionCompleteMsg(error_code, return_code, session_present))
    return nothing
end

"""
    connect(connection::Connection)

Open the actual connection to the server (async).
Returns a task which completes when the connection succeeds or fails.

If the connection succeeds, the task will contain a dict containing the following keys:
- `:session_present`: `true` if resuming an existing session, `false` if new session

If the connection fails, the task will contain an exception.
"""
function connect(
    connection::Connection,
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

    # TODO aws_mqtt_client_connection_set_connection_interruption_handlers
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

    tls_connection_options = TLSConnectionOptions(connection.client.tls_ctx, alpn_list, server_name)

    try
        server_name_cur = Ref(aws_byte_cursor_from_c_str(server_name))
        client_id_cur = Ref(aws_byte_cursor_from_c_str(client_id))

        ch = Channel(1)
        out = @async begin
            result = take!(ch)
            if result isa Exception
                throw(result)
            else
                return result
            end
        end
        on_connection_complete_fcb = ForeignCallbacks.ForeignCallback{OnConnectionCompleteMsg}() do msg
            result = if msg.return_code != AWS_MQTT_CONNECT_ACCEPTED
                ErrorException("Connection failed. return_code=$(aws_mqtt_connect_return_code(msg.return_code))")
            elseif msg.error_code != AWS_ERROR_SUCCESS
                ErrorException("Connection failed. error_code=$(aws_common_error(msg.error_code))")
            else
                Dict(:session_present => msg.session_present)
            end
            put!(ch, result)
        end
        on_connection_complete_token = Ref(ForeignCallbacks.ForeignToken(on_connection_complete_fcb))

        on_connection_complete_cb = @cfunction(on_connection_complete, Cvoid, (Ptr{aws_mqtt_client_connection}, Cint, Cint, Cuchar, Ptr{Cvoid}))

        GC.@preserve server_name_cur socket_options tls_connection_options client_id_cur on_connection_complete_fcb on_connection_complete_token on_connection_complete_cb begin
            conn_options = Ref(
                aws_mqtt_connection_options(
                    server_name_cur[],
                    port,
                    Base.unsafe_convert(Ptr{aws_socket_options}, socket_options),
                    Base.unsafe_convert(Ptr{aws_tls_connection_options}, tls_connection_options.ptr),
                    client_id_cur[],
                    keep_alive_secs,
                    ping_timeout_ms,
                    protocol_operation_timeout_ms,
                    on_connection_complete_cb,
                    Base.unsafe_convert(Ptr{Cvoid}, on_connection_complete_token), # user_data for on_connection_complete
                    clean_session,
                ),
            )

            if aws_mqtt_client_connection_connect(connection.ptr, conn_options) != AWS_OP_SUCCESS
                error("Failed to connect. $(aws_err_string())")
            end
            return out
        end
    finally
        aws_tls_connection_options_clean_up(tls_connection_options.ptr)
    end
end

"""
    disconnect(connection::Connection)

Close the connection to the server (async).
Returns a task which completes when the connection is closed.
"""
disconnect(connection::Connection) = error("Not implemented.")

"""
    subscribe(connection::Connection, topic::String, qos::aws_mqtt_qos, callback::OnMessage)

Subsribe to a topic filter (async).
The client sends a SUBSCRIBE packet and the server responds with a SUBACK.
This function may be called while the device is offline, though the async operation cannot complete
successfully until the connection resumes.
Once subscribed, `callback` is invoked each time a message matching the `topic` is received. It is
possible for such messages to arrive before the SUBACK is received.

Arguments:
- `connection`: Connection to use.
- `topic`: Subscribe to this topic filter, which may include wildcards.
- `qos`: Maximum requested QoS that server may use when sending messages to the client. The server may grant a lower QoS in the SUBACK (see returned task).
- `callback`: Optional callback invoked when message received. See [`OnMessage`](@ref) for the required signature.

Returns a task and the ID of the SUBSCRIBE packet.
The task completes when a SUBACK is received from the server.

If successful, the task will contain a dict with the following members:
- `:packet_id (Int)`: ID of the SUBSCRIBE packet being acknowledged.
- `:topic (String)`: Topic filter of the SUBSCRIBE packet being acknowledged.
- `:qos (aws_mqtt_qos)`: Maximum QoS that was granted by the server. This may be lower than the requested QoS.

If unsucessful, the task contains an exception.

# TODO test if the AWS IoT broker grants QoS 0 or 1 if you ask for 2. Or if it actually doesn't send PUBACK or SUBACK.
"""
subscribe(connection::Connection, topic::String, qos::aws_mqtt_qos, callback::OnMessage) = error("Not implemented.")

"""
    on_message(connection::Connection, callback::OnMessage)

Set callback to be invoked when ANY message is received.

Arguments:
- `connection`: Connection to use.
- `callback`: Optional callback invoked when message received. See [`OnMessage`](@ref) for the required signature.

Returns nothing.
"""
on_message(connection::Connection, callback::OnMessage) = error("Not implemented.")

"""
    unsubscribe(connection::Connection, topic::String)

Unsubscribe from a topic filter (async).
The client sends an UNSUBSCRIBE packet, and the server responds with an UNSUBACK.

Arguments:
- `connection`: Connection to use.
- `topic`: Unsubscribe from this topic filter.

Returns a task and the ID of the UNSUBSCRIBE packet.
The task completes when an UNSUBACK is received from the server.

If sucessful, the task will contain a dict with the following members:
- `:packet_id (Int)`: ID of the UNSUBSCRIBE packet being acknowledged.

Is unsuccessful, the task will contain an exception.
"""
unsubscribe(connection::Connection, topic::String) = error("Not implemented.")

"""
    resubscribe_existing_topics(connection::Connection)

Subscribe again to all current topics.
This is to help when resuming a connection with a clean session.

Returns a task and the ID of the SUBSCRIBE packet.
The task completes when a SUBACK is received from the server.

If successful, the task will contain a dict with the following members:
- `:packet_id (Int)`: ID of the SUBSCRIBE packet being acknowledged.
- `:topics (Vector{Tuple{Union{String,Nothing},aws_mqtt_qos}})`: Topic filter of the SUBSCRIBE packet being acknowledged and its QoS level. The topic will be `nothing` if the topic failed to resubscribe. The vector will be empty if there were no topics to resubscribe.

If unsucessful, the task contains an exception.
"""
resubscribe_existing_topics(connection::Connection) = error("Not implemented.")

"""
Publish message (async).
If the device is offline, the PUBLISH packet will be sent once the connection resumes.

Arguments:
- `connection`: Connection to use.
- `topic`: Topic name.
- `payload`: Contents of message.
- `qos`: Quality of Service for delivering this message.
- `retain`: If `true`, the server will store the message and its QoS so that it can be delivered to future subscribers whose subscriptions match its topic name.

Returns a task and the ID of the PUBLISH packet.
The QoS determines when the task completes:
- For QoS 0, completes as soon as the packet is sent.
- For QoS 1, completes when PUBACK is received.
- For QoS 2, completes when PUBCOMP is received.

If successful, the task will contain a dict with the following members:
- `:packet_id (Int)`: ID of the PUBLISH packet that is complete.

If unsuccessful, the task will contain an exception.
"""
publish(connection::Connection, topic::String, payload, qos::aws_mqtt_qos, retain::Bool = false) =
    error("Not implemented.")
