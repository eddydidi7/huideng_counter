package org.huideng.huideng_counter
import android.app.Activity
import android.content.Intent
import android.os.Build
import android.speech.tts.TextToSpeech
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class ReaderBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel=MethodChannel(messenger,"org.huideng.counter/reader")
    private var originalBrightness: Float?=null
    private var readingBrightness: Float?=null
    init {
        channel.setMethodCallHandler { call,result ->
            try {
                val args=call.arguments as? Map<*,*> ?: emptyMap<String,Any>()
                when(call.method) {
                    "snapshot" -> result.success(ReadingService.snapshot(activity,args["scope"] as? String ?: "",args["noteId"] as? String ?: ""))
                    "start", "control" -> {
                        val intent=Intent(activity,ReadingService::class.java).setAction(if(call.method=="start") "start" else args["action"] as? String ?: "pause")
                        for(key in listOf("scope","noteId","title","path","language")) (args[key] as? String)?.let { intent.putExtra(key,it) }
                        for(key in listOf("index","offset")) (args[key] as? Number)?.let { intent.putExtra(key,it.toInt()) }
                        (args["rate"] as? Number)?.let { intent.putExtra("rate",it.toFloat()) }
                        (args["repeat"] as? Boolean)?.let { intent.putExtra("repeat",it) }
                        if(call.method=="start") {
                            if(Build.VERSION.SDK_INT>=33 && activity.checkSelfPermission("android.permission.POST_NOTIFICATIONS")!=android.content.pm.PackageManager.PERMISSION_GRANTED) activity.requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"),8043)
                            activity.startForegroundService(intent)
                        } else if(ReadingService.live!=null) activity.startService(intent)
                        result.success(true)
                    }
                    "brightness" -> { if(originalBrightness==null) originalBrightness=activity.window.attributes.screenBrightness; readingBrightness=(call.arguments as Number).toFloat().coerceIn(.02f,1f); brightness(readingBrightness!!); result.success(null) }
                    "exit" -> { restore(); result.success(null) }
                    "settings", "install" -> {
                        try { activity.startActivity(Intent(if(call.method=="install") TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA else "com.android.settings.TTS_SETTINGS")) }
                        catch(_:Exception) { activity.startActivity(Intent(android.provider.Settings.ACTION_SETTINGS)) }; result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch(_:Exception) { result.error("READER_UNAVAILABLE","无法启动朗读，请检查系统语音设置与后台权限",null) }
        }
    }
    private fun brightness(value:Float) { val params=activity.window.attributes; params.screenBrightness=value; activity.window.attributes=params }
    private fun restore() { originalBrightness?.let { brightness(it) }; originalBrightness=null; readingBrightness=null }
    fun pause() { originalBrightness?.let { brightness(it) } }
    fun resume() { readingBrightness?.let { brightness(it) } }
    fun destroy() { restore(); channel.setMethodCallHandler(null) }
}
