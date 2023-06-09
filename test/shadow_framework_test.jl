mutable struct ExampleShadowDocument <: Comparable
    foo::Int
    bar::String
    version::Int
end

mutable struct BadShadowDocWithoutVersion
    foo::Int
    bar::String
end

struct ImmutableShadowDocWithVersion
    version::Int
end

const EXAMPLE_SD_1_DICT = Dict("foo" => 1, "bar" => "a", "version" => 2)
const EXAMPLE_SD_1_STRUCT = ExampleShadowDocument(1, "a", 2)
const ALL_EXAMPLE_SD_1 = [EXAMPLE_SD_1_DICT, EXAMPLE_SD_1_STRUCT]
const EXAMPLE_UPDATE_1_STATE = Dict("foo" => 23849, "bar" => "dmwofsh")

function empty_shadow_framework(
    shadow_document;
    shadow_document_property_callbacks = Dict{String,Function}(),
    shadow_document_pre_update_callback = (v) -> nothing,
    shadow_document_post_update_callback = (v) -> nothing,
)
    return ShadowFramework(
        1,
        ReentrantLock(),
        nothing,
        shadow_document,
        shadow_document_property_callbacks,
        shadow_document_pre_update_callback,
        shadow_document_post_update_callback,
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

@testset "create ShadowFramework with struct without version number" begin
    @test_throws ErrorException empty_shadow_framework(BadShadowDocWithoutVersion(1, ""))
end

@testset "create ShadowFramework with immutable struct" begin
    @test_throws ErrorException empty_shadow_framework(ImmutableShadowDocWithVersion(1))
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

    doc = ExampleShadowDocument(0, "", 1)
    @test !AWSCRT._version_allows_update(doc, 0)
    @test AWSCRT._version_allows_update(doc, 1)
    @test AWSCRT._version_allows_update(doc, 2)
end

@testset "_update_shadow_property!" begin
    d = Dict()
    sf = empty_shadow_framework(d)
    @test AWSCRT._update_shadow_property!(sf, "foo", 1)
    @test !AWSCRT._update_shadow_property!(sf, "foo", 1) # no update now that it's set
    @test AWSCRT._update_shadow_property!(sf, "bar", "a")
    @test AWSCRT._update_shadow_property!(sf, "baz", "b") # new properties can be introduced
    @test d == Dict("foo" => 1, "bar" => "a", "baz" => "b", "version" => 1)

    doc = ExampleShadowDocument(0, "", 1)
    sf = empty_shadow_framework(doc)
    @test AWSCRT._update_shadow_property!(sf, "foo", 1)
    @test !AWSCRT._update_shadow_property!(sf, "foo", 1) # no update now that it's set
    @test AWSCRT._update_shadow_property!(sf, "bar", "a")
    @test @test_logs (:error,) !AWSCRT._update_shadow_property!(sf, "baz", "b") # new properties fail with structs. returns false because there is no update
    @test doc == ExampleShadowDocument(1, "a", 1)
end

@testset "_get_shadow_property_pairs" for doc in ALL_EXAMPLE_SD_1
    expected = ["foo" => 1, "bar" => "a"]
    @test sort_pairs(expected) == sort_pairs(AWSCRT._get_shadow_property_pairs(doc))
end

@testset "_create_reported_state_payload" for doc in ALL_EXAMPLE_SD_1
    sf = empty_shadow_framework(doc)
    expected = Dict("state" => Dict("reported" => Dict("foo" => 1, "bar" => "a")), "version" => 2)
    @test json(expected) == AWSCRT._create_reported_state_payload(sf)

    expected = Dict("state" => Dict("reported" => Dict("foo" => 1, "bar" => "a")))
    @test json(expected) == AWSCRT._create_reported_state_payload(sf; include_version = false)
end

@testset "_fire_callback (happy path)" for doc in ALL_EXAMPLE_SD_1
    values = []
    sf = empty_shadow_framework(
        deepcopy(doc);
        shadow_document_property_callbacks = Dict("foo" => x -> push!(values, x), "baz" => x -> push!(values, x)),
    )
    AWSCRT._fire_callback(sf, "foo", 0)
    @test values == [0]
end

@testset "_fire_callback (callback throws)" for doc in ALL_EXAMPLE_SD_1
    values = []
    sf = empty_shadow_framework(
        doc;
        shadow_document_property_callbacks = Dict{String,Function}("foo" => x -> error("Boom!")),
    )
    @test_logs (:error,) AWSCRT._fire_callback(sf, "foo", 0)
    @test isempty(values)
end

@testset "_fire_callback (no matching callback)" for doc in ALL_EXAMPLE_SD_1
    values = []
    sf = empty_shadow_framework(
        doc;
        shadow_document_property_callbacks = Dict{String,Function}("foo" => x -> push!(values, x)),
    )
    AWSCRT._fire_callback(sf, "bar", 0)
    @test isempty(values)
end

@testset "_fire_callback (no callbacks)" for doc in ALL_EXAMPLE_SD_1
    sf = empty_shadow_framework(doc)
    AWSCRT._fire_callback(sf, "bar", 0)
end

@testset "_do_local_shadow_update!" for doc in ALL_EXAMPLE_SD_1
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

@testset "out of order messages, version is respected" for doc in ALL_EXAMPLE_SD_1,
    update_type in [:get_accepted, :delta]

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
