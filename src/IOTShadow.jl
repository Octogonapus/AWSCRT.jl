"""
    ShadowClient(
        connection::MQTTConnection,
    )

Device Shadow service client.
[AWS Documentation](https://docs.aws.amazon.com/iot/latest/developerguide/iot-device-shadows.html).

Arguments:
- `connection (MQTTConnection)`: MQTT connection to publish and subscribe on.
"""
mutable struct ShadowClient
    connection::MQTTConnection
    shadow_topic_prefix::Union{String,Nothing}

    function ShadowClient(connection::MQTTConnection)
        new(connection, nothing)
    end
end

"""
    on_shadow_message(
        shadow_client::ShadowClient,
        topic::String,
        payload::String,
        dup::Bool,
        qos::aws_mqtt_qos,
        retain::Bool,
    )

A callback invoked when a shadow document message is received.

Arguments:
- `shadow_client (ShadowClient)`: Shadow client that received the message.
- `topic (String)`: Topic receiving message.
- `payload (String)`: Payload of message.
- `dup (Bool)`: DUP flag. If True, this might be re-delivery of an earlier attempt to send the message.
- `qos (aws_mqtt_qos)`: $subscribe_qos_docs
- `retain (Bool)`: Retain flag. If `true`, the message was sent as a result of a new subscription being made by the client.

Returns `nothing`.
"""
const OnShadowMessage = Function

"""
    subscribe(
        client::ShadowClient,
        thing_name::String,
        shadow_name::Union{String,Nothing},
        qos::aws_mqtt_qos,
        callback::OnShadowMessage,
    )

Subscribes to all topics under the given shadow document using a wildcard, including but not limited to:
- `/get/accepted`
- `/get/rejected`
- `/update/delta`
- `/update/accepted`
- `/update/documents`
- `/update/rejected`
- `/delete/accepted`
- `/delete/rejected`

Arguments:
- `client (ShadowClient)`: Shadow client to use.
- `thing_name (String)`: Name of the Thing in AWS IoT.
- `shadow_name (Union{String,Nothing})`: Shadow name for a named shadow document or `nothing` for an unnamed shadow document.
- `qos (aws_mqtt_qos)`: $subscribe_qos_docs
- `callback (OnShadowMessage)`: Callback invoked when message received. See [`OnShadowMessage`](@ref) for the required signature.

Returns the tasks from each subscribe call (`/get/#`, `/update/#`, and `/delete/#`).
"""
function subscribe(
    client::ShadowClient,
    thing_name::String,
    shadow_name::Union{String,Nothing},
    qos::aws_mqtt_qos,
    callback::OnShadowMessage,
)
    client.shadow_topic_prefix =
        shadow_name === nothing ? "\$aws/things/$thing_name/shadow" :
        "\$aws/things/$thing_name/shadow/name/$shadow_name"
    mqtt_callback =
        (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) ->
            callback(client, topic, payload, dup, qos, retain)
    getf = subscribe(client.connection, "$(client.shadow_topic_prefix)/get/#", qos, mqtt_callback)
    updatef = subscribe(client.connection, "$(client.shadow_topic_prefix)/update/#", qos, mqtt_callback)
    deletef = subscribe(client.connection, "$(client.shadow_topic_prefix)/delete/#", qos, mqtt_callback)
    return getf, updatef, deletef
end

"""
    unsubscribe(client::ShadowClient)

Unsubscribes from the shadow document topics.

Arguments:
- `client (ShadowClient)`: Shadow client to use.

$unsubscribe_return_docs
"""
function unsubscribe(client::ShadowClient)
    topic = client.shadow_topic_prefix
    client.shadow_topic_prefix = nothing
    return unsubscribe(client.connection, "$topic/#")
end

"""
    publish(client::ShadowClient, topic::String, payload::String, qos::aws_mqtt_qos)

Publishes the payload to the topic under the configured shadow topic.

Arguments:
- `client (ShadowClient)`: Shadow client to use.
- `topic (String)`: Topic name, not including the shadow topic prefix. E.g. `/get`.
- `payload (String)`: Message contents.
- `qos (aws_mqtt_qos)`: $subscribe_qos_docs

$publish_return_docs
"""
function publish(client::ShadowClient, topic::String, payload::String, qos::aws_mqtt_qos)
    return publish(client.connection, "$(client.shadow_topic_prefix)$topic", payload, qos)
end
