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
    on_connection_complete_refs::Vector{Ref}
    on_subscribe_complete_refs::Dict{String,Vector{Ref}}
    subscribe_refs::Dict{String,Vector{Ref}}
    on_message_refs::Vector{Ref}
    disconnect_refs::Vector{Ref}
    on_unsubscribe_complete_refs::Dict{String,Vector{Ref}}
    on_publish_complete_refs::Dict{String,Vector{Ref}}

    """
    MQTT client connection.
    # TODO docs
    """
    function Connection(client::Client)
        ptr = aws_mqtt_client_connection_new(client.ptr)
        if ptr == C_NULL
            error("Failed to create connection")
        end

        out = new(ptr, client, Ref[], Dict{String,Vector{Ref}}(), Dict{String,Vector{Ref}}(), Ref[], Ref[], Dict{String,Vector{Ref}}(), Dict{String,Vector{Ref}}())
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

    tls_connection_options = if connection.client.tls_ctx !== nothing
        TLSConnectionOptions(connection.client.tls_ctx, alpn_list, server_name)
    else
        nothing
    end

    try
        server_name_cur = Ref(aws_byte_cursor_from_c_str(server_name))
        client_id_cur = Ref(aws_byte_cursor_from_c_str(client_id))

        ch = Channel(1)
        on_connection_complete_fcb = ForeignCallbacks.ForeignCallback{OnConnectionCompleteMsg}() do msg
            result = if msg.return_code != AWS_MQTT_CONNECT_ACCEPTED
                ErrorException("Connection failed. $(aws_err_string(msg.return_code))")
            elseif msg.error_code != AWS_ERROR_SUCCESS
                ErrorException("Connection failed. $(aws_err_string(msg.error_code))")
            else
                Dict(:session_present => msg.session_present != 0)
            end
            put!(ch, result)
        end
        on_connection_complete_token = Ref(ForeignCallbacks.ForeignToken(on_connection_complete_fcb))

        on_connection_complete_cb =
            @cfunction(on_connection_complete, Cvoid, (Ptr{aws_mqtt_client_connection}, Cint, Cint, Cuchar, Ptr{Cvoid}))

        # The lifetime of the on_connection_complete FCB and its token is the same as the lifetime of the connection
        connection.on_connection_complete_refs = [Ref(on_connection_complete_fcb), on_connection_complete_token]

        GC.@preserve server_name_cur socket_options tls_connection_options client_id_cur on_connection_complete_fcb on_connection_complete_token begin
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
                    on_connection_complete_cb,
                    Base.unsafe_convert(Ptr{Cvoid}, on_connection_complete_token), # user_data for on_connection_complete
                    clean_session,
                ),
            )

            if aws_mqtt_client_connection_connect(connection.ptr, conn_options) != AWS_OP_SUCCESS
                error("Failed to connect. $(aws_err_string())")
            end

            return @async begin
                GC.@preserve connection conn_options on_connection_complete_fcb on_connection_complete_token begin
                    result = take!(ch)
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

function on_disconnect_complete(connection::Ptr{aws_mqtt_client_connection}, userdata::Ptr{Cvoid})
    # This is a native function and may not interact with the Julia runtime
    token = Base.unsafe_load(Base.unsafe_convert(Ptr{ForeignCallbacks.ForeignToken}, userdata))
    ForeignCallbacks.notify!(token, nothing)
    return nothing
end

"""
    disconnect(connection::Connection)

Close the connection to the server (async).
Returns a task which completes when the connection is closed.
The task will contain nothing.
"""
function disconnect(connection::Connection)
    latch = CountDownLatch(1)
    on_disconnect_complete_fcb = ForeignCallbacks.ForeignCallback{Nothing}() do _
        count_down(latch)
    end
    on_disconnect_complete_token = Ref(ForeignCallbacks.ForeignToken(on_disconnect_complete_fcb))
    on_disconnect_complete_cb = @cfunction(on_disconnect_complete, Cvoid, (Ptr{aws_mqtt_client_connection}, Ptr{Cvoid}))

    # The liftime of the on_disconnect FCB and its token is the same as the lifetime of the connection
    connection.disconnect_refs = [Ref(on_disconnect_complete_fcb), on_disconnect_complete_token]

    GC.@preserve connection on_disconnect_complete_fcb on_disconnect_complete_token begin
        aws_mqtt_client_connection_disconnect(connection.ptr, on_disconnect_complete_cb, on_disconnect_complete_token)
        return @async begin
            GC.@preserve connection on_disconnect_complete_fcb on_disconnect_complete_token begin
                await(latch)
                return nothing
            end
        end
    end
end

