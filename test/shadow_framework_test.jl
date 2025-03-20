EXAMPLE_SD_1_DICT = Dict("foo" => 1, "bar" => "a", "version" => 2)
EXAMPLE_UPDATE_1_STATE = Dict("foo" => 23849, "bar" => "dmwofsh")

function empty_shadow_framework(
    shadow_document;
    shadow_document_property_callbacks = Dict{String,Function}(),
    shadow_document_pre_update_callback = (v) -> nothing,
    shadow_document_post_update_callback = (v) -> nothing,
    shadow_document_property_pre_update_funcs = Dict{String,Function}(),
)
    return ShadowFramework(
        1,
        ReentrantLock(),
        nothing,
        shadow_document,
        shadow_document_property_callbacks,
        shadow_document_pre_update_callback,
        shadow_document_post_update_callback,
        shadow_document_property_pre_update_funcs,
    )
end

function are_shadow_states_equal_without_version(a, b)
    ap = sort_pairs(filter(it -> it[1] != "version", AWSCRT._get_shadow_property_pairs(a)))
    bp = sort_pairs(filter(it -> it[1] != "version", AWSCRT._get_shadow_property_pairs(b)))
    return ap == bp
end

@testset "create ShadowFramework with dict without version number" begin
    d = Dict()
    empty_shadow_framework(d)
    @test d["version"] == 1
end

@testset "_sync_version!" begin
    d = Dict("version" => 1)
    AWSCRT._sync_version!(d, json(Dict("version" => 0)))
    @test d["version"] == 1
    AWSCRT._sync_version!(d, json(Dict("version" => 1)))
    @test d["version"] == 1
    AWSCRT._sync_version!(d, json(Dict("version" => 2)))
    @test d["version"] == 2

    d = Dict("version" => 1)
    AWSCRT._sync_version!(d, json(Dict("version" => 3)))
    @test d["version"] == 3
end

@testset "_version_allows_update" begin
    d = Dict("version" => 1)
    @test !AWSCRT._version_allows_update(d, 0)
    @test AWSCRT._version_allows_update(d, 1)
    @test AWSCRT._version_allows_update(d, 2)
end

@testset "_update_shadow_property!" begin
    d = Dict()
    sf = empty_shadow_framework(d)
    @test AWSCRT._update_shadow_property!(sf, d, "foo", 1)
    @test !AWSCRT._update_shadow_property!(sf, d, "foo", 1) # no update now that it's set
    @test AWSCRT._update_shadow_property!(sf, d, "bar", "a")
    @test AWSCRT._update_shadow_property!(sf, d, "baz", "b") # new properties can be introduced
    @test d == Dict("foo" => 1, "bar" => "a", "baz" => "b", "version" => 1)
end

@testset "_get_shadow_property_pairs" begin
    doc = EXAMPLE_SD_1_DICT
    expected = ["foo" => 1, "bar" => "a"]
    @test sort_pairs(expected) == sort_pairs(AWSCRT._get_shadow_property_pairs(doc))
end

@testset "_create_reported_state_payload" begin
    doc = EXAMPLE_SD_1_DICT
    sf = empty_shadow_framework(doc)
    expected = Dict("state" => Dict("reported" => Dict("foo" => 1, "bar" => "a")), "version" => 2)
    @test json(expected) == AWSCRT._create_reported_state_payload(sf)

    expected = Dict("state" => Dict("reported" => Dict("foo" => 1, "bar" => "a")))
    @test json(expected) == AWSCRT._create_reported_state_payload(sf; include_version = false)
end

@testset "_fire_callback (happy path)" begin
    doc = EXAMPLE_SD_1_DICT
    values = []
    sf = empty_shadow_framework(
        deepcopy(doc);
        shadow_document_property_callbacks = Dict("foo" => x -> push!(values, x), "baz" => x -> push!(values, x)),
    )
    AWSCRT._fire_callback(sf, "foo", 0)
    @test values == [0]
end

@testset "_fire_callback (callback throws)" begin
    doc = EXAMPLE_SD_1_DICT
    values = []
    sf = empty_shadow_framework(
        doc;
        shadow_document_property_callbacks = Dict{String,Function}("foo" => x -> error("Boom!")),
    )
    @test_logs (:error,) AWSCRT._fire_callback(sf, "foo", 0)
    @test isempty(values)
