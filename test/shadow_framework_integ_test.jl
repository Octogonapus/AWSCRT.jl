struct OOBShadowClient
    shadow_client::ShadowClient
    msgs::Vector{Any}
    shadow_callback::Function

    function OOBShadowClient(oob_connection, THING1_NAME, shadow_name)
        msgs = Any[]
        function shadow_callback(
            shadow_client::ShadowClient,
            topic::String,
            payload::String,
            dup::Bool,
            qos::aws_mqtt_qos,
            retain::Bool,
        )
            push!(msgs, (; shadow_client, topic, payload, dup, qos, retain))
        end
        return new(ShadowClient(oob_connection, THING1_NAME, shadow_name), msgs, shadow_callback)
    end
end

function subscribe_for_single_shadow_msg(oobsc, topic, payload)
    fetch(subscribe(oobsc.shadow_client, AWS_MQTT_QOS_AT_LEAST_ONCE, oobsc.shadow_callback)[1])
    fetch(publish(oobsc.shadow_client, topic, payload, AWS_MQTT_QOS_AT_LEAST_ONCE)[1])
    wait_for(() -> !isempty(oobsc.msgs))
    fetch(unsubscribe(oobsc.shadow_client)[1])
end

function test_get_accepted_payload_equals_shadow_doc(payload, doc)
    @info "test_get_accepted_payload_equals_shadow_doc" payload doc
    p = JSON.parse(payload)
    for k in keys(doc)
        if k != "version"
            @test p["state"]["reported"][k] == doc[k]
        end
    end
    @test p["version"] == doc["version"]
end

function maybe_get(d, keys...)
    return if length(keys) == 1
        get(d, keys[1], nothing)
    else
        if haskey(d, keys[1])
            maybe_get(d[keys[1]], keys[2:end]...)
        else
            nothing
        end
    end
end

mutable struct ShadowDocMissingProperty
    foo::Int
    version::Int
end

@testset "unsubscribe" begin
    connection = new_mqtt_connection()
    shadow_name = random_shadow_name()
    doc = Dict("foo" => 1)

    values_foo = []
    foo_cb = x -> push!(values_foo, x)

    values_pre_update = []
    pre_update_cb = x -> push!(values_pre_update, x)

    values_post_update = []
    latch_post_update = Ref(CountDownLatch(1))
    post_update_cb = x -> begin
        push!(values_post_update, x)
        count_down(latch_post_update[])
    end

    sf = ShadowFramework(
        connection,
        THING1_NAME,
        shadow_name,
        doc;
        shadow_document_pre_update_callback = pre_update_cb,
        shadow_document_post_update_callback = post_update_cb,
        shadow_document_property_callbacks = Dict{String,Function}("foo" => foo_cb),
    )
    sc = shadow_client(sf)

    msgs = []
    function shadow_callback(
        shadow_client::ShadowClient,
        topic::String,
        payload::String,
        dup::Bool,
        qos::aws_mqtt_qos,
        retain::Bool,
    )
        push!(msgs, (; shadow_client, topic, payload, dup, qos, retain))
    end

    oobc = new_mqtt_connection()
    oobsc = OOBShadowClient(oobc, THING1_NAME, shadow_name)

    try
        fetch(subscribe(sf)[1])

        @info "publishing first update"
        fetch(
            publish(
                oobsc.shadow_client,
                "/update",
                json(Dict("state" => Dict("desired" => Dict("foo" => 2)))),
                AWS_MQTT_QOS_AT_LEAST_ONCE,
            )[1],
        )
        wait_for(() -> !isempty(values_post_update))
        @test doc["foo"] == 2

        @info "unsubscribing"
        fetch(unsubscribe(sf)[1])
        @info "done unsubscribing"

        @info "publishing second update"
        fetch(
            publish(
                oobsc.shadow_client,
                "/update",
                json(Dict("state" => Dict("desired" => Dict("foo" => 3)))),
                AWS_MQTT_QOS_AT_LEAST_ONCE,
            )[1],
        )
        sleep(5) # wait for the update to NOT happen
        @test doc["foo"] == 2 # check the update did not happen

        fetch(unsubscribe(oobsc.shadow_client)[1])
    catch ex
        @error exception = (ex, catch_backtrace())
    finally
        fetch(publish(sc, "/delete", "", AWS_MQTT_QOS_AT_LEAST_ONCE)[1])
    end
