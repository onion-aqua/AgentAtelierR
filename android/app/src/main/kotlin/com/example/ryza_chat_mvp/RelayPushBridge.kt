package com.example.ryza_chat_mvp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Implemented by an explicitly configured vendor/aggregate SDK module.
 * Providers own cold-start hint persistence and must never log registration tokens.
 * No vendor SDK or project credentials are bundled in the default build. */
interface RelayVendorPushAdapter {
    fun register(onToken: (String) -> Unit, onHint: (Map<String, Any>) -> Unit, result: (String?) -> Unit)
    fun unregister(result: () -> Unit)
    fun consumeInitialHint(): Map<String, Any>?
}

class RelayPushBridge(context: Context, messenger: BinaryMessenger) {
    companion object {
        val adapters = mutableMapOf<String, RelayVendorPushAdapter>()
        const val CHANNEL = "pc_agent_private"
    }
    private val handler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "agent_atelier_r/relay_push")
    init {
        // Create before any push can be displayed. PRIVATE hides details on lockscreen.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notifications = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notifications.createNotificationChannel(NotificationChannel(CHANNEL, "PC Agent 提醒", NotificationManager.IMPORTANCE_DEFAULT).apply {
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                description = "仅显示通用提示，打开应用后鉴权读取问题"
            })
        }
        channel.setMethodCallHandler { call, result ->
            val provider = call.argument<String>("provider") ?: ""
            val adapter = adapters[provider]
            when (call.method) {
                "createPrivateChannel" -> result.success(null)
                "register" -> if (adapter == null) result.success(mapOf("available" to false)) else {
                    adapter.register(
                        { token -> handler.post { channel.invokeMethod("tokenChanged", mapOf("provider" to provider, "registration_token" to token)) } },
                        { hint -> handler.post { channel.invokeMethod("pushHint", hint + mapOf("provider" to provider)) } },
                        { token -> handler.post { result.success(mapOf("available" to (token != null), "registration_token" to token)) } }
                    )
                }
                "unregister" -> if (adapter == null) result.success(null) else adapter.unregister { handler.post { result.success(null) } }
                "initialHint" -> result.success(adapter?.consumeInitialHint())
                else -> result.notImplemented()
            }
        }
    }
}
