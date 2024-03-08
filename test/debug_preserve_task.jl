mutable struct Obj
    x::Float32
end

function foo()
    x = Ref(Obj(1234567.0f32))
    p = Base.pointer_from_objref(x)
    Threads.@spawn begin
        GC.gc(true)
        GC.@preserve x begin
            GC.gc(true)
            y = Base.unsafe_pointer_to_objref(p)::Ref{Obj}
            @show y
        end
    end
end

t = foo()
GC.gc(true)
wait(t)
