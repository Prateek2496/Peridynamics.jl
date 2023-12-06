using Peridynamics, Test

# TODO: test all materials and create the simmodel directly...
if Threads.nthreads() <= 2
    positions = [
        0.0 1.0
        0.0 0.0
        0.0 0.0
    ]
    point_spacing = 1.0
    δ = 1.5 * point_spacing
    n_points = 2
    volumes = fill(point_spacing^3, n_points)
    pc = PointCloud(positions, volumes)
    mat = BBMaterial(; horizon=δ, rho=1, E=1, Gc=1)
    body = Peridynamics.init_body(mat, pc)
    sf = 0.7
    Δt = sf * sqrt(2 * 1 / (body.volume[2] * 1 / 1 * 18 * 2/3 / (π * δ^4)))
    @test Peridynamics.calc_stable_timestep(body, mat, sf) == Δt
else
    @warn "Test omitted! Threads.nthreads() should be <= 2"
end