struct OnMessageMsg
    topic_copy::Ptr{Cuchar}
    topic_len::Csize_t
    payload_copy::Ptr{Cuchar}
    payload_len::Csize_t
    dup::Cuchar
    qos::Cint
    retain::Cuchar
end

function on_message(
    connection::Ptr{aws_mqtt_client_connection},
    topic::Ptr{aws_byte_cursor},
    payload::Ptr{aws_byte_cursor},
    dup::Cuchar,
    qos::Cint,
    retain::Cuchar,
    userdata::Ptr{Cvoid},
)
    # This is a native function and may not interact with the Julia runtime
    token = Base.unsafe_load(Base.unsafe_convert(Ptr{ForeignCallbacks.ForeignToken}, userdata))

    # Make a copy because we only have topic inside this function, not inside the ForeignCallback
    topic_obj = Base.unsafe_load(topic)
    topic_copy = ccall(:calloc, Ptr{Cvoid}, (Csize_t, Csize_t), topic_obj.len, 1)
    ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), topic_copy, topic_obj.ptr, topic_obj.len)

    # Make a copy because we only have payload inside this function, not inside the ForeignCallback
    payload_obj = Base.unsafe_load(payload)
    payload_copy = ccall(:calloc, Ptr{Cvoid}, (Csize_t, Csize_t), payload_obj.len, 1)
    ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), payload_copy, payload_obj.ptr, payload_obj.len)

    ForeignCallbacks.notify!(
        token,
        OnMessageMsg(
            Base.unsafe_convert(Ptr{Cuchar}, topic_copy),
            topic_obj.len,
            Base.unsafe_convert(Ptr{Cuchar}, payload_copy),
            payload_obj.len,
            dup,
            qos,
            retain,
        ),
    )
    return nothing
end

struct OnSubcribeCompleteMsg
    packet_id::Cuint
    topic_copy::Ptr{Cuchar}
    topic_len::Csize_t
    qos::Cint
    error_code::Cint
end

function on_subscribe_complete(
    connection::Ptr{aws_mqtt_client_connection},
    packet_id::Cuint,
    topic::Ptr{aws_byte_cursor},
    qos::Cint,
    error_code::Cint,
    userdata::Ptr{Cvoid},
)
    # This is a native function and may not interact with the Julia runtime
    token = Base.unsafe_load(Base.unsafe_convert(Ptr{ForeignCallbacks.ForeignToken}, userdata))

    # Make a copy because we only have topic inside this function, not inside the ForeignCallback
    topic_obj = Base.unsafe_load(topic)
    topic_copy = ccall(:calloc, Ptr{Cvoid}, (Csize_t, Csize_t), topic_obj.len, 1)
    ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), topic_copy, topic_obj.ptr, topic_obj.len)

    ForeignCallbacks.notify!(
        token,
        OnSubcribeCompleteMsg(packet_id, Base.unsafe_convert(Ptr{Cuchar}, topic_copy), topic_obj.len, qos, error_code),
    )
    return nothing
end

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
"""
function subscribe(connection::Connection, topic::String, qos::aws_mqtt_qos, callback::OnMessage)
    on_message_fcb = ForeignCallbacks.ForeignCallback{OnMessageMsg}() do msg
        callback(
            String(Base.unsafe_wrap(Array, msg.topic_copy, msg.topic_len, own = true)),
            String(Base.unsafe_wrap(Array, msg.payload_copy, msg.payload_len, own = true)),
            msg.dup != 0,
            aws_mqtt_qos(msg.qos),
            msg.retain != 0,
        )
    end
    on_message_token = Ref(ForeignCallbacks.ForeignToken(on_message_fcb))
    on_message_cb = @cfunction(
        on_message,
        Cvoid,
        (Ptr{aws_mqtt_client_connection}, Ptr{aws_byte_cursor}, Ptr{aws_byte_cursor}, Cuchar, Cint, Cuchar, Ptr{Cvoid})
    )

    # The lifetime of the on_message FCB and its token is the same as the lifetime of the subscription.
    connection.subscribe_refs[topic] = [Ref(on_message_fcb), on_message_token]

    ch = Channel(1)
    on_subscribe_complete_fcb = ForeignCallbacks.ForeignCallback{OnSubcribeCompleteMsg}() do msg
        result = if msg.error_code != AWS_ERROR_SUCCESS
            ErrorException("Subscribe failed. $(aws_err_string(msg.error_code))")
        else
            Dict(
                :packet_id => UInt(msg.packet_id),
                :topic => String(Base.unsafe_wrap(Array, msg.topic_copy, msg.topic_len, own = true)),
                :qos => aws_mqtt_qos(msg.qos),
            )
        end
        put!(ch, result)
    end
    on_subscribe_complete_token = Ref(ForeignCallbacks.ForeignToken(on_subscribe_complete_fcb))
    on_subscribe_complete_cb = @cfunction(
        on_subscribe_complete,
        Cvoid,
        (Ptr{aws_mqtt_client_connection}, Cuint, Ptr{aws_byte_cursor}, Cint, Cint, Ptr{Cvoid})
    )

    # The lifetime of the on_subscribe_complete FCB and its token is from SUBSCRIBE to SUBACK so we can preserve it
    # until the task returned from this function has finished, as it finishes when a SUBACK is received.
    # We also preserve it on the connection in case we get a stray SUBACK.
    connection.on_subscribe_complete_refs[topic] = [Ref(on_subscribe_complete_fcb), on_subscribe_complete_token]

    topic_cur = Ref(aws_byte_cursor_from_c_str(topic))
    GC.@preserve connection topic_cur on_subscribe_complete_fcb on_subscribe_complete_token on_message_fcb on_message_token begin
        packet_id = aws_mqtt_client_connection_subscribe(
            connection.ptr,
            topic_cur,
            qos,
            on_message_cb,
            Base.unsafe_convert(Ptr{Cvoid}, on_message_token),
            C_NULL, # called when a subscription is removed
            on_subscribe_complete_cb,
            Base.unsafe_convert(Ptr{Cvoid}, on_subscribe_complete_token),
        )
        return (@async begin
            GC.@preserve connection topic_cur on_subscribe_complete_fcb on_subscribe_complete_token on_message_fcb on_message_token begin
                result = take!(ch)
                if result isa Exception
                    throw(result)
                else
                    return result
                end
            end
        end),
        packet_id
    end
end

"""
    on_message(connection::Connection, callback::OnMessage)

