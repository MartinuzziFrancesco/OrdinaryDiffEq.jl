const ROSENBROCK_INV_CUTOFF = 7 # https://github.com/SciML/OrdinaryDiffEq.jl/pull/1539

struct StaticWOperator{isinv, T}
    W::T
    function StaticWOperator(W::T,callinv = true) where T
        isinv = size(W, 1) <= ROSENBROCK_INV_CUTOFF

        # when constructing W for the first time for the type
        # inv(W) can be singular
        _W = if isinv && callinv
          inv(W)
        else
          W
        end
        new{isinv, T}(_W)
    end
end
isinv(W::StaticWOperator{S}) where S = S
Base.:\(W::StaticWOperator, v) = isinv(W) ? W.W * v : W.W \ v

function calc_tderivative!(integrator, cache, dtd1, repeat_step)
  @inbounds begin
    @unpack t,dt,uprev,u,f,p = integrator
    @unpack du2,fsalfirst,dT,tf,linsolve_tmp = cache

    # Time derivative
    if !repeat_step # skip calculation if step is repeated
      if DiffEqBase.has_tgrad(f)
        f.tgrad(dT, uprev, p, t)
      else
        tf.uprev = uprev
        tf.p = p
        derivative!(dT, tf, t, du2, integrator, cache.grad_config)
      end
    end

    @.. broadcast=false linsolve_tmp = fsalfirst + dtd1*dT
  end
end

function calc_tderivative!(integrator::ODEIntegrator{algType,IIP,<:Array}, cache, dtd1, repeat_step) where {algType,IIP}
  @inbounds begin
    @unpack t,dt,uprev,u,f,p = integrator
    @unpack du2,fsalfirst,dT,tf,linsolve_tmp = cache

    # Time derivative
    if !repeat_step # skip calculation if step is repeated
      if DiffEqBase.has_tgrad(f)
        f.tgrad(dT, uprev, p, t)
      else
        tf.uprev = uprev
        if !(p isa DiffEqBase.NullParameters)
          tf.p = p
        end
        derivative!(dT, tf, t, du2, integrator, cache.grad_config)
      end
    end

    @inbounds @simd ivdep for i in eachindex(uprev)
      linsolve_tmp[i] = fsalfirst[i] + dtd1*dT[i]
    end
  end
end

function calc_tderivative(integrator, cache)
  @unpack t,dt,uprev,u,f,p = integrator

  # Time derivative
  if DiffEqBase.has_tgrad(f)
    dT = f.tgrad(uprev, p, t)
  else
    tf = cache.tf
    tf.u = uprev
    tf.p = p
    dT = derivative(tf, t, integrator)
  end
  dT
end

"""
    calc_J(integrator, cache)

Return a new Jacobian object.

If `integrator.f` has a custom Jacobian update function, then it will be called. Otherwise,
either automatic or finite differencing will be used depending on the `uf` object of the
cache.
"""
function calc_J(integrator, cache)
  @unpack t,uprev,f,p,alg = integrator

  if alg isa DAEAlgorithm
    if DiffEqBase.has_jac(f)
      J = f.jac(duprev, uprev, p, t)
    else
      @unpack uf = cache
      x = zero(uprev)
      J = jacobian(uf, x, integrator)
    end
  else
    if DiffEqBase.has_jac(f)
      J = f.jac(uprev, p, t)
    else
      @unpack uf = cache

      uf.f = nlsolve_f(f, alg)
      uf.p = p
      uf.t = t

      J = jacobian(uf, uprev, integrator)
    end

    integrator.destats.njacs += 1

    if alg isa CompositeAlgorithm
      integrator.eigen_est = constvalue(opnorm(J, Inf))
    end
  end

  J
end

