"""
mm1.jl - first multimode experiment
"""

WDIR = joinpath(@__DIR__, "../..")
include(joinpath(WDIR, "src", "mm", "mm.jl"))

using Altro
using CUDA
using ForwardDiff
using HDF5
using LinearAlgebra
using RobotDynamics
using SparseArrays
using StaticArrays
using TrajectoryOptimization
const RD = RobotDynamics
const TO = TrajectoryOptimization

# paths
const EXPERIMENT_META = "mm"
const EXPERIMENT_NAME = "mm1"
const SAVE_PATH = abspath(joinpath(WDIR, "out", EXPERIMENT_META, EXPERIMENT_NAME))

# problem
const CONTROL_COUNT = 4
const STATE_COUNT = 1
const ASTATE_SIZE_BASE = STATE_COUNT * HDIM_ISO + 2 * CONTROL_COUNT
const ACONTROL_SIZE = CONTROL_COUNT #+ 1
# state indices
const STATE1_IDX = 1:HDIM_ISO
const CONTROLS_IDX = STATE1_IDX[end] + 1:STATE1_IDX[end] + CONTROL_COUNT
const DCONTROLS_IDX = CONTROLS_IDX[end] + 1:CONTROLS_IDX[end] + CONTROL_COUNT
const ASTATE_IDX = Array(1:DCONTROLS_IDX[end])
# control indices
const D2CONTROLS_IDX = 1:CONTROL_COUNT
const DT_IDX = D2CONTROLS_IDX[end] + 1:D2CONTROLS_IDX[end] + 1
const ACONTROL_IDX = Array(1:D2CONTROLS_IDX[end])

# model
struct Model{TH,Ts} <: AbstractModel
    H_tmp::Vector{TH}
    state_tmp::Vector{Ts}
end
function Model(M_, V_)
    H_tmp = [M_(zeros(HDIM_ISO, HDIM_ISO)) for i = 1:5]
    TH = typeof(H_tmp[1])
    state_tmp = [V_(zeros(HDIM_ISO)) for i = 1:2]
    Ts = typeof(state_tmp[1])
    return Model{TH,Ts}(H_tmp, state_tmp)
end
@inline RD.state_dim(::Model) = ASTATE_SIZE_BASE
@inline RD.control_dim(::Model) = ACONTROL_SIZE
# vector and matrix constructors (use CPU arrays)
@inline M(mat_) = CuArray(mat_)
@inline V(vec_) = CuArray(vec_)

# dynamics
abstract type EXP <: RD.Explicit end

const NEGI_H0ROT_ISO_ = M(NEGI_H0ROT_ISO)
const NEGI_H1R_ISO_ = M(NEGI_H1R_ISO)
const NEGI_H1I_ISO_ = M(NEGI_H1I_ISO)
const NEGI_H2R_ISO_ = M(NEGI_H2R_ISO)
const NEGI_H2I_ISO_ = M(NEGI_H2I_ISO)

function RD.discrete_dynamics!(astate_::AbstractVector, ::Type{EXP}, model::Model,
                               astate::AbstractVector,
                               acontrol::AbstractVector, time::Real, dt::Real)
    # get hamiltonian and unitary
    H = model.H_tmp[1]
    H1r = model.H_tmp[2] .= NEGI_H1R_ISO_
    lmul!(astate[CONTROLS_IDX[1]], H1r)
    H1i = model.H_tmp[3] .= NEGI_H1I_ISO_
    lmul!(astate[CONTROLS_IDX[2]], H1i)
    H2r = model.H_tmp[4] .= NEGI_H2R_ISO_
    lmul!(astate[CONTROLS_IDX[3]], H2r)
    H2i = model.H_tmp[5] .= NEGI_H2I_ISO_
    lmul!(astate[CONTROLS_IDX[4]], H2i)
    for i in eachindex(H)
        H[i] = NEGI_H0ROT_ISO_[i] + H1r[i] + H1i[i] + H2r[i] + H2i[i]
    end
    lmul!(dt, H)
    U = exp_(H)
    # propagate state
    mul!(astate_[STATE1_IDX], U, astate[STATE1_IDX])
    # propagate controls
    astate_[CONTROLS_IDX] .= astate[DCONTROLS_IDX]
    astate_[CONTROLS_IDX] .*= dt
    astate_[CONTROLS_IDX] .+= astate[CONTROLS_IDX]
    # propagate dcontrols
    astate_[DCONTROLS_IDX] .= acontrol[D2CONTROLS_IDX]
    astate_[DCONTROLS_IDX] .*= dt
    astate_[DCONTROLS_IDX] .+= astate[DCONTROLS_IDX]
    return nothing
end

