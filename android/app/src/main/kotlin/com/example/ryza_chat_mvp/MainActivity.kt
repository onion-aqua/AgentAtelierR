package com.example.ryza_chat_mvp

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs

class MainActivity : FlutterActivity() {
    private val channelName = "ryza_chat/device_tools"
    private val frameRateChannelName = "agent_atelier_r/frame_rate"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var requestedFramesPerSecond = 24f
    private var preferMaximumFrameRate = false
    private var hasFrameRateRequest = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "agent_atelier_r/speech_envelope")
            .setMethodCallHandler { call, result ->
                if (call.method != "analyze" && call.method != "decodeWav") { result.notImplemented(); return@setMethodCallHandler }
                val path = call.argument<String>("path")
                if (path == null) { result.error("path", "Missing audio path", null); return@setMethodCallHandler }
                Thread {
                    try {
                        val output = if (call.method == "decodeWav") "$path.decoded.wav" else null
                        val values = SpeechEnvelope.decode(path, output)
                        mainHandler.post { result.success(output ?: values) }
                    } catch (error: Exception) {
                        mainHandler.post { result.error("decode", error.message, null) }
                    }
                }.start()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCurrentLocation" -> getCurrentLocation(result)
                    "listLaunchableApps" -> result.success(listLaunchableApps())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, frameRateChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setPreferredFrameRate" -> {
                        requestedFramesPerSecond =
                            (call.argument<Double>("framesPerSecond") ?: 24.0)
                                .toFloat()
                                .coerceIn(1f, 240f)
                        preferMaximumFrameRate =
                            call.argument<Boolean>("preferMaximum") ?: false
                        hasFrameRateRequest = true
                        result.success(
                            applyPreferredFrameRate(
                                requestedFramesPerSecond,
                                preferMaximumFrameRate,
                            ),
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        if (hasFrameRateRequest) {
            mainHandler.post {
                applyPreferredFrameRate(
                    requestedFramesPerSecond,
                    preferMaximumFrameRate,
                )
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && hasFrameRateRequest) {
            applyPreferredFrameRate(
                requestedFramesPerSecond,
                preferMaximumFrameRate,
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun applyPreferredFrameRate(
        requested: Float,
        preferMaximum: Boolean,
    ): Map<String, Any> {
        val activeDisplay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display
        } else {
            windowManager.defaultDisplay
        }
        if (activeDisplay == null) {
            return mapOf(
                "requestedFramesPerSecond" to requested.toDouble(),
                "appliedFramesPerSecond" to requested.toDouble(),
                "displayModeId" to 0,
            )
        }

        val currentMode = activeDisplay.mode
        val sameResolutionModes = activeDisplay.supportedModes.filter { mode ->
            mode.physicalWidth == currentMode.physicalWidth &&
                mode.physicalHeight == currentMode.physicalHeight
        }
        val modes = sameResolutionModes.ifEmpty {
            activeDisplay.supportedModes.toList()
        }
        val selectedMode = if (preferMaximum) {
            modes.maxByOrNull { it.refreshRate }
        } else {
            modes.minByOrNull { abs(it.refreshRate - requested) }
        }
        val exactMode = selectedMode != null &&
            abs(selectedMode.refreshRate - requested) < 0.75f
        val attributes = window.attributes
        attributes.preferredDisplayModeId = if (
            selectedMode != null && (preferMaximum || exactMode)
        ) {
            selectedMode.modeId
        } else {
            0
        }
        attributes.preferredRefreshRate = when {
            selectedMode == null -> requested
            preferMaximum || exactMode -> selectedMode.refreshRate
            requested >= 30f -> requested
            else -> selectedMode.refreshRate
        }
        window.attributes = attributes

        return mapOf(
            "requestedFramesPerSecond" to requested.toDouble(),
            "appliedFramesPerSecond" to
                (selectedMode?.refreshRate ?: requested).toDouble(),
            "displayModeId" to (selectedMode?.modeId ?: 0),
        )
    }

    private fun listLaunchableApps(): List<Map<String, String>> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return packageManager.queryIntentActivities(intent, PackageManager.MATCH_ALL)
            .map { info ->
                mapOf(
                    "name" to info.loadLabel(packageManager).toString(),
                    "packageName" to info.activityInfo.packageName,
                )
            }
            .distinctBy { it["packageName"] }
            .sortedBy { it["name"]?.lowercase() }
    }

    private fun getCurrentLocation(result: MethodChannel.Result) {
        val coarseGranted = ActivityCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val fineGranted = ActivityCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        if (!coarseGranted && !fineGranted) {
            result.error("permission_denied", "Location permission is not granted", null)
            return
        }

        val manager = getSystemService(LOCATION_SERVICE) as LocationManager
        val providers = manager.getProviders(true)
        val cached = providers.mapNotNull { provider ->
            runCatching { manager.getLastKnownLocation(provider) }.getOrNull()
        }.maxByOrNull { it.time }
        if (cached != null && System.currentTimeMillis() - cached.time < 10 * 60 * 1000) {
            result.success(locationPayload(cached))
            return
        }

        val provider = providers.firstOrNull { it == LocationManager.GPS_PROVIDER }
            ?: providers.firstOrNull { it == LocationManager.NETWORK_PROVIDER }
            ?: providers.firstOrNull()
        if (provider == null) {
            result.error("location_disabled", "No enabled location provider", null)
            return
        }

        var completed = false
        lateinit var listener: LocationListener
        fun finish(location: Location?, message: String? = null) {
            if (completed) return
            completed = true
            mainHandler.removeCallbacksAndMessages(listener)
            runCatching { manager.removeUpdates(listener) }
            if (location != null) result.success(locationPayload(location))
            else result.error("location_unavailable", message ?: "Location unavailable", null)
        }
        listener = object : LocationListener {
            override fun onLocationChanged(location: Location) = finish(location)
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
            @Deprecated("Deprecated in Android")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        }
        try {
            manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
            mainHandler.postAtTime(
                { finish(cached, "Timed out while obtaining location") },
                listener,
                SystemClock.uptimeMillis() + 12_000,
            )
        } catch (error: Exception) {
            finish(cached, error.message)
        }
    }

    private fun locationPayload(location: Location): Map<String, Any> = mapOf(
        "latitude" to location.latitude,
        "longitude" to location.longitude,
        "accuracyMeters" to location.accuracy.toDouble(),
        "provider" to (location.provider ?: "unknown"),
        "capturedAt" to location.time,
    )
}
