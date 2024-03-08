using TestEnv
TestEnv.activate()

rm(joinpath(@__DIR__, "log.txt"); force = true)

ENV["AWS_CRT_MEMORY_TRACING"] = "1"
ENV["AWS_CRT_LOG_LEVEL"] = "6"
ENV["AWS_CRT_LOG_PATH"] = joinpath(@__DIR__, "log.txt")
ENV["JULIA_DEBUG"] = "AWSCRT"

using Test, AWSCRT, LibAWSCRT, JSON, CountDownLatches, Random, Documenter, Aqua, Dates

include("util.jl")

#####################################################################################################

Base.errormonitor(Threads.@spawn begin
    while true
        GC.gc(true)
        sleep(1)
    end
end)

include("shadow_framework_integ_test.jl")

#####################################################################################################

# topic1 = "test-topic-$(Random.randstring(6))"
# payload1 = Random.randstring(48)
# payload2 = Random.randstring(48)
# client_id1 = random_client_id()
# @show topic1 payload1 client_id1

# client = MQTTClient(new_tls_ctx())
# connection = MQTTConnection(client)

# any_msg = Channel(1)
# sub_msg = Channel(1)

# # on_message(
# #     connection,
# #     (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) -> begin
# #         put!(any_msg, (; topic, payload, qos, retain))
# #     end,
# # )

# task = connect(
#     connection,
#     ENV["ENDPOINT"],
#     8883,
#     client_id1;
#     will = Will(topic1, AWS_MQTT_QOS_AT_LEAST_ONCE, "The client has gone offline!", false),
#     on_connection_interrupted = (conn, error_code) -> begin
#         @warn "connection interrupted" error_code
#     end,
#     on_connection_resumed = (conn, return_code, session_present) -> begin
#         @info "connection resumed" return_code session_present
#     end,
# )
# @test fetch(task) == Dict(:session_present => false)

# task, id = subscribe(
#     connection,
#     topic1,
#     AWS_MQTT_QOS_AT_LEAST_ONCE,
#     (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) -> begin
#         @info "subscribe callback" topic payload dup qos retain
#     end,
# )
# d = fetch(task)

# task, id = publish(connection, topic1, payload1, AWS_MQTT_QOS_AT_LEAST_ONCE)
# task, id = publish(connection, topic1, payload1, AWS_MQTT_QOS_AT_LEAST_ONCE)

# sleep(12)

# # Subscribe, publish a message, and test we get it on both callbacks
# task, id = subscribe(
#     connection,
#     topic1,
#     AWS_MQTT_QOS_AT_LEAST_ONCE,
#     (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) -> begin
#         put!(sub_msg, (; topic, payload, qos, retain))
#     end,
# )
# d = fetch(task)
# @test d[:packet_id] == id
# @test d[:topic] == topic1
# @test d[:qos] == AWS_MQTT_QOS_AT_LEAST_ONCE

# task, id = resubscribe_existing_topics(connection)
# d = fetch(task)
# @test d[:packet_id] == id
# @test d[:topics] == [(topic1, AWS_MQTT_QOS_AT_LEAST_ONCE)]

# for _ = 1:10
#     payload = Random.randstring(48)
#     @show payload
#     task, id = publish(connection, topic1, payload, AWS_MQTT_QOS_AT_LEAST_ONCE)
#     @test fetch(task) == Dict(:packet_id => id)

#     msg = take!(sub_msg)
#     @show msg
#     @test msg.topic == topic1
#     @test msg.payload == payload
#     @test msg.qos == AWS_MQTT_QOS_AT_LEAST_ONCE
#     @test !msg.retain

#     msg = take!(any_msg)
#     @show msg
#     @test msg.topic == topic1
#     @test msg.payload == payload
#     @test msg.qos == AWS_MQTT_QOS_AT_LEAST_ONCE
#     @test !msg.retain
# end

# @show task, id = publish(
#     connection,
#     "\$aws/things/AWSCRT_Test1/shadow/name/shadow-abc123/update",
#     json(Dict("state" => Dict("desired" => Dict("foo" => 2)))),
#     AWS_MQTT_QOS_AT_LEAST_ONCE,
# )
# @show fetch(task)

# shadow_name = Random.randstring(6)
# @show task, id = subscribe(
#     connection,
#     "\$aws/things/AWSCRT_Test1/shadow/name/shadow-$shadow_name/get/rejected",
#     AWS_MQTT_QOS_AT_LEAST_ONCE,
#     (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) -> begin
#         @info "get rejected callback" topic payload dup qos retain

#         task, id = publish(
#             connection,
#             "\$aws/things/AWSCRT_Test1/shadow/name/shadow-$shadow_name/update",
#             json(Dict("state" => Dict("desired" => Dict("foo" => 2)))),
#             AWS_MQTT_QOS_AT_LEAST_ONCE,
#         )
#         @info "get rejected callback" task id fetch(task)
#     end,
# )
# @show d = fetch(task)

