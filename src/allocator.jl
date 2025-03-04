function _c_aws_malloc(allocator::Ptr{aws_allocator}, size::Csize_t)::Ptr{Cvoid}
    return @ccall jl_malloc(size::Csize_t)::Ptr{Cvoid}
end

function _c_aws_free(allocator::Ptr{aws_allocator}, ptr::Ptr{Cvoid})::Cvoid
    return @ccall jl_free(ptr::Ptr{Cvoid})::Cvoid
end

function _c_aws_realloc(
    allocator::Ptr{aws_allocator},
    ptr::Ptr{Cvoid},
    old_size::Csize_t,
    new_size::Csize_t,
)::Ptr{Cvoid}
    return @ccall jl_realloc(ptr::Ptr{Cvoid}, new_size::Csize_t)::Ptr{Cvoid}
end

function _c_aws_calloc(allocator::Ptr{aws_allocator}, num::Csize_t, size::Csize_t)::Ptr{Cvoid}
    return @ccall jl_calloc(num::Csize_t, size::Csize_t)::Ptr{Cvoid}
end

"""
    new_jl_allocator()

Returns an `aws_allocator` which integrates with Julia's GC to track memory allocated by native code.
"""
function new_jl_allocator()
    return aws_allocator(_C_AWS_MALLOC[], _C_AWS_FREE[], _C_AWS_REALLOC[], _C_AWS_CALLOC[], C_NULL)
end
