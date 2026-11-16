"""Full-softmax cross-entropy over the 30k vocabulary without materializing all logits.

A [tokens x 30k] logit matrix for a 6k-token batch is ~0.7 GB in fp32, plus as much
again for its gradient. This computes the loss in row chunks, so peak memory is one
chunk, and accumulates the gradients of the summed loss in the same pass (they depend
only on each chunk's softmax), so every chunk's logits and softmax are computed once.
The loss is exact (no sampling): P(<unk>|context) must be calibrated, and sampled
softmax biases exactly the rare-class probabilities the <unk> fallback depends on.
"""

from __future__ import annotations

import torch

class ChunkedCrossEntropy(torch.autograd.Function):
    """Rows weighted 0/1 rather than dropped: every batch keeps one shape, so MPS reuses
    its compiled kernels (a boolean-masked row count differs per batch and recompiles)."""

    @staticmethod
    def forward(ctx, features, weight, bias, targets, rows_weight, chunk):
        total = features.new_zeros(())
        grad_features = torch.empty_like(features)
        grad_weight = torch.zeros_like(weight)
        grad_bias = torch.zeros_like(bias)
        for start in range(0, features.shape[0], chunk):
            rows, wanted, scale = features[start:start + chunk], targets[start:start + chunk], rows_weight[start:start + chunk]
            log_probabilities = torch.log_softmax(torch.addmm(bias, rows, weight.t()), -1)
            total = total - (log_probabilities.gather(1, wanted[:, None]).squeeze(1) * scale).sum()
            probabilities = log_probabilities.exp_()
            probabilities[torch.arange(rows.shape[0], device=rows.device), wanted] -= 1
            probabilities *= scale[:, None]
            grad_features[start:start + chunk] = probabilities @ weight
            grad_weight.addmm_(probabilities.t(), rows)
            grad_bias += probabilities.sum(0)
        ctx.save_for_backward(grad_features, grad_weight, grad_bias)
        return total

    @staticmethod
    def backward(ctx, grad):
        grad_features, grad_weight, grad_bias = ctx.saved_tensors
        return grad_features * grad, grad_weight * grad, grad_bias * grad, None, None, None

def cross_entropy_sum(features: torch.Tensor, weight: torch.Tensor, bias: torch.Tensor,
                      targets: torch.Tensor, chunk: int = 1024, rows_weight: torch.Tensor | None = None) -> torch.Tensor:
    """Summed exact cross-entropy of `targets` given `features` [N, D], each row weighted
    by `rows_weight` (default 1)."""
    if rows_weight is None:
        rows_weight = features.new_ones(features.shape[0])
    return ChunkedCrossEntropy.apply(features.contiguous(), weight, bias, targets, rows_weight.to(features.dtype), chunk)
