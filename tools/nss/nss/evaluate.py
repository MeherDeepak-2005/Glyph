"""Evaluate an NSS checkpoint.

    python -m nss.evaluate runs/NAME/best.pt [--device cpu] [--out results.json]

1. Held-out sets (tatoeba/wikitext test, MASC held-out), fp32 and as exported (int8):
   perplexity, P(<unk>) calibration and next-word top-1/top-3 (see nss.metrics).
2. MASC held-out over the keyboard's lexicon (keyboard/langdata.bin): every token that is
   an emittable lexicon word, each scored given the words before it in its sentence (a
   token the corpus builder could not represent is skipped, as the keyboard's parser
   skips digits). Vocabulary words are scored directly and the rest through
   P(<unk>|context), as the decoder scores them. Reported: mean log-probability per
   target (higher is better), the equivalent perplexity, and top-1/top-3 next-word
   prediction among lexicon words. NSS never saw MASC.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
import torch

from . import DATA
from .data import Shard
from .export import quantized_copy
from .lexicon import Lexicon, UnkPolicy
from .metrics import evaluate, word_log_probs
from .models import build
from .sources import masc_heldout
from .vocab import BOS, UNK, Vocabulary

@torch.no_grad()
def masc_lexicon(model, vocab: Vocabulary, lexicon: Lexicon, policy: UnkPolicy, device) -> dict:
    log_share = math.log(policy.lexicon_share) - math.log(policy.oov_mass)
    totals = {name: {"nss": 0.0, "count": 0, "nss_top1": 0, "nss_top3": 0, "in_vocab": 0}
              for name in ("all", "spoken", "written")}
    lexicon_ids = torch.tensor([i for i, w in enumerate(vocab.words) if i >= 4 and w in lexicon], device=device)
    for document, tokens, _ in masc_heldout():
        words = [t for t in tokens if t is not None]
        if not words:
            continue
        ids = torch.tensor([[BOS] + [vocab.id(w) for w in words]], device=device)
        features, _ = model(ids)
        log_probs = word_log_probs(model.logits(features[0])).double()
        allowed = torch.full_like(log_probs, float("-inf"))
        allowed[:, lexicon_ids] = log_probs[:, lexicon_ids]
        top = allowed.topk(3, -1).indices.cpu().numpy()
        register = "spoken" if document.split("/")[1] == "spoken" else "written"
        for position, word in enumerate(words):
            if word not in lexicon:
                continue
            index = vocab.exact(word)
            nss = float(log_probs[position, index]) if index != UNK else \
                float(log_probs[position, UNK]) + log_share + math.log(lexicon.unigram_mass(word))
            nss_top = [vocab.words[i] for i in top[position]]
            for name in ("all", register):
                t = totals[name]
                t["nss"] += nss
                t["count"] += 1
                t["in_vocab"] += index != UNK
                t["nss_top1"] += nss_top[0] == word
                t["nss_top3"] += word in nss_top
    report = {}
    for name, t in totals.items():
        n = max(t["count"], 1)
        report[name] = {"targets": t["count"], "in_vocabulary": t["in_vocab"] / n,
                        "nss_mean_log_prob": t["nss"] / n, "nss_ppl": math.exp(-t["nss"] / n),
                        "nss_top1": t["nss_top1"] / n, "nss_top3": t["nss_top3"] / n}
    return report

def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("--data", type=Path, default=DATA)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args(argv)
    device = torch.device(args.device)
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    vocab = Vocabulary.load()
    if checkpoint["vocabulary_sha256"] != vocab.sha256:
        raise SystemExit("checkpoint was trained on a different vocabulary")
    model = build(checkpoint["config"]["model"], len(vocab))
    model.load_state_dict(checkpoint["model"])
    model.eval()
    variants = {"fp32": model.to(device)}
    if model.arch in ("lstm", "gru"):
        variants["int8"] = quantized_copy(model).to(device)
    results: dict = {"checkpoint": str(args.checkpoint), "step": checkpoint["step"], "arch": model.config(),
                     "parameters": model.parameter_count()}
    for name, variant in variants.items():
        sets = {}
        for source in ("tatoeba", "wikitext", "masc"):
            shard = Shard.load(args.data, source, "test")
            scored = np.load(args.data / "masc.test.scored.npy") if source == "masc" else None
            sets[source] = evaluate(variant, shard, device, scored)
            print(name, source, json.dumps({k: round(v, 4) for k, v in sets[source].items()}), flush=True)
        results[name] = sets
    lexicon = Lexicon.load()
    policy = UnkPolicy.build(lexicon, vocab, float(checkpoint["unk_lexicon_share"]))
    reference = variants.get("int8", model)
    results["masc_lexicon"] = masc_lexicon(reference, vocab, lexicon, policy, device)
    for name, row in results["masc_lexicon"].items():
        print("masc lexicon", name, json.dumps({k: round(v, 4) for k, v in row.items()}), flush=True)
    if args.out:
        args.out.write_text(json.dumps(results, indent=2) + "\n")

if __name__ == "__main__":
    main()
