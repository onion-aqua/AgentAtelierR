package com.example.ryza_chat_mvp

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRouting
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
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
        var routeListener: AudioRouting.OnRoutingChangedListener? = null
        // Read and written only on the single audio worker.
        var submittedFrames = 0L
        var lastHead = 0L
        var headWraps = 0L
    }

    private class PcmFailure(val code: String, message: String) : Exception(message)

    private val channel = MethodChannel(messenger, "agent_atelier_r/realtime_pcm")
    private val routes = EventChannel(messenger, "agent_atelier_r/realtime_pcm_routes")
    private val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val lifecycle = Any()
    private val epoch = AtomicInteger()
    @Volatile private var playback: Playback? = null
    @Volatile private var disposed = false
    @Volatile private var preference = RealtimeOutputPreference()
    private var routeSink: EventChannel.EventSink? = null
    private var publishedRoute = "unknown"
    private var routeRefresh: Runnable? = null
    private var routeRevision = 0
    private var routeRecoveryDeadline = 0L
    private var knownHeadsets = emptySet<Int>()
    private val deviceListener = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = devicesChanged()
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = devicesChanged()
    }
    private val guardListener: (Map<String, Any>) -> Unit = { state ->
        // `muted` also represents ordinary media-focus loss and focus-pending
        // while this call is acquiring its own AudioTrack. Only native
        // communication/alarm ownership may interrupt the call's playback.
        if (state["callActive"] == true || state["alarmActive"] == true) stop()
    }

    init {
        // Media routing uses A2DP / LE Audio without taking communication mode
        // or SCO ownership away from real calls or the live ASR microphone.
        knownHeadsets = outputDevices().filter { isHeadset(it) }.map { it.id }.toSet()
        manager.registerAudioDeviceCallback(deviceListener, main)
        routes.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                routeSink = events
                publishedRoute = actualRoute(playback)
                events.success(publishedRoute)
            }
            override fun onCancel(arguments: Any?) { routeSink = null }
        })
        CallAudioGuard.addListener(guardListener)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "stop" -> { stop(); result.success(null) }
                "start" -> start(result)
                "write" -> write(call.argument<ByteArray>("pcm"), result)
                "drain" -> drain(result)
                "speaker" -> setSpeaker(call.argument<Boolean>("enabled") ?: true, result)
                "resetRoute" -> {
                    preference = RealtimeOutputPreference()
                    refreshRoute()
                    result.success(null)
                }
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
                        val target = preferredDevice(candidate)
                        candidate.output.setPreferredDevice(target)
                        val listener = AudioRouting.OnRoutingChangedListener {
                            // The worker may be waiting for drain: reroute on the
                            // main thread instead of queueing behind that wait.
                            if (isCurrent(candidate)) {
                                publishRoute(candidate)
                                scheduleRouteRefresh(candidate)
                            }
                        }
                        candidate.routeListener = listener
                        candidate.output.addOnRoutingChangedListener(listener, main)
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
                main.post {
                    if (isCurrent(candidate)) refreshRoute()
                    result.success(null)
                }
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

    private fun outputDevices(): List<AudioDeviceInfo> =
        runCatching { manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList() }.getOrDefault(emptyList())

    private fun outputKind(device: AudioDeviceInfo): RealtimeOutputKind = when (device.type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_HEARING_AID -> RealtimeOutputKind.BLUETOOTH
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE -> RealtimeOutputKind.WIRED
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> RealtimeOutputKind.SPEAKER
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> RealtimeOutputKind.EARPIECE
        else -> RealtimeOutputKind.SYSTEM
    }

    private fun isHeadset(device: AudioDeviceInfo) = when (outputKind(device)) {
        RealtimeOutputKind.BLUETOOTH, RealtimeOutputKind.WIRED -> true
        else -> false
    }

    private fun isCurrent(current: Playback): Boolean =
        !disposed && !current.released.get() && playback === current && epoch.get() == current.generation

    private fun preferredDevice(current: Playback): AudioDeviceInfo? {
        val devices = outputDevices()
        val target = RealtimeOutputRoutePolicy.select(
            devices.map { RealtimeOutputEndpoint(it.id, outputKind(it)) },
            preference,
            runCatching { current.output.routedDevice?.id }.getOrNull(),
        )
        return devices.firstOrNull { it.id == target?.id }
    }

    private fun actualRoute(current: Playback?): String {
        if (current == null || !isCurrent(current)) return "unknown"
        val device = synchronized(lifecycle) {
            if (isCurrent(current)) runCatching { current.output.routedDevice }.getOrNull() else null
        } ?: return "unknown"
        // An already-active SCO route may be chosen by Android. Do not try to
        // establish SCO ourselves for this media track.
        return if (device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) "bluetooth" else outputKind(device).wireName
    }

    private fun publishRoute(current: Playback?) {
        val value = actualRoute(current)
        if (publishedRoute == value) return
        publishedRoute = value
        Log.i("AAR/CallAudioRoute", "output=$value")
        routeSink?.success(value)
    }

    private fun devicesChanged() {
        if (disposed) return
        val devices = outputDevices().filter { isHeadset(it) }
        val ids = devices.map { it.id }.toSet()
        val added = devices.filter { it.id !in knownHeadsets }
        knownHeadsets = ids
        val connected = added.firstOrNull { outputKind(it) == RealtimeOutputKind.BLUETOOTH } ?: added.firstOrNull()
        if (connected != null) preference = preference.withConnectedHeadset(connected.id)
        refreshRoute()
    }

    private fun cancelRouteRefresh() {
        routeRevision++
        routeRefresh?.let { main.removeCallbacks(it) }
        routeRefresh = null
    }

    private fun refreshRoute() {
        cancelRouteRefresh()
        routeRecoveryDeadline = System.nanoTime() + 3_000_000_000L
        val current = playback
        if (current == null || !isCurrent(current) || blocked()) {
            publishRoute(null)
            return
        }
        applyRoute(current)
        publishRoute(current)
        scheduleRouteRefresh(current)
    }

    private fun applyRoute(current: Playback) {
        synchronized(lifecycle) {
            if (!isCurrent(current) || blocked()) return
            val target = preferredDevice(current)
            val actual = runCatching { current.output.routedDevice }.getOrNull()
            val previous = runCatching { current.output.preferredDevice }.getOrNull()
            if (previous?.id != target?.id || target != null && actual?.id != target.id) {
                // A headset can be enumerated before its A2DP path is ready.
                // Clear a stale builtin preference before requesting it again.
                runCatching {
                    current.output.setPreferredDevice(null)
                    if (target != null) current.output.setPreferredDevice(target)
                }
            }
        }
    }

    private fun scheduleRouteRefresh(current: Playback) {
        if (routeRefresh != null || !isCurrent(current) || System.nanoTime() >= routeRecoveryDeadline) return
        val revision = routeRevision
        val delays = longArrayOf(120, 280, 600, 1000)
        var attempt = 0
        val task = object : Runnable {
            override fun run() {
                if (revision != routeRevision || !isCurrent(current) || blocked() ||
                    System.nanoTime() >= routeRecoveryDeadline) {
                    if (revision == routeRevision) routeRefresh = null
                    return
                }
                routeRefresh = null
                applyRoute(current)
                publishRoute(current)
                val target = preferredDevice(current)
                val actual = runCatching { current.output.routedDevice }.getOrNull()
                attempt++
                if (target != null && actual?.id != target.id && attempt < delays.size) {
                    routeRefresh = this
                    main.postDelayed(this, delays[attempt])
                }
            }
        }
        routeRefresh = task
        main.postDelayed(task, delays[0])
    }

    private fun setSpeaker(enabled: Boolean, result: MethodChannel.Result) {
        val current = playback
        if (current == null || blocked()) { result.success(false); return }
        val previousPreference = preference
        preference = preference.withSpeaker(enabled)
        val device = preferredDevice(current)
        if (device == null) {
            preference = previousPreference
            result.success(false)
            return
        }
        val generation = epoch.get()
        cancelRouteRefresh()
        routeRecoveryDeadline = System.nanoTime() + 3_000_000_000L
        val revision = routeRevision
        var previous: AudioDeviceInfo? = null
        val accepted = synchronized(lifecycle) {
            if (playback !== current || generation != epoch.get()) false else {
                previous = runCatching { current.output.preferredDevice }.getOrNull()
                runCatching { current.output.setPreferredDevice(device) }.getOrDefault(false)
            }
        }
        if (!accepted) {
            preference = previousPreference
            refreshRoute()
            result.success(false)
            return
        }
        val deadline = System.nanoTime() + 1_200_000_000L
        fun verify() {
            if (disposed || generation != epoch.get() || playback !== current || blocked() || revision != routeRevision) {
                result.success(false)
                return
            }
            val routed = runCatching { current.output.routedDevice }.getOrNull()
            if (routed?.id == device.id) {
                publishRoute(current)
                result.success(true)
            } else if (System.nanoTime() >= deadline) {
                // A preference acceptance alone is not a successful route.
                // Restore the previous preference if Android did not route it.
                synchronized(lifecycle) {
                    if (playback === current) runCatching { current.output.setPreferredDevice(previous) }
                }
                preference = previousPreference
                refreshRoute()
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
        current.routeListener?.let { listener -> runCatching { current.output.removeOnRoutingChangedListener(listener) } }
        current.routeListener = null
        runCatching { current.output.pause() }
        runCatching { current.output.flush() }
        runCatching { current.output.release() }
    }

    private fun stop() {
        cancelRouteRefresh()
        routeRecoveryDeadline = 0L
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
        publishRoute(null)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        routes.setStreamHandler(null)
        routeSink = null
        runCatching { manager.unregisterAudioDeviceCallback(deviceListener) }
        CallAudioGuard.removeListener(guardListener)
        synchronized(lifecycle) { disposed = true }
        stop()
        worker.shutdown()
    }
}
