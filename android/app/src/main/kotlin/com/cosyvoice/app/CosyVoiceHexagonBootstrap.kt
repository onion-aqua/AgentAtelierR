package com.cosyvoice.app

import android.content.Context
import android.system.Os
import java.io.File

internal data class CosyVoiceHexagonStatus(
    val available: Boolean,
    val detail: String
)

internal object CosyVoiceHexagonBootstrap {

    private const val SKELETON_ASSET = "hexagon/libMNN_htpops_skel.so"
    private const val SKELETON_FILE = "libMNN_htpops_skel.so"
    private const val SYSTEM_ADSP_PATHS = "/vendor/lib/rfsa/adsp;/system/lib/rfsa/adsp"

    @Volatile
    private var cached: CosyVoiceHexagonStatus? = null

    fun initialize(context: Context): CosyVoiceHexagonStatus {
        cached?.let { return it }
        return synchronized(this) {
            cached ?: initializeOnce(context.applicationContext).also { cached = it }
        }
    }

    private fun initializeOnce(context: Context): CosyVoiceHexagonStatus {
        return runCatching {
            val directory = File(context.filesDir, "cosyvoice3-mnn/hexagon").apply {
                check(mkdirs() || isDirectory) { "无法创建 Hexagon 运行目录" }
            }
            val skeleton = File(directory, SKELETON_FILE)
            val staging = File(directory, "$SKELETON_FILE.writing")
            context.assets.open(SKELETON_ASSET).use { input ->
                staging.outputStream().buffered().use(input::copyTo)
            }
            check(staging.length() > 0L) { "Hexagon Skeleton 为空" }
            if (skeleton.exists()) {
                check(skeleton.delete()) { "无法替换旧 Hexagon Skeleton" }
            }
            check(staging.renameTo(skeleton)) { "无法安装 Hexagon Skeleton" }

            val adspLibraryPath = (
                listOf(directory.absolutePath) +
                    System.getenv("ADSP_LIBRARY_PATH").orEmpty()
                        .split(';')
                        .filter(String::isNotBlank) +
                    SYSTEM_ADSP_PATHS.split(';')
                ).distinct().joinToString(";")
            Os.setenv("ADSP_LIBRARY_PATH", adspLibraryPath, true)
            System.loadLibrary("MNN_htpops")
            CosyVoiceHexagonStatus(true, "Hexagon Stub/Skeleton 已就绪")
        }.getOrElse { error ->
            CosyVoiceHexagonStatus(
                false,
                "Hexagon 初始化失败：${error.message ?: error.javaClass.simpleName}"
            )
        }
    }
}
