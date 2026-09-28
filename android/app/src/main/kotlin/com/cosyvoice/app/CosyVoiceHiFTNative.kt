package com.cosyvoice.app

/*
 * 注意：真正的 external 声明在 io.legado.app.cosy.CosyVoiceJniBridge.kt ——
 * 因为预编译的 .so 导出的是 Java_io_legado_app_cosy_* 符号（见 bridge 文件里的说明）。
 * 本对象只做转发，保持 app 内既有调用点不变。
 */
internal object CosyVoiceHiFTNative {
    fun run(
        f0ModelPath: String,
        coreModelPath: String,
        manifestPath: String,
        threads: Int,
        reportPath: String,
        coreBackend: String,
        corePrecision: String,
        coreCachePath: String,
        coreGpuMode: Int
    ): Int = io.legado.app.cosy.CosyVoiceHiFTNative.run(
        f0ModelPath, coreModelPath, manifestPath, threads, reportPath,
        coreBackend, corePrecision, coreCachePath, coreGpuMode)

    fun reset() = io.legado.app.cosy.CosyVoiceHiFTNative.reset()
}