"""
    calc_J!(J, integrator, cache) -> J

Update the Jacobian object `J`.

If `integrator.f` has a custom Jacobian update function, then it will be called. Otherwise,
either automatic or finite differencing will be used depending on the `cache`.
"""
function calc_J!(J, integrator, cache)
  @unpack t,uprev,f,p,alg = integrator

  if alg isa DAEAlgorithm
    if DiffEqBase.has_jac(f)
      duprev = integrator.duprev
      uf = cache.uf
      f.jac(J, duprev, uprev, p, uf.α * uf.invγdt, t)
    else
      @unpack du1, uf, jac_config = cache
      # using `dz` as temporary array
      x = cache.dz
      fill!(x, zero(eltype(x)))
      jacobian!(J, uf, x, du1, integrator, jac_config)
    end
  else
    if DiffEqBase.has_jac(f)
      f.jac(J, uprev, p, t)
    else
      @unpack du1, uf, jac_config = cache

      uf.f = nlsolve_f(f, alg)
      uf.t = t
      if !(p isa DiffEqBase.NullParameters)
        uf.p = p
      end

      jacobian!(J, uf, uprev, du1, integrator, jac_config)
    end

    integrator.destats.njacs += 1

    if alg isa CompositeAlgorithm
      integrator.eigen_est = constvalue(opnorm(J, Inf))
    end
  end

  return nothing
end

"""
    WOperator(mass_matrix,gamma,J[;transform=false])

A linear operator that represents the W matrix of an ODEProblem, defined as

```math
W = MM - \\gamma J
```

or, if `transform=true`:

```math
W = \\frac{1}{\\gamma}MM - J
```

where `MM` is the mass matrix (a regular `AbstractMatrix` or a `UniformScaling`),
`γ` is a real number proportional to the time step, and `J` is the Jacobian
operator (must be a `AbstractDiffEqLinearOperator`). A `WOperator` can also be
constructed using a `*DEFunction` directly as

    WOperator(f,gamma[;transform=false])

`f` needs to have a jacobian and `jac_prototype`, but the prototype does not need
to be a diffeq operator --- it will automatically be converted to one.

`WOperator` supports lazy `*` and `mul!` operations, the latter utilizing an
internal cache (can be specified in the constructor; default to regular `Vector`).
It supports all of `AbstractDiffEqLinearOperator`'s interface.
"""
mutable struct WOperator{IIP,T,
  MType,
  GType,
  JType,
  F,
  C,
  JV} <: DiffEqBase.AbstractDiffEqLinearOperator{T}
  mass_matrix::MType
  gamma::GType
  J::JType
  transform::Bool          # true => W = mm/gamma - J; false => W = mm - gamma*J
  _func_cache::F           # cache used in `mul!`
  _concrete_form::C        # non-lazy form (matrix/number) of the operator
  jacvec::JV

  function WOperator{IIP}(mass_matrix, gamma, J, u, jacvec = nothing; transform=false) where IIP
    # TODO: there is definitely a missing interface.
    # Tentative interface: `has_concrete` and `concertize(A)`
    if J isa Union{Number,DiffEqScalar}
      if transform
        _concrete_form = -mass_matrix / gamma + convert(Number,J)
      else
        _concrete_form = -mass_matrix + gamma * convert(Number,J)
      end
      _func_cache = nothing
    else
      AJ = J isa DiffEqArrayOperator ? convert(AbstractMatrix, J) : J
      if AJ isa AbstractMatrix
        mm = mass_matrix isa DiffEqArrayOperator ? convert(AbstractMatrix, mass_matrix) : mass_matrix
        if transform
          _concrete_form = -mm / gamma + AJ
        else
          _concrete_form = -mm + gamma * AJ
        end
      else
        _concrete_form = nothing
      end
      _func_cache = zero(u)
    end
    T = eltype(_concrete_form)
    MType = typeof(mass_matrix)
    GType = typeof(gamma)
    JType = typeof(J)
    F = typeof(_func_cache)
    C = typeof(_concrete_form)
    JV = typeof(jacvec)
    return new{IIP,T,MType,GType,JType,F,C,JV}(mass_matrix,gamma,J,transform,_func_cache,_concrete_form,jacvec)
  end
