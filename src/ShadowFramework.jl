"""
    shadow_document_property_pre_update_function(shadow_document::AbstractDict, key::String, value)::Bool

A function invoked when updating a property in the shadow document.
This allows you to replace the update behavior in this package if you want to implement custom update behavior for
a given property.
The parent [`ShadowFramework`](@ref) will be locked when this function is invoked. The lock is reentrant.

    !!! warning "Warning"
        This function may only update the given `key`. This function cannot modify other properties in the `shadow_document`.

Arguments:

  - `shadow_document (AbstractDict)`: The shadow document being updated.
  - `key (String)`: The key in the `shadow_document` for the value being updated.
  - `value (Any)`: The new value for the `key`.

Returns a `Bool` indicating whether an update was done.
"""
const ShadowDocumentPropertyPreUpdateFunction = Function

"""
    shadow_document_property_update_callback(value)

A callback invoked immediately after a property in the shadow document is updated.
The parent [`ShadowFramework`](@ref) will be locked when this callback is invoked. The lock is reentrant.

Arguments:

  - `value (Any)`: The new value of the property in the shadow document.
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
    shadow_document_post_update_callback(shadow_document::AbstractDict)

A callback invoked after the shadow document is updated.
The parent [`ShadowFramework`](@ref) will not be locked when this callback is invoked.
This is a good place to persist the shadow document to disk.

Arguments:

  - `shadow_document (AbstractDict)`: The updated shadow document.
"""
const ShadowDocumentPostUpdateCallback = Function