# @show task, id = publish(
#     connection,
#     "\$aws/things/AWSCRT_Test1/shadow/name/shadow-$shadow_name/get",
#     json(Dict()),
#     AWS_MQTT_QOS_AT_LEAST_ONCE,
# )
# @show fetch(task)

# sleep(3)

"""
summary

with FCBs:
1. publish from julia thread
2. subscribe callback runs on CRT event loop thread, puts msg in FCBs queue, and returns
3. julia thread waiting on FCBs queue is woken, publishes another msg, and waits again (i.e. fetch())
4. CRT event loop thread is not blocked

without FCBs:
1. publish from julia thread
2. subscribe callback runs on CRT event loop thread, publishes another msg, and waits (i.e. fetch())
3. CRT event loop thread is now deadlocked waiting for the subscribe callback to run again, but the event loop is blocked due to that wait

solution: ???
need to get off the CRT event loop thread somehow to unblock the event loop
am i just arriving back at FCBs?
Valentin said FCBs were not necessary as of v1.9, and strictly speaking they aren't because the code "works" but we have this deadlock now
I think it will be too much burden on the user to always have fast nonblocking callbacks and we need to keep the code running on the event loop 100% inside this package, therefore we need a solution like FCBs

add comments to CRT callbacks that note they block the event loop
"""

#####################################################################################################

# struct OOBShadowClient
#     shadow_client::ShadowClient
#     msgs::Vector{Any}
#     shadow_callback::Function

#     function OOBShadowClient(oob_connection, thing1_name, shadow_name)
#         msgs = Any[]
#         function shadow_callback(
#             shadow_client::ShadowClient,
#             topic::String,
#             payload::String,
#             dup::Bool,
#             qos::aws_mqtt_qos,
#             retain::Bool,
#         )
#             push!(msgs, (; shadow_client, topic, payload, dup, qos, retain))
#         end
#         return new(ShadowClient(oob_connection, thing1_name, shadow_name), msgs, shadow_callback)
#     end
# end

# function subscribe_for_single_shadow_msg(oobsc, topic, payload)
#     tasks_and_ids = subscribe(oobsc.shadow_client, AWS_MQTT_QOS_AT_LEAST_ONCE, oobsc.shadow_callback)
#     for (task, id) in tasks_and_ids
#         fetch(task)
#     end
#     fetch(publish(oobsc.shadow_client, topic, payload, AWS_MQTT_QOS_AT_LEAST_ONCE)[1])
#     wait_for(() -> !isempty(oobsc.msgs))
#     fetch(unsubscribe(oobsc.shadow_client)[1])
# end

# function test_get_accepted_payload_equals_shadow_doc(payload, doc)
#     @info "test_get_accepted_payload_equals_shadow_doc" payload doc
#     p = JSON.parse(payload)
#     for k in keys(doc)
#         if k != "version"
#             @test p["state"]["reported"][k] == doc[k]
#         end
#     end
#     @test p["version"] == doc["version"]
# end

# function maybe_get(d, keys...)
#     return if length(keys) == 1
#         get(d, keys[1], nothing)
#     else
#         if haskey(d, keys[1])
#             maybe_get(d[keys[1]], keys[2:end]...)
#         else
#             nothing
#         end
#     end
# end

# mutable struct ShadowDocMissingProperty
#     foo::Int
#     version::Int
# end

# connection = new_mqtt_connection()
# shadow_name = random_shadow_name()
# doc = Dict("foo" => 1)

# values_foo = []
# foo_cb = x -> push!(values_foo, x)

# values_pre_update = []
# pre_update_cb = x -> push!(values_pre_update, x)

# values_post_update = []
# latch_post_update = Ref(CountDownLatch(1))
# post_update_cb = x -> begin
#     push!(values_post_update, x)
#     count_down(latch_post_update[])
# end

# sf = ShadowFramework(
#     connection,
#     thing1_name,
#     shadow_name,
#     doc;
#     shadow_document_pre_update_callback = pre_update_cb,
#     shadow_document_post_update_callback = post_update_cb,
#     shadow_document_property_callbacks = Dict{String,Function}("foo" => foo_cb),
# )
# sc = shadow_client(sf)

# msgs = []
# function shadow_callback(
#     shadow_client::ShadowClient,
#     topic::String,
#     payload::String,
#     dup::Bool,
#     qos::aws_mqtt_qos,
#     retain::Bool,
# )
#     push!(msgs, (; shadow_client, topic, payload, dup, qos, retain))
# end

# oobc = new_mqtt_connection()
# oobsc = OOBShadowClient(oobc, thing1_name, shadow_name)

# fetch(subscribe(sf)[1])
# sleep(3)

# @info "publishing first update"
# @show publish(
#     oobsc.shadow_client,
#     "/update",
#     json(Dict("state" => Dict("desired" => Dict("foo" => 2)))),
#     AWS_MQTT_QOS_AT_LEAST_ONCE,
# )
# sleep(3)
# # wait_for(() -> !isempty(values_post_update))
# # @test doc["foo"] == 2

# # @info "unsubscribing"
# # for (task, id) in unsubscribe(sf)
# #     fetch(task)
# # end
# # @info "done unsubscribing"