end
function WOperator{IIP}(f, u, gamma; transform=false) where IIP
  if isa(f, Union{SplitFunction, DynamicalODEFunction})
    error("WOperator does not support $(typeof(f)) yet")
  end
  mass_matrix = f.mass_matrix
  # TODO: does this play nicely with time-state dependent mass matrix?
  if !isa(mass_matrix, Union{AbstractMatrix,UniformScaling})
    mass_matrix = convert(AbstractMatrix, mass_matrix)
  end
  # Convert jacobian, if needed
  J = deepcopy(f.jac_prototype)
  if J isa AbstractMatrix
    @assert DiffEqBase.has_jac(f) "f needs to have an associated jacobian"
    J = DiffEqArrayOperator(J; update_func=f.jac)
  end
  return WOperator{IIP}(mass_matrix, gamma, J, u; transform=transform)
end

SciMLBase.isinplace(::WOperator{IIP}, i) where IIP = IIP
Base.eltype(W::WOperator) = eltype(W.J)

set_gamma!(W::WOperator, gamma) = (W.gamma = gamma; W)
function DiffEqBase.update_coefficients!(W::WOperator,u,p,t)
  update_coefficients!(W.J,u,p,t)
  update_coefficients!(W.mass_matrix,u,p,t)
  W.jacvec !== nothing && update_coefficients!(W.jacvec,u,p,t)
  W
end

function DiffEqBase.update_coefficients!(J::SparseDiffTools.JacVec,u,p,t)
  copyto!(J.x,u)
  J.f.t = t
  J.f.p = p
end

function Base.convert(::Type{AbstractMatrix}, W::WOperator{IIP}) where IIP
  if !IIP
    # Allocating
    if W.transform
      W._concrete_form = -W.mass_matrix / W.gamma + convert(AbstractMatrix,W.J)
    else
      W._concrete_form = -W.mass_matrix + W.gamma * convert(AbstractMatrix,W.J)
    end
  else
    # Non-allocating already updated
    #_W = W._concrete_form
    #jacobian2W!(_W, W.mass_matrix, W.gamma, W.J, W.transform)
  end
  return W._concrete_form
end
function Base.convert(::Type{Number}, W::WOperator)
  if W.transform
    W._concrete_form = -W.mass_matrix / W.gamma + convert(Number,W.J)
  else
    W._concrete_form = -W.mass_matrix + W.gamma * convert(Number,W.J)
  end
  return W._concrete_form
end
Base.size(W::WOperator, args...) = size(W.J, args...)
function Base.getindex(W::WOperator, i::Int)
  if W.transform
    -W.mass_matrix[i] / W.gamma + W.J[i]
  else
    -W.mass_matrix[i] + W.gamma * W.J[i]
  end
end
function Base.getindex(W::WOperator, I::Vararg{Int,N}) where {N}
  if W.transform
    -W.mass_matrix[I...] / W.gamma + W.J[I...]
  else
    -W.mass_matrix[I...] + W.gamma * W.J[I...]
  end
end
function Base.:*(W::WOperator, x::Union{AbstractVecOrMat,Number})
  if W.transform
    (W.mass_matrix*x) / -W.gamma + W.J*x
  else
    -W.mass_matrix*x + W.gamma * (W.J*x)
  end
end
function Base.:\(W::WOperator, x::AbstractVecOrMat)
  if size(W) == () # scalar operator
    convert(Number,W) \ x
  else
    convert(AbstractMatrix,W) \ x
  end
end
function Base.:\(W::WOperator, x::Number)
  if size(W) == () # scalar operator
    convert(Number,W) \ x
  else
    convert(AbstractMatrix,W) \ x
  end
end