Set callback to be invoked when ANY message is received.

Arguments:
- `connection`: Connection to use.
- `callback`: Optional callback invoked when message received. See [`OnMessage`](@ref) for the required signature. Set to `nothing` to clear this callback.

Returns nothing.
"""
function on_message(connection::Connection, callback::Union{OnMessage,Nothing})
    if callback === nothing
        if aws_mqtt_client_connection_set_on_any_publish_handler(connection.ptr, C_NULL, C_NULL) != AWS_OP_SUCCESS
            error("Failed to set on_message. $(aws_err_string())")
        end

        # Clear any refs from a prior callback so they can be GC'd
        connection.on_message_refs = []

        return nothing
    else
        on_message_fcb = ForeignCallbacks.ForeignCallback{OnMessageMsg}() do msg
            callback(
                String(Base.unsafe_wrap(Array, msg.topic_copy, msg.topic_len, own = true)),
                String(Base.unsafe_wrap(Array, msg.payload_copy, msg.payload_len, own = true)),
                msg.dup != 0,
                aws_mqtt_qos(msg.qos),
                msg.retain != 0,
            )
        end
        on_message_token = Ref(ForeignCallbacks.ForeignToken(on_message_fcb))

        # The lifetime of this on_message FCB and its token is the same as the lifetime of the connection
        connection.on_message_refs = [Ref(on_message_fcb), on_message_token]

        on_message_cb = @cfunction(
            on_message,
            Cvoid,
            (
                Ptr{aws_mqtt_client_connection},
                Ptr{aws_byte_cursor},
                Ptr{aws_byte_cursor},
                Cuchar,
                Cint,
                Cuchar,
                Ptr{Cvoid},
            )
        )

        GC.@preserve on_message_fcb on_message_token begin
            if aws_mqtt_client_connection_set_on_any_publish_handler(
                connection.ptr,
                on_message_cb,
                Base.unsafe_convert(Ptr{Cvoid}, on_message_token),
            ) != AWS_OP_SUCCESS
                error("Failed to set on_message. $(aws_err_string())")
            end
            return nothing
        end
    end
end

struct OnUnsubscribeCompleteMsg
    packet_id::Cuint
    error_code::Cint
end

function on_unsubscribe_complete(
    connection::Ptr{aws_mqtt_client_connection},
    packet_id::Cuint,
    error_code::Cint,
    userdata::Ptr{Cvoid},
)
    # This is a native function and may not interact with the Julia runtime
    token = Base.unsafe_load(Base.unsafe_convert(Ptr{ForeignCallbacks.ForeignToken}, userdata))

    ForeignCallbacks.notify!(token, OnUnsubscribeCompleteMsg(packet_id, error_code))
    return nothing
end

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
function unsubscribe(connection::Connection, topic::String)
    ch = Channel(1)
    on_unsubscribe_complete_fcb = ForeignCallbacks.ForeignCallback{OnUnsubscribeCompleteMsg}() do msg
        result = if msg.error_code != AWS_ERROR_SUCCESS
            ErrorException("Unsubscribe failed. $(aws_err_string(msg.error_code))")
        else
            Dict(:packet_id => UInt(msg.packet_id))
        end
        put!(ch, result)
    end
    on_unsubscribe_complete_token = Ref(ForeignCallbacks.ForeignToken(on_unsubscribe_complete_fcb))
    on_unsubscribe_complete_cb =
        @cfunction(on_unsubscribe_complete, Cvoid, (Ptr{aws_mqtt_client_connection}, Cuint, Cint, Ptr{Cvoid}))

    # It's not documented, but it seems like the lifetime of the on_unsubscribe_complete FCB and its token is
    # from UNSUBSCRIBE to UNSUBACK so we can preserve it until the task returned from this function has finished,
    # as it finishes when an UNSUBACK is received.
    # We also preserve it on the connection in case we get a stray UNSUBACK.
    connection.on_unsubscribe_complete_refs[topic] = [Ref(on_unsubscribe_complete_fcb), on_unsubscribe_complete_token]

    topic_cur = Ref(aws_byte_cursor_from_c_str(topic))
    GC.@preserve connection topic_cur on_unsubscribe_complete_fcb on_unsubscribe_complete_token begin
        packet_id = aws_mqtt_client_connection_unsubscribe(
            connection.ptr,
            topic_cur,
            on_unsubscribe_complete_cb,
            Base.unsafe_convert(Ptr{Cvoid}, on_unsubscribe_complete_token),
        )
        return (@async begin
            GC.@preserve connection topic_cur on_unsubscribe_complete_fcb on_unsubscribe_complete_token begin
                result = take!(ch)
                if result isa Exception
                    throw(result)
                else
                    # Now that the subscription is done, we can GC its callbacks
                    connection.subscribe_refs[topic] = Ref[]
                    connection.on_subscribe_complete_refs[topic] = Ref[]
                    return result
                end
            end
        end),
        packet_id
    end
end

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

struct OnPublishCompleteMsg
    packet_id::Cuint
    error_code::Cint
end

function on_publish_complete(
    connection::Ptr{aws_mqtt_client_connection},
    packet_id::Cuint,
    error_code::Cint,
    userdata::Ptr{Cvoid},
)
    # This is a native function and may not interact with the Julia runtime
    token = Base.unsafe_load(Base.unsafe_convert(Ptr{ForeignCallbacks.ForeignToken}, userdata))

    ForeignCallbacks.notify!(token, OnPublishCompleteMsg(packet_id, error_code))
    return nothing
end

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
function publish(connection::Connection, topic::String, payload::String, qos::aws_mqtt_qos, retain::Bool = false)
    ch = Channel(1)
    on_publish_complete_fcb = ForeignCallbacks.ForeignCallback{OnPublishCompleteMsg}() do msg
        result = if msg.error_code != AWS_ERROR_SUCCESS
            ErrorException("Publish failed. $(aws_err_string(msg.error_code))")
        else
            Dict(:packet_id => UInt(msg.packet_id))
        end
        put!(ch, result)
    end
    on_publish_complete_token = Ref(ForeignCallbacks.ForeignToken(on_publish_complete_fcb))
    on_publish_complete_cb =
        @cfunction(on_publish_complete, Cvoid, (Ptr{aws_mqtt_client_connection}, Cuint, Cint, Ptr{Cvoid}))

    # It's not documented, but it seems like the lifetime of the on_publish_complete FCB and its token is
    # from PUBLISH to either packet send, PUBACK, or PUBCOMP depending on QoS level, so we can preserve it until
    # the task returned from this function has finished, as it finishes when the correct event is received.
    # We also preserve it on the connection in case we get a stray PUBACK or PUBCOMP, depending on QoS level.
    connection.on_publish_complete_refs[topic] = [Ref(on_publish_complete_fcb), on_publish_complete_token]

    topic_cur = Ref(aws_byte_cursor_from_c_str(topic))
    payload_cur = Ref(aws_byte_cursor_from_c_str(payload))
    GC.@preserve connection topic_cur payload_cur on_publish_complete_fcb on_publish_complete_token begin
        packet_id = aws_mqtt_client_connection_publish(
            connection.ptr,
            topic_cur,
            qos,
            retain,
            payload_cur,
            on_publish_complete_cb,
            Base.unsafe_convert(Ptr{Cvoid}, on_publish_complete_token),
        )
        return (@async begin
            GC.@preserve connection topic_cur payload_cur on_publish_complete_fcb on_publish_complete_token begin
                result = take!(ch)
                if result isa Exception
                    throw(result)
                else
                    return result
                end
            end
        end),
        packet_id
    end
end