end

shadow_types = parallel ? [:named] : [:named, :unnamed]
@testset "the initial update syncs with the desired state ($shadow_type)" for shadow_type in shadow_types
    if shadow_type == :unnamed
        lock_test_unnamed_shadow(THING1_NAME) # only one test can use the unnamed shadow at a time
    end
    try
        connection = new_mqtt_connection()
        shadow_name = if shadow_type == :unnamed
            nothing
        else
            random_shadow_name()
        end
        doc = Dict("foo" => 1)

        values_foo = []
        foo_cb = x -> push!(values_foo, x)

        values_pre_update = []
        pre_update_cb = x -> push!(values_pre_update, x)

        values_post_update = []
        latch_post_update = Ref(CountDownLatch(1))
        post_update_cb = x -> begin
            push!(values_post_update, x)
            count_down(latch_post_update[])
        end

        sf = ShadowFramework(
            connection,
            THING1_NAME,
            shadow_name,
            doc;
            shadow_document_pre_update_callback = pre_update_cb,
            shadow_document_post_update_callback = post_update_cb,
            shadow_document_property_callbacks = Dict{String,Function}("foo" => foo_cb),
        )
        sc = shadow_client(sf)

        msgs = []
        function shadow_callback(
            shadow_client::ShadowClient,
            topic::String,
            payload::String,
            dup::Bool,
            qos::aws_mqtt_qos,
            retain::Bool,
        )
            push!(msgs, (; shadow_client, topic, payload, dup, qos, retain))
        end

        oobc = new_mqtt_connection()
        oobsc = OOBShadowClient(oobc, THING1_NAME, shadow_name)

        try
            fetch(publish(sc, "/delete", "", AWS_MQTT_QOS_AT_LEAST_ONCE)[1]) # ensure the shadow is deleted just in case of a prior broken test

            fetch(subscribe(sf)[1]) # subscribe and trigger the initial update, which will fail because there is no shadow
            wait_until_synced(sf)
            sleep(3) # we need to make sure the local shadow won't get modified. no better way than to just wait a bit in case something modifies it.
            @test collect(keys(doc)) == ["version", "foo"] # we should have the version and the initial foo key we set
            @test doc["foo"] == 1 # should be unchanged from our initial state

            @info "unsubscribing"
            fetch(unsubscribe(sf)[1])
            @info "done unsubscribing"

            # the intitial shadow doc state should have been published as reported state from the initial subscribe.
            # test this is correct on the broker's side.
            @info "testing shadow state on the broker"
            subscribe_for_single_shadow_msg(oobsc, "/get", "")
            test_get_accepted_payload_equals_shadow_doc(oobsc.msgs[1][:payload], doc)

            @info "subscribing for out of band shadow updates"
            update_msgs = []
            task, id = subscribe(
                oobsc.shadow_client,
                "/update",
                AWS_MQTT_QOS_AT_LEAST_ONCE,
                (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) -> begin
                    @info "received OOB shadow update" topic payload
                    push!(update_msgs, (; topic, payload, dup, qos, retain))
                end,
            )
            @info "waiting for out of band shadow update subscribe to finish" id
            fetch(task)

            # Prepare some content so we can test the initial update. i.e. pretend the shadow moved while we were offline
            @info "publishing out of band /update"
            fetch(
                publish(
                    oobsc.shadow_client,
                    "/update",
                    json(Dict("state" => Dict("desired" => Dict("foo" => 2)))),
                    AWS_MQTT_QOS_AT_LEAST_ONCE,
                )[1],
            )

            # wait a bit so that the sf doesn't get any responses from the /update above. we're trying to test what
            # happens on the initial sync, not what happens after that, so the sf should not be getting any messages
            # other than the ones published in response to its initial /get
            sleep(3)

            @info "subscribing in band shadow"
            values_post_update = []
            fetch(subscribe(sf)[1]) # subscribe and trigger the initial update
            wait_until_synced(sf)
            wait_for(() -> length(values_post_update) >= 1) # wait for the update to finish since it requires multiple messages
            # The initial update should have pulled in that desired state
            @test doc["foo"] == 2
            @test values_foo == [2]
            @test values_pre_update == [Dict("foo" => 2)]
            @test values_post_update == [doc]
            wait_for(() -> length(update_msgs) >= 2; throw = false)
            @test length(update_msgs) == 2
            @show update_msgs
            payloads = [JSON.parse(it.payload) for it in update_msgs]
            @test any(it -> maybe_get(it, "state", "desired", "foo") == 2, payloads) # from our desired state update above
            @test any(it -> maybe_get(it, "state", "reported", "foo") == 2, payloads) # new reported state after the initial get

            @info "unsubscribing"
            fetch(unsubscribe(sf)[1])
            @info "done unsubscribing"
            fetch(unsubscribe(oobsc.shadow_client)[1])
        finally
            fetch(publish(sc, "/delete", "", AWS_MQTT_QOS_AT_LEAST_ONCE)[1])
        end
    finally
        if shadow_type == :unnamed
            unlock_test_unnamed_shadow(THING1_NAME)
        end
    end