function LinearAlgebra.mul!(Y::AbstractVecOrMat, W::WOperator, B::AbstractVecOrMat)
  if W.transform
    # Compute mass_matrix * B
    if isa(W.mass_matrix, UniformScaling)
      a = -W.mass_matrix.λ / W.gamma
      @.. broadcast=false Y = a * B
    else
      mul!(_vec(Y), W.mass_matrix, _vec(B))
      lmul!(-1/W.gamma, Y)
    end
    # Compute J * B and add
    if W.jacvec !== nothing
      mul!(_vec(W._func_cache), W.jacvec, _vec(B))
    else
      mul!(_vec(W._func_cache), W.J, _vec(B))
    end
    _vec(Y) .+= _vec(W._func_cache)
  else
    # Compute mass_matrix * B
    if isa(W.mass_matrix, UniformScaling)
      vY = _vec(Y)
      vB = _vec(B)
      @.. broadcast=false vY = W.mass_matrix.λ * vB
    else
      mul!(_vec(Y), W.mass_matrix, _vec(B))
    end
    # Compute J * B
    if W.jacvec !== nothing
      mul!(_vec(W._func_cache), W.jacvec, _vec(B))
    else
      mul!(_vec(W._func_cache), W.J, _vec(B))
    end
    # Add result
    axpby!(W.gamma, _vec(W._func_cache), -one(W.gamma), _vec(Y))
  end
end

"""
    islinearfunction(integrator) -> Tuple{Bool,Bool}

return the tuple `(is_linear_wrt_odealg, islinearodefunction)`.
"""
islinearfunction(integrator) = islinearfunction(integrator.f, integrator.alg)

"""
    islinearfunction(f, alg) -> Tuple{Bool,Bool}

return the tuple `(is_linear_wrt_odealg, islinearodefunction)`.
"""
function islinearfunction(f, alg)::Tuple{Bool,Bool}
  isode = f isa ODEFunction && islinear(f.f)
  islin = isode || (alg isa SplitAlgorithms && f isa SplitFunction && islinear(f.f1.f))
  return islin, isode
end

function do_newJW(integrator, alg, nlsolver, repeat_step)::NTuple{2,Bool}
  integrator.iter <= 1 && return true, true # at least one JW eval at the start
  repeat_step && return false, false
  islin, _ = islinearfunction(integrator)
  islin && return false, false # no further JW eval when it's linear
  !integrator.opts.adaptive && return true, true # Not adaptive will always refactorize
  alg isa DAEAlgorithm && return true, true
  isnewton(nlsolver) || return true, true
  isfirstcall(nlsolver) && return true, true
  isfs = isfirststage(nlsolver)
  iszero(nlsolver.fast_convergence_cutoff) && return isfs, isfs
  W_iγdt = inv(nlsolver.cache.W_γdt)
  iγdt = inv(nlsolver.γ * integrator.dt)
  smallstepchange = abs(iγdt/W_iγdt - 1) <= get_new_W_γdt_cutoff(nlsolver)
  jbad = nlsolver.status === TryAgain && smallstepchange
  errorfail = integrator.EEst > one(integrator.EEst)
  return jbad, (jbad || (!smallstepchange) || (isfs && errorfail))
end

@noinline _throwWJerror(W, J) = throw(DimensionMismatch("W: $(axes(W)), J: $(axes(J))"))
@noinline _throwWMerror(W, mass_matrix) = throw(DimensionMismatch("W: $(axes(W)), mass matrix: $(axes(mass_matrix))"))
@noinline _throwJMerror(J, mass_matrix) = throw(DimensionMismatch("J: $(axes(J)), mass matrix: $(axes(mass_matrix))"))

