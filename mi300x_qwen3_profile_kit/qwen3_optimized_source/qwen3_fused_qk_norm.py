
import torch
import triton
import triton.language as tl


@triton.jit
def _fused_qk_rmsnorm(
    QKV,
    Q_OUT,
    K_OUT,
    Q_WEIGHT,
    K_WEIGHT,
    Q_HEADS: tl.constexpr,
    K_HEADS: tl.constexpr,
    HEAD_DIM: tl.constexpr,
    ROW_STRIDE: tl.constexpr,
    EPS: tl.constexpr,
    BLOCK: tl.constexpr,
):
    pid = tl.program_id(0)
    heads_per_token = Q_HEADS + K_HEADS

    token = pid // heads_per_token
    head = pid % heads_per_token

    d = tl.arange(0, BLOCK)
    valid = d < HEAD_DIM

    if head < Q_HEADS:
        src = (
            QKV
            + token * ROW_STRIDE
            + head * HEAD_DIM
            + d
        )
        dst = (
            Q_OUT
            + token * Q_HEADS * HEAD_DIM
            + head * HEAD_DIM
            + d
        )

        x = tl.load(src, mask=valid, other=0).to(tl.float32)
        w = tl.load(
            Q_WEIGHT + d, mask=valid, other=0
        ).to(tl.float32)

        variance = tl.sum(x * x, 0) / HEAD_DIM
        inv_rms = tl.rsqrt(variance + EPS)

        y = (x * inv_rms) * w
        tl.store(dst, y, mask=valid)

    else:
        kh = head - Q_HEADS
        src = (
            QKV
            + token * ROW_STRIDE
            + Q_HEADS * HEAD_DIM
            + kh * HEAD_DIM
            + d
        )
        dst = (
            K_OUT
            + token * K_HEADS * HEAD_DIM
            + kh * HEAD_DIM
            + d
        )

        x = tl.load(src, mask=valid, other=0).to(tl.float32)
        w = tl.load(
            K_WEIGHT + d, mask=valid, other=0
        ).to(tl.float32)

        variance = tl.sum(x * x, 0) / HEAD_DIM
        inv_rms = tl.rsqrt(variance + EPS)

        y = (x * inv_rms) * w
        tl.store(dst, y, mask=valid)


def fused_qk_rmsnorm(
    qkv: torch.Tensor,
    q_heads: int,
    k_heads: int,
    head_dim: int,
    q_weight: torch.Tensor,
    k_weight: torch.Tensor,
    eps: float,
) -> tuple[torch.Tensor, torch.Tensor]:
    assert qkv.ndim == 2
    assert qkv.is_cuda
    assert qkv.dtype == torch.bfloat16
    assert qkv.is_contiguous()
    assert q_weight.numel() == head_dim
    assert k_weight.numel() == head_dim
    assert q_weight.is_contiguous()
    assert k_weight.is_contiguous()

    tokens = qkv.shape[0]
    assert qkv.shape[1] == (q_heads + 2 * k_heads) * head_dim

    q = torch.empty(
        (tokens, q_heads * head_dim),
        device=qkv.device,
        dtype=qkv.dtype,
    )
    k = torch.empty(
        (tokens, k_heads * head_dim),
        device=qkv.device,
        dtype=qkv.dtype,
    )

    if tokens == 0:
        return q, k

    grid = (tokens * (q_heads + k_heads),)

    _fused_qk_rmsnorm[grid](
        qkv,
        q,
        k,
        q_weight,
        k_weight,
        q_heads,
        k_heads,
        head_dim,
        qkv.stride(0),
        eps,
        triton.next_power_of_2(head_dim),
        num_warps=4,
    )

    return q, k
