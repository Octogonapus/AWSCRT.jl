"""
    shadow_document_property_update_callback(value)

A callback invoked immediately after a property in the shadow document is updated.
The parent [`ShadowFramework`](@ref) will be locked when this callback is invoked. The lock is reentrant.

Arguments:

  - `value (Any)`: The value of the shadow property that was just set in the shadow document.
"""
const ShadowDocumentPropertyUpdateCallback = Function

"""
    shadow_document_pre_update_callback(state::Dict{String,Any})

A callback invoked before the shadow document is updated.
The parent [`ShadowFramework`](@ref) will not be locked when this callback is invoked.

Arguments:

  - `state (Dict{String,Any})`: The incoming shadow state. This could be reported state or delta state.
"""
const ShadowDocumentPreUpdateCallback = Function

"""
    shadow_document_post_update_callback(shadow_document::T)

A callback invoked after the shadow document is updated.
The parent [`ShadowFramework`](@ref) will not be locked when this callback is invoked.
This is a good place to persist the shadow document to disk.

Arguments:

  - `shadow_document (T)`: The updated shadow document.
"""
const ShadowDocumentPostUpdateCallback = Function

struct ShadowFramework{T}
    _id::Int
    _shadow_document_lock::ReentrantLock
    _shadow_client::Union{ShadowClient,Nothing} # set to nothing in unit tests
    _shadow_document::T
    _shadow_document_property_callbacks::Dict{String,ShadowDocumentPropertyUpdateCallback}
    _shadow_document_pre_update_callback::ShadowDocumentPreUpdateCallback
    _shadow_document_post_update_callback::ShadowDocumentPostUpdateCallback

    function ShadowFramework(
        id::Int,
        shadow_document_lock::ReentrantLock,
        shadow_client::Union{ShadowClient,Nothing},
        shadow_document::T,
        shadow_document_property_callbacks::Dict{String,ShadowDocumentPropertyUpdateCallback},
        shadow_document_pre_update_callback::ShadowDocumentPreUpdateCallback,
        shadow_document_post_update_callback::ShadowDocumentPostUpdateCallback,
    ) where {T}
        if T <: AbstractDict
            if !haskey(shadow_document, "version")
                shadow_document["version"] = 1
            end
        elseif !hasproperty(shadow_document, :version)
            error("The given shadow document type $T must have a property `version::Int` used for storing the \
                shadow document version.")
        elseif !ismutabletype(T)
            error("The given shadow document type $T must be mutable.")
        end

        return new{T}(
            id,
            shadow_document_lock,
            shadow_client,
            shadow_document,
            shadow_document_property_callbacks,
            shadow_document_pre_update_callback,
            shadow_document_post_update_callback,
        )
    end
end