function jacobian2W!(W::AbstractMatrix, mass_matrix::MT, dtgamma::Number, J::AbstractMatrix, W_transform::Bool)::Nothing where MT
  # check size and dimension
  iijj = axes(W)
  @boundscheck (iijj == axes(J) && length(iijj) == 2) || _throwWJerror(W, J)
  mass_matrix isa UniformScaling || @boundscheck axes(mass_matrix) == axes(W) || _throwWMerror(W, mass_matrix)
  @inbounds if W_transform
    invdtgamma = inv(dtgamma)
    if MT <: UniformScaling
      copyto!(W, J)
      idxs = diagind(W)
      λ = -mass_matrix.λ
      if ArrayInterface.fast_scalar_indexing(J) && ArrayInterface.fast_scalar_indexing(W)
          @inbounds for i in 1:size(J,1)
              W[i,i] = muladd(λ, invdtgamma, J[i,i])
          end
      else
          @.. broadcast=false @view(W[idxs]) = muladd(λ, invdtgamma, @view(J[idxs]))
      end
    else
      @.. broadcast=false W = muladd(-mass_matrix, invdtgamma, J)
    end
  else
    if MT <: UniformScaling
      λ = -mass_matrix.λ
      if W isa AbstractSparseMatrix && !(W isa SparseMatrixCSC)
        # This is specifically to catch the GPU sparse matrix cases
        # Which do not support diagonal indexing
        # https://github.com/JuliaGPU/CUDA.jl/issues/1395
        Wn = nonzeros(W)
        Jn = nonzeros(J)
        @.. broadcast=false Wn = dtgamma*Jn
        W .= W + λ*I
      else
        idxs = diagind(W)
        @.. broadcast=false W = dtgamma*J
        @.. broadcast=false @view(W[idxs]) = @view(W[idxs]) + λ
      end
    else
      @.. broadcast=false W = muladd(dtgamma, J, -mass_matrix)
    end
  end
  return nothing
end

function jacobian2W!(W::Matrix, mass_matrix::MT, dtgamma::Number, J::Matrix, W_transform::Bool)::Nothing where MT
  # check size and dimension
  iijj = axes(W)
  @boundscheck (iijj == axes(J) && length(iijj) == 2) || _throwWJerror(W, J)
  mass_matrix isa UniformScaling || @boundscheck axes(mass_matrix) == axes(W) || _throwWMerror(W, mass_matrix)
  @inbounds if W_transform
    invdtgamma = inv(dtgamma)
    if MT <: UniformScaling
      copyto!(W, J)
      idxs = diagind(W)
      λ = -mass_matrix.λ
      @inbounds for i in 1:size(J,1)
          W[i,i] = muladd(λ, invdtgamma, J[i,i])
      end
    else
      @inbounds @simd ivdep for i in eachindex(W)
        W[i] = muladd(-mass_matrix[i], invdtgamma, J[i])
      end
    end
  else
    if MT <: UniformScaling
      idxs = diagind(W)
      @inbounds @simd ivdep for i in eachindex(W)
        W[i] = dtgamma*J[i]
      end
      λ = -mass_matrix.λ
      @inbounds for i in idxs
        W[i] = W[i] + λ
      end
    else
      @inbounds @simd ivdep for i in eachindex(W)
        W[i] = muladd(dtgamma, J[i], -mass_matrix[i])
      end
    end
  end
  return nothing
end

function jacobian2W(mass_matrix::MT, dtgamma::Number, J::AbstractMatrix, W_transform::Bool)::Nothing where MT
  # check size and dimension
  mass_matrix isa UniformScaling || @boundscheck axes(mass_matrix) == axes(J) || _throwJMerror(J, mass_matrix)
  @inbounds if W_transform
    invdtgamma = inv(dtgamma)
    if MT <: UniformScaling
      λ = -mass_matrix.λ
      W = J + (λ * invdtgamma)*I
    else
      W = muladd(-mass_matrix, invdtgamma, J)
    end
  else
    if MT <: UniformScaling
      λ = -mass_matrix.λ
      W = dtgamma*J + λ*I
    else
      W = muladd(dtgamma, J, -mass_matrix)
    end
  end
  return W