end

@testset "_fire_callback (no matching callback)" begin
    doc = EXAMPLE_SD_1_DICT
    values = []
    sf = empty_shadow_framework(
        doc;
        shadow_document_property_callbacks = Dict{String,Function}("foo" => x -> push!(values, x)),
    )
    AWSCRT._fire_callback(sf, "bar", 0)
    @test isempty(values)
end

@testset "_fire_callback (no callbacks)" begin
    doc = EXAMPLE_SD_1_DICT
    sf = empty_shadow_framework(doc)
    AWSCRT._fire_callback(sf, "bar", 0)
end

@testset "_do_local_shadow_update!" begin
    doc = EXAMPLE_SD_1_DICT
    values = []
    doc_copy = deepcopy(doc)
    sf = empty_shadow_framework(
        doc_copy;
        shadow_document_pre_update_callback = x -> begin
            push!(values, x)
            error("Boom!")
        end,
        shadow_document_post_update_callback = x -> begin
            push!(values, x)
            error("Boom!")
        end,
        shadow_document_property_callbacks = Dict{String,Function}("bar" => x -> push!(values, x)),
    )
    state = Dict("foo" => 5, "bar" => "asd", "baz" => 9)
    @test @test_logs (:error,) match_mode = :any AWSCRT._do_local_shadow_update!(sf, state)
    if doc_copy isa AbstractDict
        @test doc_copy["foo"] == 5
        @test doc_copy["bar"] == "asd"
        @test doc_copy["baz"] == 9
    else
        @test doc_copy.foo == 5
        @test doc_copy.bar == "asd"
        # baz will not be set because it does not exist in the example shadow struct
    end
    @test values == [state, "asd", doc_copy]

    @test @test_logs (:error,) match_mode = :any !AWSCRT._do_local_shadow_update!(sf, state) # no update the second time
end

@testset "use pre-update function instead of default behavior" begin
    @testset "regular update" begin
        doc = Dict("a" => 1)
        sf = empty_shadow_framework(
            doc,
            shadow_document_property_pre_update_funcs = Dict("a" => (doc, key, value) -> begin
                    if key != "a"
                        error("bad key $key")
                    end
                    doc[key] = 3
                    return true
                end),
        )
        @test AWSCRT._do_local_shadow_update!(sf, Dict("a" => 2))
        @test doc == Dict("a" => 3, "version" => 1)
    end

    @testset "no update" begin
        doc = Dict("a" => 1)
        sf = empty_shadow_framework(
            doc,
            shadow_document_property_pre_update_funcs = Dict("a" => (doc, key, value) -> begin
                    if key != "a"
                        error("bad key $key")
                    end
                    doc[key] = 3
                    return false
                end),
        )
        @test !AWSCRT._do_local_shadow_update!(sf, Dict("a" => 2))
        @test doc == Dict("a" => 3, "version" => 1)
    end

    @testset "nested key" begin
        doc = Dict{String,Any}("a" => Dict("b" => 1, "c" => 1))
        sf = empty_shadow_framework(
            doc,
            shadow_document_property_pre_update_funcs = Dict("b" => (doc, key, value) -> begin
                    if key != "b"
                        error("bad key $key")
                    end
                    doc[key] = 3
                    return true
                end),
        )
        @test AWSCRT._do_local_shadow_update!(sf, Dict("a" => Dict("b" => 2)))
        @test doc == Dict("a" => Dict("b" => 3, "c" => 1), "version" => 1)
    end
end

@testset "_update_local_shadow_from_get!" begin
    doc = EXAMPLE_SD_1_DICT
    doc_copy = deepcopy(doc)
    sf = empty_shadow_framework(doc_copy)
    @test AWSCRT._update_local_shadow_from_get!(
        sf,
        json(Dict("state" => Dict("delta" => Dict("foo" => 2)), "version" => 3)),
    )
    @test are_shadow_states_equal_without_version(doc_copy, Dict("foo" => 2, "bar" => "a"))
end

