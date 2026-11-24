"""Contextual training loss over vocabulary words that share a likely typing error."""
import torch

from .vocab import Vocabulary


def spelling_neighbors(vocab: Vocabulary) -> torch.Tensor:
    """Pack one-edit word pairs into a padded table. Each edge is symmetric."""
    neighbors = [set() for _ in vocab.words]
    keyboard_rows = ("qwertyuiop", "asdfghjkl", "zxcvbnm")
    adjacent = {ch: row[max(0, i - 1):i] + row[i + 1:i + 2]
                for row in keyboard_rows for i, ch in enumerate(row)}
    for idx, word in enumerate(vocab.words[4:], 4):
        for pos, letter in enumerate(word):
            left, right = word[:pos], word[pos + 1:]
            alternatives = [left + right]
            if right:
                alternatives.append(left + right[0] + letter + right[1:])
            alternatives.extend(left + ch + right for ch in adjacent.get(letter, ""))
            for alternative in alternatives:
                other = vocab.index.get(alternative)
                if other is not None and other >= 4 and other != idx:
                    neighbors[idx].add(other)
                    neighbors[other].add(idx)

    width = max(map(len, neighbors))
    table = torch.full((len(vocab), width), -1, dtype=torch.long)
    for idx, group in enumerate(neighbors):
        if group:
            table[idx, :len(group)] = torch.tensor(sorted(group))
    return table


def spelling_loss(features, weight, bias, targets, has_context, table):
    """Cross entropy conditional on the target and its neighbors, averaged over eligible rows."""
    # Bound the temporary [rows, neighbors, embedding] tensor on full-size training batches.
    if targets.numel() > 512:
        sample = torch.randperm(targets.numel(), device=targets.device)[:512]
        features, targets, has_context = features[sample], targets[sample], has_context[sample]
    nearby = table[targets]
    ids = torch.cat((targets[:, None], nearby), dim=1)
    safe_ids = ids.clamp_min(0)
    scores = (features[:, None] * weight[safe_ids]).sum(-1) + bias[safe_ids]
    scores = scores.masked_fill(ids < 0, float('-inf'))
    eligible = (nearby >= 0).any(dim=1) & has_context
    losses = torch.logsumexp(scores, dim=1) - scores[:, 0]
    return (losses * eligible).sum() / eligible.sum().clamp_min(1)