end

function calc_W!(W, integrator, nlsolver::Union{Nothing,AbstractNLSolver}, cache, dtgamma, repeat_step, W_transform=false)
  @unpack t,dt,uprev,u,f,p = integrator
  lcache = nlsolver === nothing ? cache : nlsolver.cache
  @unpack J = lcache
  isdae = integrator.alg isa DAEAlgorithm
  alg = unwrap_alg(integrator, true)
  if !isdae
    mass_matrix = integrator.f.mass_matrix
  end
  is_compos = integrator.alg isa CompositeAlgorithm

  # handle Wfact
  if W_transform && DiffEqBase.has_Wfact_t(f)
    f.Wfact_t(W, u, p, dtgamma, t)
    isnewton(nlsolver) && set_W_γdt!(nlsolver, dtgamma)
    is_compos && (integrator.eigen_est = constvalue(opnorm(LowerTriangular(W), Inf)) + inv(dtgamma)) # TODO: better estimate
    return nothing
  elseif !W_transform && DiffEqBase.has_Wfact(f)
    f.Wfact(W, u, p, dtgamma, t)
    isnewton(nlsolver) && set_W_γdt!(nlsolver, dtgamma)
    if is_compos
      opn = opnorm(LowerTriangular(W), Inf)
      integrator.eigen_est = (constvalue(opn) + one(opn)) / dtgamma # TODO: better estimate
    end
    return nothing
  end

  # check if we need to update J or W
  new_jac, new_W = do_newJW(integrator, alg, nlsolver, repeat_step)

  if new_jac && isnewton(lcache)
    lcache.J_t = t
    if isdae
      lcache.uf.α = nlsolver.α
      lcache.uf.invγdt = inv(dtgamma)
      lcache.uf.tmp = nlsolver.tmp
    end
  end

  # calculate W
  if W isa WOperator
    isnewton(nlsolver) || DiffEqBase.update_coefficients!(W,uprev,p,t) # we will call `update_coefficients!` in NLNewton
    W.transform = W_transform; set_gamma!(W, dtgamma)
    if W.J !== nothing && !(W.J isa SparseDiffTools.JacVec) && !(W.J isa SciMLBase.AbstractDiffEqLinearOperator)
      islin, isode = islinearfunction(integrator)
      islin ? (J = isode ? f.f : f.f1.f) : ( new_jac && (calc_J!(W.J, integrator, lcache)) )
      new_W && !isdae && jacobian2W!(W._concrete_form, mass_matrix, dtgamma, J, W_transform)
    end
  else # concrete W using jacobian from `calc_J!`
    islin, isode = islinearfunction(integrator)
    islin ? (J = isode ? f.f : f.f1.f) : ( new_jac && (calc_J!(J, integrator, lcache)) )
    update_coefficients!(W,uprev,p,t)
    new_W && !isdae && jacobian2W!(W, mass_matrix, dtgamma, J, W_transform)
  end
  if isnewton(nlsolver)
    set_new_W!(nlsolver, new_W)
    if new_jac && isdae
      set_W_γdt!(nlsolver, nlsolver.α * inv(dtgamma))
    elseif new_W && !isdae
      set_W_γdt!(nlsolver, dtgamma)
    end
  end
  new_W && (integrator.destats.nw += 1)
  return new_W
end

