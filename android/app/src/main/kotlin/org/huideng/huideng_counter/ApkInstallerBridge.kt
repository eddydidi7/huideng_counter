package org.huideng.huideng_counter

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Opens system confirmation only. Never installs or confirms automatically. */
class ApkInstallerBridge(private val activity: MainActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "org.huideng.counter/apk")
    private var pending: File? = null
    private var leftForSettings = false
    init {
        channel.setMethodCallHandler { call, result ->
            try {
                if (call.method == "current") {
                    val current = activity.packageManager.getPackageInfo(activity.packageName, 0)
                    result.success(mapOf("versionName" to current.versionName,
                        "versionCode" to if (Build.VERSION.SDK_INT >= 28) current.longVersionCode else current.versionCode.toLong()))
                    return@setMethodCallHandler
                }
                val file = checked(call.arguments as? String ?: "")
                when (call.method) {
                    "share" -> {
                        val uri = FileProvider.getUriForFile(activity, activity.packageName + ".apkfiles", file)
                        activity.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                            type = "application/vnd.android.package-archive"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            clipData = android.content.ClipData.newRawUri("APK", uri)
                        }, "分享安装包"))
                        result.success(null)
                    }
                    "inspect" -> {
                        val info = activity.packageManager.getPackageArchiveInfo(file.path, 0)
                            ?: throw IllegalArgumentException("Invalid APK")
                        result.success(mapOf("versionName" to info.versionName, "packageName" to info.packageName))
                    }
                    "verifyUpdate" -> {
                        @Suppress("DEPRECATION")
                        val candidate = activity.packageManager.getPackageArchiveInfo(file.path, android.content.pm.PackageManager.GET_SIGNATURES)
                            ?: throw IllegalArgumentException("Invalid APK")
                        @Suppress("DEPRECATION")
                        val installed = activity.packageManager.getPackageInfo(activity.packageName, android.content.pm.PackageManager.GET_SIGNATURES)
                        require(candidate.packageName == activity.packageName)
                        @Suppress("DEPRECATION")
                        require(candidate.signatures?.map { it.toCharsString() }?.toSet() == installed.signatures?.map { it.toCharsString() }?.toSet()
                            && !candidate.signatures.isNullOrEmpty())
                        val code = if (Build.VERSION.SDK_INT >= 28) candidate.longVersionCode else candidate.versionCode.toLong()
                        val currentCode = if (Build.VERSION.SDK_INT >= 28) installed.longVersionCode else installed.versionCode.toLong()
                        require(code > currentCode)
                        result.success(mapOf("versionCode" to code, "versionName" to candidate.versionName))
                    }
                    "install" -> {
                        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
                            pending = file
                            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:" + activity.packageName)))
                            result.success("permission_required")
                        } else { launch(file); result.success("installer_opened") }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { pending = null; result.error("APK_INSTALL", "无法打开安装包或系统安装设置", null) }
        }
    }
    private fun checked(path: String): File {
        val file = File(path).canonicalFile
        val root = File(activity.filesDir, "apk_share").canonicalFile
        require(file.path.startsWith(root.path + File.separator) && file.isFile && file.extension.equals("apk", true))
        require(file.length() in 1..524288000L)
        require(activity.packageManager.getPackageArchiveInfo(file.path, 0) != null)
        return file
    }
    private fun launch(file: File) {
        val uri = FileProvider.getUriForFile(activity, activity.packageName + ".apkfiles", checked(file.path))
        activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = android.content.ClipData.newRawUri("APK", uri)
        })
    }
    fun pause() { if (pending != null) leftForSettings = true }
    fun resume() {
        if (!leftForSettings) return
        leftForSettings = false
        val file = pending ?: return
        pending = null
        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) return
        try { launch(file) } catch (e: Exception) {
            android.widget.Toast.makeText(activity, "无法继续安装，请再次点击安装", android.widget.Toast.LENGTH_LONG).show()
        }
    }
    fun destroy() { pending = null; channel.setMethodCallHandler(null) }
}