function RD.discrete_jacobian!(D::AbstractMatrix, A::AbstractMatrix, B::AbstractMatrix,
                               ::Type{EXP}, model::Model, astate::AbstractVector,
                               acontrol::AbstractVector, time::Real, dt::Real,
                               ix::AbstractVector, iu::AbstractVector)
    # get hamiltonian and unitary
    H = model.H_tmp[1]
    H1r = model.H_tmp[2] .= NEGI_H1R_ISO_
    lmul!(astate[CONTROLS_IDX[1]], H1r)
    H1i = model.H_tmp[3] .= NEGI_H1I_ISO_
    lmul!(astate[CONTROLS_IDX[2]], H1i)
    H2r = model.H_tmp[4] .= NEGI_H2R_ISO_
    lmul!(astate[CONTROLS_IDX[3]], H2r)
    H2i = model.H_tmp[5] .= NEGI_H2I_ISO_
    lmul!(astate[CONTROLS_IDX[4]], H2i)
    for i in eachindex(H)
        H[i] = NEGI_H0ROT_ISO_[i] + H1r[i] + H1i[i] + H2r[i] + H2i[i]
    end
    lmul!(dt, H)
    U = exp_(H)
    # get state at this time step and next
    state1k = model.state_tmp[1] .= astate[STATE1_IDX]
    state1kp = model.state_tmp[2]
    mul!(state1kp, U, state1k)
    # state1 modifications
    A[STATE1_IDX, STATE1_IDX] .= U
    H1r .= NEGI_H1R_ISO_
    lmul!(dt, H1r)
    mul!(A[STATE1_IDX, CONTROLS_IDX[1]], exp_frechet!(H, H1r), state1k)
    H1i .= NEGI_H1I_ISO_
    lmul!(dt, H1i)
    mul!(A[STATE1_IDX, CONTROLS_IDX[2]], exp_frechet!(H, H1i; reuse_UV=true), state1k)
    H2r .= NEGI_H1I_ISO_
    lmul!(dt, H2r)
    mul!(A[STATE1_IDX, CONTROLS_IDX[3]], exp_frechet!(H, H2r; reuse_UV=true), state1k)
    H2i .= NEGI_H2I_ISO_
    lmul!(dt, H2i)
    mul!(A[STATE1_IDX, CONTROLS_IDX[4]], exp_frechet!(H, H2i; reuse_UV=true), state1k)
    for i = 1:CONTROL_COUNT
        # control modifications
        A[CONTROLS_IDX[i], CONTROLS_IDX[i]] = 1
        A[CONTROLS_IDX[i], DCONTROLS_IDX[i]] = dt
        # dcontrol modifications
        A[DCONTROLS_IDX[i], DCONTROLS_IDX[i]] = 1
        B[DCONTROLS_IDX[i], D2CONTROLS_IDX[i]] = dt
    end
end


