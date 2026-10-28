"""Evaluate the real local ONNX encoder on a fixed multilingual recall set.

This script is offline after prepare_rag_memory_assets.py has downloaded assets.
Requires numpy, onnxruntime and tokenizers; it does not use an LLM or account.
"""
from pathlib import Path
import json
import time

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

ROOT = Path(__file__).resolve().parents[1]


def main():
    fixture = json.loads((ROOT / "test/fixtures/rag_memory_real_embedding_eval.json").read_text(encoding="utf-8"))
    tokenizer = Tokenizer.from_file(str(ROOT / "build/rag-research/downloads/tokenizer.json"))
    tokenizer.enable_truncation(max_length=128)
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    started = time.perf_counter()
    session = ort.InferenceSession(str(ROOT / "assets/models/memory_rag/model.onnx"), sess_options=options, providers=["CPUExecutionProvider"])
    load_seconds = time.perf_counter() - started

    def embed(texts):
        vectors = []
        for start in range(0, len(texts), 4):
            values = tokenizer.encode_batch(texts[start:start + 4])
            length = max(len(value.ids) for value in values)
            feeds = {
                "input_ids": np.asarray([value.ids + [0] * (length - len(value.ids)) for value in values], dtype=np.int64),
                "attention_mask": np.asarray([[1] * len(value.ids) + [0] * (length - len(value.ids)) for value in values], dtype=np.int64),
            }
            vectors.extend(session.run(["sentence_embedding"], feeds)[0])
        return np.asarray(vectors)

    started = time.perf_counter()
    source = embed([entry["text"] for entry in fixture["entries"]])
    queries = embed([query["query"] for query in fixture["queries"]])
    negative_vectors = embed([query["query"] for query in fixture.get("negatives", [])])
    elapsed = time.perf_counter() - started
    scores = queries @ source.T
    negative_scores = negative_vectors @ source.T
    ids = [entry["id"] for entry in fixture["entries"]]
    results = []
    for query, values in zip(fixture["queries"], scores):
        order = np.argsort(-values)
        expected = ids.index(query["expected_id"])
        results.append({
            "query": query["query"], "expected_id": query["expected_id"],
            "top_id": ids[int(order[0])], "rank": int(np.where(order == expected)[0][0]) + 1,
            "expected_cosine": float(values[expected]), "top_cosine": float(values[int(order[0])]),
            "top_margin": float(values[int(order[0])] - values[int(order[1])]),
        })
    report = {
        "model_id": fixture["model_id"], "dimensions": int(source.shape[1]),
        "queries": len(results), "source_entries": len(ids),
        "top1_correct": sum(item["rank"] == 1 for item in results),
        "top3_correct": sum(item["rank"] <= 3 for item in results),
        "positive_cosine_min": min(item["expected_cosine"] for item in results),
        "positive_cosine_median": float(np.median([item["expected_cosine"] for item in results])),
        "positive_under_052": sum(item["expected_cosine"] < .52 for item in results),
        "load_seconds": load_seconds, "inference_seconds": elapsed,
        "unit_norm_error_max": float(np.abs(np.linalg.norm(source, axis=1) - 1).max()),
        "pipeline": "real quantized ONNX + attention-mask mean + official Dense/Tanh + L2",
        "results": results,
        "negative_results": [
            {"query": query["query"], "top_id": ids[int(np.argmax(values))], "top_cosine": float(np.max(values)),
             "top_margin": float(np.sort(values)[-1] - np.sort(values)[-2])}
            for query, values in zip(fixture.get("negatives", []), negative_scores)
        ],
        "threshold_metrics": [
            {"threshold": threshold,
             "positive_expected_recalled": sum(item["expected_cosine"] >= threshold for item in results),
             "positive_recall_rate": sum(item["expected_cosine"] >= threshold for item in results) / len(results),
             "negative_false_recall": sum(float(np.max(value)) >= threshold for value in negative_scores),
             "negative_false_recall_rate": sum(float(np.max(value)) >= threshold for value in negative_scores) / len(negative_scores)}
            for threshold in [.25, .28, .3, .32, .35, .4, .45, .52]
        ],
        "negative_max_score_min": float(negative_scores.max(axis=1).min()),
        "negative_max_score_median": float(np.median(negative_scores.max(axis=1))),
        "negative_max_score_max": float(negative_scores.max(axis=1).max()),
    }
    path = ROOT / "build/rag-research/real-embedding-evaluation.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (path.parent / "real-embedding-vectors.json").write_text(json.dumps({
        "model_id": fixture["model_id"], "entries": fixture["entries"],
        "queries": fixture["queries"], "negatives": fixture.get("negatives", []),
        "entry_vectors": source.tolist(), "query_vectors": queries.tolist(),
        "negative_vectors": negative_vectors.tolist(),
    }, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key not in ["results", "negative_results"]}))


if __name__ == "__main__":
    main()
