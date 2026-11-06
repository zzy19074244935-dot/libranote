package io.github.zzy19074244935.libranote

import android.app.Activity
import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * 主 Activity。
 *
 * 额外提供 MethodChannel：
 * - io.github.zzy19074244935.libranote/file_export：把 App 私有目录里的文件复制到系统 Downloads
 *   （Android 10+ scoped storage 下只能走 MediaStore）。
 * - io.github.zzy19074244935.libranote/share：FileProvider + ACTION_SEND 分享（chooser 带
 *   NEW_TASK，修复「分享到微信后 App 任务被并进微信、返回不了 App」）。
 * - io.github.zzy19074244935.libranote/update：自建更新 —— DownloadManager 下载 APK +
 *   FileProvider 安装（REQUEST_INSTALL_PACKAGES）。
 * - io.github.zzy19074244935.libranote/split：分屏打开哔哩哔哩（FLAG_ACTIVITY_LAUNCH_ADJACENT）。
 * - io.github.zzy19074244935.libranote/app_info：读取 versionName/versionCode（版本更新比对）。
 * - io.github.zzy19074244935.libranote/shot：MediaProjection 整屏截图（分屏时连 B 站那半屏
 *   一起截下来，供 Flutter 端全屏框选区域）。
 */
class MainActivity : FlutterActivity() {
    private val channel = "io.github.zzy19074244935.libranote/file_export"
    private val shareChannel = "io.github.zzy19074244935.libranote/share"
    private val updateChannel = "io.github.zzy19074244935.libranote/update"
    private val splitChannel = "io.github.zzy19074244935.libranote/split"
    private val appInfoChannel = "io.github.zzy19074244935.libranote/app_info"
    private val batteryChannel = "io.github.zzy19074244935.libranote/battery"
    private val ttsChannel = "io.github.zzy19074244935.libranote/tts"
    private val secureFlagChannel = "io.github.zzy19074244935.libranote/secure_flag"
    private val shotChannel = "io.github.zzy19074244935.libranote/shot"
    private val agentTaskChannel = "io.github.zzy19074244935.libranote/agent_task"

    // ── MediaProjection 整屏截图（分屏场景：连另一侧 App 一起截） ────
    private var pendingScreenShotResult: MethodChannel.Result? = null
    private var shotHandlerThread: HandlerThread? = null

