
@kwdef struct NOSBMaterial <: AbstractMaterial
    maxdmg::Float64 = 0.95
    corr::Float64 = 10.0
end

struct NOSBPointParameters <: AbstractPointParameters
    δ::Float64
    rho::Float64
    E::Float64
    nu::Float64
    G::Float64
    K::Float64
    λ::Float64
    μ::Float64
    Gc::Float64
    εc::Float64
    bc::Float64
end

@inline point_param_type(::NOSBMaterial) = NOSBPointParameters
@inline allowed_material_kwargs(::NOSBMaterial) = DEFAULT_POINT_KWARGS

function get_point_params(::NOSBMaterial, p::Dict{Symbol,Any})
    δ = get_horizon(p)
    rho = get_density(p)
    E, nu, G, K, λ, μ = get_elastic_params(p)
    Gc, εc = get_frac_params(p, δ, K)
    bc = 18 * K / (π * δ^4) # bond constant
    return NOSBPointParameters(δ, rho, E, nu, G, K, λ, μ, Gc, εc, bc)
end

@inline discretization_type(::NOSBMaterial) = BondDiscretization

@inline function init_discretization(body::Body{NOSBMaterial}, args...)
    return init_bond_discretization(body, args...)
end

struct NOSBVerletStorage <: AbstractStorage
    position::Matrix{Float64}
    displacement::Matrix{Float64}
    velocity::Matrix{Float64}
    velocity_half::Matrix{Float64}
    acceleration::Matrix{Float64}
    b_int::Matrix{Float64}
    b_ext::Matrix{Float64}
    damage::Vector{Float64}
    bond_active::Vector{Bool}
    n_active_bonds::Vector{Int}
end

const NOSBStorage = Union{NOSBVerletStorage}

@inline storage_type(::NOSBMaterial, ::VelocityVerlet) = NOSBVerletStorage

function init_storage(::Body{NOSBMaterial}, ::VelocityVerlet, bd::BondDiscretization,
                      ch::ChunkHandler)
    n_loc_points = length(ch.loc_points)
    position = copy(bd.position)
    displacement = zeros(3, n_loc_points)
    velocity = zeros(3, n_loc_points)
    velocity_half = zeros(3, n_loc_points)
    acceleration = zeros(3, n_loc_points)
    b_int = zeros(3, length(ch.point_ids))
    b_ext = zeros(3, n_loc_points)
    damage = zeros(n_loc_points)
    bond_active = ones(Bool, length(bd.bonds))
    n_active_bonds = copy(bd.n_neighbors)
    return NOSBVerletStorage(position, displacement, velocity, velocity_half, acceleration,
                           b_int, b_ext, damage, bond_active, n_active_bonds)
end

@inline reads_from_halo(::Type{NOSBMaterial}) = (:position,)
@inline writes_to_halo(::Type{NOSBMaterial}) = (:b_int,)

function force_density_point!(s::NOSBStorage, bd::BondDiscretization, mat::NOSBMaterial,
                              param::NOSBPointParameters, i::Int)
    F, Kinv, ω0 = calc_deformation_gradient(s, bd, param, i)
    if s.damage[i] > mat.maxdmg || containsnan(F)
        kill_point!(s, bd, i)
        return nothing
    end
    P = calc_first_piola_stress(F, param)
    if iszero(P) || containsnan(P)
        kill_point!(s, bd, i)
        return nothing
    end
    PKinv = P * Kinv
    for bond_id in each_bond_idx(bd, i)
        bond = bd.bonds[bond_id]
        j, L = bond.neighbor, bond.length

        ΔXijx = bd.position[1, j] - bd.position[1, i]
        ΔXijy = bd.position[2, j] - bd.position[2, i]
        ΔXijz = bd.position[3, j] - bd.position[3, i]
        ΔXij = SVector{3}(ΔXijx, ΔXijy, ΔXijz)
        Δxijx = s.position[1, j] - s.position[1, i]
        Δxijy = s.position[2, j] - s.position[2, i]
        Δxijz = s.position[3, j] - s.position[3, i]
        Δxij = SVector{3}(Δxijx, Δxijy, Δxijz)
        l = sqrt(Δxijx * Δxijx + Δxijy * Δxijy + Δxijz * Δxijz)
        ε = (l - L) / L

        # failure mechanism
        if ε > param.εc && bond.fail_permit
            s.bond_active[bond_id] = false
        end

        # stabilization
        ωij = (1 + param.δ / L) * s.bond_active[bond_id]
        Tij = mat.corr .* param.bc * ωij / ω0 .* (Δxij .- F * ΔXij)

        # update of force density
        tij = ωij * PKinv * ΔXij + Tij
        if containsnan(tij)
            tij = zero(SMatrix{3,3})
            s.bond_active[bond_id] = false
        end
        s.n_active_bonds[i] += s.bond_active[bond_id]
        s.b_int[1, i] += tij[1] * bd.volume[j]
        s.b_int[2, i] += tij[2] * bd.volume[j]
        s.b_int[3, i] += tij[3] * bd.volume[j]
        s.b_int[1, j] -= tij[1] * bd.volume[i]
        s.b_int[2, j] -= tij[2] * bd.volume[i]
        s.b_int[3, j] -= tij[3] * bd.volume[i]
    end
    return nothing
