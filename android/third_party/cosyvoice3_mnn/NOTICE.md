CosyVoice3-MNN Android integration
==================================

Source: https://github.com/Nian27/CosyVoice3-MNN
Revision: b4c2fafde21d1f138bfcd0ccaf7ddd9dcca2511a (2026-09-18)
License for application source: Apache License 2.0 (see LICENSE).

The Kotlin core and prebuilt arm64-v8a native libraries in this Android app
come from that revision. The native libraries include Alibaba MNN and
CosyVoice JNI wrappers derived from CrispASR. The upstream repository documents
their respective licenses; model weights are distributed separately from
https://huggingface.co/VicenTrent/Cosy-Voice-MNN .

The Flutter MethodChannel bridge and enrollment downloader were added for this
application. The upstream Compose UI and VoiceDesign feature were not copied.
