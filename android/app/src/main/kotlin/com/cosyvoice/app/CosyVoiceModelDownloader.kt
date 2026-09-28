package com.cosyvoice.app

import android.content.Context
import android.os.StatFs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.job
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

data class CosyVoiceModelDownloadProgress(
    val fileName: String,
    val fileIndex: Int,
    val fileCount: Int,
    val fileBytes: Long,
    val fileTotalBytes: Long,
    val totalBytes: Long,
    val totalExpectedBytes: Long
) {
    val percent: Int
        get() = if (totalExpectedBytes <= 0L) 0 else
            (totalBytes * 100L / totalExpectedBytes).toInt().coerceIn(0, 100)
}

class CosyVoiceModelDownloader(
    context: Context,
    private val store: CosyVoiceStore = CosyVoiceStore(context.applicationContext)
) {
    companion object {
        private const val MODEL_ZIP = "cosyvoice3-mnn-mobile-fp16-complete.zip"
        private const val MODEL_ZIP_BYTES = 1_399_083_563L
        private const val MODEL_ZIP_SHA256 =
            "b1c74dfc90972d82d8166813620a882fe37a0dc02964e19c4f33daafefeb1c84"
        private const val MODEL_URL =
            "https://huggingface.co/VicenTrent/Cosy-Voice-MNN/resolve/main/$MODEL_ZIP?download=true"
        private const val EXTRA_FREE_BYTES = 512L * 1024L * 1024L
    }

    private val appContext = context.applicationContext
    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .callTimeout(0, TimeUnit.MILLISECONDS)
        .retryOnConnectionFailure(true)
        .build()

    suspend fun download(
        onProgress: (CosyVoiceModelDownloadProgress) -> Unit,
        onStage: (String) -> Unit = {}
    ) {
        val expectedModels = CosyVoiceStore.MODEL_FILE_SPECS.sumOf { it.bytes }
        val largestModel = CosyVoiceStore.MODEL_FILE_SPECS.maxOf { it.bytes }
        val downloadDir = File(appContext.filesDir, "cosyvoice3-mnn/downloads").apply {
            check(mkdirs() || isDirectory) { "无法创建模型下载目录" }
        }
        val part = File(downloadDir, "$MODEL_ZIP.download")
        val archive = File(downloadDir, MODEL_ZIP)
        val required = MODEL_ZIP_BYTES + expectedModels + largestModel + EXTRA_FREE_BYTES
        val available = StatFs(appContext.filesDir.absolutePath).availableBytes
        check(store.modelStatus().ready || available >= required) {
            "在线安装至少需要 ${formatBytes(required)} 可用空间，当前 ${formatBytes(available)}"
        }

        if (!archive.isFile || archive.length() != MODEL_ZIP_BYTES) {
            onStage("正在从 Hugging Face 下载模型")
            downloadArchive(part, onProgress)
            onStage("正在校验模型包 SHA-256")
            check(part.sha256() == MODEL_ZIP_SHA256) { "模型包 SHA-256 校验失败" }
            archive.delete()
            check(part.renameTo(archive)) { "模型包无法保存" }
        } else {
            onStage("正在校验已下载模型包")
            check(archive.sha256() == MODEL_ZIP_SHA256) {
                archive.delete()
                "已下载模型包校验失败，请重新下载"
            }
        }

        onStage("正在安装并逐文件校验模型")
        archive.inputStream().use { input ->
            store.importModelZip(input, onStage)
        }
        check(archive.delete()) { "模型已安装，但临时 ZIP 清理失败" }
    }

    private suspend fun downloadArchive(
        part: File,
        onProgress: (CosyVoiceModelDownloadProgress) -> Unit
    ) {
        if (part.length() > MODEL_ZIP_BYTES) part.delete()
        var offset = part.length()
        val request = Request.Builder()
            .url(MODEL_URL)
            .header("Accept-Encoding", "identity")
            .apply { if (offset > 0L) header("Range", "bytes=$offset-") }
            .build()
        val call = client.newCall(request)
        val cancellation = currentCoroutineContext().job.invokeOnCompletion { cause ->
            if (cause is CancellationException) call.cancel()
        }
        try {
            call.execute().use { response ->
                check(response.isSuccessful) { "模型下载失败：HTTP ${response.code}" }
                val append = offset > 0L && response.code == 206
                if (!append) {
                    offset = 0L
                    part.delete()
                }
                RandomAccessFile(part, "rw").use { output ->
                    output.seek(offset)
                    response.body.byteStream().use { input ->
                        val buffer = ByteArray(1024 * 1024)
                        var downloaded = offset
                        var lastProgressAt = 0L
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                            downloaded += count
                            check(downloaded <= MODEL_ZIP_BYTES) { "下载数据超过预期大小" }
                            val now = System.currentTimeMillis()
                            if (now - lastProgressAt >= 250L || downloaded == MODEL_ZIP_BYTES) {
                                onProgress(
                                    CosyVoiceModelDownloadProgress(
                                        MODEL_ZIP, 1, 1, downloaded, MODEL_ZIP_BYTES,
                                        downloaded, MODEL_ZIP_BYTES
                                    )
                                )
                                lastProgressAt = now
                            }
                        }
                    }
                }
            }
        } finally {
            cancellation.dispose()
        }
        check(part.length() == MODEL_ZIP_BYTES) {
            "模型下载不完整：${formatBytes(part.length())}/${formatBytes(MODEL_ZIP_BYTES)}"
        }
    }

    private fun File.sha256(): String {
        val digest = MessageDigest.getInstance("SHA-256")
        inputStream().buffered(1024 * 1024).use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun formatBytes(bytes: Long): String =
        "%.2f GiB".format(bytes / 1024.0 / 1024.0 / 1024.0)
}
