package com.example.ryza_chat_mvp

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Bounded worker writes provide PCM backpressure without blocking Flutter. */
class RealtimePcmBridge(context: Context, messenger: BinaryMessenger) {
    companion object {
        private const val SAMPLE_RATE = 24000L
        private const val MIN_DRAIN_TIMEOUT_NANOS = 5_000_000_000L
        private const val DRAIN_GRACE_NANOS = 3_000_000_000L
        private const val MAX_DRAIN_TIMEOUT_NANOS = 90_000_000_000L
    }

    private class Playback(val output: AudioTrack, val generation: Int) {
        val released = AtomicBoolean(false)
        // Read and written only on the single audio worker.
        var submittedFrames = 0L
        var lastHead = 0L
        var headWraps = 0L
    }

    private class PcmFailure(val code: String, message: String) : Exception(message)

    private val channel = MethodChannel(messenger, "agent_atelier_r/realtime_pcm")
    private val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val lifecycle = Any()
    private val epoch = AtomicInteger()
    @Volatile private var playback: Playback? = null
    @Volatile private var disposed = false
    @Volatile private var preferredSpeaker = true
    private val guardListener: (Map<String, Any>) -> Unit = { state ->
        // `muted` also represents ordinary media-focus loss and focus-pending
        // while this call is acquiring its own AudioTrack. Only native
        // communication/alarm ownership may interrupt the call's playback.
        if (state["callActive"] == true || state["alarmActive"] == true) stop()
    }

