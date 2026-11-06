package io.github.zzy19074244935.libranote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Agent 任务前台服务（Phase 1 任务式 Agent）：
 *
 * 任务执行期间通知栏常驻「Libranote · Agent 任务」+ 进度条，退回桌面 /
 * 熄屏后任务继续跑（前台服务保活 + 可选 PARTIAL_WAKE_LOCK）。
 * 点通知回到 App（MainActivity）。
 *
 * 与 TtsPlaybackService 同构；区别：foregroundServiceType=dataSync
 * （Android 14+ 对非媒体类前台服务的强制要求）。
 */
class AgentTaskService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        const val CHANNEL_ID = "libranote_agent_task"
        const val NOTIFICATION_ID = 0x4167
        private var running = false

        @Volatile
        private var instance: AgentTaskService? = null

        fun start(context: Context) {
            val intent = Intent(context, AgentTaskService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** 任务运行中（用于 update 时兜底重启）。 */
        fun isRunning(): Boolean = running

        /** 更新/重建通知（MainActivity 通道转发）。服务没起来时先拉起。 */
        fun update(context: Context, goal: String, text: String, step: Int, total: Int) {
            val svc = instance
            if (svc == null) {
                start(context)
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    instance?.updateNotification(goal, text, step, total)
                }, 400)
            } else {
                svc.updateNotification(goal, text, step, total)
            }
        }

        fun stop(context: Context) {
            running = false
            try {
                context.stopService(Intent(context, AgentTaskService::class.java))
            } catch (_: Exception) {
                // 服务没起来 / 已停止，忽略。
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        running = true
        createChannel()
        acquireWakeLock()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(
            NOTIFICATION_ID,
            buildNotification("准备执行…", 0, 0)
        )
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        if (instance === this) instance = null
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** 更新通知（标题/进度），由 MainActivity 的通道转发调用。 */
    fun updateNotification(goal: String, text: String, step: Int, total: Int) {
        startForeground(NOTIFICATION_ID, buildNotificationWithProgress(goal, text, step, total))
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Agent 任务",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "AI 任务执行期间的进度通知"
                setShowBadge(false)
            }
            val manager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String, step: Int, total: Int): Notification {
        return buildNotificationWithProgress("Agent 任务", text, step, total)
    }

    private fun buildNotificationWithProgress(
        goal: String,
        text: String,
        step: Int,
        total: Int,
    ): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(if (goal.isNotEmpty()) goal else "Agent 任务")
            .setContentText(text)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
        // 点通知回到 App（任务页）。
        val tap = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this,
            0,
            tap,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        builder.setContentIntent(pi)
        if (step in 1..total) {
            builder.setProgress(total, step, false)
        } else {
            builder.setProgress(0, 0, step < 0)
        }
        return builder.build()
    }

    private fun acquireWakeLock() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "libranote:agent_task"
            ).apply { acquire() }
        } catch (e: Exception) {
            // 个别 ROM 拒绝 wakelock——任务仍继续，只是熄屏后可能被限速。
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
