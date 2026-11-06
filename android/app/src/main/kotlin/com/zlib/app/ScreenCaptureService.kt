package io.github.zzy19074244935.libranote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 整屏截图用的前台服务。
 *
 * 为什么必须有它：Android 10（API 29）起，`MediaProjection` 只能在一个
 * **类型为 mediaProjection 的前台服务**运行期间创建虚拟屏；Android 14
 * （API 34）起更是直接抛 SecurityException
 * （"Media projections require a foreground service of type
 *   ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION"）。
 *
 * 之前没有这个服务 → `createVirtualDisplay` 每次都失败 → Dart 侧
 * `ScreenCapture.captureFullScreen()` 恒返回 null → 阅读器悄悄回退成
 * 「只截 App 自己」，分屏/浮窗里的 B 站永远截不进来。
 *
 * 生命周期：授权成功 → start() → 截一帧 → stop()。只活几百毫秒。
 */
class ScreenCaptureService : Service() {

    companion object {
        const val CHANNEL_ID = "libranote_capture"
        const val NOTIFICATION_ID = 0x5343

        fun start(context: Context) {
            val intent = Intent(context, ScreenCaptureService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, ScreenCaptureService::class.java))
            } catch (_: Exception) {
                // 服务没起来 / 已停止，忽略。
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
        goForeground()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        goForeground()
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** Android 10+ 必须带 FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION 类型。 */
    private fun goForeground() {
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // 个别 ROM 会拒绝，退化成普通前台服务，截图仍可能成功。
            try {
                startForeground(NOTIFICATION_ID, notification)
            } catch (_: Exception) {
            }
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "整屏截图",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "截取整块屏幕时短暂显示"
                setShowBadge(false)
            }
            val manager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Libranote")
            .setContentText("正在截取屏幕…")
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }
}