    init {
        CallAudioGuard.addListener(guardListener)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "stop" -> { stop(); result.success(null) }
                "start" -> start(result)
                "write" -> write(call.argument<ByteArray>("pcm"), result)
                "drain" -> drain(result)
                "speaker" -> setSpeaker(call.argument<Boolean>("enabled") ?: true, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun blocked(): Boolean {
        val state = CallAudioGuard.snapshot()
        return state["callActive"] == true || state["alarmActive"] == true
    }

    private fun start(result: MethodChannel.Result) {
        stop()
        val generation = epoch.get()
        worker.execute {
            var next: Playback? = null
            try {
                if (blocked()) throw PcmFailure("pcm_audio_interrupted", "System audio is interrupted")
                val size = maxOf(9600, AudioTrack.getMinBufferSize(
                    24000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
                ))
                val candidate = Playback(AudioTrack.Builder()
                    .setAudioAttributes(AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    .setAudioFormat(AudioFormat.Builder().setSampleRate(24000)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                    .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(size).build(), generation)
                next = candidate
                check(candidate.output.state == AudioTrack.STATE_INITIALIZED)
                val installed = synchronized(lifecycle) {
                    if (disposed || generation != epoch.get()) false else {
                        if (blocked()) throw PcmFailure("pcm_audio_interrupted", "System audio is interrupted")
                        // Validation, publication and play are one lifecycle
                        // operation. Stop can never miss a late publication.
                        playback = candidate
                        outputDevice(preferredSpeaker)?.let { candidate.output.setPreferredDevice(it) }
                        candidate.output.play()
                        true
                    }
                }
                if (!installed) {
                    release(candidate)
                    finishFailure(
                        result,
                        generation,
                        PcmFailure("pcm_cancelled", "Call playback was cancelled"),
                        "pcm_start",
                        "Cannot initialize call audio",
                    )
                    return@execute
                }
                main.post { result.success(null) }
            } catch (error: Exception) {
                synchronized(lifecycle) {
                    if (playback === next) playback = null
                }
                next?.let { release(it) }
                finishFailure(result, generation, error, "pcm_start", "Cannot initialize call audio")
            }
        }
    }

    private fun write(bytes: ByteArray?, result: MethodChannel.Result) {
        if (bytes == null || bytes.size > 96000 || bytes.size % 2 != 0) {
            result.error("pcm_input", "Invalid PCM frame", null)
            return
        }
        val generation = epoch.get()
        worker.execute {
            try {
                requireCurrent(generation)
                val current = playback ?: throw PcmFailure("pcm_not_started", "Call audio is not started")
                var offset = 0
                while (offset < bytes.size && generation == epoch.get()) {
                    if (blocked()) throw PcmFailure("pcm_audio_interrupted", "System audio is interrupted")
                    // A caller cannot accidentally create a multi-second
                    // uncancellable blocking AudioTrack write.
                    val count = current.output.write(bytes, offset,
                        minOf(3840, bytes.size - offset), AudioTrack.WRITE_BLOCKING)
                    check(count > 0)
                    offset += count
                    current.submittedFrames += count / 2
                }
                requireCurrent(generation)
                main.post { result.success(null) }
            } catch (error: Exception) {
                finishFailure(result, generation, error, "pcm_write", "Call playback interrupted")
            }
        }
    }

    private fun drain(result: MethodChannel.Result) {
        val generation = epoch.get()
        worker.execute {
            try {
                requireCurrent(generation)
                val current = playback ?: throw PcmFailure("pcm_not_started", "Call audio is not started")
                val initialPlayedFrames = playedFrames(current)
                val remainingFrames = (current.submittedFrames - initialPlayedFrames).coerceAtLeast(0L)
                val expectedNanos = (remainingFrames * 1_000_000_000L) / SAMPLE_RATE
                val timeoutNanos = (expectedNanos + DRAIN_GRACE_NANOS)
                    .coerceIn(MIN_DRAIN_TIMEOUT_NANOS, MAX_DRAIN_TIMEOUT_NANOS)
                val deadline = System.nanoTime() + timeoutNanos
                while (generation == epoch.get()) {
                    if (blocked()) throw PcmFailure("pcm_audio_interrupted", "System audio is interrupted")
                    if (playedFrames(current) >= current.submittedFrames) break
                    if (System.nanoTime() >= deadline) {
                        throw PcmFailure("pcm_drain_timeout", "Call audio did not finish playing")
                    }
                    Thread.sleep(10)
                }
                requireCurrent(generation)
                main.post { result.success(null) }
            } catch (error: Exception) {
                finishFailure(result, generation, error, "pcm_drain", "Cannot finish call playback")
            }
        }
    }

    private fun outputDevice(speaker: Boolean): AudioDeviceInfo? {
        val type = if (speaker) AudioDeviceInfo.TYPE_BUILTIN_SPEAKER else AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
        return manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.type == type }
    }

    private fun setSpeaker(enabled: Boolean, result: MethodChannel.Result) {
        val current = playback
        val device = outputDevice(enabled)
        if (current == null || device == null || blocked()) { result.success(false); return }
        val generation = epoch.get()
        var previous: AudioDeviceInfo? = null
        val accepted = synchronized(lifecycle) {
            if (playback !== current || generation != epoch.get()) false else {
                previous = runCatching { current.output.preferredDevice }.getOrNull()
                runCatching { current.output.setPreferredDevice(device) }.getOrDefault(false)
            }
        }
        if (!accepted) { result.success(false); return }
        val deadline = System.nanoTime() + 600_000_000L
        fun verify() {
            if (disposed || generation != epoch.get() || playback !== current || blocked()) {
                result.success(false)
                return
            }
            val routed = runCatching { current.output.routedDevice }.getOrNull()
            if (routed?.id == device.id) {
                preferredSpeaker = enabled
                result.success(true)
            } else if (System.nanoTime() >= deadline) {
                // A preference acceptance alone is not a successful route.
                // Restore the previous preference if Android did not route it.
                synchronized(lifecycle) {
                    if (playback === current) runCatching { current.output.setPreferredDevice(previous) }
                }
                result.success(false)
            } else main.postDelayed({ verify() }, 20)
        }
        verify()
    }

    private fun finishFailure(
        result: MethodChannel.Result, generation: Int, error: Exception,
        fallbackCode: String, fallbackMessage: String,
    ) {
        main.post {
            val cancelled = generation != epoch.get()
            result.error(
                if (cancelled) "pcm_cancelled" else (error as? PcmFailure)?.code ?: fallbackCode,
                if (cancelled) "Call playback was cancelled" else
                    (error as? PcmFailure)?.message ?: fallbackMessage,
                null,
            )
        }
    }

    private fun requireCurrent(generation: Int) {
        if (generation != epoch.get()) {
            throw PcmFailure("pcm_cancelled", "Call playback was cancelled")
        }
    }

    private fun playedFrames(current: Playback): Long {
        val head = current.output.playbackHeadPosition.toLong() and 0xffffffffL
        if (head < current.lastHead) current.headWraps += 0x100000000L
        current.lastHead = head
        return current.headWraps + head
    }

    private fun release(current: Playback) {
        if (!current.released.compareAndSet(false, true)) return
        runCatching { current.output.pause() }
        runCatching { current.output.flush() }
        runCatching { current.output.release() }
    }

    private fun stop() {
        val old = synchronized(lifecycle) {
            epoch.incrementAndGet()
            playback.also { playback = null }
        }
        if (old != null) {
            // Unblock the worker's write before scheduling release behind it.
            runCatching { old.output.pause() }
            runCatching { old.output.flush() }
            worker.execute { release(old) }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        CallAudioGuard.removeListener(guardListener)
        synchronized(lifecycle) { disposed = true }
        stop()
        worker.shutdown()
    }
}