mutable struct ShadowFramework
    const _id::Int
    const _shadow_document_lock::ReentrantLock
    const _shadow_client::Union{ShadowClient,Nothing} # set to nothing in unit tests
    const _shadow_document::AbstractDict
    const _shadow_document_property_callbacks::Dict{String,ShadowDocumentPropertyUpdateCallback}
    const _shadow_document_pre_update_callback::ShadowDocumentPreUpdateCallback
    const _shadow_document_post_update_callback::ShadowDocumentPostUpdateCallback
    const _shadow_document_property_pre_update_funcs::Dict{String,ShadowDocumentPropertyPreUpdateFunction}
    _sync_latch::CountDownLatch

    function ShadowFramework(
        id::Int,
        shadow_document_lock::ReentrantLock,
        shadow_client::Union{ShadowClient,Nothing},
        shadow_document::AbstractDict,
        shadow_document_property_callbacks::Dict{String,<:ShadowDocumentPropertyUpdateCallback},
        shadow_document_pre_update_callback::ShadowDocumentPreUpdateCallback,
        shadow_document_post_update_callback::ShadowDocumentPostUpdateCallback,
        shadow_document_property_pre_update_funcs::Dict{String,<:ShadowDocumentPropertyPreUpdateFunction},
    )
        if !haskey(shadow_document, "version")
            shadow_document["version"] = 1
        end

        return new(
            id,
            shadow_document_lock,
            shadow_client,
            shadow_document,
            shadow_document_property_callbacks,
            shadow_document_pre_update_callback,
            shadow_document_post_update_callback,
            shadow_document_property_pre_update_funcs,
            CountDownLatch(1),
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
  - `shadow_document (AbstractDict)`: The local shadow document. This must include all keys in the
    shadow documents published by the broker. This must also include a `version (Int)` key which will store the
    shadow document version. It is recommended that you persist this to disk. You can write the latest state to
    disk inside `shadow_document_post_update_callback`. You should also then load it from disk and pass it as
    this parameter during the start of your application.
  - `shadow_document_property_callbacks (Dict{String,ShadowDocumentPropertyUpdateCallback})`: An optional set of
    callbacks. A given callback will be fired for each update to the shadow document property matching the given key.
    Note that the callback is fired only when shadow properties are changed.
    A shadow property change occurs when the value of the shadow property is changed to a new value which is not
    equal to the prior value.
    This is implemented using `!isequal()`.
    Please ensure a satisfactory definition (satisfactory to your application's needs) of `isequal` for all types
    used in the shadow document.
    You will only need to worry about this if you are using custom JSON deserialization.
  - `shadow_document_pre_update_callback (ShadowDocumentPreUpdateCallback)`: An optional callback which will be fired immediately before updating any shadow document properties. This is always fired, even if no shadow properties will be changed.
  - `shadow_document_post_update_callback (ShadowDocumentPostUpdateCallback)`: An optional callback which will be fired immediately after updating any shadow document properties. This is fired only if shadow properties were changed.
  - `shadow_document_property_pre_update_funcs (Dict{String,ShadowDocumentPropertyPreUpdateFunction})`: An optional set of functions which customize the update behavior of certain shadow document properties. See [`ShadowDocumentPropertyPreUpdateFunction`](@ref) for more information.
  - `id (Int)`: A unique ID which disambiguates log messages from multiple shadow frameworks.

See also [`ShadowDocumentPropertyUpdateCallback`](@ref), [`ShadowDocumentPreUpdateCallback`](@ref), [`ShadowDocumentPostUpdateCallback`](@ref), [`MQTTConnection`](@ref).

    !!! note "Limitations"
        Removing properties by setting their desired value to `null` is not currently supported. AWS IoT will remove
        that `null` property from the desired state, but the property will remain in the reported state.
"""
function ShadowFramework(
    connection::MQTTConnection,
    thing_name::String,
    shadow_name::Union{String,Nothing},
    shadow_document::AbstractDict;
    shadow_document_property_callbacks::Dict{String,<:ShadowDocumentPropertyUpdateCallback} = Dict{
        String,
        ShadowDocumentPropertyUpdateCallback,
    }(),
    shadow_document_pre_update_callback::ShadowDocumentPreUpdateCallback = v -> nothing,
    shadow_document_post_update_callback::ShadowDocumentPostUpdateCallback = v -> nothing,
    shadow_document_property_pre_update_funcs::Dict{String,<:ShadowDocumentPropertyPreUpdateFunction} = Dict{
        String,
        ShadowDocumentPropertyPreUpdateFunction,
    }(),
    id = 1,
)
    return ShadowFramework(
        id,
        ReentrantLock(),
        ShadowClient(connection, thing_name, shadow_name),
        shadow_document,
        shadow_document_property_callbacks,
        shadow_document_pre_update_callback,
        shadow_document_post_update_callback,
        shadow_document_property_pre_update_funcs,
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
    subscribe(sf::ShadowFramework)

Subscribes to the shadow document's topics and begins processing updates.
The `sf` is always locked before reading/writing from/to the shadow document.
If the remote shadow document does not exist, the local shadow document will be used to create it.

Publishes an initial message to the `/get` topic to synchronize the shadow document with the broker's state.
You can call `wait_until_synced(sf)` if you need to wait until this synchronization is done.

$publish_return_docs
"""
function subscribe(sf::ShadowFramework)
    sf._sync_latch = CountDownLatch(1)
    callback = _create_sf_callback(sf)
    task, id = subscribe(sf._shadow_client, AWS_MQTT_QOS_AT_LEAST_ONCE, callback)
    # Wait for the subscriptions to finish before publishing the initial /get so that we are guaranteed to be able
    # to receive the reply
    task_result = fetch(task)
    @debug "SF-$(sf._id): subscribe" id task_result

    # Publish an initial get to synchronize the local document
    @debug "SF-$(sf._id): publishing initial shadow /get"
    return publish(sf._shadow_client, "/get", "", AWS_MQTT_QOS_AT_LEAST_ONCE)
end

"""
    unsubscribe(sf::ShadowFramework)

Unsubscribes from the shadow document's topics and stops processing updates.
After calling this, `wait_until_synced(sf)` will again block until the first publish in response to
calling `subscribe(sf)`.

$_iot_shadow_unsubscribe_return_docs
"""
function unsubscribe(sf::ShadowFramework)
    return unsubscribe(sf._shadow_client)
end

"""
    publish_current_state(sf::ShadowFramework; include_version::Bool = true)

Publishes the current state of the shadow document.

Arguments:
- `include_version (Bool)`: Includes the version of the shadow document if this is `true`. You may want to exclude the version if you don't know what the broker's version is.

$publish_return_docs
"""
function publish_current_state(sf::ShadowFramework; include_version::Bool = true)
    current_state = _create_reported_state_payload(sf; include_version)
    @debug "SF-$(sf._id): publishing shadow update" current_state
    return publish(sf._shadow_client, "/update", current_state, AWS_MQTT_QOS_AT_LEAST_ONCE)
end

"""
    wait_until_synced(sf::ShadowFramework)

Blocks until the next time the shadow document is synchronized with the broker.

    !!! warning "Warning: Race Condition"
        If you are using this function to publish a message and then wait for the following synchronization, you
        must use the `do` form of [`wait_until_synced`](@ref) instead which accepts a lambda as the first argument.
        Otherwise, your publish will race the synchronization and there is a chance the synchronization will finish before
        you begin waiting for it (so you miss the edge and your program hangs).
"""
wait_until_synced(sf::ShadowFramework) = wait_until_synced(() -> nothing, sf)

"""
    wait_until_synced(f::Function, sf::ShadowFramework)

Blocks until the next time the shadow document is synchronized with the broker.
If you want to wait for a synchronization after a publication that you make, then you must make that publication inside
the lambda `f`.
"""
function wait_until_synced(f::Function, sf::ShadowFramework)
    sf._sync_latch = CountDownLatch(1)
    f()
    await(sf._sync_latch)
    return nothing
end

function _create_sf_callback(sf::ShadowFramework)
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
            # (isequals implementation, etc.). we need to avoid endless communications.
            updated = _update_local_shadow_from_get!(sf, payload)
            if updated
                publish_current_state(sf)
            else
                # no update to do, we're already synced
                count_down(sf._sync_latch)
            end
        elseif endswith(topic, "/get/rejected")
            # there is no shadow document, so we need to publish the first version. do not include a version number
            # because we have no idea what the version is. AWS IoT remembers the version number even after you delete
            # the shadow document. when we publish an initial /update without a version number, it's guaranteed to pass
            # the version check and if it's accepted, we will get an /update/accepted containing the new version number.
            publish_current_state(sf; include_version = false)
        elseif endswith(topic, "/update/delta")
            # there was an update published that doesn't match our reported state, so update our state to match
            # and publish our new state
            updated = _update_local_shadow_from_delta!(sf, payload)
            # we still need to check updated here, because there's a chance the delta state is permanent due to the
            # user's configuration (isequals implementation, etc.). we need to avoid endless communications.
            if updated
                publish_current_state(sf)
            else
                # no update to do, we're already synced
                count_down(sf._sync_latch)
            end
        elseif endswith(topic, "/update/accepted")
            # our update was accepted, which means the broker incremented the version number. we need to use the new
            # version number before publishing a new update or it will be rejected. sync to pull in the new version number
            _sync_version!(sf._shadow_document, payload)
            count_down(sf._sync_latch)
        end
    end
end

"""
    _update_local_shadow_from_get!(sf::ShadowFramework, payload_str::String)

Performs a local shadow update using the delta state from a /get/accepted document.
Returns `true` if the local shadow was updated.
"""
function _update_local_shadow_from_get!(sf::ShadowFramework, payload_str::String)
    payload = JSON.parse(payload_str)
    version = get(payload, "version", nothing)
    return lock(sf) do
        if _version_allows_update(sf._shadow_document, version)
            _set_version!(sf._shadow_document, version)
            state = get(payload, "state", nothing)
            if state !== nothing
                # first sync with the previously reported state to ensure that if our local copy and what was previously
                # reported somehow got out of sync, we can catch up even if there is no delta state
                reported = get(state, "reported", nothing)
                delta = get(state, "delta", nothing)
                if reported !== nothing
                    # also sync with the delta state to avoid having multiple shadow updates
                    if delta !== nothing
                        _recursive_merge!(reported, delta)
                    end
                    return _do_local_shadow_update!(sf, reported)
                else
                    if delta !== nothing
                        return _do_local_shadow_update!(sf, delta)
                    end
                end
            end
        else
            @debug "SF-$(sf._id): not processing shadow delta because its version ($version) is less than the current version ($(_version(sf._shadow_document)))"
        end
        return false
    end
end

function _recursive_merge!(d::AbstractDict, other::AbstractDict)
    for (k, v) in other
        if haskey(d, k)
            d[k] = _recursive_merge!(d[k], v)
        else
            d[k] = v
        end
    end
    return d
end

_recursive_merge!(d, other) = other

"""
    _update_local_shadow_from_delta!(sf::ShadowFramework, payload_str::String)

Performs a local shadow update using the delta state from an /update/delta document.
Returns `true` if the local shadow was updated.
"""
function _update_local_shadow_from_delta!(sf::ShadowFramework, payload_str::String)
    payload = JSON.parse(payload_str)
    version = get(payload, "version", nothing)
    return lock(sf) do
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
end

"""
    _do_local_shadow_update!(sf::ShadowFramework, state::Dict{String,<:Any})

 1. Fires the pre-update callback
 2. Updates each shadow property from `state` and fires its callback if an update occured
 3. Fires the post-update callback
 4. Returns `true` if any updated occured.
"""
function _do_local_shadow_update!(sf::ShadowFramework, state::Dict{String,<:Any})
    return lock(sf) do
        _fire_pre_update_callback(sf, state)
        any_updates = false
        for (k, v) in state
            updated = _update_shadow_property!(sf, sf._shadow_document, k, v)
            if updated
                _fire_callback(sf, k, sf._shadow_document[k])
                any_updates = true
            end
        end
        _fire_post_update_callback(sf)
        return any_updates
    end
end

function _fire_pre_update_callback(sf::ShadowFramework, state::Dict{String,<:Any})
    try
        sf._shadow_document_pre_update_callback(state)
    catch ex
        @error "SF-$(sf._id): failed to run shadow document pre-update callback" exception = (ex, catch_backtrace())
    end
    return nothing
end

function _fire_post_update_callback(sf::ShadowFramework)
    try
        sf._shadow_document_post_update_callback(sf._shadow_document)
    catch ex
        @error "SF-$(sf._id): failed to run shadow document pre-update callback" exception = (ex, catch_backtrace())
    end
    return nothing
end

function _fire_callback(sf::ShadowFramework, key::String, value)
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

function _create_reported_state_payload(sf::ShadowFramework; include_version = true)
    return lock(sf) do
        d = Dict()
        d["state"] = Dict("reported" => Dict(_get_shadow_property_pairs(sf._shadow_document)))
        if include_version
            d["version"] = _version(sf._shadow_document)
        end
        return json(d)
    end
end

_get_shadow_property_pairs(doc::AbstractDict) = filter(it -> it[1] != "version", collect(doc))

"""
    _update_shadow_property!(sf::ShadowFramework, doc::AbstractDict, key::String, value)

Updates the shadow property if the new `value` is not equal to the current value at the `key`.
If the `value` is an `AbstractDict`, it is merged into the `doc` instead of overwriting the `key`.
Returns `true` if an update occured.
"""
function _update_shadow_property!(sf::ShadowFramework, doc::AbstractDict, key::String, value)
    return if value isa AbstractDict
        updated = false
        for (k, v) in collect(value)
            updated |= _update_shadow_property!(sf, doc[key], k, v)
        end
        updated
    else
        if haskey(sf._shadow_document_property_pre_update_funcs, key)
            sf._shadow_document_property_pre_update_funcs[key](doc, key, value)
        else
            if !haskey(doc, key) || !isequal(doc[key], value)
                doc[key] = value
                true
            else
                false
            end
        end
    end
end

"""
    _sync_version!(doc::AbstractDict, payload_str::String)

Updates the local shadow's version number using the version in the `payload`.
"""
function _sync_version!(doc::AbstractDict, payload_str::String)
    payload = JSON.parse(payload_str)
    version = get(payload, "version", nothing)
    if _version_allows_update(doc, version)
        _set_version!(doc, version)
    end
    return nothing
end

_version_allows_update(doc::AbstractDict, version::Int) = version >= _version(doc)
_version_allows_update(doc::AbstractDict, version::Nothing) = false

_version(doc::AbstractDict) = doc["version"]
_version(doc) = doc.version

_set_version!(doc::AbstractDict, version::Int) = doc["version"] = version
_set_version!(doc, version::Int) = doc.version = version
