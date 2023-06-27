import Base.Int, Base.Real
import Base.<, Base.<=, Base.>, Base.<=, Base.+, Base.-, Base.*, Base./# Base.sum, Base.prod

abstract type NumericExpr <: AbstractExpr end


mutable struct IntExpr <: NumericExpr
    op       :: Symbol
    children :: Array{AbstractExpr}
    value    :: Union{Int, Nothing, Missing}
    name     :: String
end

function Base.Int(name::String) :: IntExpr
	# This unsightly bit enables warning when users define two variables with the same string name.
	global GLOBAL_VARNAMES
	global WARN_DUPLICATE_NAMES
	if name ∈ GLOBAL_VARNAMES[IntExpr]
        if WARN_DUPLICATE_NAMES @warn("Duplicate variable name $name of type Int") end
    else
        push!(GLOBAL_VARNAMES[IntExpr], name)
    end
	return IntExpr(:IDENTITY, Array{AbstractExpr}[], nothing, "$(name)")
end
Int(n::Int, name::String) :: Vector{IntExpr}         = IntExpr[Int("$(name)_$(i)") for i=1:n]
Int(m::Int, n::Int, name::String) :: Matrix{IntExpr} = IntExpr[Int("$(name)_$(i)_$(j)") for i=1:m, j=1:n]


mutable struct RealExpr <: NumericExpr
    op       :: Symbol
    children :: Array{AbstractExpr}
    value    :: Union{Float64, Nothing, Missing}
    name     :: String
end

function Base.Real(name::String) :: RealExpr
	# This unsightly bit enables warning when users define two variables with the same string name.
	global GLOBAL_VARNAMES
	global WARN_DUPLICATE_NAMES
	if name ∈ GLOBAL_VARNAMES[RealExpr]
        if WARN_DUPLICATE_NAMES @warn("Duplicate variable name $name of type Real") end
    else
        push!(GLOBAL_VARNAMES[RealExpr], name)
    end
	return RealExpr(:IDENTITY, Array{AbstractExpr}[], nothing, "$(name)")
end
Real(n::Int, name::String) :: Vector{RealExpr}         = RealExpr[Real("$(name)_$(i)") for i=1:n]
Real(m::Int, n::Int, name::String) :: Matrix{RealExpr} = RealExpr[Real("$(name)_$(i)_$(j)") for i=1:m, j=1:n]



##### COMPARISON OPERATIONS ####
# These return Boolean values. In the SMT dialect we would say they have sort Bool
# See figure 3.3 in the SMT-LIB standard.

function  Base.:<(e1::AbstractExpr, e2::AbstractExpr)
    value = isnothing(e1.value) || isnothing(e2.value) ? nothing : e1.value < e2.value
    name = __get_hash_name(:LT, [e1, e2])
    return BoolExpr(:LT, [e1, e2], value, name)
end

function  Base.:<=(e1::AbstractExpr, e2::AbstractExpr)
    value = isnothing(e1.value) || isnothing(e2.value) ? nothing : e1.value <= e2.value
    name = __get_hash_name(:LEQ, [e1, e2])
    return BoolExpr(:LEQ, [e1, e2], value, name)
end

function Base.:>=(e1::AbstractExpr, e2::AbstractExpr)
    value = isnothing(e1.value) || isnothing(e2.value) ? nothing : e1.value >= e2.value
    name = __get_hash_name(:GEQ, [e1, e2])
    return BoolExpr(:GEQ, [e1, e2], value, name)
end

function Base.:>(e1::AbstractExpr, e2::AbstractExpr)
    value = isnothing(e1.value) || isnothing(e2.value) ? nothing : e1.value > e2.value
    name = __get_hash_name(:GT, [e1, e2])
    return BoolExpr(:GT, [e1, e2], value, name)
end

# IMPORTANT NOTE
# DO NOT DEFINE A FUNCTION (==) THAT GENERATES AN EQUALITY CONSTRAINT
# This is because (==) is already defined as a comparison operator between two AbstractExprs.
# We can't swap the definitions eq and (==) because that breaks Base behavior.
# For example, if (==) generates an equality constraint instead of making a Boolean, you can't write z ∈ [z1,...,zn].

function eq(e1::T, e2::T) where T <: AbstractExpr
    value = isnothing(e1.value) || isnothing(e2.value) ? nothing : e1.value == e2.value
    name = __get_hash_name(:EQ, [e1, e2])
    return BoolExpr(:EQ, [e1, e2], value, name)
end


##### UNARY OPERATIONS #####
# Ok there's only one... negation.
Base.:-(e::IntExpr) = IntExpr(:NEG, IntExpr[e,], isnothing(e.value) ? nothing : -e.value, __get_hash_name(:NEG, [e,]))
Base.:-(e::RealExpr) = RealExpr(:NEG, RealExpr[e,], isnothing(e.value) ? nothing : -e.value, __get_hash_name(:NEG, [e,]))

# Define array version for convenience because the syntax .- for unary operators is confusing.
Base.:-(es::Array{T}) where T <: NumericExpr = .-es


##### COMBINING OPERATIONS #####
# These return Int values. We would say they have sort Int.
# See figure 3.3 in the SMT-LIB standard.

NumericInteroperableExpr  = Union{NumericExpr, BoolExpr}
NumericInteroperableConst = Union{Bool, Int, Float64}
NumericInteroperable = Union{NumericInteroperableExpr, NumericInteroperableConst}