    companion object {
        private const val SCREEN_SHOT_REQUEST = 9012
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToDownloads" -> saveToDownloads(call, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "shareFile" -> shareFile(call, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "download" -> downloadApk(call, result)
                    "queryStatus" -> queryDownloadStatus(call, result)
                    "install" -> installApk(call, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, splitChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openBilibili" -> openBilibiliSplit(result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appInfoChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "version" -> {
                        try {
                            val pkg = packageManager
                                .getPackageInfo(packageName, 0)
                            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                                pkg.longVersionCode else pkg.versionCode.toLong()
                            result.success(
                                mapOf(
                                    "versionName" to (pkg.versionName ?: ""),
                                    "versionCode" to code,
                                )
                            )
                        } catch (e: Exception) {
                            result.error("APP_INFO_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // 截屏/录屏开关：FLAG_SECURE 开启时系统禁止截屏（屏幕显示
        // 「涉及隐私/版权的内容不能截屏」）。App 自身默认从不加这个 flag，
        // 这里提供显式的清除/设置通道，供设置页开关 + 每次回前台复位。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, secureFlagChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "set" -> {
                        val secure = call.argument<Boolean>("secure") ?: false
                        setSecureFlag(secure)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // 整屏截图（MediaProjection）：先弹系统「开始投射/录屏」授权，
        // 授权后截取整块屏幕（含分屏的另一半）→ PNG 写到 cacheDir →
        // 返回文件路径给 Flutter。每次截图都重新请求授权（Android 14+
        // 复用投影需要前台服务，一次一授权最稳）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shotChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "captureScreen" -> requestScreenCapture(result)
                    else -> result.notImplemented()
                }
            }
        // Agent 任务前台服务（任务式 Agent 后台执行）：start/update/stop。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, agentTaskChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        AgentTaskService.start(this)
                        result.success(true)
                    }
                    "updateProgress" -> {
                        val goal = call.argument<String>("goal") ?: ""
                        val text = call.argument<String>("text") ?: ""
                        val step = (call.argument<Number>("step"))?.toInt() ?: 0
                        val total = (call.argument<Number>("total"))?.toInt() ?: 0
                        AgentTaskService.update(this, goal, text, step, total)
                        result.success(true)
                    }
                    "stop" -> {
                        AgentTaskService.stop(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // 后台运行保护：请求加入电池优化白名单，减少被国产 ROM 杀后台。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, batteryChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestIgnoreBatteryOptimizations" ->
                        requestIgnoreBatteryOptimizations(result)
                    "openBatteryOptimizationSettings" ->
                        openBatteryOptimizationSettings(result)
                    else -> result.notImplemented()
                }
            }
        // 朗读前台服务：start = 开始后台播放，stop = 结束。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ttsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            TtsPlaybackService.start(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "stop" -> {
                        try {
                            TtsPlaybackService.stop(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── 分享（FileProvider + 独立任务 chooser） ──────────────────────

    /**
     * 把文件复制到 cache/shared 后走 FileProvider + ACTION_SEND。
     * chooser 显式加 FLAG_ACTIVITY_NEW_TASK：目标 App（微信等）不会进本
     * App 的任务栈，分享完按返回一定回到 App（修复「分享后 App 变成微信」）。
     */
    private fun shareFile(call: MethodCall, result: MethodChannel.Result) {
        try {
            val filePath = call.argument<String>("filePath")
            val fileName = call.argument<String>("fileName")
            val mimeType = call.argument<String>("mimeType")
                ?: "application/octet-stream"
            val text = call.argument<String>("text")
            if (filePath == null || fileName == null) {
                result.error("BAD_ARGS", "filePath/fileName required", null)
                return
            }
            val src = File(filePath)
            if (!src.exists()) {
                result.error("NO_FILE", "file not found: $filePath", null)
                return
            }
            val shared = prepareSharedFile(src, fileName)
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                shared,
            )
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                if (!text.isNullOrEmpty()) putExtra(Intent.EXTRA_TEXT, text)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(intent, "分享").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(chooser)
            result.success(true)
        } catch (e: Exception) {
            result.error("SHARE_FAILED", e.message, null)
        }
    }

    /** 复制到 cache/shared 供 FileProvider 分享，返回副本。 */
    private fun prepareSharedFile(src: File, fileName: String): File {
        val dir = File(cacheDir, "shared").apply { mkdirs() }
        val safe = fileName.replace(Regex("[\\\\/:*?\"<>|]"), "_")
        val dst = File(dir, safe)
        src.inputStream().use { input ->
            dst.outputStream().use { out -> input.copyTo(out) }
        }
        return dst
    }

    // ── 自建更新（DownloadManager + FileProvider 安装） ─────────────

    private fun downloadApk(call: MethodCall, result: MethodChannel.Result) {
        try {
            val url = call.argument<String>("url")
            val fileName = call.argument<String>("fileName") ?: "libranote-update.apk"
            if (url.isNullOrEmpty()) {
                result.error("BAD_ARGS", "url required", null)
                return
            }
            val request = DownloadManager.Request(Uri.parse(url)).apply {
                setTitle("Libranote 更新")
                setDescription("正在下载新版本…")
                setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
                )
                setMimeType("application/vnd.android.package-archive")
                setDestinationInExternalPublicDir(
                    Environment.DIRECTORY_DOWNLOADS,
                    fileName,
                )
                setAllowedOverMetered(true)
                setAllowedOverRoaming(true)
            }
            val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            val id = dm.enqueue(request)
            result.success(id.toString())
        } catch (e: Exception) {
            result.error("DOWNLOAD_FAILED", e.message, null)
        }
    }

    private fun queryDownloadStatus(call: MethodCall, result: MethodChannel.Result) {
        try {
            val idStr = call.argument<String>("downloadId")
            val id = idStr?.toLongOrNull()
            if (id == null) {
                result.error("BAD_ARGS", "downloadId required", null)
                return
            }
            val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            val q = DownloadManager.Query().setFilterById(id)
            val cursor = dm.query(q)
            if (cursor == null || !cursor.moveToFirst()) {
                result.success(mapOf("status" to "not_found", "progress" to 0))
                cursor?.close()
                return
            }
            val status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val bytes = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
            val total = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
            cursor.close()
            val statusName = when (status) {
                DownloadManager.STATUS_SUCCESSFUL -> "success"
                DownloadManager.STATUS_FAILED -> "failed"
                DownloadManager.STATUS_PAUSED -> "paused"
                DownloadManager.STATUS_PENDING -> "pending"
                else -> "running"
            }
            result.success(
                mapOf(
                    "status" to statusName,
                    "progress" to (if (total > 0) (bytes * 100 / total).toInt() else 0),
                )
            )
        } catch (e: Exception) {
            result.error("QUERY_FAILED", e.message, null)
        }
    }

    private fun installApk(call: MethodCall, result: MethodChannel.Result) {
        try {
            // 没有「未知来源」权限 → 引导用户打开设置。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                try {
                    val uri = Uri.parse("package:$packageName")
                    startActivity(
                        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, uri)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(mapOf("needsPermission" to true))
                    return
                } catch (e: Exception) {
                    result.error("PERMISSION_FAILED", e.message, null)
                    return
                }
            }
            // 先解析 DownloadManager 落盘的本地路径。
            val idStr = call.argument<String>("downloadId")
            var apkPath: String? = call.argument<String>("apkPath")
            if (apkPath.isNullOrEmpty() && idStr != null) {
                val id = idStr.toLongOrNull()
                if (id != null) {
                    val dm =
                        getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                    val q = DownloadManager.Query().setFilterById(id)
                    val cursor = dm.query(q)
                    if (cursor != null && cursor.moveToFirst()) {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            val uri = dm.getUriForDownloadedFile(id)
                            if (uri != null) {
                                // content:// → 先拷到 cache/shared（FileProvider 只能发自有目录）。
                                val dir = File(cacheDir, "shared").apply { mkdirs() }
                                val dst = File(dir, "app_update.apk")
                                contentResolver.openInputStream(uri)?.use { input ->
                                    dst.outputStream().use { out -> input.copyTo(out) }
                                }
                                apkPath = dst.absolutePath
                            }
                        } else {
                            // API < 24：直接读本地路径列。
                            val col = cursor.getColumnIndex(DownloadManager.COLUMN_LOCAL_URI)
                            if (col >= 0) {
                                val localUri = cursor.getString(col)
                                if (!localUri.isNullOrEmpty()) {
                                    val f = File(android.net.Uri.parse(localUri).path ?: "")
                                    if (f.exists()) apkPath = f.absolutePath
                                }
                            }
                        }
                        cursor.close()
                    }
                }
            }
            if (apkPath.isNullOrEmpty()) {
                result.error("NO_APK", "apk file not found", null)
                return
            }
            val apk = File(apkPath)
            if (!apk.exists()) {
                result.error("NO_APK", "apk file not found: $apkPath", null)
                return
            }
            val installApk = if (apk.parentFile?.absolutePath == File(cacheDir, "shared").absolutePath) {
                apk
            } else {
                prepareSharedFile(apk, "app_update.apk")
            }
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", installApk)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            try {
                startActivity(intent)
            } catch (e: ActivityNotFoundException) {
                result.error("NO_INSTALLER", "没有可用的安装器", null)
                return
            }
            result.success(mapOf("needsPermission" to false))
        } catch (e: Exception) {
            result.error("INSTALL_FAILED", e.message, null)
        }
    }

    // ── 分屏打开哔哩哔哩 ─────────────────────────────────────────────

    /** 分屏打开哔哩哔哩（手机版 + HD 版都支持；HD 版包名是
     *  tv.danmaku.bilibilihd，之前只查手机版 → 平板只装 HD 时
     *  报「未检测到哔哩哔哩 App」）。 */
    private fun openBilibiliSplit(result: MethodChannel.Result) {
        try {
            val candidates = listOf("tv.danmaku.bili", "tv.danmaku.bilibilihd")
            var intent: android.content.Intent? = null
            var found = ""
            for (pkg in candidates) {
                val it = packageManager.getLaunchIntentForPackage(pkg)
                if (it != null) {
                    intent = it
                    found = pkg
                    break
                }
            }
            if (intent == null) {
                result.success(mapOf("ok" to false, "reason" to "not_installed"))
                return
            }
            intent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT or
                    Intent.FLAG_ACTIVITY_MULTIPLE_TASK
            )
            startActivity(intent)
            result.success(mapOf("ok" to true, "package" to found))
        } catch (e: Exception) {
            result.success(mapOf("ok" to false, "reason" to e.message))
        }
    }

    private fun setSecureFlag(secure: Boolean) {
        try {
            runOnUiThread {
                val flags = android.view.WindowManager.LayoutParams.FLAG_SECURE
                if (secure) {
                    window.addFlags(flags)
                } else {
                    window.clearFlags(flags)
                }
            }
        } catch (e: Exception) {
            // 个别窗口类型不支持 flag，忽略即可。
        }
    }

    // ── MediaProjection 整屏截图（分屏时连另一侧 App 一起截） ─────────

    /** 统一的返回格式：{"path": 文件路径 或 null, "error": 失败原因 或 null}。 */
    private fun finishShot(
        result: MethodChannel.Result?,
        path: String?,
        error: String?,
    ) {
        ScreenCaptureService.stop(this)
        try {
            shotHandlerThread?.quitSafely()
        } catch (_: Exception) {
        }
        shotHandlerThread = null
        try {
            result?.success(mapOf("path" to path, "error" to error))
        } catch (_: Exception) {
            // Result 已被消费（重复回调），忽略。
        }
    }

    /** 请求截屏授权（系统弹「开始录制或投射」确认框）。 */
    private fun requestScreenCapture(result: MethodChannel.Result) {
        try {
            if (pendingScreenShotResult != null) {
                result.success(mapOf("path" to null, "error" to "上一张整屏截图还没完成"))
                return
            }
            pendingScreenShotResult = result
            val manager =
                getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                        as MediaProjectionManager
            startActivityForResult(
                manager.createScreenCaptureIntent(),
                SCREEN_SHOT_REQUEST,
            )
        } catch (e: Exception) {
            val pending = pendingScreenShotResult
            pendingScreenShotResult = null
            finishShot(pending ?: result, null, "无法唤起系统投射授权：${e.message}")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SCREEN_SHOT_REQUEST) return
        val result = pendingScreenShotResult
        pendingScreenShotResult = null
        if (result == null) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            finishShot(result, null, "用户拒绝了整屏截图授权")
            return
        }
        // Android 10+：必须先让 mediaProjection 类型的前台服务跑起来，
        // 否则 createVirtualDisplay 会被系统拒绝（14+ 直接 SecurityException）。
        // startForegroundService 的 onStartCommand 排在当前消息之后执行，
        // 所以这里延后一点再真正开始投射。
        ScreenCaptureService.start(this)
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                val manager =
                    getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                            as MediaProjectionManager
                val projection: MediaProjection? =
                    manager.getMediaProjection(resultCode, data)
                if (projection == null) {
                    finishShot(result, null, "系统未返回投射会话")
                    return@postDelayed
                }
                captureWithProjection(projection, result)
            } catch (e: Exception) {
                finishShot(result, null, "整屏截图失败：${e.message}")
            }
        }, 250)
    }

    /** 用已授权的投影截一帧屏幕 → PNG 写到 cacheDir，返回路径。 */
    private fun captureWithProjection(
        projection: MediaProjection,
        result: MethodChannel.Result,
    ) {
        // 分屏时 resources.displayMetrics 只有本 App 那半块窗口的尺寸，
        // 必须取「整块物理屏」的尺寸，否则截出来还是只有自己这一半。
        var width: Int
        var height: Int
        val density = resources.configuration.densityDpi
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.maximumWindowMetrics.bounds
            width = bounds.width()
            height = bounds.height()
        } else {
            val metrics = android.util.DisplayMetrics()
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.getRealMetrics(metrics)
            width = metrics.widthPixels
            height = metrics.heightPixels
        }
        if (width <= 0 || height <= 0) {
            width = resources.displayMetrics.widthPixels
            height = resources.displayMetrics.heightPixels
        }
        if (width <= 0 || height <= 0) {
            projection.stop()
            finishShot(result, null, "读不到屏幕尺寸")
            return
        }

        val thread = HandlerThread("libranote-shot").apply { start() }
        shotHandlerThread = thread
        val handler = Handler(thread.looper)

        val imageReader =
            ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)

        // Android 14+ 要求 createVirtualDisplay 之前先注册回调。
        projection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {}
        }, handler)

        val vd: VirtualDisplay?
        try {
            vd = projection.createVirtualDisplay(
                "libranote-shot",
                width,
                height,
                density,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                imageReader.surface,
                null,
                handler,
            )
        } catch (e: Exception) {
            try {
                imageReader.close()
            } catch (_: Exception) {
            }
            try {
                projection.stop()
            } catch (_: Exception) {
            }
            finishShot(result, null, "创建投射虚拟屏失败：${e.message}")
            return
        }

        val done = java.util.concurrent.atomic.AtomicBoolean(false)

        fun cleanup() {
            try {
                vd?.release()
            } catch (_: Exception) {
            }
            try {
                imageReader.close()
            } catch (_: Exception) {
            }
            try {
                projection.stop()
            } catch (_: Exception) {
            }
        }

        // 帧就绪回调（比固定延时可靠：虚拟屏首帧到达时间因机型而异）。
        imageReader.setOnImageAvailableListener({ reader ->
            if (done.get()) {
                try {
                    reader.acquireLatestImage()?.close()
                } catch (_: Exception) {
                }
                return@setOnImageAvailableListener
            }
            val image = try {
                reader.acquireLatestImage()
            } catch (e: Exception) {
                null
            } ?: return@setOnImageAvailableListener
            if (!done.compareAndSet(false, true)) {
                image.close()
                return@setOnImageAvailableListener
            }
            var path: String? = null
            var error: String? = null
            try {
                val plane = image.planes[0]
                val buffer = plane.buffer
                val pixelStride = plane.pixelStride
                val rowStride = plane.rowStride
                val rowPadding = rowStride - pixelStride * width
                val bitmapWidth = width + rowPadding / pixelStride
                val bitmap = Bitmap.createBitmap(
                    bitmapWidth, height, Bitmap.Config.ARGB_8888,
                )
                bitmap.copyPixelsFromBuffer(buffer)
                image.close()
                val cropped = Bitmap.createBitmap(bitmap, 0, 0, width, height)
                if (cropped !== bitmap) bitmap.recycle()
                val file = File(cacheDir, "screen_shot.png")
                FileOutputStream(file).use {
                    cropped.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
                cropped.recycle()
                path = file.absolutePath
            } catch (e: Exception) {
                error = "截屏帧解码失败：${e.message}"
                try {
                    image.close()
                } catch (_: Exception) {
                }
            } finally {
                cleanup()
            }
            val finalPath = path
            val finalError = error
            Handler(Looper.getMainLooper()).post {
                finishShot(result, finalPath, finalError)
            }
        }, handler)

        // 兜底超时：3 秒还没等到帧就放弃，回退到 App 内截图。
        handler.postDelayed({
            if (done.compareAndSet(false, true)) {
                cleanup()
                Handler(Looper.getMainLooper()).post {
                    finishShot(result, null, "等待屏幕帧超时")
                }
            }
        }, 3000)
    }

    private fun requestIgnoreBatteryOptimizations(result: MethodChannel.Result) {
        try {
            val intent = android.content.Intent(
                android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                android.net.Uri.parse("package:$packageName")
            )
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            // 个别 ROM 不支持直接申请 → 退回打开系统电池设置列表。
            try {
                openBatteryOptimizationSettings(result)
            } catch (e2: Exception) {
                result.success(false)
            }
        }
    }

    private fun openBatteryOptimizationSettings(result: MethodChannel.Result) {
        try {
            val intent = android.content.Intent(
                android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
            )
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun saveToDownloads(call: MethodCall, result: MethodChannel.Result) {
        try {
            val filePath = call.argument<String>("filePath")
            val fileName = call.argument<String>("fileName")
            val mimeType = call.argument<String>("mimeType")
                ?: "application/octet-stream"
            if (filePath == null || fileName == null) {
                result.error("BAD_ARGS", "filePath/fileName required", null)
                return
            }
            val file = File(filePath)
            if (!file.exists()) {
                result.error("NO_FILE", "file not found: $filePath", null)
                return
            }
            val uri = insertIntoDownloads(file, fileName, mimeType)
            result.success(uri?.toString())
        } catch (e: Exception) {
            result.error("SAVE_FAILED", e.message, null)
        }
    }

    private fun insertIntoDownloads(
        file: File,
        fileName: String,
        mimeType: String,
    ): android.net.Uri? {
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // 明确落到 Download/Libranote 子目录（文件 App 更好找）。
                put(
                    MediaStore.Downloads.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/Libranote",
                )
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
        }
        val collection =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                @Suppress("DEPRECATION")
                MediaStore.Downloads.EXTERNAL_CONTENT_URI
            }
        val uri = resolver.insert(collection, values)
        if (uri == null) {
            // 个别 ROM 的 MediaStore 插入失败 → 旧系统直接写公共下载目录兜底。
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                @Suppress("DEPRECATION")
                val dir = Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS
                )
                val out = File(dir, fileName)
                file.inputStream().use { input ->
                    out.outputStream().use { o -> input.copyTo(o) }
                }
                return Uri.fromFile(out)
            }
            return null
        }
        try {
            resolver.openOutputStream(uri)?.use { out ->
                file.inputStream().use { input -> input.copyTo(out) }
            }
        } catch (e: Exception) {
            // 写入失败 → 清理半截记录。
            try {
                resolver.delete(uri, null, null)
            } catch (_: Exception) {
            }
            throw e
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        }
        return uri
    }
}