end

@testset "out of order messages are discarded" begin
    connection = new_mqtt_connection()
    shadow_name = random_shadow_name()
    doc = Dict("foo" => 1, "version" => 2)

    values_foo = []
    foo_cb = x -> push!(values_foo, x)

    values_pre_update = []
    pre_update_cb = x -> push!(values_pre_update, x)

    values_post_update = []
    latch_post_update = Ref(CountDownLatch(1))
    post_update_cb = x -> begin
        push!(values_post_update, x)
        count_down(latch_post_update[])
    end

    sf = ShadowFramework(
        connection,
        THING1_NAME,
        shadow_name,
        doc;
        shadow_document_pre_update_callback = pre_update_cb,
        shadow_document_post_update_callback = post_update_cb,
        shadow_document_property_callbacks = Dict{String,Function}("foo" => foo_cb),
    )
    sc = shadow_client(sf)

    msgs = []
    function shadow_callback(
        shadow_client::ShadowClient,
        topic::String,
        payload::String,
        dup::Bool,
        qos::aws_mqtt_qos,
        retain::Bool,
    )
        push!(msgs, (; shadow_client, topic, payload, dup, qos, retain))
    end

    oobc = new_mqtt_connection()
    oobsc = OOBShadowClient(oobc, THING1_NAME, shadow_name)

    update_msgs = []
    task, id = subscribe(
        oobc,
        "/update",
        AWS_MQTT_QOS_AT_LEAST_ONCE,
        (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) ->
            push!(update_msgs, (; topic, payload, dup, qos, retain)),
    )
    fetch(task)

    try
        fetch(subscribe(sf)[1])

        # publish a /get/accepted with a lesser version number. this should be rejected. no local shadow update
        # should occur. no update should be published.
        fetch(
            publish(
                oobsc.shadow_client,
                "/get/accepted",
                json(Dict("state" => Dict("delta" => Dict("foo" => 2)), "version" => 1)),
                AWS_MQTT_QOS_AT_LEAST_ONCE,
            )[1],
        )
        sleep(3)
        @test isempty(values_pre_update)
        @test isempty(values_foo)
        @test isempty(values_post_update)
        @test isempty(update_msgs)

        # publish a /update/delta with a lesser version number. this should be rejected. no local shadow update
        # should occur. no update should be published.
        fetch(
            publish(
                oobsc.shadow_client,
                "/update/delta",
                json(Dict("state" => Dict("foo" => 2), "version" => 1)),
                AWS_MQTT_QOS_AT_LEAST_ONCE,
            )[1],
        )
        sleep(3)
        @test isempty(values_pre_update)
        @test isempty(values_foo)
        @test isempty(values_post_update)
        @test isempty(update_msgs)

        @info "unsubscribing"
        fetch(unsubscribe(sf)[1])
        @info "done unsubscribing"
        fetch(unsubscribe(oobsc.shadow_client)[1])
    finally
        fetch(publish(sc, "/delete", "", AWS_MQTT_QOS_AT_LEAST_ONCE)[1])
    end
