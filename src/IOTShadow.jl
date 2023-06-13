"""
    ShadowClient(
        connection::MQTTConnection,
    )

Device Shadow service client.
[AWS Documentation](https://docs.aws.amazon.com/iot/latest/developerguide/iot-device-shadows.html).

Arguments:

  - `connection (MQTTConnection)`: MQTT connection to publish and subscribe on.
  - `thing_name (String)`: Name of the Thing in AWS IoT under which the shadow document will exist.
  - `shadow_name (Union{String,Nothing})`: Shadow name for a named shadow document or `nothing` for an unnamed shadow document.
"""
mutable struct ShadowClient
    connection::MQTTConnection
    shadow_topic_prefix::String

    function ShadowClient(connection::MQTTConnection, thing_name::String, shadow_name::Union{String,Nothing})
        new(
            connection,
            shadow_name === nothing ? "\$aws/things/$thing_name/shadow" :
            "\$aws/things/$thing_name/shadow/name/$shadow_name",
        )
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
- `dup (Bool)`: DUP flag. If `true`, this might be re-delivery of an earlier attempt to send the message.
- `qos (aws_mqtt_qos)`: $subscribe_qos_docs
- `retain (Bool)`: Retain flag. If `true`, the message was sent as a result of a new subscription being made by the client.

Returns `nothing`.
"""
const OnShadowMessage = Function

"""
    subscribe(client::ShadowClient, qos::aws_mqtt_qos, callback::OnShadowMessage)

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
- `qos (aws_mqtt_qos)`: $subscribe_qos_docs
- `callback (OnShadowMessage)`: Callback invoked when message received. See [`OnShadowMessage`](@ref) for the required signature.

Returns the tasks from each subscribe call (`/get/#`, `/update/#`, and `/delete/#`).
"""
function subscribe(client::ShadowClient, qos::aws_mqtt_qos, callback::OnShadowMessage)
    mqtt_callback =
        (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) ->
            callback(client, topic, payload, dup, qos, retain)
    getf = subscribe(client, "/get/#", qos, mqtt_callback)
    updatef = subscribe(client, "/update/#", qos, mqtt_callback)
    deletef = subscribe(client, "/delete/#", qos, mqtt_callback)
    return getf, updatef, deletef
end

"""
    subscribe(client::ShadowClient, topic::String, qos::aws_mqtt_qos, callback::OnMessage)

Subscribes to the given `topic` (must contain a leading forward slash (`/`)) under the given shadow document.

Arguments:
- `client (ShadowClient)`: Shadow client to use.
- `topic (String)`: Subscribe to this topic filter, which may include wildcards, under the given shadow document.
- `qos (aws_mqtt_qos)`: $subscribe_qos_docs
- `callback (OnMessage)`: $subscribe_callback_docs

$subscribe_return_docs
"""
function subscribe(client::ShadowClient, topic::String, qos::aws_mqtt_qos, callback::OnMessage)
    @debug "subscribing to $(client.shadow_topic_prefix)$topic"
    return subscribe(client.connection, "$(client.shadow_topic_prefix)$topic", qos, callback)
end

const _UNSUBCRIBE_TOPICS = [
    # If the wildcard topics are unsubscribed from after the other topics, the CRT segfaults
    "/get/#",
    "/update/#",
    "/delete/#",
    # Non-wildcard topics below...
    "/get",
    "/get/accepted",
    "/get/rejected",
    "/update",
    "/update/delta",
    "/update/accepted",
    "/update/documents",
    "/update/rejected",
    "/delete",
    "/delete/accepted",
    "/delete/rejected",
]

const _iot_shadow_unsubscribe_return_docs = "Returns a list of the tasks from each [`unsubscribe`](@ref) call."

"""
    unsubscribe(client::ShadowClient)

Unsubscribes from all shadow document topics.

Arguments:
- `client (ShadowClient)`: Shadow client to use.

$_iot_shadow_unsubscribe_return_docs
"""
function unsubscribe(client::ShadowClient)
    # there is no function in the CRT to get the current topics (though they are stored internally)
    # so we need to unsubscribe from every possible topic
    out = []
    for topic in _UNSUBCRIBE_TOPICS
        @debug "unsubscribing from $(client.shadow_topic_prefix)$topic"
        push!(out, unsubscribe(client.connection, "$(client.shadow_topic_prefix)$topic"))
    end
    return out
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