"""
    ShadowFramework(
        connection::MQTTConnection,
        thing_name::String,
        shadow_name::Union{String,Nothing},
        shadow_document::T;
        shadow_document_property_callbacks::Dict{String,ShadowDocumentPropertyUpdateCallback} = Dict{
            String,
            ShadowDocumentPropertyUpdateCallback,
        }(),
        shadow_document_pre_update_callback::ShadowDocumentPreUpdateCallback = (v) -> nothing,
        shadow_document_post_update_callback::ShadowDocumentPostUpdateCallback = (v) -> nothing,
        id = 1,
    ) where {T}

Creates a `ShadowFramework`.

Arguments:

  - `connection (MQTTConnection)`: The connection.
  - `thing_name (String)`: Name of the Thing in AWS IoT under which the shadow document will exist.
  - `shadow_name (Union{String,Nothing})`: Shadow name for a named shadow document or `nothing` for an unnamed shadow document.
  - `shadow_document (T)`: The local shadow document. This can be an `AbstractDict` or a mutable struct.
    This must include keys/properties for all keys in the shadow documents published by the broker.
    If this type is not an AbstractDict and is missing a property in the desired shadow document state, an error will
    be logged and there will be a permanent difference between the reported and desired state, causing excessive communications.
    This must also include a `version (Int)` key/property which will store the shadow document version.
    It is recommended that you persist this to disk.
    You can write the latest state to disk inside `shadow_document_post_update_callback`.
    You should also then load it from disk and pass it as this parameter during the start of your application.
  - `shadow_document_property_callbacks (Dict{String,ShadowDocumentPropertyUpdateCallback})`: An optional set of callbacks. A given callback will be fired for each update to the shadow document property matching the given key. Note that the callback is fired only when shadow properties are changed. A shadow property change occurs when the value of the shadow property is changed to a new value which is not equal to the prior value. This is implemented using `!isequal()`. Please ensure a satisfactory definition (satifactory to your application's needs) of `isequal` for all types used in the shadow document. You will only need to worry about this if you are using custom JSON deserialization.
  - `shadow_document_pre_update_callback (ShadowDocumentPreUpdateCallback)`: An optional callback which will be fired immediately before updating any shadow document properties. This is always fired, even if no shadow properties will be changed.
  - `shadow_document_post_update_callback (ShadowDocumentPostUpdateCallback)`: An optional callback which will be fired immediately after updating any shadow document properties. This is fired only if shadow properties were changed.
  - `id (Int)`: A unique ID which disambiguates log messages from multiple shadow frameworks.

See also [`ShadowDocumentPropertyUpdateCallback`](@ref), [`ShadowDocumentPreUpdateCallback`](@ref), [`ShadowDocumentPostUpdateCallback`](@ref), [`MQTTConnection`](@ref).
"""
function ShadowFramework(
    connection::MQTTConnection,
    thing_name::String,
    shadow_name::Union{String,Nothing},
    shadow_document::T;
    shadow_document_property_callbacks::Dict{String,ShadowDocumentPropertyUpdateCallback} = Dict{
        String,
        ShadowDocumentPropertyUpdateCallback,
    }(),
    shadow_document_pre_update_callback::ShadowDocumentPreUpdateCallback = v -> nothing,
    shadow_document_post_update_callback::ShadowDocumentPostUpdateCallback = v -> nothing,
    id = 1,
) where {T}
    return ShadowFramework(
        id,
        ReentrantLock(),
        ShadowClient(connection, thing_name, shadow_name),
        shadow_document,
        shadow_document_property_callbacks,
        shadow_document_pre_update_callback,
        shadow_document_post_update_callback,
    )
end

"""
    lock(sf::ShadowFramework)

Locks the `sf` to ensure atomic access to the shadow document.
"""
lock(sf::ShadowFramework) = lock(sf._shadow_document_lock)

"""
    lock(f::Function, sf::ShadowFramework)

Locks the `sf` to ensure atomic access to the shadow document.
"""
lock(f::Function, sf::ShadowFramework) = lock(f, sf._shadow_document_lock)

"""
    unlock(sf::ShadowFramework)

Unlocks the `sf`.
"""
unlock(sf::ShadowFramework) = unlock(sf._shadow_document_lock)

"""
    shadow_client(sf::ShadowFramework)

Returns the [`ShadowClient`](@ref) for `sf`.
"""
shadow_client(sf::ShadowFramework) = sf._shadow_client

"""
    subscribe(sf::ShadowFramework{T}) where {T}

Subscribes to the shadow document's topics and begins processing updates.
The `sf` is always locked before reading/writing from/to the shadow document.
If the remote shadow document does not exist, the local shadow document will be used to create it.
Publishes and initial message to the `/get` topic to synchronize the shadow document with the broker's state.

Returns the return value of the call to [`publish`](@ref) used to publish the initial `/get`.
"""
function subscribe(sf::ShadowFramework{T}) where {T}
    callback = _create_sf_callback(sf)
    tasks_and_ids = subscribe(sf._shadow_client, AWS_MQTT_QOS_AT_LEAST_ONCE, callback)

    # Wait for the subscriptions to finish before publishing the initial /get so that we are guaranteed to be able
    # to receive the reply
    for (task, id) in tasks_and_ids
        task_result = fetch(task)
        @debug "SF-$(sf._id): connect" id task_result
    end

    # Publish an initial get to synchronize the local document
    @debug "SF-$(sf._id): publishing initial shadow /get"
    return publish(sf._shadow_client, "/get", "", AWS_MQTT_QOS_AT_LEAST_ONCE)
end

"""
    unsubscribe(sf::ShadowFramework{T}) where {T}

Unsubscribes from the shadow document's topics and stops processing updates.

Returns the return value from the call to [`unsubscribe`](@ref).
"""
unsubscribe(sf::ShadowFramework{T}) where {T} = unsubscribe(sf._shadow_client)

"""
Publishes the current state of the shadow document.

Arguments:
- `include_version (Bool)`: Includes the version of the shadow document if this is `true`. You may want to exclude the version if you don't know what the broker's version is.

$publish_return_docs
"""
function publish_current_state(sf::ShadowFramework{T}; include_version::Bool = true) where {T}
    current_state = _create_reported_state_payload(sf; include_version)
    @debug "SF-$(sf._id): publishing shadow update" current_state
    return publish(sf._shadow_client, "/update", current_state, AWS_MQTT_QOS_AT_LEAST_ONCE)