function run_traj(;fock_state=0, evolution_time=200., dt_inv=1., verbose=true,
                  sqrtbp=false, derivative_order=0,
                  qs=[1e0, 1e-1, 1e-1, 1e-1],
                  smoke_test=false, constraint_tol=1e-8, al_tol=1e-4,
                  pn_steps=2, max_penalty=1e11, save=true, max_iterations=Int64(2e5),
                  max_cost_value=1e8, benchmark=false, static_bp=false)
    model = Model(M, V)
    n_ = state_dim(model)
    m_ = control_dim(model)
    t0 = 0.

    # initial state
    x0 = zeros(n_)
    x0[STATE1_IDX] = IS1_ISO
    x0 = V(x0)

    # target state
    xf = zeros(n_)
    cavity_state = zeros(CAVITY_STATE_COUNT)
    cavity_state[fock_state + 1] = 1
    xf[STATE1_IDX] = get_vec_iso(kron(cavity_state, TRANSMON_G))
    xf = V(xf)

    # control amplitude constraint at boundary
    x_max = fill(Inf, n_)
    x_max[CONTROLS_IDX[1:2]] .= MAX_AMP_NORM_TRANSMON
    x_max[CONTROLS_IDX[3:4]] .= MAX_AMP_NORM_CAVITY
    x_max = V(x_max)
    u_max = V(fill(Inf, m_))
    x_min = fill(-Inf, n_)
    x_min[CONTROLS_IDX[1:2]] .= -MAX_AMP_NORM_TRANSMON
    x_min[CONTROLS_IDX[3:4]] .= -MAX_AMP_NORM_CAVITY
    x_min = V(x_min)
    u_min = V(fill(-Inf, m_))
    # control amplitude constraint at boundary
    x_max_boundary = fill(Inf, n_)
    x_max_boundary[CONTROLS_IDX] .= 0
    x_max_boundary = V(x_max_boundary)
    u_max_boundary = V(fill(Inf, m_))
    x_min_boundary = fill(-Inf, n_)
    x_min_boundary[CONTROLS_IDX] .= 0
    x_min_boundary = V(x_min_boundary)
    u_min_boundary = V(fill(-Inf, m_))

    # initial trajectory
    N_ = Int(floor(evolution_time * dt_inv)) + 1
    X0 = [V(zeros(n_)) for k = 1:N_]
    X0[1] .= x0
    U0 = [V([
        fill(1e-6, 2);
        fill(1e-6, 2);
    ]) for k = 1:N_-1]
    dt = dt_inv^(-1)
    ts = V(zeros(N_))
    ts[1] = t0
    for k = 1:N_-1
        ts[k + 1] = ts[k] + dt
        RD.discrete_dynamics!(X0[k + 1], EXP, model, X0[k], U0[k], ts[k], dt)
    end
    
    # cost function
    Q = V(zeros(n_))
    Q[STATE1_IDX] .= qs[1]
    Q[CONTROLS_IDX] .= qs[2]
    Q[DCONTROLS_IDX] .= qs[3]
    # Q = Diagonal(SVector{n_}(Q))
    Q = Diagonal(Q)
    Qf = Q * N_
    R = V(zeros(m_))
    R[D2CONTROLS_IDX] .= qs[4]
    # R = Diagonal(SVector{m_}(R))
    R = Diagonal(R)
    objective = LQRObjective(Q, Qf, R, xf, n_, m_, N_, M, V)

    # must satisfy control amplitude constraints
    control_amp = BoundConstraint(n_, m_, x_max, x_min, u_max, u_min, M, V)
    # must statisfy controls start and stop at 0
    control_amp_boundary = BoundConstraint(n_, m_, x_max_boundary, x_min_boundary,
                                           u_max_boundary, u_min_boundary, M, V)
    # must reach target state, must have integral of controls = 0
    target_astate_constraint = GoalConstraint(n_, m_, xf, STATE1_IDX, M, V)

    constraints = TO.ConstraintList()
    add_constraint!(constraints, control_amp, V(2:N_-2))
    add_constraint!(constraints, control_amp_boundary, V(1:1))
    add_constraint!(constraints, control_amp_boundary, V(N_-1:N_-1))
    add_constraint!(constraints, target_astate_constraint, V(N_:N_))
    
    prob = Problem(EXP, model, objective, constraints, X0, U0, ts, N_, M, V)
    solver = AugmentedLagrangianSolver(prob)
    verbose_pn = verbose ? true : false
    verbose_ = verbose ? 2 : 0
    iterations_inner = smoke_test ? 1 : 300
    iterations_outer = smoke_test ? 1 : 30
    n_steps = smoke_test ? 1 : pn_steps
    set_options!(solver, square_root=sqrtbp, constraint_tolerance=constraint_tol,
                 projected_newton_tolerance=al_tol, n_steps=n_steps,
                 penalty_max=max_penalty, verbose_pn=verbose_pn, verbose=verbose_,
                 projected_newton=true, iterations_inner=iterations_inner,
                 iterations_outer=iterations_outer, iterations=max_iterations,
                 max_cost_value=max_cost_value, static_bp=static_bp,
                 gradient_tolerance=1e-4)
    if benchmark
        benchmark_result = Altro.benchmark_solve!(solver)
    else
        benchmark_result = nothing
        Altro.solve!(solver)
    end

    # post-process
    acontrols_raw = TO.controls(solver)
    acontrols_arr = permutedims(reduce(hcat, map(Array, acontrols_raw)), [2, 1])
    astates_raw = TO.states(solver)
    astates_arr = permutedims(reduce(hcat, map(Array, astates_raw)), [2, 1])
    Q_raw = Array(Q)
    Q_arr = [Q_raw[i, i] for i in 1:size(Q_raw)[1]]
    Qf_raw = Array(Qf)
    Qf_arr = [Qf_raw[i, i] for i in 1:size(Qf_raw)[1]]
    R_raw = Array(R)
    R_arr = [R_raw[i, i] for i in 1:size(R_raw)[1]]
    cidx_arr = Array(CONTROLS_IDX)
    d2cidx_arr = Array(D2CONTROLS_IDX)
    # cmax = TO.max_violation(solver)
    # cmax_info = TO.findmax_violation(TO.get_constraints(solver))
    cmax = cmax_info = 0
    iterations_ = Altro.iterations(solver)

    result = Dict(
        "acontrols" => acontrols_arr,
        "controls_idx" => cidx_arr,
        "d2controls_dt2_idx" => d2cidx_arr,
        "evolution_time" => evolution_time,
        "astates" => astates_arr,
        "Q" => Q_arr,
        "Qf" => Qf_arr,
        "R" => R_arr,
        "cmax" => cmax,
        "cmax_info" => cmax_info,
        "dt" => dt,
        "derivative_order" => derivative_order,
        "sqrtbp" => Integer(sqrtbp),
        "max_penalty" => max_penalty,
        "constraint_tol" => constraint_tol,
        "al_tol" => al_tol,
        "save_type" => Integer(jl),
        "iterations" => iterations_,
        "max_iterations" => max_iterations,
        "pn_steps" => pn_steps,
        "max_cost_value" => max_cost_value,
        "static_bp" => Integer(static_bp),
    )
    
    # save
    if save
        save_file_path = generate_file_path("h5", EXPERIMENT_NAME, SAVE_PATH)
        println("Saving this optimization to $(save_file_path)")
        h5open(save_file_path, "cw") do save_file
            for key in keys(result)
                write(save_file, key, result[key])
            end
        end
        result["save_file_path"] = save_file_path
    end

    result = benchmark ? benchmark_result : result

    return result
end