end

@testset "updates are published only if the reported state changed" begin
    @testset "happy path" begin
        connection = new_mqtt_connection()
        shadow_name = random_shadow_name()
        doc = Dict("foo" => 1)

        values_foo = []
        foo_cb = x -> push!(values_foo, x)

        values_pre_update = []
        pre_update_cb = x -> push!(values_pre_update, x)

        values_post_update = []
        latch_post_update = Ref(CountDownLatch(1))
        post_update_cb = x -> begin
            push!(values_post_update, x)
            count_down(latch_post_update[])
        end

        sf = ShadowFramework(
            connection,
            THING1_NAME,
            shadow_name,
            doc;
            shadow_document_pre_update_callback = pre_update_cb,
            shadow_document_post_update_callback = post_update_cb,
            shadow_document_property_callbacks = Dict{String,Function}("foo" => foo_cb),
        )
        sc = shadow_client(sf)

        msgs = []
        function shadow_callback(
            shadow_client::ShadowClient,
            topic::String,
            payload::String,
            dup::Bool,
            qos::aws_mqtt_qos,
            retain::Bool,
        )
            push!(msgs, (; shadow_client, topic, payload, dup, qos, retain))
        end

        oobc = new_mqtt_connection()
        oobsc = OOBShadowClient(oobc, THING1_NAME, shadow_name)

        update_msgs = []
        task, id = subscribe(
            oobsc.shadow_client,
            "/update",
            AWS_MQTT_QOS_AT_LEAST_ONCE,
            (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) ->
                push!(update_msgs, (; topic, payload, dup, qos, retain)),
        )
        fetch(task)

        try
            @info "subscribing"
            fetch(subscribe(sf)[1])
            # wait for the first publish to finish, otherwise we will race it with our next update, which could arrive
            # first and break this test
            wait_until_synced(sf)

            # publish a /update. this should be accepted. the local shadow should be updated.
            # an /update should be published with the new reported state.
            @info "publishing out of band /update"
            fetch(
                publish(
                    oobsc.shadow_client,
                    "/update",
                    json(Dict("state" => Dict("desired" => Dict("foo" => 2)))),
                    AWS_MQTT_QOS_AT_LEAST_ONCE,
                )[1],
            )
            wait_for(() -> !isempty(values_post_update))
            @test doc["foo"] == 2
            wait_for(() -> length(update_msgs) >= 3)
            @test length(update_msgs) == 3
            payloads = [JSON.parse(it.payload) for it in update_msgs]
            # FIXME: this test can be flaky
            @test any(it -> maybe_get(it, "state", "reported", "foo") == 1, payloads) # from the initial update since the shadow doc didn't exist
            @test any(it -> maybe_get(it, "state", "reported", "foo") == 2, payloads) # from our desired state update above

            @info "unsubscribing"
            fetch(unsubscribe(sf)[1])
            @info "done unsubscribing"
            fetch(unsubscribe(oobsc.shadow_client)[1])
        finally
            fetch(publish(sc, "/delete", "", AWS_MQTT_QOS_AT_LEAST_ONCE)[1])
        end
    end

    @testset "desired state that can't be reconciled with the local shadow doesn't cause excessive publishing" begin
        @warn "Missing property errors are expected in this test"
        connection = new_mqtt_connection()
        shadow_name = random_shadow_name()
        doc = ShadowDocMissingProperty(1, 0)

        values_foo = []
        foo_cb = x -> push!(values_foo, x)

        values_pre_update = []
        pre_update_cb = x -> push!(values_pre_update, x)

        values_post_update = []
        latch_post_update = Ref(CountDownLatch(1))
        post_update_cb = x -> begin
            push!(values_post_update, x)
            count_down(latch_post_update[])
        end

        sf = ShadowFramework(
            connection,
            THING1_NAME,
            shadow_name,
            doc;
            shadow_document_pre_update_callback = pre_update_cb,
            shadow_document_post_update_callback = post_update_cb,
            shadow_document_property_callbacks = Dict{String,Function}("foo" => foo_cb),
        )
        sc = shadow_client(sf)

        msgs = []
        function shadow_callback(
            shadow_client::ShadowClient,
            topic::String,
            payload::String,
            dup::Bool,
            qos::aws_mqtt_qos,
            retain::Bool,
        )
            push!(msgs, (; shadow_client, topic, payload, dup, qos, retain))
        end

        oobc = new_mqtt_connection()
        oobsc = OOBShadowClient(oobc, THING1_NAME, shadow_name)

        update_msgs = []
        task, id = subscribe(
            oobsc.shadow_client,
            "/update",
            AWS_MQTT_QOS_AT_LEAST_ONCE,
            (topic::String, payload::String, dup::Bool, qos::aws_mqtt_qos, retain::Bool) ->
                push!(update_msgs, (; topic, payload, dup, qos, retain)),
        )
        fetch(task)

        try
            @info "subscribing"
            fetch(subscribe(sf)[1])
            # wait for the first publish to finish, otherwise we will race it with our next update, which could arrive
            # first and break this test
            wait_until_synced(sf)

            # publish an /update which adds bar=1. this should be rejected because bar is not present in the struct.
            # the local shadow should not be updated. an /update should not be published.
            @info "publishing out of band /update"
            @info "the following shadow property error is expected"
            fetch(
                publish(
                    oobsc.shadow_client,
                    "/update",
                    json(Dict("state" => Dict("desired" => Dict("bar" => 1)))),
                    AWS_MQTT_QOS_AT_LEAST_ONCE,
                )[1],
            )
            sleep(3)
            wait_for(() -> length(update_msgs) >= 2)
            @test length(update_msgs) == 2
            @show update_msgs
            payloads = [JSON.parse(it.payload) for it in update_msgs]
            @test any(it -> maybe_get(it, "state", "reported", "foo") == 1, payloads) # from the initial update since the shadow doc didn't exist
            @test any(it -> maybe_get(it, "state", "desired", "bar") == 1, payloads) # from our desired state update above
            # there should not be any other update because the bar update should not have been accepted

            update_msgs = []

            # publish an /update which changes foo=2 (with bar=1 still set). this should be accepted.
            # the local shadow should be updated. an /update should be published. the broker will respond with another
            # /update/delta which should be ignored.
            @info "publishing second out of band /update"
            @info "the following shadow property error is expected"
            fetch(
                publish(
                    oobsc.shadow_client,
                    "/update",
                    json(Dict("state" => Dict("desired" => Dict("foo" => 2)))),
                    AWS_MQTT_QOS_AT_LEAST_ONCE,
                )[1],
            )
            sleep(3)
            wait_for(() -> length(update_msgs) >= 2)
            @test length(update_msgs) == 2
            @show update_msgs
            payloads = [JSON.parse(it.payload) for it in update_msgs]
            @test any(it -> maybe_get(it, "state", "desired", "foo") == 2, payloads) # from our desired state update above
            @test any(it -> maybe_get(it, "state", "reported", "foo") == 2, payloads) # the response to our update
            # there should not be any other update because the bar update should not have been accepted

            @info "unsubscribing"
            fetch(unsubscribe(sf)[1])
            @info "done unsubscribing"
            fetch(unsubscribe(oobsc.shadow_client)[1])
        finally
            fetch(publish(sc, "/delete", "", AWS_MQTT_QOS_AT_LEAST_ONCE)[1])
        end
    end
end
