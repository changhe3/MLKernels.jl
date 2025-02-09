# Nystrom Approximation ====================================================================

for orientation in (:row, :col)
    (dim, S, fulldim) = orientation == :row ? (1, :S, :(:)) : (2, :(:), :S)

    @eval begin
        function samplematrix(
                σ::Val{$(Meta.quot(orientation))},
                X::Matrix,
                r::T
            ) where {T<:AbstractFloat}
            0 < r <= 1 || error("Sample rate must be in range (0,1]")
            n = size(X, $dim)
            s = max(Int64(trunc(n*r)),1)
            S = [rand(1:n) for i = 1:s]

        end

        function nystrom_sample(
                σ::Val{$(Meta.quot(orientation))},
                κ::Kernel{T},
                X::Matrix{T},
                S::Vector{U}
            ) where {T<:AbstractFloat,U<:Integer}
            Xs = getindex(X, $S, $fulldim)
            C = kernelmatrix(σ, κ, Xs, X)   # kernel matrix of X and sampled X
            Cs = getindex(C, :, S)  # purely sampled component of C
            return (C, Cs)
        end

    end
end

function nystrom_pinv!(
        Cs::Matrix{T},
        tol::T = eps(T)*size(Cs,1)
    ) where {T<:LinearAlgebra.BlasReal}
    # Compute eigendecomposition of sampled component of C
    QΛQᵀ = LinearAlgebra.eigen!(LinearAlgebra.Symmetric(Cs))

    # Solve for D = Λ^(-1/2) (pseudo inverse - use tolerance from before factorization)
    D = QΛQᵀ.values
    λ_tol = maximum(D)*tol

    for i in eachindex(D)
        @inbounds D[i] = abs(D[i]) <= λ_tol ? zero(T) : one(T)/sqrt(D[i])
    end

    # Scale eigenvectors by D
    Q = QΛQᵀ.vectors
    QD = LinearAlgebra.rmul!(Q, LinearAlgebra.Diagonal(D))  # Scales column i of Q by D[i]

    # W := (QD)(QD)ᵀ = (QΛQᵀ)^(-1)  (pseudo inverse)
    W = LinearAlgebra.syrk_wrapper!(similar(QD), 'N', QD)

    return LinearAlgebra.copytri!(W, 'U')
end

"""
    NystromFact

Type for storing a Nystrom factorization. The factorization contains two fields: `W` and
`C` as described in the `nystrom` documentation.
"""
struct NystromFact{T<:LinearAlgebra.BlasReal}
    W::Matrix{T}
    C::Matrix{T}
end

@doc raw"""
    nystrom([σ::Orientation,] κ::Kernel, X::Matrix, [S::Vector])

Computes a factorization of Nystrom approximation of the square kernel matrix of data
matrix `X` with respect to kernel `κ`. Returns a `NystromFact` struct which stores a
Nystrom factorization satisfying:

```math
\mathbf{K} \approx \mathbf{C}^{\intercal}\mathbf{WC}
```
"""
function nystrom(
        σ::Orientation,
        κ::Kernel{T},
        X::Matrix{T},
        S::Vector{U} = samplematrix(σ, X, convert(T,0.15))
    ) where {T<:LinearAlgebra.BlasReal,U<:Integer}
    C, Cs = nystrom_sample(σ, κ, X, S)
    W = nystrom_pinv!(Cs)
    NystromFact{T}(W, C)
end

function nystrom(
        κ::Kernel{T},
        X::Matrix{T},
        S::Vector{U} = samplematrix(:(row), X, convert(T,0.15))
    ) where {T<:LinearAlgebra.BlasReal,U<:Integer}
    nystrom(:(row), κ, X, S)
end

function rsvd(W::Matrix{T}, k::Int64, p::Int64, q::Int64) where {T<:LinearAlgebra.BlasReal}
    m = size(W, 1)
    Ω = randn(T, m, k + p)
    Z = W * Ω
    Y = W^(q-1) * Z
    Q = LinearAlgebra.qr!(Y).Q
    # B = Q' * W * Q
    B = (Q' * Y) \ (Q' * Ω)
    eig_fac = LinearAlgebra.eigen!(B)
    V = eig_fac.vectors
    Λ = LinearAlgebra.Diagonal(eig_fac.values)
    return Q * V, Λ
end

function nystrom_rsvd(
        σ::Orientation,
        κ::Kernel{T},
        X::Matrix{T},
        S::Vector{U} = samplematrix(σ, X, convert(T, 0.15));
        rank::Float64 = 0.01,
        oversampling::Int64 = 5,
        power::Int64 = 2
    ) where {T<:LinearAlgebra.BlasReal,U<:Integer}
    Cᵀ, W = nystrom_sample(σ, κ, X, S)
    m, n = size(Cᵀ)
    d = fill(sqrt(n/m), m)
    Cᵀ .*= d
    W .*= d
    k = max(Int64(trunc(n*rank)), 1)
    Û, Λ = rsvd(W, k, oversampling, power)
    # tol = eps(T)*size(Cs,1)
    U_ = Cᵀ' * Û * LinearAlgebra.pinv(Λ)
    return U_, Λ
end

function nystrom_rsvd(
        κ::Kernel{T},
        X::Matrix{T},
        S::Vector{U} = samplematrix(:(row), X, convert(T,0.15))
    ) where {T<:LinearAlgebra.BlasReal,U<:Integer}
    nystrom_rsvd(:(row), κ, X, S)
end

"""
    nystrom(CᵀWC::NystromFact)

Compute the approximate kernel matrix based on the Nystrom factorization.
"""
function kernelmatrix(CᵀWC::NystromFact{T}) where {T<:LinearAlgebra.BlasReal}
    W = CᵀWC.W
    C = CᵀWC.C
    C' * W * C
end