@noinline function calc_W(integrator, nlsolver, dtgamma, repeat_step, W_transform=false)
  @unpack t,uprev,p,f = integrator

  # Handle Rosenbrock has no nlsolver so passes cache directly
  cache = nlsolver isa OrdinaryDiffEqCache ? nlsolver : nlsolver.cache

  isdae = integrator.alg isa DAEAlgorithm
  if !isdae
    mass_matrix = integrator.f.mass_matrix
  end
  isarray = uprev isa AbstractArray
  # calculate W
  is_compos = integrator.alg isa CompositeAlgorithm
  islin, isode = islinearfunction(integrator)
  !isdae && update_coefficients!(mass_matrix,uprev,p,t)

  if islin
    J = isode ? f.f : f.f1.f # unwrap the Jacobian accordingly
    W = WOperator{false}(mass_matrix, dtgamma, J, uprev; transform=W_transform)
  elseif DiffEqBase.has_jac(f)
    J = f.jac(uprev, p, t)
    if typeof(J) <: StaticArray && typeof(integrator.alg) <: Union{Rosenbrock23,Rodas4,Rodas4P,Rodas4P2,Rodas5,Rodas5P}
      W = W_transform ? J - mass_matrix*inv(dtgamma) :
                             dtgamma*J - mass_matrix
    else
      if !isa(J, DiffEqBase.AbstractDiffEqLinearOperator) && (!isnewton(nlsolver) || nlsolver.cache.W.J isa DiffEqBase.AbstractDiffEqLinearOperator)
        J = DiffEqArrayOperator(J)
      end
      W = WOperator{false}(mass_matrix, dtgamma, J, uprev, cache.W.jacvec; transform=W_transform)
    end
    integrator.destats.nw += 1
  else
    integrator.destats.nw += 1
    J = calc_J(integrator, cache)
    if isdae
      W = J
    else
      W_full = W_transform ? J - mass_matrix*inv(dtgamma) :
                             dtgamma*J - mass_matrix
      len = ArrayInterface.known_length(typeof(W_full))
      W = if W_full isa Number
        W_full
      elseif len !== nothing && typeof(integrator.alg) <: Union{Rosenbrock23,Rodas4,Rodas4P,Rodas4P2,Rodas5,Rodas5P}
        StaticWOperator(W_full)
      else
        DiffEqBase.default_factorize(W_full)
      end
    end
  end
  (W isa WOperator && unwrap_alg(integrator, true) isa NewtonAlgorithm) && (W = DiffEqBase.update_coefficients!(W,uprev,p,t)) # we will call `update_coefficients!` in NLNewton
  is_compos && (integrator.eigen_est = isarray ? constvalue(opnorm(J, Inf)) : integrator.opts.internalnorm(J, t))
  return W
end

function calc_rosenbrock_differentiation!(integrator, cache, dtd1, dtgamma, repeat_step, W_transform)
  nlsolver = nothing
  # we need to skip calculating `W` when a step is repeated
  new_W = false
  if !repeat_step
      new_W = calc_W!(cache.W, integrator, nlsolver, cache, dtgamma, repeat_step, W_transform)
  end
  calc_tderivative!(integrator, cache, dtd1, repeat_step)
  return new_W
end

# update W matrix (only used in Newton method)
update_W!(integrator, cache, dtgamma, repeat_step) =
  update_W!(cache.nlsolver, integrator, cache, dtgamma, repeat_step)

function update_W!(nlsolver::AbstractNLSolver, integrator, cache::OrdinaryDiffEqMutableCache, dtgamma, repeat_step)
  if isnewton(nlsolver)
    calc_W!(get_W(nlsolver), integrator, nlsolver, cache, dtgamma, repeat_step, true)
  end
  nothing
end

function update_W!(nlsolver::AbstractNLSolver, integrator, cache, dtgamma, repeat_step)
  if isnewton(nlsolver)
    isdae = integrator.alg isa DAEAlgorithm
    new_jac, new_W = true, true
    if isdae && new_jac
      lcache = nlsolver.cache
      lcache.uf.α = nlsolver.α
      lcache.uf.invγdt = inv(dtgamma)
      lcache.uf.tmp = @. nlsolver.tmp
      lcache.uf.uprev = @. integrator.uprev
    end
    nlsolver.cache.W = calc_W(integrator, nlsolver, dtgamma, repeat_step, true)
    #TODO: jacobian reuse for oop
    new_jac && (nlsolver.cache.J_t = integrator.t)
    set_new_W!(nlsolver, new_W)
    if new_jac && isdae
      set_W_γdt!(nlsolver, nlsolver.α * inv(dtgamma))
    elseif new_W && !isdae
      set_W_γdt!(nlsolver, dtgamma)
    end
  end
  nothing
