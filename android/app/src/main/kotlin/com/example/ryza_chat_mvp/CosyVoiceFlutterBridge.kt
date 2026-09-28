package com.example.ryza_chat_mvp

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.net.Uri
import com.cosyvoice.app.CosyVoiceAudioDecoder
import com.cosyvoice.app.CosyVoiceEnrollmentDownloader
import com.cosyvoice.app.CosyVoiceEnrollmentNative
import com.cosyvoice.app.CosyVoiceModelDownloader
import com.cosyvoice.app.CosyVoiceRuntime
import com.cosyvoice.app.CosyVoiceStore
import com.cosyvoice.app.CosyVoiceSynthesisOptions
import com.cosyvoice.app.CosyVoiceVoiceProfile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

internal class CosyVoiceFlutterBridge(
    context: Context,
    messenger: BinaryMessenger
) {
    private val appContext = context.applicationContext
    private val store = CosyVoiceStore(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val operationMutex = Mutex()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val methodChannel = MethodChannel(messenger, "agent_atelier_r/cosyvoice3")
    private val progressChannel = EventChannel(messenger, "agent_atelier_r/cosyvoice3_progress")
    private var progressSink: EventChannel.EventSink? = null

    init {
        progressChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })
        methodChannel.setMethodCallHandler(::handle)
    }

    fun dispose() {
        scope.cancel()
        methodChannel.setMethodCallHandler(null)
        progressChannel.setStreamHandler(null)
        progressSink = null
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf(
                "status", "downloadModel", "downloadEnrollment", "importModel",
                "importEnrollment", "synthesize", "enroll", "selectVoice",
                "deleteVoice", "deleteModel", "deleteEnrollment"
            )) {
            result.notImplemented()
            return
        }
        scope.launch {
            try {
                val value = withContext(Dispatchers.IO) {
                    operationMutex.withLock { dispatch(call) }
                }
                result.success(value)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                result.error("cosyvoice3", error.message ?: error.javaClass.simpleName, null)
            }
        }
    }

    private suspend fun dispatch(call: MethodCall): Any? {
        if (call.method != "status") requireSupportedDevice()
        return when (call.method) {
            "status" -> status()
            "downloadModel" -> {
                emit("正在准备朗读模型", 0.0)
                CosyVoiceRuntime.close()
                var progress = 0.0
                CosyVoiceModelDownloader(appContext, store).download(
                    onProgress = {
                        progress = it.fileBytes.toDouble() / it.fileTotalBytes.coerceAtLeast(1L)
                        emit("正在下载朗读模型", progress)
                    },
                    onStage = { emit(it, progress) }
                )
                emit("朗读模型已安装", 1.0)
                status()
            }
            "downloadEnrollment" -> {
                emit("正在准备音色创建扩展", 0.0)
                var progress = 0.0
                CosyVoiceEnrollmentDownloader(appContext, store).download(
                    onProgress = {
                        progress = it
                        emit("正在下载音色创建扩展", progress)
                    },
                    onStage = { emit(it, progress) }
                )
                emit("音色创建扩展已安装", 1.0)
                status()
            }
            "importModel" -> {
                val archive = requiredFile(call.argument<String>("path"))
                CosyVoiceRuntime.close()
                emit("正在导入朗读模型", 0.0)
                archive.inputStream().use { store.importModelZip(it) { stage -> emit(stage, 0.0) } }
                emit("朗读模型已安装", 1.0)
                status()
            }
            "importEnrollment" -> {
                val archive = requiredFile(call.argument<String>("path"))
                emit("正在导入音色创建扩展", 0.0)
                archive.inputStream().use { store.importEnrollmentZip(it) { stage -> emit(stage, 0.0) } }
                emit("音色创建扩展已安装", 1.0)
                status()
            }
            "synthesize" -> {
                val text = call.argument<String>("text")?.trim().orEmpty()
                require(text.isNotEmpty()) { "朗读文字不能为空" }
                check(store.modelStatus().ready) { "请先安装 CosyVoice3 朗读模型" }
                val voiceId = call.argument<String>("voiceId")?.takeIf { it.isNotBlank() }
                    ?: CosyVoiceStore.DEFAULT_VOICE_PROFILE_ID
                val voicePromptText = call.argument<String>("voicePromptText")
                    ?.replace(Regex("[\\r\\n]+"), " ")
                    ?.replace("<|endofprompt|>", "")
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
                CosyVoiceRuntime.ensureInitialized(appContext)
                pruneCachedWav()
                val output = File(appContext.cacheDir, "cosyvoice3-${System.nanoTime()}.wav")
                emit("正在合成语音", 0.0)
                CosyVoiceRuntime.synthesize(
                    store = store,
                    text = text,
                    output = output,
                    options = CosyVoiceSynthesisOptions(
                        voiceProfileId = voiceId,
                        voicePromptText = voicePromptText
                    ),
                    onStage = { emit(it, 0.0) }
                )
                emit("语音合成完成", 1.0)
                output.absolutePath
            }
            "enroll" -> enroll(call)
            "selectVoice" -> {
                val id = requiredString(call, "id")
                store.selectVoiceProfile(id)
                status()
            }
            "deleteVoice" -> {
                store.deleteVoiceProfile(requiredString(call, "id"))
                status()
            }
            "deleteModel" -> {
                CosyVoiceRuntime.close()
                store.deleteModel()
                status()
            }
            "deleteEnrollment" -> {
                store.deleteEnrollment()
                status()
            }
            else -> error("未知 CosyVoice3 方法")
        }
    }

    private suspend fun enroll(call: MethodCall): Map<String, Any> {
        check(store.modelStatus().ready) { "请先安装 CosyVoice3 朗读模型" }
        check(store.enrollmentStatus().ready) { "请先安装音色创建扩展" }
        val audio = requiredFile(call.argument<String>("audioPath"))
        val start = (call.argument<Number>("startSeconds"))?.toDouble()
            ?: error("缺少参考音频起点")
        val end = (call.argument<Number>("endSeconds"))?.toDouble()
            ?: error("缺少参考音频终点")
        require(start >= 0.0 && end - start in 3.0..5.0) { "参考音频片段须为 3 到 5 秒" }
        val promptText = requiredString(call, "promptText")
        val name = requiredString(call, "name")
        CosyVoiceRuntime.close()
        val directory = File(store.workDir, "enroll-${System.nanoTime()}").apply { mkdirs() }
        try {
            val sourceWav = File(directory, "source.wav")
            emit("正在解码参考音频", 0.0)
            CosyVoiceAudioDecoder.decodeSegmentToWav(
                appContext, Uri.fromFile(audio), start, end, sourceWav
            )
            ditherPcm16(sourceWav)
            val nativeOutput = File(directory, "profile").apply { mkdirs() }
            emit("正在提取音色特征", 0.0)
            val code = CosyVoiceEnrollmentNative.enroll(
                tokenizerModelPath = store.enrollmentFile("speech-tokenizer-v3.fp32.inline.mnn").absolutePath,
                campPlusModelPath = store.enrollmentFile("campplus.fp32.mnn").absolutePath,
                affineWeightPath = store.enrollmentFile("flow-speaker-affine-weight.bin").absolutePath,
                affineBiasPath = store.enrollmentFile("flow-speaker-affine-bias.bin").absolutePath,
                sourceWavPath = sourceWav.absolutePath,
                outputDirectory = nativeOutput.absolutePath,
                threads = 6
            )
            check(code == 0) { "音色创建失败：${CosyVoiceEnrollmentNative.errorMessage(code)} ($code)" }
            val profile = store.installEnrolledVoiceProfile(name, promptText, nativeOutput, sourceWav)
            store.selectVoiceProfile(profile.id)
            emit("音色创建完成", 1.0)
            return voiceMap(profile)
        } finally {
            directory.deleteRecursively()
        }
    }

    private fun status(): Map<String, Any> {
        val supported = deviceSupported()
        val model = store.modelStatus()
        return mapOf(
            "supported" to supported,
            "modelReady" to (supported && model.ready),
            "enrollmentReady" to (supported && store.enrollmentStatus().ready),
            "modelBytes" to model.installedBytes,
            "voices" to if (supported) store.voiceProfiles().map(::voiceMap) else emptyList<Map<String, Any>>(),
            "selectedVoiceId" to store.selectedVoiceProfileId()
        )
    }

    private fun voiceMap(profile: CosyVoiceVoiceProfile): Map<String, Any> = mapOf(
        "id" to profile.id,
        "name" to profile.displayName,
        "builtIn" to profile.builtIn,
        "promptText" to profile.promptPrefix
            .substringAfter(CosyVoiceStore.SYSTEM_PROMPT_PREFIX, "")
            .trim()
    )

    private fun emit(stage: String, progress: Double) {
        mainHandler.post {
            progressSink?.success(mapOf(
                "stage" to stage,
                "progress" to progress.coerceIn(0.0, 1.0)
            ))
        }
    }

    private fun requiredString(call: MethodCall, key: String): String =
        call.argument<String>(key)?.trim()?.takeIf { it.isNotEmpty() }
            ?: error("缺少 $key")

    private fun requiredFile(path: String?): File {
        val file = File(path?.takeIf { it.isNotBlank() } ?: error("缺少文件路径"))
        require(file.isFile) { "文件不存在：${file.absolutePath}" }
        return file
    }

    private fun pruneCachedWav() {
        appContext.cacheDir.listFiles()
            .orEmpty()
            .filter { it.isFile && it.name.startsWith("cosyvoice3-") && it.extension == "wav" }
            .sortedByDescending(File::lastModified)
            .drop(20)
            .forEach(File::delete)
    }

    private fun requireSupportedDevice() {
        check(deviceSupported()) { "CosyVoice3 需要 Android 8.0 及以上的 arm64 设备" }
    }

    private fun deviceSupported(): Boolean =
        Build.VERSION.SDK_INT >= 26 && Build.SUPPORTED_ABIS.contains("arm64-v8a")

    private fun ditherPcm16(wav: File) {
        val bytes = wav.readBytes()
        require(bytes.size > 44 && bytes[0] == 'R'.code.toByte() && bytes[1] == 'I'.code.toByte()) {
            "参考 WAV 格式不正确"
        }
        var seed = 0x5DEECE66DL
        var index = 44
        while (index + 1 < bytes.size) {
            seed = seed * 6364136223846793005L + 1442695040888963407L
            val delta = ((seed ushr 33).toInt() and 1) * 2 - 1
            val sample = (bytes[index + 1].toInt() shl 8) or (bytes[index].toInt() and 0xff)
            val changed = (sample + delta).coerceIn(-32768, 32767)
            bytes[index] = changed.toByte()
            bytes[index + 1] = (changed shr 8).toByte()
            index += 2
        }
        wav.writeBytes(bytes)
    }
}
