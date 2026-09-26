package org.huideng.huideng_counter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.view.KeyEvent

class MainActivity : FlutterActivity() {
    private var apkInstaller: ApkInstallerBridge? = null
    private var reader: ReaderBridge? = null
    private var largeFiles: LargeFileBridge? = null
    private var speechResult: MethodChannel.Result? = null
    private var ringtoneResult: MethodChannel.Result? = null
    private val speechRequest = 6217
    private var volumeEnabled = false
    private var resumed = false
    private var volumeChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.huideng.counter/notifications")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "settings" -> {
                            startActivity(android.content.Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName))
                            result.success(null)
                        }
                        "ringtone" -> {
                            if (ringtoneResult != null) { result.error("BUSY", "Picker already open", null) }
                            else {
                                val current = call.arguments as? String
                                val uri = when(current) {
                                    "silent" -> null
                                    null, "default" -> android.provider.Settings.System.DEFAULT_NOTIFICATION_URI
                                    else -> android.net.Uri.parse(current)
                                }
                                val intent = android.content.Intent(android.media.RingtoneManager.ACTION_RINGTONE_PICKER)
                                    .putExtra(android.media.RingtoneManager.EXTRA_RINGTONE_TYPE, android.media.RingtoneManager.TYPE_NOTIFICATION)
                                    .putExtra(android.media.RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
                                    .putExtra(android.media.RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, true)
                                    .putExtra(android.media.RingtoneManager.EXTRA_RINGTONE_EXISTING_URI, uri)
                                startActivityForResult(intent, 6220)
                                ringtoneResult = result
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) { result.error("UNAVAILABLE", e.message, null) }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.huideng.counter/haptics")
            .setMethodCallHandler { call, result ->
                if (call.method != "count") { result.notImplemented() }
                else {
                    try {
                        @Suppress("DEPRECATION")
                        val vibrator = if (android.os.Build.VERSION.SDK_INT >= 31) {
                            getSystemService(android.os.VibratorManager::class.java)?.defaultVibrator
                        } else { getSystemService(android.content.Context.VIBRATOR_SERVICE) as? android.os.Vibrator }
                        if (vibrator == null || !vibrator.hasVibrator() || !hasWindowFocus() || android.provider.Settings.System.getInt(contentResolver, android.provider.Settings.System.HAPTIC_FEEDBACK_ENABLED, 1) == 0) {
                            result.success(false)
                        } else {
                            val audio = android.media.AudioAttributes.Builder()
                                .setUsage(android.media.AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
                            if (android.os.Build.VERSION.SDK_INT >= 26) {
                                val effect = if (android.os.Build.VERSION.SDK_INT >= 29) {
                                    android.os.VibrationEffect.createPredefined(android.os.VibrationEffect.EFFECT_TICK)
                                } else { android.os.VibrationEffect.createOneShot(25, 80) }
                                if (android.os.Build.VERSION.SDK_INT >= 33) {
                                    vibrator.vibrate(effect, android.os.VibrationAttributes.Builder()
                                        .setUsage(android.os.VibrationAttributes.USAGE_TOUCH).build())
                                } else {
                                    @Suppress("DEPRECATION")
                                    vibrator.vibrate(effect, audio)
                                }
                            } else {
                                @Suppress("DEPRECATION")
                                vibrator.vibrate(25, audio)
                            }
                            result.success(true)
                        }
                    } catch (_: Exception) { result.success(false) }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.huideng.counter/location")
            .setMethodCallHandler { call, result ->
                if (call.method != "placeName") { result.notImplemented() }
                else {
                    val lat = call.argument<Number>("latitude")?.toDouble()
                    val lon = call.argument<Number>("longitude")?.toDouble()
                    if (lat == null || lon == null || !lat.isFinite() || !lon.isFinite() || lat !in -90.0..90.0 || lon !in -180.0..180.0) {
                        result.error("INVALID_LOCATION", "Invalid location", null)
                    } else {
                        Thread {
                            val name = try {
                                @Suppress("DEPRECATION")
                                val address = android.location.Geocoder(this, java.util.Locale.getDefault()).getFromLocation(lat, lon, 1)?.firstOrNull()
                                listOfNotNull(address?.subLocality, address?.locality, address?.adminArea, address?.countryName)
                                    .filter { it.isNotBlank() }.distinct().joinToString(", ")
                            } catch (_: Exception) { "" }
                            runOnUiThread { result.success(name) }
                        }.start()
                    }
                }
            }
        largeFiles = LargeFileBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        reader = ReaderBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        apkInstaller = ApkInstallerBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.huideng.counter/notes")
            .setMethodCallHandler { call, result ->
                if (call.method == "shareText") {
                    val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(android.content.Intent.EXTRA_TEXT, call.arguments as? String ?: "")
                    }
                    startActivity(android.content.Intent.createChooser(intent, null))
                    result.success(null)
                } else result.notImplemented()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.huideng.counter/speech")
            .setMethodCallHandler { call, result ->
                if (call.method != "recognize") { result.notImplemented() }
                else if (speechResult != null) { result.error("BUSY", "Speech recognition is already open", null) }
                else {
                    val intent = android.content.Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                        putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL, android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                        putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE, call.arguments as? String ?: "zh-CN")
                    }
                    try { speechResult = result; startActivityForResult(intent, speechRequest) }
                    catch (e: android.content.ActivityNotFoundException) { speechResult = null; result.error("UNAVAILABLE", "此手机没有系统语音识别服务，请使用输入法麦克风。", null) }
                    catch (e: Exception) { speechResult = null; result.error("FAILED", "无法启动系统语音输入", null) }
                }
            }
        volumeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.huideng.counter/volume")
        volumeChannel?.setMethodCallHandler { call, result ->
            if (call.method == "setEnabled") {
                volumeEnabled = call.arguments == true
                result.success(null)
            } else result.notImplemented()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (largeFiles?.onActivityResult(requestCode, resultCode, data) == true) return
        if (requestCode == 6220) {
            val pending = ringtoneResult
            ringtoneResult = null
            @Suppress("DEPRECATION")
            val uri = data?.getParcelableExtra<android.net.Uri>(android.media.RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
            pending?.success(if (resultCode != android.app.Activity.RESULT_OK) null
                else if (uri == null) "silent"
                else if (android.media.RingtoneManager.isDefault(uri)) "default" else uri.toString())
        }
        if (requestCode == speechRequest) {
            val pending = speechResult
            speechResult = null
            pending?.success(if (resultCode == android.app.Activity.RESULT_OK) data?.getStringArrayListExtra(android.speech.RecognizerIntent.EXTRA_RESULTS)?.firstOrNull() else null)
        }
    }

    override fun onDestroy() {
        ringtoneResult?.error("CANCELLED", "Picker closed", null)
        ringtoneResult = null
        speechResult?.error("CANCELLED", "Speech input closed", null)
        speechResult = null
        reader?.destroy()
        largeFiles?.destroy()
        apkInstaller?.destroy()
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        reader?.resume()
        apkInstaller?.resume()
    }

    override fun onPause() {
        resumed = false
        reader?.pause()
        apkInstaller?.pause()
        super.onPause()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (volumeEnabled && resumed && hasWindowFocus() && (event.keyCode == KeyEvent.KEYCODE_VOLUME_UP || event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                volumeChannel?.invokeMethod("increment", if (event.keyCode == KeyEvent.KEYCODE_VOLUME_UP) "volumeUp" else "volumeDown")
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }
}
