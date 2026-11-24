from sentence_transformers import SentenceTransformer
Q = ["going", "went", "వెళ్తున్నా", "velthunna"]
T = ["going", "went", "go", "will go", "coming",
     "వెళ్తున్నా", "వెళ్తున్నాడు", "వెళ్ళాను", "వెళ్తాను", "వస్తున్నా",
     "velthunna", "velthunnadu", "vellanu", "velthanu", "veltunna", "banana"]
for name in ["sentence-transformers/LaBSE", "BAAI/bge-m3"]:
    m = SentenceTransformer(name)
    q = m.encode(Q, normalize_embeddings=True); t = m.encode(T, normalize_embeddings=True)
    s = q @ t.T
    print(f"\n== {name}\n{'':14}" + "".join(f"{x:>13}" for x in Q))
    for j, w in enumerate(T):
        print(f"{w:14}" + "".join(f"{s[i,j]:13.3f}" for i in range(len(Q))))
