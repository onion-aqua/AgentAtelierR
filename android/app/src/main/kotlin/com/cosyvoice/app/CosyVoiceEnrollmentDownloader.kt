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

class CosyVoiceEnrollmentDownloader(
    context: Context,
    private val store: CosyVoiceStore = CosyVoiceStore(context.applicationContext)
) {
    companion object {
        private const val ARCHIVE_NAME = "cosyvoice3-mnn-enrollment-extension.zip"
        private const val ARCHIVE_BYTES = 997_807_778L
        private const val ARCHIVE_SHA256 =
            "59ef5c8810d3cead01ff21a64379cf0a819f0a72651a6ba2b2343e9da5a72231"
        private const val URL =
            "https://huggingface.co/VicenTrent/Cosy-Voice-MNN/resolve/main/$ARCHIVE_NAME?download=true"
        private const val EXTRA_FREE_BYTES = 512L * 1024L * 1024L
    }

    private val appContext = context.applicationContext
    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .callTimeout(0, TimeUnit.MILLISECONDS)
        .retryOnConnectionFailure(true)
        .build()

    suspend fun download(
        onProgress: (Double) -> Unit,
        onStage: (String) -> Unit = {}
    ) {
        if (store.enrollmentStatus().ready) return
        val specs = CosyVoiceStore.ENROLLMENT_FILE_SPECS
        val required = ARCHIVE_BYTES + specs.sumOf { it.bytes } +
            specs.maxOf { it.bytes } + EXTRA_FREE_BYTES
        val available = StatFs(appContext.filesDir.absolutePath).availableBytes
        check(available >= required) {
            "音色创建扩展在线安装至少需要 %.2f GiB 空间".format(required / 1024.0 / 1024.0 / 1024.0)
        }

        val directory = File(appContext.filesDir, "cosyvoice3-mnn/downloads").apply { mkdirs() }
        val part = File(directory, "$ARCHIVE_NAME.download")
        val archive = File(directory, ARCHIVE_NAME)
        if (!archive.isFile || archive.length() != ARCHIVE_BYTES) {
            onStage("正在下载音色创建扩展")
            downloadArchive(part, onProgress)
            onStage("正在校验音色创建扩展")
            check(part.sha256() == ARCHIVE_SHA256) { "音色创建扩展 SHA-256 校验失败" }
            archive.delete()
            check(part.renameTo(archive)) { "音色创建扩展无法保存" }
        } else {
            onStage("正在校验音色创建扩展")
            check(archive.sha256() == ARCHIVE_SHA256) { "音色创建扩展 SHA-256 校验失败" }
        }

        onStage("正在安装音色创建扩展")
        archive.inputStream().use { store.importEnrollmentZip(it, onStage) }
        check(store.enrollmentStatus().ready) { "音色创建扩展安装不完整" }
        archive.delete()
    }

    private suspend fun downloadArchive(part: File, onProgress: (Double) -> Unit) {
        if (part.length() > ARCHIVE_BYTES) part.delete()
        var offset = part.length()
        val request = Request.Builder().url(URL)
            .header("Accept-Encoding", "identity")
            .apply { if (offset > 0L) header("Range", "bytes=$offset-") }
            .build()
        val call = client.newCall(request)
        val cancellation = currentCoroutineContext().job.invokeOnCompletion { cause ->
            if (cause is CancellationException) call.cancel()
        }
        try {
            call.execute().use { response ->
                check(response.isSuccessful) { "音色创建扩展下载失败：HTTP ${response.code}" }
                if (offset > 0L && response.code != 206) {
                    offset = 0L
                    part.delete()
                }
                RandomAccessFile(part, "rw").use { output ->
                    output.seek(offset)
                    response.body.byteStream().use { input ->
                        val buffer = ByteArray(1024 * 1024)
                        var downloaded = offset
                        var lastUpdate = 0L
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                            downloaded += count
                            check(downloaded <= ARCHIVE_BYTES) { "音色创建扩展超过预期大小" }
                            val now = System.currentTimeMillis()
                            if (now - lastUpdate >= 250L || downloaded == ARCHIVE_BYTES) {
                                onProgress(downloaded.toDouble() / ARCHIVE_BYTES)
                                lastUpdate = now
                            }
                        }
                    }
                }
            }
        } finally {
            cancellation.dispose()
        }
        check(part.length() == ARCHIVE_BYTES) { "音色创建扩展下载不完整" }
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
}
