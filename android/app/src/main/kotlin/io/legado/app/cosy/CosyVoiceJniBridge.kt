package io.legado.app.cosy

/*
 * JNI 桥接层 —— 包名必须与预编译 .so 的导出符号一致。
 *
 * 背景：app/src/main/jniLibs 里的 4 个 libcosy_*_jni.so 导出的是
 *   Java_io_legado_app_cosy_CosyVoiceLlmNative_run / _reset
 *   Java_io_legado_app_cosy_CosyVoiceFlowNative_run / _reset
 *   Java_io_legado_app_cosy_CosyVoiceHiFTNative_run / _reset
 *   Java_io_legado_app_cosy_CosyVoiceEnrollmentNative_enroll
 * （它们是早期作为 Legado 插件 io.legado.app.cosy 编译的）
 *
 * 而本 app 的 Kotlin 包名是 com.cosyvoice.app，且没有任何 RegisterNatives /
 * JNI_OnLoad 兜底 —— 于是每次原生调用都会抛 UnsatisfiedLinkError。
 *
 * 修法：在 .so 期望的包下放一层薄桥接，业务代码照旧用 com.cosyvoice.app.*Native。
 * 这样无需重编原生库；将来重编 JNI 时把 C++ 侧的 Java_ 前缀改成 com_cosyvoice_app_
 * 即可删掉本文件。
 */

internal object CosyVoiceLlmNative {
    init { System.loadLibrary("cosy_llm_jni") }
    external fun run(
        configPath: String,
        promptsPath: String,
        maxTokens: Int,
        promptSpeechTokensPath: String,
        outputDirectory: String,
        appendPromptSpeechTokens: Boolean
    ): Int
    external fun reset()
}

internal object CosyVoiceFlowNative {
    init { System.loadLibrary("cosy_flow_jni") }
    external fun run(
        modelPath: String,
        manifestPath: String,
        backend: String,
        precision: String,
        threads: Int,
        reportPath: String,
        cachePath: String
    ): Int
    external fun reset()
}

internal object CosyVoiceHiFTNative {
    init { System.loadLibrary("cosy_hift_jni") }
    external fun run(
        f0ModelPath: String,
        coreModelPath: String,
        manifestPath: String,
        threads: Int,
        reportPath: String,
        coreBackend: String,
        corePrecision: String,
        coreCachePath: String,
        coreGpuMode: Int
    ): Int
    external fun reset()
}

internal object CosyVoiceEnrollmentNative {
    init { System.loadLibrary("cosy_enrollment_jni") }
    external fun enroll(
        tokenizerModelPath: String,
        campPlusModelPath: String,
        affineWeightPath: String,
        affineBiasPath: String,
        sourceWavPath: String,
        outputDirectory: String,
        threads: Int
    ): Int
}