end

function _create_sf_callback(sf::ShadowFramework{T}) where {T}
    return function shadow_callback(
        shadow_client::ShadowClient,
        topic::String,
        payload::String,
        dup::Bool,
        qos::aws_mqtt_qos,
        retain::Bool,
    )
        @debug "SF-$(sf._id): received shadow message" topic payload dup qos retain
        if endswith(topic, "/get/accepted")
            # process any delta state from when we last reported our current state. if something changed, report our
            # current state again. there's a chance the delta state is permanent due to the user's configuration
            # (isequals implementation, struct definition, etc.). we need to avoid endless communications.
            updated = _update_local_shadow_from_get!(sf, payload)
            if updated
                current_state = _create_reported_state_payload(sf)
                @debug "SF-$(sf._id): publishing shadow update" current_state
                task, id = publish(shadow_client, "/update", current_state, AWS_MQTT_QOS_AT_LEAST_ONCE)
                task_result = fetch(task)
                @debug id task_result
            end
        elseif endswith(topic, "/get/rejected")
            # there is no shadow document, so we need to publish the first version. do not include a version number
            # because we have no idea what the version is. AWS IoT remembers the version number even after you delete
            # the shadow document. when we publish an initial /update without a version number, it's guaranteed to pass
            # the version check and if it's accepted, we will get an /update/accepted containing the new version number.
            task, id = publish_current_state(sf; include_version = false)
            task_result = fetch(task)
            @debug id task_result
        elseif endswith(topic, "/update/delta")
            # there was an update published that doesn't match our reported state, so update our state to match
            # and publish our new state
            updated = _update_local_shadow_from_delta!(sf, payload)
            # we still need to check updated here, because there's a chance the delta state is permanent due to the
            # user's configuration (isequals implementation, struct definition, etc.). we need to avoid endless communications.
            if updated
                current_state = _create_reported_state_payload(sf)
                @debug "SF-$(sf._id): publishing shadow update" current_state
                task, id = publish(shadow_client, "/update", current_state, AWS_MQTT_QOS_AT_LEAST_ONCE)
                task_result = fetch(task)
                @debug id task_result
            end
        elseif endswith(topic, "/update/accepted")
            # our update was accepted, which means the broker incremented the version number. we need to use the new
            # version number before publishing a new update or it will be rejected. sync to pull in the new version number
            _sync_version!(sf._shadow_document, payload)
        end
    end
end

"""
    _update_local_shadow_from_get!(sf::ShadowFramework{T}, payload_str::String) where {T}

Performs a local shadow update using the delta state from a /get/accepted document.
Returns `true` if the local shadow was updated.
"""
function _update_local_shadow_from_get!(sf::ShadowFramework{T}, payload_str::String) where {T}
    payload = JSON.parse(payload_str)
    version = get(payload, "version", nothing)
    if _version_allows_update(sf._shadow_document, version)
        _set_version!(sf._shadow_document, version)
        state = get(payload, "state", nothing)
        if state !== nothing
            delta = get(state, "delta", nothing)
            if delta !== nothing
                @debug "updating shadow"
                return _do_local_shadow_update!(sf, delta)
            end
        end
    else
        @debug "SF-$(sf._id): not processing shadow delta because its version ($version) is less than the current version ($(_version(sf._shadow_document)))"
    end
    return false
end

"""
    _update_local_shadow_from_delta!(sf::ShadowFramework{T}, payload_str::String) where {T}

Performs a local shadow update using the delta state from an /update/delta document.
Returns `true` if the local shadow was updated.
"""
function _update_local_shadow_from_delta!(sf::ShadowFramework{T}, payload_str::String) where {T}
    payload = JSON.parse(payload_str)
    version = get(payload, "version", nothing)
    if _version_allows_update(sf._shadow_document, version)
        _set_version!(sf._shadow_document, version)
        state = get(payload, "state", nothing)
        if state !== nothing
            return _do_local_shadow_update!(sf, state)
        end
    else
        @debug "SF-$(sf._id): not processing shadow delta because its version ($version) is less than the current version ($(_version(sf._shadow_document)))"
    end
    return false
end

