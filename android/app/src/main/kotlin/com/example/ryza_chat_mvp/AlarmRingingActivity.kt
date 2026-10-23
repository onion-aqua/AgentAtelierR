package com.example.ryza_chat_mvp

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.gdelataillade.alarm.alarm.AlarmReceiver
import com.gdelataillade.alarm.alarm.AlarmService
import com.gdelataillade.alarm.services.AlarmStorage

/** A stop control available over the lock screen without booting Flutter. */
class AlarmRingingActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private var alarmId = 0
    private var stoppingUntil = 0L
    private lateinit var title: TextView
    private lateinit var body: TextView
    private lateinit var status: TextView
    private lateinit var stopButton: Button

    private val checkRinging = object : Runnable {
        override fun run() {
            val active = AlarmService.ringingAlarmIds
            if (!active.contains(alarmId)) {
                if (active.isEmpty()) {
                    finish()
                    return
                }
                // Stopping one overlapping alarm must leave the next one's
                // control visible instead of closing the only ringing surface.
                showAlarm(active.first())
            } else if (stoppingUntil != 0L &&
                android.os.SystemClock.uptimeMillis() >= stoppingUntil) {
                stoppingUntil = 0L
                stopButton.isEnabled = true
                status.setText(R.string.alarm_stop_failed)
            }
            handler.postDelayed(this, 400)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val padding = (32 * resources.displayMetrics.density).toInt()
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(padding, padding, padding, padding)
            setBackgroundColor(Color.rgb(24, 29, 34))
        }
        fun label(size: Float) = TextView(this).apply {
            textSize = size
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setPadding(0, padding / 2, 0, padding / 2)
            content.addView(this, LinearLayout.LayoutParams(-1, -2))
        }
        label(24f).setText(R.string.alarm_ringing)
        title = label(30f)
        body = label(18f)
        status = label(16f)
        stopButton = Button(this).apply {
            textSize = 22f
            minHeight = (72 * resources.displayMetrics.density).toInt()
            setOnClickListener { stopAlarm() }
        }
        content.addView(stopButton, LinearLayout.LayoutParams(-1, -2))
        setContentView(ScrollView(this).apply {
            isFillViewport = true
            addView(content)
        })
        showAlarm(intent.getIntExtra(AlarmService.EXTRA_ALARM_ID, 0), intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        showAlarm(intent.getIntExtra(AlarmService.EXTRA_ALARM_ID, 0), intent)
    }

    private fun showAlarm(id: Int, source: Intent? = null) {
        alarmId = id
        stoppingUntil = 0L
        status.text = ""
        stopButton.isEnabled = true
        // The notification extras are already localized by the app. Native
        // storage supplies them when switching to another overlapping alarm.
        val settings = runCatching {
            AlarmStorage(this).getSavedAlarms().firstOrNull { it.id == id }
        }.getOrNull()?.notificationSettings
        title.text = source?.getStringExtra(AlarmService.EXTRA_ALARM_TITLE)
            ?: settings?.title ?: getString(R.string.alarm_ringing)
        body.text = source?.getStringExtra(AlarmService.EXTRA_ALARM_BODY)
            ?: settings?.body ?: ""
        stopButton.text = source?.getStringExtra(AlarmService.EXTRA_ALARM_STOP_LABEL)
            ?: settings?.stopButton ?: getString(R.string.alarm_stop)
    }

    private fun stopAlarm() {
        if (stoppingUntil != 0L || alarmId == 0) return
        stoppingUntil = android.os.SystemClock.uptimeMillis() + 2000L
        stopButton.isEnabled = false
        status.setText(R.string.alarm_stopping)
        try {
            // Use the same native path as the notification; no Flutter engine,
            // network call or new alarm is required to silence playback.
            sendBroadcast(Intent(this, AlarmReceiver::class.java).apply {
                action = AlarmReceiver.ACTION_ALARM_STOP
                putExtra("id", alarmId)
            })
        } catch (_: Exception) {
            stoppingUntil = 0L
            stopButton.isEnabled = true
            status.setText(R.string.alarm_stop_failed)
        }
        // Remain visible until the service actually reports this id stopped.
    }

    override fun onResume() {
        super.onResume()
        handler.removeCallbacks(checkRinging)
        handler.post(checkRinging)
    }

    override fun onPause() {
        handler.removeCallbacks(checkRinging)
        super.onPause()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}
