##### CONSTANTS FOR USE IN THIS FILE #####
# Dictionary of opnames with n>=2 operands. This is necessary because not all opnames are valid symbols
# For example, iff is = and := is an invalid symbol.
__smt_n_opnames = Dict(
    :AND     => "and",
    :OR      => "or",
    :XOR     => "xor",
    :IMPLIES => "=>",
    :IFF     => "=",
    :ITE     => "ite",
)

# Dictionary of opnames with 1 operand.
__smt_1_opnames = Dict(
    :NOT     => "not",
)

# Mapping of Julia Expr types to SMT names. This is necessary because to distinguish from native types Bool, Int, Real, etc, we call ours BoolExpr, IntExpr, RealExpr, etc.
__smt_typenames = Dict(
    BoolExpr => "Bool"
)

##### GENERATING SMTLIB REPRESENTATION #####

"""
    declare(z)

Generate SMT variable declarations for a BoolExpr variable (operation = :IDENTITY).

Examples:
* `declare(z1)` returns `"(declare-const z1 Bool)\\n"`
* `declare(and(z1, z2))` returns `"(declare-const z1 Bool)\\n(declare-const z2 Bool)\\n"`.
"""
function declare(z::BoolExpr)
    # There is only one variable
    if length(z) == 1
        return "(declare-const $(z.name) Bool)\n"
    # Variable is 1D
    elseif length(size(z)) == 1
        return join(map( (i) -> "(declare-const $(z.name)_$i Bool)\n", 1:size(z)[1]))
    # Variable is 2D
    elseif length(size(z)) == 2
        declarations = String[]
        # map over 2D variable rows, then cols inside
        m,n = size(z)
        map(1:m) do i
            append_unique!(declarations, map( (j) -> "(declare-const $(z.name)_$(i)_$j Bool)\n", 1:size(z)[2]))
        end
        return join(declarations)
    else
        error("Invalid size $(z.shape) for variable!")
    end
    join(declarations, '\n')
end

declare(zs::Array{T}) where T <: BoolExpr = reduce(*, map(declare, zs))


"__define_n_op! is a helper function for defining the SMT statements for n-ary ops where n >= 2.
cache is a Dict where each value is an SMT statement and its key is the hash of the statement. This allows us to avoid two things:
1. Redeclaring SMT statements, which causes the solver to emit errors.
2. Re-using named functions. For example if we \"(define-fun FUNC_NAME or(z1, z2))\" and then the expression or(z1, z2) re-appears later in the expression \"and(or(z1, z2), z3)\", we can write and(FUNC_NAME, z3)."
function __define_n_op!(zs::Array{T}, op::Symbol, cache::Dict{UInt64, String}, depth::Int) where T <: AbstractExpr
    if length(zs) == 0
        return ""

    elseif length(zs) == 1
        return depth == 0 ? "(assert ($(zs[1].name)))\n" : ""

    else
        fname = __get_hash_name(op, zs)
        varnames = map( (c) -> c.name, zs)
        typename = __smt_typenames[typeof(zs[1])]

        declaration = "(define-fun $fname () $typename ($(__smt_n_opnames[op]) $(join(sort(varnames), " "))))\n"
        cache_key = hash(declaration) # we use this to find out if we already declared this item
        prop = ""
        if cache_key in keys(cache)
            prop = depth == 0 ? cache[cache_key] : ""
        else
            prop = depth == 0 ? declaration*"(assert $fname)\n" : declaration
            cache[cache_key] = "(assert $fname)\n"
        end
        return prop
    end
end

function __define_1_op!(z::AbstractExpr, op::Symbol, cache::Dict{UInt64, String}, depth::Int)
    fname = __get_hash_name(op, z.children)
    typename = __smt_typenames[typeof(z)]

    declaration = "(define-fun $fname () $typename ($(__smt_1_opnames[op]) $(z.children[1].name)))\n"
    cache_key = hash(declaration)

    if cache_key in keys(cache) && depth == 0
        prop = cache[cache_key]
    else
        prop = depth == 0 ? declaration*"\n(assert $fname)\n" : declaration
        cache[cache_key] = "(assert $fname)\n"
    end
    
    return prop
