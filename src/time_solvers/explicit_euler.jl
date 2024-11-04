"""
    ExplicitEuler(; kwargs...)

Time integration solver for the Velocity Verlet algorithm. Specify either the number of
steps or the time the simulation should cover.

# Keywords
- `time::Real`: The total time the simulation will cover. If this keyword is specified, the
    keyword `steps` is no longer allowed. (optional)
- `steps::Int`: Number of calculated time steps. If this keyword is specified, the keyword
    `time` is no longer allowed. (optional)
- `stepsize::Real`: Manually specify the size of the time step. (optional)
- `safety_factor::Real`: Safety factor for step size to ensure stability. (default: `0.7`)

!!! warning "Specification of the time step"
    Keep in mind that manually specifying the critical time step is dangerous! If the
    specified time step is too high and the CFL condition no longer holds, the simulation
    will give wrong results and maybe crash!

# Throws
- Errors if both `time` and `steps` are specified as keywords.
- Errors if neither `time` nor `steps` are specified as keywords.
- Errors if `safety_factor < 0` or `safety_factor > 1`.

# Example

```julia-repl
julia> ExplicitEuler(steps=2000)
ExplicitEuler:
  n_steps        2000
  safety_factor  0.7

julia> ExplicitEuler(time=0.001)
ExplicitEuler:
  end_time       0.001
  safety_factor  0.7

julia> ExplicitEuler(steps=2000, stepsize=0.0001)
┌ Warning: stepsize specified! Please be sure that the CFD-condition holds!
└ @ Peridynamics ~/Code/Peridynamics.jl/src/time_solvers/velocity_verlet.jl:66
ExplicitEuler:
  n_steps        2000
  Δt             0.0001
  safety_factor  0.7
```
"""

