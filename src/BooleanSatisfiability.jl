module BooleanSatisfiability

export AbstractExpr,
       BoolExpr,
       IntExpr,
       RealExpr,
       isequal,
       hash, # required by isequal (?)
       in # specialize to use isequal instead of ==

export
       and, ∧,
       or,  ∨,
       not, ¬,
       implies, ⟹,
       xor, ⊻,
       iff, ⟺,
       ite,
       value
export
       ==, <, <=, >, >=
       
export
       +, -, *, /

export smt,
       save

export sat!

# This tells us how to invoke the solvers
DEFAULT_SOLVER_CMDS = Dict(
    :Z3 => `z3 -smt2 -in`
)

#=  INCLUDES
    * BoolExpr.jl (definition of BoolExpr)
    * utilities.jl (internal, no public-facing functions)
    * Logical operators and, or, not, implies
    * Logical operators any and all
=#
include("BooleanOperations.jl")

#= INCLUDES
    * Declarations for IntExpr and RealExpr
    * Operations for IntExpr and RealExpr
=#
include("IntExpr.jl")


__EXPR_TYPES = [BoolExpr, RealExpr, IntExpr]

# Track the user-declared BoolExpr names so the user doesn't make duplicates.
# This will NOT contain hash names. If the user declares x = Bool("x"); y = Bool("y"); xy = and(x,y)
# GLOBAL_VARNAMES will contain "x" and "y", but not __get_hash_name(:AND, [x,y]).
global GLOBAL_VARNAMES = Dict(t => String[] for t in __EXPR_TYPES)
# When false, no warnings will be issued
global WARN_DUPLICATE_NAMES = false

SET_DUPLICATE_NAME_WARNING!(value::Bool) = global WARN_DUPLICATE_NAMES = value

# this might be useful when solving something in a loop
CLEAR_VARNAMES!() = global GLOBAL_VARNAMES = Dict(t => String[] for t in __EXPR_TYPES)

export GLOBAL_VARNAMES,
       SET_DUPLICATE_NAME_WARNING!,
       CLEAR_VARNAMES!

#=  INCLUDES
    * declare (generate SMT variable declarations for expression)
    * smt (generate SMT representation of problem)
=#
include("smt_representation.jl")

#=  INCLUDES
    * sat! (solve problem)
    * sat.jl includes call_solver.jl
=#
include("sat.jl")

# Module end
end