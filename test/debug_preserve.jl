mutable struct Obj
    x::Float32
end

l = ReentrantLock()
refs = []

function foo()
    x = Ref(Obj(1234567.0f32))
    p = Base.pointer_from_objref(x)
    lock(l) do
        push!(refs, x)
    end
    return p
end

function bar(p)
    GC.gc(true)
    x = Base.unsafe_pointer_to_objref(p)::Ref{Obj}
    @show x
end

bar(foo())