@testset "_update_local_shadow_from_get! ignores an old version in the reported state" begin
    doc = EXAMPLE_SD_1_DICT
    doc_copy = deepcopy(doc)
    sf = empty_shadow_framework(doc_copy)
    @test AWSCRT._update_local_shadow_from_get!(
        sf,
        json(Dict("state" => Dict("delta" => Dict("foo" => 2), "reported" => Dict("version" => 1)), "version" => 3)),
    )
    @test are_shadow_states_equal_without_version(doc_copy, Dict("foo" => 2, "bar" => "a"))
    @test doc_copy["version"] == 3
end

@testset "_update_local_shadow_from_delta!" begin
    doc = EXAMPLE_SD_1_DICT
    doc_copy = deepcopy(doc)
    sf = empty_shadow_framework(doc_copy)
    @test AWSCRT._update_local_shadow_from_delta!(
        sf,
        json(Dict("state" => Dict("foo" => 2, "version" => 1), "version" => 3)),
    )
    @test are_shadow_states_equal_without_version(doc_copy, Dict("foo" => 2, "bar" => "a"))
    @test doc_copy["version"] == 3
end

@testset "out of order messages, version is respected" for update_type in [:get_accepted, :delta]
    doc = EXAMPLE_SD_1_DICT

    update_func = if update_type == :get_accepted
        AWSCRT._update_local_shadow_from_get!
    else
        AWSCRT._update_local_shadow_from_delta!
    end

    function get_payload_str(state, version)
        wrapped = if update_type == :get_accepted
            Dict{String,Any}("state" => Dict{String,Any}("delta" => state))
        else
            Dict{String,Any}("state" => state)
        end
        if version !== nothing
            wrapped["version"] = version
        end
        return json(wrapped)
    end

    @testset "state update with higher version number is accepted" begin
        doc_copy = deepcopy(doc)
        sf = empty_shadow_framework(doc_copy)
        state = EXAMPLE_UPDATE_1_STATE
        @test update_func(sf, get_payload_str(state, 1234))
        @test are_shadow_states_equal_without_version(doc_copy, state)
    end

    @testset "state update with equal version number is accepted" begin
        doc_copy = deepcopy(doc)
        sf = empty_shadow_framework(doc_copy)
        state = EXAMPLE_UPDATE_1_STATE
        @test update_func(sf, get_payload_str(state, AWSCRT._version(doc_copy)))
        @test are_shadow_states_equal_without_version(doc_copy, state)
    end

    @testset "state update with lower version number is rejected" begin
        doc_copy = deepcopy(doc)
        sf = empty_shadow_framework(doc_copy)
        state = EXAMPLE_UPDATE_1_STATE
        @test !update_func(sf, get_payload_str(state, AWSCRT._version(doc_copy) - 1))
        @test !are_shadow_states_equal_without_version(doc_copy, state)
    end

    @testset "state update with no version key is rejected" begin
        doc_copy = deepcopy(doc)
        sf = empty_shadow_framework(doc_copy)
        state = EXAMPLE_UPDATE_1_STATE
        @test !update_func(sf, get_payload_str(state, nothing))
        @test !are_shadow_states_equal_without_version(doc_copy, state)
    end

    @testset "state update with no state key is rejected" begin
        doc_copy = deepcopy(doc)
        sf = empty_shadow_framework(doc_copy)
        state = EXAMPLE_UPDATE_1_STATE
        @test !update_func(sf, json(state))
        @test !are_shadow_states_equal_without_version(doc_copy, state)
    end

    if update_type == :get_accepted
        @testset "state update with no reported key is rejected" begin
            doc_copy = deepcopy(doc)
            sf = empty_shadow_framework(doc_copy)
            state = EXAMPLE_UPDATE_1_STATE
            @test !update_func(sf, json(Dict("state" => state)))
            @test !are_shadow_states_equal_without_version(doc_copy, state)
        end
    end
end

@testset "lock and unlock" begin
    sf = empty_shadow_framework(Dict())
    lock(sf)
    lock(sf) # must be reentrant
    @test true
    unlock(sf)
    lock(sf) do
        lock(sf) # must be reentrant
        @test true
    end
end
