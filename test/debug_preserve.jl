mutable struct Obj
    x::Float32
end

l = ReentrantLock()
refs = Base.IdDict()

function foo()
    x = Obj(1234567.0f32)
    p = Base.pointer_from_objref(x)
    lock(l) do
        @time refs[x] = nothing
        @time refs[p] = nothing
    end
    @show refs
    return p
end

function bar(p)
    GC.gc(true)
    @time haskey(refs, p)
    x = Base.unsafe_pointer_to_objref(p)::Obj
    @time haskey(refs, x)
    @show x
end

bar(foo())
