"""Learned multi-letter spelling error model (Brill & Moore 2000 style) and a dictionary-trie candidate search.

    model = train(pairs)                       # [(typed, target), ...]
    search = Speller(model, words)
    search.candidates("fisical", k=8)          # [(word, cost in nats), ...]

A rule rewrites a chunk of the intended word (alpha) into what was typed (beta), with 0-2 letters of
matched context on each side; '^' and '$' mark the word's edges. P(alpha -> beta) =
count(alpha typed as beta) / count(alpha in the training words); cost = -ln P. Typed letters that match the
word are free; the search returns the dictionary words with the cheapest rewrite of the typed text.
"""
from __future__ import annotations

import collections, heapq, math

MAX_CONTEXT = 2
MAX_CHUNK = 7


def align(word: str, typed: str):
    """Damerau-Levenshtein alignment: list of (alpha, beta) ops; equal letters give (c, c)."""
    n, m = len(word), len(typed)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (word[i - 1] != typed[j - 1]))
            if i > 1 and j > 1 and word[i - 1] == typed[j - 2] and word[i - 2] == typed[j - 1]:
                d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
    ops, i, j = [], n, m
    while i or j:
        if i and j and word[i - 1] == typed[j - 1] and d[i][j] == d[i - 1][j - 1]:
            ops.append((word[i - 1], typed[j - 1])); i -= 1; j -= 1
        elif i > 1 and j > 1 and word[i - 1] == typed[j - 2] and word[i - 2] == typed[j - 1] and d[i][j] == d[i - 2][j - 2] + 1:
            ops.append((word[i - 2:i], typed[j - 2:j])); i -= 2; j -= 2
        elif i and j and d[i][j] == d[i - 1][j - 1] + 1:
            ops.append((word[i - 1], typed[j - 1])); i -= 1; j -= 1
        elif i and d[i][j] == d[i - 1][j] + 1:
            ops.append((word[i - 1], '')); i -= 1
        else:
            ops.append(('', typed[j - 1])); j -= 1
    return ops[::-1]


def rules_of(word: str, typed: str):
    """The context-expanded rewrite rules one (typed, word) pair shows."""
    ops = align('^' + word + '$', '^' + typed + '$')
    match = [a == b and len(a) == 1 for a, b in ops]
    out, k = [], 0
    while k < len(ops):
        if match[k]: k += 1; continue
        end = k
        while end < len(ops) and not match[end]: end += 1
        alpha = ''.join(a for a, _ in ops[k:end]); beta = ''.join(b for _, b in ops[k:end])
        left = 0
        while left < MAX_CONTEXT and k - left - 1 >= 0 and match[k - left - 1]: left += 1
        right = 0
        while right < MAX_CONTEXT and end + right < len(ops) and match[end + right]: right += 1
        for cl in range(left + 1):
            for cr in range(right + 1):
                L = ''.join(a for a, _ in ops[k - cl:k]); R = ''.join(a for a, _ in ops[end:end + cr])
                a, b = L + alpha + R, L + beta + R
                if a and b and len(a) <= MAX_CHUNK and len(b) <= MAX_CHUNK: out.append((a, b))
        k = end
    return out


def train(pairs, min_count: int = 2, smoothing: float = 1.0):
    """{beta: [(alpha, cost), ...]} sorted by cost."""
    rule_count = collections.Counter()
    for typed, word in pairs:
        if typed != word: rule_count.update(set(rules_of(word, typed)))
    alphas = {a for (a, _), c in rule_count.items() if c >= min_count}
    alpha_count = collections.Counter()
    for _, word in pairs:
        w = '^' + word + '$'
        seen = set()
        for i in range(len(w)):
            for j in range(i + 1, min(len(w), i + MAX_CHUNK) + 1):
                s = w[i:j]
                if s in alphas and (s, i) not in seen: seen.add((s, i)); alpha_count[s] += 1
    model = collections.defaultdict(list)
    for (a, b), c in rule_count.items():
        if c < min_count or not alpha_count[a]: continue
        p = c / (alpha_count[a] + smoothing)
        model[b].append((a, -math.log(min(p, 0.999))))
    for b in model: model[b].sort(key=lambda x: x[1])
    return dict(model)


class Speller:
    def __init__(self, model, words):
        self.model = model
        self.max_beta = max((len(b) for b in model), default=1)
        self.trie = {}
        for w in words:
            node = self.trie
            for ch in '^' + w + '$': node = node.setdefault(ch, {})
            node[None] = w

    @staticmethod
    def _walk(node, s):
        for ch in s:
            node = node.get(ch)
            if node is None: return None
        return node

    def candidates(self, typed: str, k: int = 8, max_cost: float = 14.0, max_pops: int = 30000):
        t = '^' + typed + '$'
        heap = [(0.0, 0, 0, id(self.trie))]
        nodes = {id(self.trie): self.trie}
        best, found, pops, tie = {}, {}, 0, 1
        while heap and pops < max_pops:
            cost, _, pos, nid = heapq.heappop(heap); pops += 1
            if best.get((pos, nid), math.inf) < cost: continue
            node = nodes[nid]
            if pos == len(t):
                w = node.get(None)
                if w is not None and w not in found:
                    found[w] = cost
                    if len(found) >= k: break
                continue
            nxt = []
            child = node.get(t[pos])
            if child is not None: nxt.append((cost, pos + 1, child))
            for lb in range(1, min(self.max_beta, len(t) - pos) + 1):
                for alpha, c in self.model.get(t[pos:pos + lb], ()):
                    if cost + c > max_cost: break
                    target = self._walk(node, alpha)
                    if target is not None: nxt.append((cost + c, pos + lb, target))
            for c, p, n in nxt:
                key = (p, id(n))
                if c < best.get(key, math.inf):
                    best[key] = c; nodes[id(n)] = n
                    heapq.heappush(heap, (c, tie, p, id(n))); tie += 1
        return sorted(found.items(), key=lambda x: x[1])