# If op is nested, such as and(x, and(y, and(z, true))), flatten it. In the example we would get and(x, y, z, true).
#= function flatten(es::Array{T}, op::Symbol) where T <: AbstractExpr

    # this is all the child operators that aren't CONST or IDENTITY
    child_operators = filter( (op) -> op != :IDENTITY && op != :CONST, map( (e) -> e.op, es))
    
    if length(child_operators) > 0 && all(child_operators .== op)
        # This line flattens the children of expr e unless e has no children, in which case we keep e
        children = flatten(AbstractExpr[e.children for e in es])
        println("children =", children)
        return children
    else
        return es
    end

end
=#
# If literal is != 0, add a :CONST expr to es representing literal
function add_const!(es::Array{T}, literal::Real) where T <: AbstractExpr
    if literal != 0
        const_expr = isa(literal, Float64) ? RealExpr(:CONST, AbstractExpr[], literal, "const_$literal") : IntExpr(:CONST, AbstractExpr[], literal, "const_$literal")
        push!(es, const_expr)
    end
end

# If there is more than one :CONST expr in es, merge them into one
function merge_const!(es::Array{T}) where T <: AbstractExpr
    const_exprs = filter( (e) -> e.op == :CONST, es)
    if length(const_exprs) > 1
        filter!( (e) -> e.op != :CONST, es)
        add_const!(es, sum(map( (e) -> e.value, const_exprs)))
    end
end

# This is NOT a recursive function. It will only unnest one level.
function unnest(es::Array{T}, op::Symbol) where T <: AbstractExpr
    # this is all the child operators that aren't CONST or IDENTITY
    child_operators = filter( (op) -> op != :IDENTITY && op != :CONST, map( (e) -> e.op, es))
    
    if length(child_operators) > 0 && all(child_operators .== op)
        children = AbstractExpr[]
        map( (e) -> length(e.children) > 0 ? append!(children, e.children) : push!(children, e), es)
        return children
    else
        return es
    end
end

# This works for any n_ary op that takes as input NumericInteroperable arguments.
function __numeric_n_ary_op(es_mixed::Array, op::Symbol)
    # clean up types! This guarantees es::Array{AbstractExpr}
    es, literals = __check_inputs_nary_op(es_mixed, const_type=NumericInteroperableConst, expr_type=NumericInteroperableExpr)
    literal = length(literals) > 0 ? sum(literals) : 0

    # flatten nestings, this prevents unsightly things like and(x, and(y, and(z, true)))
    es = unnest(es, op)
    # now we are guaranteed all es are valid exprs and all literals have been condensed to one
    # hack to store literals
    add_const!(es, literal)

    # Now it is possible we have several CONST exprs. This occurs if, for example, one writes 1 + a + true
    # TO clean up, we should merge the CONST exprs
    merge_const!(es)

    # Now everything is in es and we are all cleaned up.
    # Determine return expr type. Note that / promotes to RealExpr because the SMT theory of integers doesn't include it
    ReturnExpr = any(map((e) -> isa(e, RealExpr), es)) || op == :DIV ? RealExpr : IntExpr

    value = any(isnothing.(map( (e) -> e.value, es))) ? nothing : sum(values)
    return ReturnExpr(op, es, value, __get_hash_name(op, es))
end

#Base.sum(es_mixed::Array) = __numeric_n_ary_op(es_mixed, :ADD)
#Base.prod(es_mixed::Array) = __numeric_n_ary_op(es_mixed, :MUL)

# The unsightly typing here specifies the following extensions to Base.:+
# NumericExpr + NumericExpr
# NumericExpr + Const
# Const + NumericExpr

Base.:+(e1::Union{NumericInteroperableExpr}, e2::NumericInteroperableExpr)  = __numeric_n_ary_op([e1, e2], :ADD)
Base.:+(e1::Union{NumericInteroperableExpr}, e2::NumericInteroperableConst) = __numeric_n_ary_op([e1, e2], :ADD)
Base.:+(e1::Union{NumericInteroperableConst}, e2::NumericInteroperableExpr) = e2 + e1

Base.:-(e1::Union{NumericInteroperableExpr}, e2::NumericInteroperableExpr)  = __numeric_n_ary_op([e1, e2], :SUB)
Base.:-(e1::Union{NumericInteroperableExpr}, e2::NumericInteroperableConst) = __numeric_n_ary_op([e1, e2], :SUB)
Base.:-(e1::Union{NumericInteroperableConst}, e2::NumericInteroperableExpr) = __numeric_n_ary_op([e1, e2], :SUB)

Base.:*(e1::Union{NumericInteroperableExpr}, e2::NumericInteroperableExpr)  = __numeric_n_ary_op([e1, e2], :MUL)
Base.:*(e1::Union{NumericInteroperableExpr}, e2::NumericInteroperableConst) = __numeric_n_ary_op([e1, e2], :MUL)
Base.:*(e1::Union{NumericInteroperableConst}, e2::NumericInteroperableExpr) = e2 * e1

Base.:/(e1::Union{NumericInteroperableExpr}, e2::NumericInteroperableExpr)  = __numeric_n_ary_op([e1, e2], :DIV)
Base.:/(e1::Union{NumericInteroperableExpr}, e2::NumericInteroperableConst) = __numeric_n_ary_op([e1, e2], :DIV)
Base.:/(e1::Union{NumericInteroperableConst}, e2::NumericInteroperableExpr) = __numeric_n_ary_op([e1, e2], :DIV)