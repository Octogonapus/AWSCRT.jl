# AWSCRT

| :exclamation: This is unfinished, early software. Expect bugs and breakages! |
| ---------------------------------------------------------------------------- |

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://Octogonapus.github.io/AWSCRT.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://Octogonapus.github.io/AWSCRT.jl/dev)
[![TagBot](https://github.com/Octogonapus/AWSCRT.jl/actions/workflows/TagBot.yml/badge.svg)](https://github.com/Octogonapus/AWSCRT.jl/actions/workflows/TagBot.yml)
[![Build Status](https://github.com/Octogonapus/AWSCRT.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Octogonapus/AWSCRT.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![codecov](https://codecov.io/gh/Octogonapus/AWSCRT.jl/branch/main/graph/badge.svg?token=VFJ87JOF1O)](https://codecov.io/gh/Octogonapus/AWSCRT.jl)

A high-level wrapper for the code in [LibAWSCRT.jl](https://github.com/Octogonapus/LibAWSCRT.jl).
Currently, only an MQTT client is implemented.

- [AWSCRT](#awscrt)
  - [Installation](#installation)
  - [MQTT Client](#mqtt-client)
    - [Create a client](#create-a-client)
    - [Connect a client](#connect-a-client)
    - [Subscribe](#subscribe)
    - [Publish](#publish)
    - [Clean Up](#clean-up)
    - [See Also](#see-also)
  - [AWS IoT Device Shadow Service](#aws-iot-device-shadow-service)
  - [Create a ShadowFramework](#create-a-shadowframework)
    - [Using the ShadowFramework](#using-the-shadowframework)
    - [Update Callbacks: Ordering and Other Behaviors](#update-callbacks-ordering-and-other-behaviors)
    - [Persisting the Shadow Document Locally](#persisting-the-shadow-document-locally)
    - [See Also](#see-also-1)


## Installation

```julia
pkg> add AWSCRT
```

## MQTT Client

### Create a client

A client requires a TLS context that describes how the connection should (or should not) be secured.
Here, we use mutual TLS. The certificate and the private key here are those given to you by AWS IoT Core when you
create a new certificate ("Device certificate" `foo.pem.crt` and "Private key file" `foo-private.pem.key` in
the AWS Console).

```julia
tls_ctx_options = create_client_with_mtls(
    ENV["CERT_STRING"],
    ENV["PRI_KEY_STRING"],
    ca_filepath = joinpath(@__DIR__, "certs", "AmazonRootCA1.pem"),
    alpn_list = ["x-amzn-mqtt-ca"],
)
tls_ctx = ClientTLSContext(tls_ctx_options)
client = MQTTClient(tls_ctx)
```

### Connect a client

We can create a connection using the client and connect it to the MQTT endpoint (the server).
`ENV["ENDPOINT"]` is something like `dsf9dh7fd7s9f8-ats.iot.us-east-1.amazonaws.com`.
A will is not required, but we set one here.

```julia
topic = "my-topic"
connection = MQTTConnection(client)
task = connect(
    connection,
    ENV["ENDPOINT"],
    8883,
    "my-client-id";
    will = Will(topic, AWS_MQTT_QOS_AT_LEAST_ONCE, "The client has gone offline!", false),
)
fetch(task) # wait for the connection to be opened (or fail)
```

### Subscribe

Once we are connected, we can subscribe to a topic(s).
A callback is passed with the subscribe call; this callback is called for each received message.

```julia
topic = "test-topic"
task, id = subscribe(
    connection,
    topic,
    AWS_MQTT_QOS_AT_LEAST_ONCE,
    (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) -> begin
        @info "Topic $topic received message: $payload"
    end,
)
fetch(task) # wait for the server to tell us the subscription was received
```

### Publish

Once we are connected, we can publish a payload to a topic.

```julia
topic = "test-topic"
payload = Random.randstring(48)
task, id = publish(connection, topic, payload, AWS_MQTT_QOS_AT_LEAST_ONCE)
fetch(task) # wait for the server to tell us the published message was received
```

### Clean Up

We can also unsubscribe and disconnect.

```julia
task, id = unsubscribe(connection, topic)
fetch(task) # wait for the server to tell us the unsubscription was received

task = disconnect(connection)
fetch(task) # wait for the connection to be closed
```

### See Also

- [AWS MQTT Documentation](https://docs.aws.amazon.com/iot/latest/developerguide/mqtt.html)
- [AWS Protocol Port Mapping and Authentication Documentation](https://docs.aws.amazon.com/iot/latest/developerguide/protocols.html)
- [AWS MQTT Topic Documentation](https://docs.aws.amazon.com/iot/latest/developerguide/topics.html)
- [AWS IoT Client Certificate Documentation](https://docs.aws.amazon.com/iot/latest/developerguide/x509-client-certs.html)

## AWS IoT Device Shadow Service

The AWS IoT Device Shadow service adds persistent JSON documents you can use to e.g. manage device settings.
This package provides both a high-level framework via the `ShadowFramework` and direct access via the `ShadowClient` object.

## Create a ShadowFramework

The `ShadowFramework` object must first be created.

```julia
mqtt_connection = ... # create this yourself
thing_name = "thing1"
shadow_name = "settings"
doc = Dict()
sf = ShadowFramework(mqtt_connection, thing_name, shadow_name, doc)
```

### Using the ShadowFramework

```julia
subscribe(sf) # Subscribe to all the shadow service topics and perform any initial state updates

lock(sf) do
    doc["k1"] = "v1" # update our copy of the shadow document
end

publish_current_state(sf) # tell the shadow service about it
```

These updates go both ways. Shadow document updates from the service are received asynchronously and the local
shadow document is updated automatically. The remote state is always reconciled with the local state.

### Update Callbacks: Ordering and Other Behaviors

If you need to take action before, during, or after a local shadow document update, there are callbacks available.

```julia
cbs = Dict(
    # This callback will run whenever the key `foo` is updated. We can do whatever we want, including update the
    # shadow document itself, but be careful about potential update order conflicts and deadlocks if you jump to
    # another thread and then update the shadow document.
    "foo" => it -> do_something(it)
)
sf = ShadowFramework(...; shadow_document_property_callbacks = cbs)
```

### Persisting the Shadow Document Locally

The post-update callback is great for persisting the shadow document to the local disk:

```julia
doc = Dict()
sf = ShadowFramework(
    ...,
    doc;
    shadow_document_post_update_callback = doc -> write(shadow_path, serialize_shadow(doc))
)
```

The function `serialize_shadow` is a modified `JSON` serializer which handles version numbers better:

```julia
import JSON.Serializations: CommonSerialization, StandardSerialization
import JSON.Writer: StructuralContext, show_json

# Custom serialization for shadow documents so that version numbers serialize cleanly
struct ShadowSerialization <: CommonSerialization end

function show_json(io::StructuralContext, ::ShadowSerialization, f::VersionNumber)
    show_json(io, StandardSerialization(), string(f))
end

serialize_shadow(shadow) = sprint(show_json, ShadowSerialization(), shadow)

deserialize_shadow(text) = JSON.parse(text)
```

The next time your application starts, it can initialize the shadow document with the value from `deserialize_shadow`.
Pass that value in to the `ShadowFramework` when creating it and run `subscribe` as usual.

### See Also

- [AWS IoT Device Shadow Service Documentation](https://docs.aws.amazon.com/iot/latest/developerguide/iot-device-shadows.html)
