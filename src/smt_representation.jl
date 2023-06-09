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
    :LT      => "<",
    :LEQ     => "<=",
    :GT      => ">",
    :GEQ     => ">=",
    :EQ      => "=",
    :ADD     => "+",
    :SUB     => "-",
    :MUL     => "*",
    :DIV     => "/",
)

__commutative_ops = [:AND, :OR, :XOR, :IFF, :EQ, :ADD, :MUL]

# Dictionary of opnames with 1 operand.
__smt_1_opnames = Dict(
    :NOT     => "not",
    :NEG     => "neg",
)

# Mapping of Julia Expr types to SMT names. This is necessary because to distinguish from native types Bool, Int, Real, etc, we call ours BoolExpr, IntExpr, RealExpr, etc.
__smt_typenames = Dict(
    BoolExpr => "Bool",
    IntExpr  => "Int",
    RealExpr => "Real",
)

__boolean_ops = [:AND, :OR, :XOR, :IMPLIES, :IFF, :ITE, :LT, :LEQ, :GT, :GEQ, :EQ, :NOT]

##### GENERATING SMTLIB REPRESENTATION #####

"""
    declare(z)

Generate SMT variable declarations for a BoolExpr variable (operation = :IDENTITY).

Examples:
* `declare(a::IntExpr)` returns `"(declare-const a Int)\\n"`
* `declare(and(z1, z2))` returns `"(declare-const z1 Bool)\\n(declare-const z2 Bool)\\n"`.
"""
function declare(z::AbstractExpr)
    # There is only one variable
    vartype = __smt_typenames[typeof(z)]
    if length(z) == 1
        return "(declare-const $(z.name) $vartype)\n"
    # Variable is 1D
    elseif length(size(z)) == 1
        return join(map( (i) -> "(declare-const $(z.name)_$i $vartype)\n", 1:size(z)[1]))
    # Variable is 2D
    elseif length(size(z)) == 2
        declarations = String[]
        # map over 2D variable rows, then cols inside
        m,n = size(z)
        map(1:m) do i
            append_unique!(declarations, map( (j) -> "(declare-const $(z.name)_$(i)_$j $vartype)\n", 1:size(z)[2]))
        end
        return join(declarations)
    else
        error("Invalid size $(z.shape) for variable!")
    end
    join(declarations, '\n')
end

declare(zs::Array{T}) where T <: AbstractExpr = reduce(*, map(declare, zs))


# Determine the return type of an expression with operation op and children zs
function __return_type(op::Symbol, zs::Array{T}) where T <: AbstractExpr
    if op ∈ __boolean_ops
        return "Bool"
    else
        if any(typeof.(zs) .== RealExpr)
            return "Real"
        else # all are IntExpr
            return "Int"
        end
    end
end

# Return either z.name or the correct (as z.name Type) if z.name is defined for multiple types
# This multiple name misbehavior is allowed in SMT2; the expression (as z.name Type) is called a fully qualified name.
# It would arise if someone wrote something like xb = Bool("x"); xi = Int("x")
function __get_smt_name(z::AbstractExpr)
    if z.op == :CONST
        return string(z.value)
    end
    global GLOBAL_VARNAMES
    appears_in = map( (t) -> z.name ∈ GLOBAL_VARNAMES[t], __EXPR_TYPES)
    if sum(appears_in) > 1
        return "(as $(z.name) $(__smt_typenames[typeof(z)]))"
    else # easy case, one variable with z.name is defined
        return z.name
    end
end

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
        # if the expr is a :CONST it will have a value (e.g. 2 or 1.5), otherwise use its name
        # This yields a list like String["z_1", "z_2", "1"].
        varnames = __get_smt_name.(zs)
        outname = __return_type(op, zs)
        if op ∈ __commutative_ops
            varnames = sort(varnames)
        end
        declaration = "(define-fun $fname () $outname ($(__smt_n_opnames[op]) $(join(varnames, " "))))\n"
        cache_key = hash(declaration) # we use this to find out if we already declared this item
        prop = ""
        if cache_key in keys(cache)
            prop = depth == 0 ? cache[cache_key] : ""
        else
            if op ∈ __boolean_ops && depth == 0
                prop = declaration*"(assert $fname)\n"
                # the proposition is generated and cached now.
                cache[cache_key] = "(assert $fname)\n"
            else
                prop = declaration
            end
        end
        return prop
    end
