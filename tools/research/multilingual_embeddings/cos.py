import sys
from sentence_transformers import SentenceTransformer

MODELS = [
    ("sentence-transformers/LaBSE", ""),
    ("sentence-transformers/paraphrase-multilingual-mpnet-base-v2", ""),
    ("intfloat/multilingual-e5-base", "query: "),
    ("BAAI/bge-m3", ""),
]
QUERIES = ["marchipoyava", "మర్చిపోయావా"]
TARGETS = [
    "forgot", "did you forget?", "forget", "remember", "lost",
    "banana", "table", "running", "annam", "అన్నం",
]

for name, prefix in MODELS:
    m = SentenceTransformer(name)
    q = m.encode([prefix + t for t in QUERIES], normalize_embeddings=True)
    t = m.encode([prefix + t for t in TARGETS], normalize_embeddings=True)
    sims = q @ t.T
    print(f"\n== {name}")
    print(f"{'':18}" + "".join(f"{x:>16}" for x in QUERIES))
    for j, tgt in enumerate(TARGETS):
        print(f"{tgt:18}" + "".join(f"{sims[i, j]:16.3f}" for i in range(len(QUERIES))))
    sys.stdout.flush()