"""
    _do_local_shadow_update!(sf::ShadowFramework{T}, state::Dict{String,<:Any}) where {T}

 1. Fires the pre-update callback
 2. Updates each shadow property from `state` and fires its callback if an update occured
 3. Fires the post-update callback
 4. Returns `true` if any updated occured.
"""
function _do_local_shadow_update!(sf::ShadowFramework{T}, state::Dict{String,<:Any}) where {T}
    _fire_pre_update_callback(sf, state)
    any_updates = false
    lock(sf) do
        for (k, v) in state
            updated = _update_shadow_property!(sf, k, v)
            if updated
                _fire_callback(sf, k, v)
                any_updates = true
            end
        end
    end
    _fire_post_update_callback(sf)
    return any_updates
end

function _fire_pre_update_callback(sf::ShadowFramework{T}, state::Dict{String,<:Any}) where {T}
    try
        sf._shadow_document_pre_update_callback(state)
    catch ex
        @error "SF-$(sf._id): failed to run shadow document pre-update callback" exception = (ex, catch_backtrace())
    end
    return nothing
end

function _fire_post_update_callback(sf::ShadowFramework{T}) where {T}
    try
        sf._shadow_document_post_update_callback(sf._shadow_document)
    catch ex
        @error "SF-$(sf._id): failed to run shadow document pre-update callback" exception = (ex, catch_backtrace())
    end
    return nothing
end

function _fire_callback(sf::ShadowFramework{T}, key::String, value) where {T}
    if haskey(sf._shadow_document_property_callbacks, key)
        callback = sf._shadow_document_property_callbacks[key]
        try
            callback(value)
        catch ex
            @error "SF-$(sf._id): failed to run shadow document property callback for property $key" exception =
                (ex, catch_backtrace())
        end
    end
    return nothing
end

function _create_reported_state_payload(sf::ShadowFramework{T}; include_version = true) where {T}
    lock(sf) do
        d = Dict()
        d["state"] = Dict("reported" => Dict(_get_shadow_property_pairs(sf._shadow_document)))
        if include_version
            d["version"] = _version(sf._shadow_document)
        end
        return json(d)
    end
end

_get_shadow_property_pairs(doc::AbstractDict) = filter(it -> it[1] != "version", collect(doc))

function _get_shadow_property_pairs(doc::T) where {T}
    names = fieldnames(T)
    out = Vector{Pair{String,Any}}(undef, length(names) - 1)
    for i in eachindex(names)
        fieldname = names[i]
        if fieldname != :version
            out[i] = String(fieldname) => getfield(doc, fieldname)
        end
    end
    return out
end

"""
    _update_shadow_property!(sf::ShadowFramework{<:AbstractDict}, key::String, value)

Updates the shadow property if the new `value` is not equal to the current value at the `key`.
Returns `true` if an update occured.
"""
function _update_shadow_property!(sf::ShadowFramework{<:AbstractDict}, key::String, value)
    if haskey(sf._shadow_document, key)
        if !isequal(sf._shadow_document[key], value)
            sf._shadow_document[key] = value
            return true
        end
    else
        sf._shadow_document[key] = value
        return true
    end
    return false
end

"""
    _update_shadow_property!(sf::ShadowFramework{<:Any}, key::String, value)

Updates the shadow property if the new `value` is not equal to the current value at the `key`.
Returns `true` if an update occured.
"""
function _update_shadow_property!(sf::ShadowFramework{<:Any}, key::String, value)
    try
        sym = Symbol(key)
        v = getproperty(sf._shadow_document, sym)
        if !isequal(v, value)
            setproperty!(sf._shadow_document, sym, value)
            return true
        end
    catch ex
        @error "SF-$(sf._id): failed to update shadow property key=$key value=$value (you probably need to extend \
            your struct type with an additional property for this key)" exception = (ex, catch_backtrace())
    end
    return false
end

"""
    _sync_version!(doc::T, payload_str::String) where {T}

Updates the local shadow's version number using the version in the `payload`.
"""
function _sync_version!(doc::T, payload_str::String) where {T}
    payload = JSON.parse(payload_str)
    version = get(payload, "version", nothing)
    if _version_allows_update(doc, version)
        _set_version!(doc, version)
    end
    return nothing
end

_version_allows_update(doc::T, version::Int) where {T} = version >= _version(doc)
_version_allows_update(doc::T, version::Nothing) where {T} = false

_version(doc::AbstractDict) = doc["version"]
_version(doc) = doc.version

_set_version!(doc::AbstractDict, version::Int) = doc["version"] = version
_set_version!(doc, version::Int) = doc.version = version
