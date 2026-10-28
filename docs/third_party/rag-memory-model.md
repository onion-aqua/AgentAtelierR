# Local multilingual memory encoder

The RAG prototype runs `sentence-transformers/distiluse-base-multilingual-cased-v2`
locally. It uses the quantized ONNX Transformer from Xenova at revision
`cad454171d918d9873a2701ba245054b6c1760dd`, followed by the original attention-mask
mean pooling and trained Dense(768,512) with tanh from upstream revision
`bfe45d0732ca50787611c0fe107ba278c7f3f889`. The final vector is L2-normalized for
cosine retrieval. This is a pretrained neural encoder, not feature hashing.

The model is published under Apache-2.0; see
[the license](rag-memory-model-LICENSE.txt). Model sources:

- https://huggingface.co/sentence-transformers/distiluse-base-multilingual-cased-v2
- https://huggingface.co/Xenova/distiluse-base-multilingual-cased-v2

`tool/prepare_rag_memory_assets.py` verifies each download against a pinned SHA-256,
adds the documented pooling/projection to the ONNX graph, and writes a local
manifest. The app validates the bundled model and vocabulary before lazy loading.
Large downloaded assets remain outside Git. The complete model is bundled in the
prototype APK so first use does not download a model or send conversation text to
an embedding server. Original text and vector caches remain local to the app.

Runtime: `onnxruntime` Flutter package 1.4.1 (MIT). Android shares Microsoft ONNX
Runtime 1.28.2 already bundled by Sherpa-ONNX 1.13.8 across all supported ABIs,
including emulator x86_64. The app Gradle file removes only the embedding
plugin's older 1.15.1 JNI source set; it does not alter the Pub cache or use a
packaging `pickFirst` rule. The Dart FFI requests ORT API 14, which the newer
runtime retains. Windows also shares Sherpa's 1.28.2 `onnxruntime.dll`, plus its
matching `onnxruntime_providers_shared.dll`. The repository's
`windows/shared_onnx_runtime.cmake` removes the embedding plugin's older 1.15.1
DLL from the bundle list before installation, so copy order cannot choose the
runtime. Unexpected same-name DLLs or missing Sherpa files fail configuration;
no plugin cache files or previously packaged releases are changed. No
communication audio mode or voice service is involved.

The background isolate uses two intra-op CPU threads, one inter-op thread, and a
maximum of 128 BERT WordPiece tokens per sentence. This sequence limit is part of
the model's sentence-transformers configuration. Chunk long conversations before
embedding instead of silently relying on text after the limit.