end

function calc_deformation_gradient(s::NOSBStorage, bd::BondDiscretization,
                                   param::NOSBPointParameters, i::Int)
    # calculate the deformation gradient F
    # K and _F need to start from zero for every point
    # Kxx = symmetric shape tensor
    K11, K12, K13 = 0.0, 0.0, 0.0
    K21, K22, K23 = 0.0, 0.0, 0.0
    K31, K32, K33 = 0.0, 0.0, 0.0
    # _Fxx = first term of deformation gradient
    _F11, _F12, _F13 = 0.0, 0.0, 0.0
    _F21, _F22, _F23 = 0.0, 0.0, 0.0
    _F31, _F32, _F33 = 0.0, 0.0, 0.0
    ω0 = 0.0
    for bond_id in each_bond_idx(bd, i)
        bond = bd.bonds[bond_id]
        j, L = bond.neighbor, bond.length
        ΔXij1 = bd.position[1, j] - bd.position[1, i]
        ΔXij2 = bd.position[2, j] - bd.position[2, i]
        ΔXij3 = bd.position[3, j] - bd.position[3, i]
        Δxij1 = s.position[1, j] - s.position[1, i]
        Δxij2 = s.position[2, j] - s.position[2, i]
        Δxij3 = s.position[3, j] - s.position[3, i]
        Vj = bd.volume[j]
        ωij = (1 + param.δ / L) * s.bond_active[bond_id]
        ω0 += ωij
        temp = ωij * Vj
        K11 += temp * ΔXij1 * ΔXij1
        K12 += temp * ΔXij1 * ΔXij2
        K13 += temp * ΔXij1 * ΔXij3
        K21 += temp * ΔXij2 * ΔXij1
        K22 += temp * ΔXij2 * ΔXij2
        K23 += temp * ΔXij2 * ΔXij3
        K31 += temp * ΔXij3 * ΔXij1
        K32 += temp * ΔXij3 * ΔXij2
        K33 += temp * ΔXij3 * ΔXij3
        _F11 += temp * Δxij1 * ΔXij1
        _F12 += temp * Δxij1 * ΔXij2
        _F13 += temp * Δxij1 * ΔXij3
        _F21 += temp * Δxij2 * ΔXij1
        _F22 += temp * Δxij2 * ΔXij2
        _F23 += temp * Δxij2 * ΔXij3
        _F31 += temp * Δxij3 * ΔXij1
        _F32 += temp * Δxij3 * ΔXij2
        _F33 += temp * Δxij3 * ΔXij3
    end
    K = SMatrix{3,3}(K11, K21, K31, K12, K22, K32, K13, K23, K33)
    _F = SMatrix{3,3}(_F11, _F21, _F31, _F12, _F22, _F32, _F13, _F23, _F33)
    Kinv = inv(K)
    F = _F * Kinv
    return F, Kinv, ω0
end

function calc_first_piola_stress(F::SMatrix{3,3}, param::NOSBPointParameters)
    J = det(F)
    J ≤ 5 * eps() && return zero(SMatrix{3,3})
    C = F' * F
    Cinv = inv(C)
    S = param.G .* (I-1/3 .* tr(C) .* Cinv) .* J^(-2/3) .+ param.K/4 .* (J^2-J^(-2)) .* Cinv
    P = F * S
    return P
end

function containsnan(K::T) where {T<:AbstractArray}
    @simd for i in eachindex(K)
        isnan(K[i]) && return true
    end
    return false
end

function kill_point!(s::AbstractStorage, bd::BondDiscretization, i::Int)
    s.bond_active[each_bond_idx(bd, i)] .= false
    s.n_active_bonds[i] = 0
    return nothing
end