end

function build_J_W(alg,u,uprev,p,t,dt,f::F,::Type{uEltypeNoUnits},::Val{IIP}) where {IIP,uEltypeNoUnits,F}
  islin, isode = islinearfunction(f, alg)
  if f.jac_prototype isa DiffEqBase.AbstractDiffEqLinearOperator
    W = WOperator{IIP}(f, u, dt)
    J = W.J
  elseif IIP && f.jac_prototype !== nothing && concrete_jac(alg) === nothing &&
        (alg.linsolve === nothing || alg.linsolve !== nothing &&
         LinearSolve.needs_concrete_A(alg.linsolve))

    # If factorization, then just use the jac_prototype
    J = similar(f.jac_prototype)
    W = similar(J)
  elseif (IIP && (concrete_jac(alg) === nothing || !concrete_jac(alg)) &&
                                    alg.linsolve !== nothing &&
                                    !LinearSolve.needs_concrete_A(alg.linsolve))
    # If the user has chosen GMRES but no sparse Jacobian, assume that the dense
    # Jacobian is a bad idea and create a fully matrix-free solver. This can
    # be overriden with concrete_jac.

    _f = islin ? (isode ? f.f : f.f1.f) : f
    jacvec = SparseDiffTools.JacVec(UJacobianWrapper(_f,t,p), copy(u), autodiff = alg_autodiff(alg))
    J = jacvec
    W = WOperator{IIP}(f.mass_matrix, dt, J, u, jacvec)

  elseif alg.linsolve !== nothing && !LinearSolve.needs_concrete_A(alg.linsolve) ||
         concrete_jac(alg) !== nothing && concrete_jac(alg)
    # The linear solver does not need a concrete Jacobian, but the user has
    # asked for one. This will happen when the Jacobian is used in the preconditioner
    # Thus setup JacVec and a concrete J, using sparsity when possible
    _f = islin ? (isode ? f.f : f.f1.f) : f
    J = if f.jac_prototype === nothing
      ArrayInterface.zeromatrix(u)
    else
      deepcopy(f.jac_prototype)
    end
    jacvec = SparseDiffTools.JacVec(UJacobianWrapper(_f,t,p), copy(u), autodiff = alg_autodiff(alg))
    W = WOperator{IIP}(f.mass_matrix, dt, J, u, jacvec)

  elseif islin || (!IIP && DiffEqBase.has_jac(f))
    J = islin ? (isode ? f.f : f.f1.f) : f.jac(uprev, p, t) # unwrap the Jacobian accordingly
    if !isa(J, DiffEqBase.AbstractDiffEqLinearOperator)
      J = DiffEqArrayOperator(J)
    end
    W = WOperator{IIP}(f.mass_matrix, dt, J, u)
  else
    J = if f.jac_prototype === nothing
      ArrayInterface.zeromatrix(u)
    else
      deepcopy(f.jac_prototype)
    end
    isdae = alg isa DAEAlgorithm
    W = if isdae
      J
    elseif IIP
      similar(J)
    else
      len = ArrayInterface.known_length(typeof(J))
      if len !== nothing && typeof(alg) <: Union{Rosenbrock23,Rodas4,Rodas4P,Rodas4P2,Rodas5,Rodas5P}
        StaticWOperator(J,false)
      else
        ArrayInterface.lu_instance(J)
      end
    end
  end
  return J, W
end

build_uf(alg,nf,t,p,::Val{true}) = UJacobianWrapper(nf,t,p)
build_uf(alg,nf,t,p,::Val{false}) = UDerivativeWrapper(nf,t,p)
