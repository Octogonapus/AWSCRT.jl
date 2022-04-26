mutable struct Client

    """
    MQTT client.
    # TODO docs
    """
    function Client(
        bootstrap, # TODO optional
        tls_ctx, # TODO optional
    ) end
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

    """
    MQTT client connection.
    # TODO docs
    """
    function Connection(
        client::Client,
        hostname::AbstractString,
        port::Integer,
        client_id::AbstractString,
        clean_session::Bool,
        on_connection_interrupted::OnConnectionInterrupted, # TODO optional
        on_connection_resumed::OnConnectionResumed, # TODO optional
        reconnect_min_timeout_secs::Integer = 5,
        reconnect_max_timeout_secs::Integer = 60,
        keep_alive_secs::Integer = 1200,
        ping_timeout_ms::Integer = 3000,
        protocol_operation_timeout_ms::Integer = 0,
        will = nothing, # TODO union type
        username::Union{AbstractString,Nothing} = nothing,
        password::Union{AbstractString,Nothing} = nothing,
        socket_options = nothing, # TODO union type
        use_websockets::Bool = false,
        websocket_proxy_options = nothing, # TODO union type
        websocket_handshake_transform = nothing, # TODO union type
        proxy_options = nothing, # TODO union type
    ) end
end

"""
    connect(connection::Connection)

Open the actual connection to the server (async).
Returns a task which completes when the connection succeeds or fails.

If the connection succeeds, the task will contain a dict containing the following keys:
- `:session_present`: `true` if resuming an existing session, `false` if new session

If the connection fails, the task will contain an exception.
"""
connect(connection::Connection) = error("Not implemented.")

"""
    disconnect(connection::Connection)

Close the connection to the server (async).
Returns a task which completes when the connection is closed.
"""
disconnect(connection::Connection) = error("Not implemented.")

"""
    subscribe(connection::Connection, topic::AbstractString, qos::aws_mqtt_qos, callback::OnMessage)

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
subscribe(connection::Connection, topic::AbstractString, qos::aws_mqtt_qos, callback::OnMessage) =
    error("Not implemented.")

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
    unsubscribe(connection::Connection, topic::AbstractString)

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
unsubscribe(connection::Connection, topic::AbstractString) = error("Not implemented.")

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
publish(connection::Connection, topic::AbstractString, payload, qos::aws_mqtt_qos, retain::Bool = false) =
    error("Not implemented.")
