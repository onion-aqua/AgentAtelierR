"""Prepare the public, local-only multilingual sentence encoder assets.

Requires numpy, onnx and safetensors. Downloads are fixed revisions and verified
before use. No user text, API credentials or private server configuration is read.
Large model/native files remain ignored by Git, as with other local app assets.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "assets/models/memory_rag"
CACHE = ROOT / "build/rag-research/downloads"
ENCODER_REVISION = "cad454171d918d9873a2701ba245054b6c1760dd"
DENSE_REVISION = "bfe45d0732ca50787611c0fe107ba278c7f3f889"
SOURCES = {
    "encoder.onnx": (
        f"https://huggingface.co/Xenova/distiluse-base-multilingual-cased-v2/resolve/{ENCODER_REVISION}/onnx/model_quantized.onnx",
        "1724c10ba3b33b58afb6ce73bbf3e0528921bd4d4e1bf5a569b6d73f234e72bf",
    ),
    "vocab.txt": (
        f"https://huggingface.co/Xenova/distiluse-base-multilingual-cased-v2/resolve/{ENCODER_REVISION}/vocab.txt",
        "fe0fda7c425b48c516fc8f160d594c8022a0808447475c1a7c6d6479763f310c",
    ),
    "tokenizer.json": (
        f"https://huggingface.co/Xenova/distiluse-base-multilingual-cased-v2/resolve/{ENCODER_REVISION}/tokenizer.json",
        "bf1b59b7b11c95f194f51708d918eea378e09d05f84c0e1656dc5180e8117088",
    ),
    "dense.safetensors": (
        f"https://huggingface.co/sentence-transformers/distiluse-base-multilingual-cased-v2/resolve/{DENSE_REVISION}/2_Dense/model.safetensors",
        "0a21b1ce908e772ebf09f93c20ca09524c32706e9918d9c0169a3f0663b191ed",
    ),
}


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def acquire(name: str) -> Path:
    url, expected = SOURCES[name]
    target = CACHE / name
    if not target.is_file() or digest(target) != expected:
        pending = target.with_suffix(target.suffix + ".download")
        with urllib.request.urlopen(url, timeout=120) as response, pending.open("wb") as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)
        if digest(pending) != expected:
            raise ValueError(f"Hash mismatch: {name}")
        pending.replace(target)
    return target


def prepare() -> None:
    import numpy as np
    import onnx
    from onnx import TensorProto, helper, numpy_helper
    from safetensors.numpy import load_file

    CACHE.mkdir(parents=True, exist_ok=True)
    DEST.mkdir(parents=True, exist_ok=True)
    acquire("tokenizer.json")  # reference tokenizer for offline evaluation
    model = onnx.load(acquire("encoder.onnx"))
    if [(value.domain, value.version) for value in model.opset_import] != [("", 11)]:
        raise ValueError("Unexpected encoder opset")
    if [value.name for value in model.graph.input] != ["input_ids", "attention_mask"]:
        raise ValueError("Unexpected model inputs")
    if [value.name for value in model.graph.output] != ["last_hidden_state"]:
        raise ValueError("Unexpected encoder output")
    dense = load_file(acquire("dense.safetensors"))
    weight, bias = dense["linear.weight"], dense["linear.bias"]
    if weight.shape != (512, 768) or bias.shape != (512,):
        raise ValueError("Unexpected sentence-transformers Dense dimensions")
    # Exact sentence-transformers pipeline: attention-mask mean pooling,
    # trained Dense(768,512,bias=True), tanh. L2 normalization is added for
    # cosine retrieval; it does not change cosine ordering.
    prefix = "aar_sentence_"
    constants = {
        "weight": np.ascontiguousarray(weight.T, dtype=np.float32),
        "bias": np.asarray(bias, dtype=np.float32),
        "epsilon": np.asarray(1e-9, dtype=np.float32),
    }
    for name, value in constants.items():
        model.graph.initializer.append(numpy_helper.from_array(value, prefix + name))
    nodes = [
        helper.make_node("Cast", ["attention_mask"], [prefix + "mask"], to=TensorProto.FLOAT),
        helper.make_node("Unsqueeze", [prefix + "mask"], [prefix + "mask3d"], axes=[2]),
        helper.make_node("Mul", ["last_hidden_state", prefix + "mask3d"], [prefix + "masked"]),
        helper.make_node("ReduceSum", [prefix + "masked"], [prefix + "sum"], axes=[1], keepdims=0),
        helper.make_node("ReduceSum", [prefix + "mask3d"], [prefix + "count"], axes=[1], keepdims=0),
        helper.make_node("Max", [prefix + "count", prefix + "epsilon"], [prefix + "divisor"]),
        helper.make_node("Div", [prefix + "sum", prefix + "divisor"], [prefix + "mean"]),
        helper.make_node("MatMul", [prefix + "mean", prefix + "weight"], [prefix + "projection"]),
        helper.make_node("Add", [prefix + "projection", prefix + "bias"], [prefix + "biased"]),
        helper.make_node("Tanh", [prefix + "biased"], [prefix + "dense"]),
        helper.make_node("Mul", [prefix + "dense", prefix + "dense"], [prefix + "squared"]),
        helper.make_node("ReduceSum", [prefix + "squared"], [prefix + "norm2"], axes=[1], keepdims=1),
        helper.make_node("Sqrt", [prefix + "norm2"], [prefix + "norm"]),
        helper.make_node("Max", [prefix + "norm", prefix + "epsilon"], [prefix + "safe_norm"]),
        helper.make_node("Div", [prefix + "dense", prefix + "safe_norm"], ["sentence_embedding"]),
    ]
    model.graph.node.extend(nodes)
    del model.graph.output[:]
    model.graph.output.append(helper.make_tensor_value_info("sentence_embedding", TensorProto.FLOAT, ["batch_size", 512]))
    onnx.checker.check_model(model)
    final = DEST / "model.onnx"
    onnx.save(model, final)
    shutil.copyfile(acquire("vocab.txt"), DEST / "vocab.txt")
    license_source = ROOT / "docs/third_party/rag-memory-model-LICENSE.txt"
    shutil.copyfile(license_source, DEST / "LICENSE.txt")
    metadata = {
        "schema_version": 1,
        "model_id": "distiluse-multilingual-cased-v2-int8-mean-dense512-v1",
        "encoder_revision": ENCODER_REVISION,
        "dense_revision": DENSE_REVISION,
        "dimensions": 512,
        "max_tokens": 128,
        "case_sensitive": True,
        "pooling": "attention_mask_mean + trained_dense_tanh + l2_normalization",
        "license": "Apache-2.0",
        "sources": {name: {"url": url, "sha256": sha} for name, (url, sha) in SOURCES.items()},
        "files": {name: {"size": (DEST / name).stat().st_size, "sha256": digest(DEST / name)}
                  for name in ("model.onnx", "vocab.txt", "LICENSE.txt")},
        "android_runtime": "Sherpa-ONNX 1.13.8 bundled ONNX Runtime 1.28.2, shared across ASR and embeddings",
    }
    (DEST / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"prepared": True, "model_id": metadata["model_id"], "dimensions": 512, "files": metadata["files"]}))


if __name__ == "__main__":
    prepare()
