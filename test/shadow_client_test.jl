@testset "unnamed shadow document" begin
    connection = new_mqtt_connection()
    shadow = ShadowClient(connection, thing1_name, nothing)

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

    try
        tasks_and_ids = subscribe(shadow, AWS_MQTT_QOS_AT_LEAST_ONCE, shadow_callback)
        for (task, id) in tasks_and_ids
            fetch(task)
        end

        fetch(publish(shadow, "/get", "", AWS_MQTT_QOS_AT_LEAST_ONCE)[1])
        wait_for(() -> !isempty(msgs))
        @test msgs[1][:shadow_client] === shadow
        @test msgs[1][:topic] == "\$aws/things/$thing1_name/shadow/get/rejected"
        @test msgs[1][:payload] == "{\"code\":404,\"message\":\"No shadow exists with name: '$thing1_name'\"}"
        empty!(msgs)

        fetch(
            publish(
                shadow,
                "/update",
                json(Dict("state" => Dict("reported" => Dict("foo" => 1)))),
                AWS_MQTT_QOS_AT_LEAST_ONCE,
            )[1],
        )
        wait_for(() -> length(msgs) >= 2)
        @test findfirst(it -> it[:topic] == "\$aws/things/$thing1_name/shadow/update/accepted", msgs) !== nothing
        @test findfirst(it -> it[:topic] == "\$aws/things/$thing1_name/shadow/update/documents", msgs) !== nothing
        empty!(msgs)

        fetch(
            publish(
                shadow,
                "/update",
                json(Dict("state" => Dict("desired" => Dict("foo" => 2)))),
                AWS_MQTT_QOS_AT_LEAST_ONCE,
            )[1],
        )
        wait_for(() -> length(msgs) >= 3)
        @test findfirst(it -> it[:topic] == "\$aws/things/$thing1_name/shadow/update/accepted", msgs) !== nothing
        @test findfirst(it -> it[:topic] == "\$aws/things/$thing1_name/shadow/update/documents", msgs) !== nothing
        let msg = msgs[findfirst(it -> it[:topic] == "\$aws/things/$thing1_name/shadow/update/delta", msgs)]
            payload = JSON.parse(msg[:payload])
            @test payload["state"]["foo"] == 2
        end
        empty!(msgs)

        fetch(
            publish(
                shadow,
                "/update",
                json(Dict("state" => Dict("reported" => Dict("foo" => 2)))),
                AWS_MQTT_QOS_AT_LEAST_ONCE,
            )[1],
        )
        wait_for(() -> length(msgs) >= 2)
        @test findfirst(it -> it[:topic] == "\$aws/things/$thing1_name/shadow/update/accepted", msgs) !== nothing
        @test findfirst(it -> it[:topic] == "\$aws/things/$thing1_name/shadow/update/documents", msgs) !== nothing
        @test findfirst(it -> it[:topic] == "\$aws/things/$thing1_name/shadow/update/delta", msgs) === nothing
        empty!(msgs)

        fetch(
            publish(
                shadow,
                "/update",
                json(Dict("state" => Dict("desired" => Dict("foo" => nothing)))),
                AWS_MQTT_QOS_AT_LEAST_ONCE,
            )[1],
        )
        wait_for(() -> length(msgs) >= 2)
        @test findfirst(it -> it[:topic] == "\$aws/things/$thing1_name/shadow/update/accepted", msgs) !== nothing
        let msg = msgs[findfirst(it -> it[:topic] == "\$aws/things/$thing1_name/shadow/update/documents", msgs)]
            payload = JSON.parse(msg[:payload])
            @test !haskey(payload["current"]["state"], "desired")
            @test haskey(payload["current"]["state"], "reported")
        end
        empty!(msgs)

        fetch(publish(shadow, "/delete", "", AWS_MQTT_QOS_AT_LEAST_ONCE)[1])
        wait_for(() -> length(msgs) >= 1)
        @test findfirst(it -> it[:topic] == "\$aws/things/$thing1_name/shadow/delete/accepted", msgs) !== nothing
        empty!(msgs)

        fetch(unsubscribe(shadow)[1])
    finally
        fetch(publish(shadow, "/delete", "", AWS_MQTT_QOS_AT_LEAST_ONCE)[1])
    end
end
