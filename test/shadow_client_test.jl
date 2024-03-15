@testset "unnamed shadow document" begin
    if parallel
        return
    end
    lock_test_unnamed_shadow(THING1_NAME) # only one test can use the unnamed shadow at a time
    try
        connection = new_mqtt_connection()
        shadow = ShadowClient(connection, THING1_NAME, nothing)

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
            fetch(subscribe(shadow, AWS_MQTT_QOS_AT_LEAST_ONCE, shadow_callback)[1])
            fetch(publish(shadow, "/get", "", AWS_MQTT_QOS_AT_LEAST_ONCE)[1])
            wait_for(() -> !isempty(msgs))
            @test msgs[1][:shadow_client] === shadow
            @test msgs[1][:topic] == "\$aws/things/$THING1_NAME/shadow/get/rejected"
            @test msgs[1][:payload] == "{\"code\":404,\"message\":\"No shadow exists with name: '$THING1_NAME'\"}"
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
            @test findfirst(it -> it[:topic] == "\$aws/things/$THING1_NAME/shadow/update/accepted", msgs) !== nothing
            @test findfirst(it -> it[:topic] == "\$aws/things/$THING1_NAME/shadow/update/documents", msgs) !== nothing
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
            @test findfirst(it -> it[:topic] == "\$aws/things/$THING1_NAME/shadow/update/accepted", msgs) !== nothing
            @test findfirst(it -> it[:topic] == "\$aws/things/$THING1_NAME/shadow/update/documents", msgs) !== nothing
            let msg = msgs[findfirst(it -> it[:topic] == "\$aws/things/$THING1_NAME/shadow/update/delta", msgs)]
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
            @test findfirst(it -> it[:topic] == "\$aws/things/$THING1_NAME/shadow/update/accepted", msgs) !== nothing
            @test findfirst(it -> it[:topic] == "\$aws/things/$THING1_NAME/shadow/update/documents", msgs) !== nothing
            @test findfirst(it -> it[:topic] == "\$aws/things/$THING1_NAME/shadow/update/delta", msgs) === nothing
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
            @test findfirst(it -> it[:topic] == "\$aws/things/$THING1_NAME/shadow/update/accepted", msgs) !== nothing
            let msg = msgs[findfirst(it -> it[:topic] == "\$aws/things/$THING1_NAME/shadow/update/documents", msgs)]
                payload = JSON.parse(msg[:payload])
                @test !haskey(payload["current"]["state"], "desired")
                @test haskey(payload["current"]["state"], "reported")
            end
            empty!(msgs)

            fetch(publish(shadow, "/delete", "", AWS_MQTT_QOS_AT_LEAST_ONCE)[1])
            wait_for(() -> length(msgs) >= 1)
            @test findfirst(it -> it[:topic] == "\$aws/things/$THING1_NAME/shadow/delete/accepted", msgs) !== nothing
            empty!(msgs)

            fetch(unsubscribe(shadow)[1])
        finally
            fetch(publish(shadow, "/delete", "", AWS_MQTT_QOS_AT_LEAST_ONCE)[1])
        end
    finally
        unlock_test_unnamed_shadow(THING1_NAME)
    end
end
