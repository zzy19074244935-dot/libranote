package io.github.zzy19074244935.libranote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * 朗读前台服务：开始朗读时启动，通知栏常驻「正在朗读」。
 *
 * 用途：App 退回桌面或熄屏后，系统不会杀这个进程，flutter_tts 的句子循环
 * （完成回调驱动）继续运行，系统 TTS 引擎持续发声 = 后台播放。
 * 附带一个 PARTIAL_WAKE_LOCK 防止个别 ROM 熄屏时 CPU 深度休眠。
 */
class TtsPlaybackService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        const val CHANNEL_ID = "libranote_tts"
        const val NOTIFICATION_ID = 0x5453

        fun start(context: Context) {
            val intent = Intent(context, TtsPlaybackService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TtsPlaybackService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
        acquireWakeLock()
        val notification = buildNotification("正在朗读 · 退回桌面朗读不断")
        // Android 8+ 必须在 startForegroundService 后 5 秒内调用，否则崩溃。
        startForeground(NOTIFICATION_ID, notification)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification("正在朗读 · 退回桌面朗读不断"))
        return START_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "听书朗读",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "朗读时保持后台播放"
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Libranote")
            .setContentText(text)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    private fun acquireWakeLock() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "libranote:tts"
            ).apply { acquire() }
        } catch (e: Exception) {
            // 个别 ROM 拒绝 wakelock——朗读仍可继续，只是熄屏后可能被限速。
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.takeIf { it.isHeld }?.release()
        } catch (e: Exception) {
            // ignore
        }
        wakeLock = null
    }
}
