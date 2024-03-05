function main()
    nmaxruns = tryparse(Int, ARGS[1])
    cmd = nmaxruns === nothing ? Cmd(ARGS) : Cmd(ARGS[begin+1:end])
    if nmaxruns === nothing
        @info "Running cmd on $(Threads.nthreads()) threads until stopped: $cmd"
    else
        @info "Running cmd on $(Threads.nthreads()) threads up to $nmaxruns times: $cmd"
    end

    print_lock = ReentrantLock()
    nruns = Threads.Atomic{Int}(0)
    tasks = Task[]
    for _ = 1:Threads.nthreads()
        t = Threads.@spawn begin
            while true
                stdout = IOBuffer()
                stderr = IOBuffer()
                try
                    run(pipeline(cmd; stdout, stderr))
                    old_nruns = Threads.atomic_add!(nruns, 1) + 1
                    if nmaxruns !== nothing && old_nruns >= nmaxruns
                        lock(print_lock) do
                            @info "Done after $nmaxruns runs"
                        end
                        exit(0)
                    end
                    if old_nruns % 10 == 0
                        lock(print_lock) do
                            @info "$old_nruns successful runs so far..."
                        end
                    end
                catch ex
                    lock(print_lock) do
                        @error "Command failed after $(nruns[]) runs." exception = ex
                        @error "Command stdout:"
                        println(String(take!(stdout)))
                        @error "Command stderr:"
                        println(String(take!(stderr)))
                        exit(1)
                    end
                end
            end
        end
        Base.errormonitor(t)
        push!(tasks, t)
    end
    for t in tasks
        fetch(t)
    end
end

main()