end


function __define_1_op!(z::AbstractExpr, op::Symbol, cache::Dict{UInt64, String}, depth::Int)
    fname = __get_hash_name(op, z.children)
    outname = __return_type(op, [z])
    prop = ""
    declaration = "(define-fun $fname () $outname ($(__smt_1_opnames[op]) $(__get_smt_name(z.children[1]))))\n"
    cache_key = hash(declaration)

    if depth == 0 && !isa(z, BoolEx)
        @warn("Cannot assert non-Boolean expression\n$z")
    end

    if cache_key in keys(cache) && depth == 0
        prop = cache[cache_key] # the proposition was already generated in a previous step
    else
        # if depth = 0 that means we are at the top-level of a nested expression.
        # thus, if the expr is Boolean we should assert it.
        if op ∈ __boolean_ops && depth == 0
            prop = declaration*"(assert $fname)\n"
            # the proposition is generated and cached now.
            cache[cache_key] = "(assert $fname)\n"
        else
            prop = declaration
        end
    end
    
    return prop
end


"smt!(prob, declarations, propositions) is an INTERNAL version of smt(prob).
We use it to iteratively build a list of declarations and propositions.
Users should call smt(prob)."
function smt!(z::AbstractExpr, declarations::Array{T}, propositions::Array{T}, cache::Dict{UInt64, String}, depth::Int) :: Tuple{Array{T}, Array{T}} where T <: String 
    if z.op == :IDENTITY
        n = length(declarations)
        push_unique!(declarations, declare(z))
    elseif z.op == :CONST
        ;
    else
        map( (c) -> smt!(c, declarations, propositions, cache, depth+1) , z.children)

        if z.op ∈ keys(__smt_1_opnames)
            props = [__define_1_op!(z, z.op, cache, depth),]

        elseif z.op ∈ keys(__smt_n_opnames) # all n-ary ops where n >= 2
            props = broadcast((zs::Vararg{AbstractExpr}) -> __define_n_op!(collect(zs), z.op, cache, depth), z.children...)
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
    smt(z::AbstractExpr)
    smt(z1,...,zn)
    smt([z1,...,zn])

Generate the SMT representation of `z` or `and(z1,...,zn)`.

When calling `smt([z1,...,zn])`, the array must have type `Array{AbstractExpr}`. Note that list comprehensions do not preserve array typing. For example, if `z` is an array of `BoolExpr`, `[z[i] for i=1:n]` will be an array of type `Any`. To preserve the correct type, use `BoolExpr[z[i] for i=1:n]`.
"""
function smt(zs::Array{T}) where T <: AbstractExpr
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


smt(zs::Vararg{Union{Array{T}, T}}) where T <: AbstractExpr = smt(collect(zs))

##### WRITE TO FILE #####

"""
    save(z::AbstractExpr, filename)
    save(z::Array{AbstractExpr}, filename=filename)
    save(z1, z2,..., filename)                  # z1, z2,... are type AbstractExpr

Write the SMT representation of `z` or `and(z1,...,zn)` to filename.smt.
"""
function save(prob::AbstractExpr, filename="out")
    if !isa(prob, BoolExpr)
        @warn "Top-level expression must be Boolean to produce a valid SMT program."
    end
    open("$filename.smt", "w") do io
        write(io, smt(prob))
        write(io, "(check-sat)\n")
    end
end

# this is the version that accepts a list of exprs, for example save(z1, z2, z3). This is necessary because if z1::BoolExpr and z2::Array{BoolExpr}, etc, then the typing is too difficult to make an array.
save(zs::Vararg{Union{Array{T}, T}}; filename="out") where T <: AbstractExpr = save(__flatten_nested_exprs(all, zs...), filename)

# array version for convenience. THIS DOES NOT ACCEPT ARRAYS OF MIXED AbstractExpr and Array{AbstractExpr}.
save(zs::Array{T}, filename="out") where T <: AbstractExpr = save(all(zs), filename)