end


"smt!(prob, declarations, propositions) is an INTERNAL version of smt(prob).
We use it to iteratively build a list of declarations and propositions.
Users should call smt(prob)."
function smt!(z::BoolExpr, declarations::Array{T}, propositions::Array{T}, cache::Dict{UInt64, String}, depth::Int) :: Tuple{Array{T}, Array{T}} where T <: String 
    if z.op == :IDENTITY
        n = length(declarations)
        push_unique!(declarations, declare(z))
    else
        map( (c) -> smt!(c, declarations, propositions, cache, depth+1) , z.children)

        if z.op ∈ keys(__smt_1_opnames)
            props = [__define_1_op!(z, z.op, cache, depth),]

        elseif z.op ∈ keys(__smt_n_opnames) # all n-ary ops where n >= 2
            props = broadcast((zs::Vararg{BoolExpr}) -> __define_n_op!(collect(zs), z.op, cache, depth), z.children...)
            #n = length(propositions)
            props = collect(props)
        else
            error("Unknown operation $(z.op)!")
        end

        append_unique!(propositions, props)
    end
    return declarations, propositions
end


# Example:
# * `smt(and(z1, z2))` yields the statements `(declare-const z1 Bool)\n(declare-const z2 Bool)\n(define-fun AND_31df279ea7439224 Bool (and z1 z2))\n(assert AND_31df279ea7439224)\n`
"""
    smt(z::BoolExpr)
    smt(z1,...,zn)
    smt([z1,...,zn])

Generate the SMT representation of `z` or `and(z1,...,zn)`.

When calling `smt([z1,...,zn])`, the array must have type `Array{BoolExpr}`. Note that list comprehensions do not preserve array typing. For example, if `z` is an array of `BoolExpr`, `[z[i] for i=1:n]` will be an array of type `Any`. To preserve the correct type, use `BoolExpr[z[i] for i=1:n]`.
"""
function smt(zs::Array{T}) where T <: BoolExpr
    declarations = String[]
    propositions = String[]
    cache = Dict{UInt64, String}()
    if length(zs) == 1
        declarations, propositions = smt!(zs[1], declarations, propositions, cache, 0)
    else
        map((z) -> smt!(z, declarations, propositions, cache, 0), zs)
    end
    # this expression concatenates all the strings in row 1, then all the strings in row 2, etc.
    return reduce(*, declarations)*reduce(*,propositions)
end


smt(zs::Vararg{Union{Array{T}, T}}) where T <: BoolExpr = smt(collect(zs))

##### WRITE TO FILE #####

"""
    save(z::BoolExpr, filename)
    save(z::Array{BoolExpr}, filename=filename)
    save(z1, z2,..., filename)                  # z1, z2,... are type BoolExpr

Write the SMT representation of `z` or `and(z1,...,zn)` to filename.smt.
"""
function save(prob::BoolExpr, filename="out")
    open("$filename.smt", "w") do io
        write(io, smt(prob))
        write(io, "(check-sat)\n")
    end
end

# this is the version that accepts a list of exprs, for example save(z1, z2, z3). This is necessary because if z1::BoolExpr and z2::Array{BoolExpr}, etc, then the typing is too difficult to make an array.
save(zs::Vararg{Union{Array{T}, T}}; filename="out") where T <: BoolExpr = save(__flatten_nested_exprs(all, zs...), filename)

# array version for convenience. THIS DOES NOT ACCEPT ARRAYS OF MIXED BoolExpr and Array{BoolExpr}.
save(zs::Array{T}, filename="out") where T <: BoolExpr = save(all(zs), filename)
