# AWSCRT


| :exclamation: This is unfinished, early software. Expect bugs and breakages! |
|------------------------------------------------------------------------------|


[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://Octogonapus.github.io/AWSCRT.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://Octogonapus.github.io/AWSCRT.jl/dev)
[![TagBot](https://github.com/Octogonapus/AWSCRT.jl/actions/workflows/TagBot.yml/badge.svg)](https://github.com/Octogonapus/AWSCRT.jl/actions/workflows/TagBot.yml)
[![Build Status](https://github.com/Octogonapus/AWSCRT.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Octogonapus/AWSCRT.jl/actions/workflows/CI.yml?query=branch%3Amain)

A high-level wrapper for the code in [LibAWSCRT.jl](https://github.com/Octogonapus/LibAWSCRT.jl).
Currently, only an MQTT client is implemented.

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
client = Client(tls_ctx)
```

### Connect a client

We can create a connection using the client and connect it to the MQTT endpoint (the server).
`ENV["ENDPOINT"]` is something like `dsf9dh7fd7s9f8-ats.iot.us-east-1.amazonaws.com`.
A will is not required, but we set one here.

```julia
topic = "my-topic"
connection = Connection(client)
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
- [AWS MQTT Topic Documentation](https://docs.aws.amazon.com/iot/latest/developerguide/topics.html)
- [AWS IoT Client Certificate Documentation](https://docs.aws.amazon.com/iot/latest/developerguide/x509-client-certs.html)
