package org.huideng.huideng_counter

import android.app.*
import android.content.Intent
import android.content.Context
import android.content.pm.ServiceInfo
import android.media.*
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.*
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.Executors

/** Owns offline speech independently of Flutter, Activity and route lifecycle. */
class ReadingService : Service() {
    companion object {
        var live: ReadingService? = null
        const val CHANNEL = "note_reading"
        const val NOTIFICATION = 8043
        fun key(scope: String, note: String) = "position:$scope:$note"
        fun snapshot(context: Context, scope: String, note: String): Map<String, Any?> {
            val current = live
            if (current != null && current.scope == scope && current.note == note) return current.state()
            val saved = context.getSharedPreferences("reading_sessions", 0).getString(key(scope,note), null)
            if (saved == null) return emptyMap()
            val json = JSONObject(saved)
            return json.keys().asSequence().associateWith { json.opt(it) }.toMutableMap().apply { put("playing",false); put("active",false) }
        }
    }
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var engine: TextToSpeech? = null
    private var ready = false
    private var offsets = emptyList<Long>()
    private var source: RandomAccessFile? = null
    private var scope = ""
    private var note = ""
    private var title = "笔记朗读"
    private var path = ""
    private var index = 0
    private var offset = 0
    private var rate = 1f
    private var repeat = false
    private var language = "auto"
    private var playing = false
    private var active = true
    private var error = ""
    private var serial = 0
    private var utterance = ""
    private var start = 0
    private var end = 0
    private var savedAt = 0L
    private lateinit var audio: AudioManager
    private lateinit var focus: AudioFocusRequest
    private lateinit var media: MediaSession
    private var wake: PowerManager.WakeLock? = null
    override fun onBind(intent: Intent?) = null
    override fun onCreate() {
        super.onCreate(); live = this
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(NotificationChannel(CHANNEL,"笔记朗读",NotificationManager.IMPORTANCE_LOW))
        media = MediaSession(this,"NoteReader")
        media.setCallback(object: MediaSession.Callback() {
            override fun onPlay() { command("resume") }
            override fun onPause() { command("pause") }
            override fun onStop() { command("stop") }
            override fun onSkipToNext() { command("next") }
            override fun onSkipToPrevious() { command("previous") }
        }); media.isActive = true
        audio = getSystemService(AUDIO_SERVICE) as AudioManager
        focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setOnAudioFocusChangeListener { if(it < 0) command("pause") }.build()
        wake = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"wenshu:reading")
        foreground()
        engine = TextToSpeech(applicationContext) { status -> main.post {
            ready = status == TextToSpeech.SUCCESS
            if (!ready) { error="没有可用的离线语音引擎，请安装语音包"; command("pause") }
            else { engine?.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()); engine?.setOnUtteranceProgressListener(object: UtteranceProgressListener() {
                override fun onStart(id: String) {}
                override fun onDone(id: String) { main.post { if(id==utterance && playing) { offset=end; persist(true); speak() } } }
                @Deprecated("Deprecated in Android") override fun onError(id: String) { failed(id) }
                override fun onError(id: String, code: Int) { failed(id) }
                override fun onRangeStart(id: String, from: Int, to: Int, frame: Int) { main.post { if(id==utterance) { offset=start+from; persist(false) } } }
            }); if(playing) speak() }
        } }
    }
    private fun failed(id: String) { main.post { if(id==utterance) { error="离线朗读失败，请检查语言语音包"; command("pause") } } }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if(intent == null) { stopSelf(); return START_NOT_STICKY }
        when(intent.action) {
            "start" -> {
                serial++; val token=serial
                command("pause")
                scope=intent.getStringExtra("scope") ?: ""; note=intent.getStringExtra("noteId") ?: ""
                title=intent.getStringExtra("title")?.take(160)?.ifBlank { "笔记朗读" } ?: "笔记朗读"
                path=intent.getStringExtra("path") ?: ""
                index=intent.getIntExtra("index",0); offset=intent.getIntExtra("offset",0)
                rate=normalized(intent.getFloatExtra("rate",1f)); repeat=intent.getBooleanExtra("repeat",false)
                language=intent.getStringExtra("language") ?: "auto"
                active=true; playing=true; error=""; offsets=emptyList(); foreground()
                worker.execute {
                    try {
                        val file=File(path).canonicalFile
                        require(file.path.startsWith(File(filesDir,"reader_sessions").canonicalPath+File.separator))
                        val positions=ArrayList<Long>(); positions.add(0L)
                        file.inputStream().buffered().use { input ->
                            val buffer=ByteArray(65536); var cursor=0L
                            while(true) {
                                val size=input.read(buffer); if(size<0) break
                                for(i in 0 until size) if(buffer[i]==10.toByte() && cursor+i+1<file.length()) positions.add(cursor+i+1)
                                cursor+=size
                            }
                        }
                        val scan=RandomAccessFile(file,"r")
                        main.post {
                            if(serial!=token || live!==this) { scan.close() }
                            else { source?.close(); source=scan; offsets=positions; index=index.coerceIn(0,(offsets.size-1).coerceAtLeast(0)); if(playing) speak() }
                        }
                    } catch (_:Exception) { main.post { if(serial==token) { error="朗读文件读取失败，原笔记未改变"; command("pause") } } }
                }
            }
            else -> {
                if(intent.hasExtra("noteId") && (intent.getStringExtra("noteId")!=note || intent.getStringExtra("scope")!=scope)) return START_NOT_STICKY
                if(intent.hasExtra("rate")) rate=normalized(intent.getFloatExtra("rate",rate))
                if(intent.hasExtra("repeat")) repeat=intent.getBooleanExtra("repeat",repeat)
                if(intent.hasExtra("language")) language=intent.getStringExtra("language") ?: "auto"
                command(intent.action ?: "pause")
            }
        }
        return START_NOT_STICKY
    }
    private fun normalized(value: Float) = (Math.round(value.coerceIn(.3f,3f)*10)/10f)
    fun state(): Map<String,Any?> = mapOf("scope" to scope,"noteId" to note,"index" to index,"offset" to offset,"rate" to rate.toDouble(),"playing" to playing,"active" to active,"count" to offsets.size,"error" to error,"path" to path,"title" to title,"lastReadAt" to System.currentTimeMillis())
    private fun persist(force: Boolean) {
        if(note.isEmpty() || (!force && SystemClock.elapsedRealtime()-savedAt<3000)) return
        savedAt=SystemClock.elapsedRealtime()
        getSharedPreferences("reading_sessions",0).edit().putString(key(scope,note),JSONObject(state()).toString()).putFloat("rate:$scope",rate).apply()
    }
    private fun text(): String {
        source!!.seek(offsets[index])
        val line=source!!.readLine() ?: return ""
        return JSONObject(String(line.toByteArray(Charsets.ISO_8859_1),Charsets.UTF_8)).optString("text")
    }
    private fun speak() {
        if(!playing || !ready || offsets.isEmpty()) return
        try {
            var content=""; var scanned=0
            while(scanned<=offsets.size) {
                if(index>=offsets.size) {
                    if(repeat) { index=0; offset=0 } else { index=offsets.size-1; command("stop"); return }
                }
                content=text()
                if(content.isNotBlank() && offset<content.length) break
                index++; offset=0; scanned++
            }
            if(scanned>offsets.size) { command("stop"); return }
            val lang=if(language=="auto") { if(content.any { it in '㐀'..'鿿' }) "zh" else "en" } else language
            val voice=engine!!.voices?.filter { !it.isNetworkConnectionRequired && it.locale.language==lang && !it.features.contains("notInstalled") }?.maxByOrNull { it.quality }
            if(voice==null) { error="请先安装${if(lang=="zh") "中文" else "英文"}离线语音包"; command("pause"); return }
            foreground()
            if(audio.requestAudioFocus(focus)!=AudioManager.AUDIOFOCUS_REQUEST_GRANTED) { error="其他应用正在使用音频"; command("pause"); return }
            if(wake?.isHeld != true) wake?.acquire(600000L)
            engine!!.setVoice(voice); engine!!.setSpeechRate(rate)
            start=offset.coerceIn(0,content.length); end=(start+900).coerceAtMost(content.length)
            if(end<content.length && end>start && Character.isHighSurrogate(content[end-1])) end--
            utterance="${++serial}:$index:$start"
            if(engine!!.speak(content.substring(start,end),TextToSpeech.QUEUE_FLUSH,Bundle(),utterance)!=TextToSpeech.SUCCESS) { error="朗读失败"; command("pause") }
            persist(true); notifyState()
        } catch (_:Exception) { error="朗读暂不可用，位置已保留"; command("pause") }
    }
    private fun command(action: String) {
        when(action) {
            "stop" -> { playing=false; active=false; utterance=""; engine?.stop(); persist(true); releaseFocus(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); return }
            "pause" -> { playing=false; utterance=""; engine?.stop(); releaseFocus() }
            "resume" -> { playing=true; active=true; error=""; speak() }
            "next", "previous" -> { utterance=""; engine?.stop(); index=(index+(if(action=="next") 1 else -1)).coerceIn(0,(offsets.size-1).coerceAtLeast(0)); offset=0; if(playing) speak() }
            "configure" -> { if(playing) { utterance=""; engine?.stop(); speak() } }
        }
        persist(true); notifyState()
    }
    private fun releaseFocus() { audio.abandonAudioFocusRequest(focus); if(wake?.isHeld==true) wake?.release() }
    private fun notification(): Notification {
        fun action(name: String, label: String, icon: Int) = Notification.Action.Builder(icon,label,PendingIntent.getService(this,name.hashCode(),Intent(this,ReadingService::class.java).setAction(name),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)).build()
        val launch=PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this,CHANNEL).setSmallIcon(android.R.drawable.ic_media_play).setContentTitle(title)
            .setContentText(if(error.isNotEmpty()) error else if(playing) "正在朗读 · ${index+1}段 · ${String.format(java.util.Locale.US,"%.1f",rate)}x" else "已暂停 · ${index+1}段")
            .setContentIntent(launch).setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PRIVATE).setOngoing(playing)
            .addAction(action("previous","上一段",android.R.drawable.ic_media_previous))
            .addAction(action(if(playing) "pause" else "resume",if(playing) "暂停" else "继续",if(playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play))
            .addAction(action("next","下一段",android.R.drawable.ic_media_next))
            .addAction(action("stop","停止",android.R.drawable.ic_menu_close_clear_cancel))
            .setStyle(Notification.MediaStyle().setMediaSession(media.sessionToken).setShowActionsInCompactView(0,1,2)).build()
    }
    private fun foreground() {
        if(Build.VERSION.SDK_INT>=29) startForeground(NOTIFICATION,notification(),ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        else startForeground(NOTIFICATION,notification())
    }
    private fun notifyState() {
        media.setPlaybackState(PlaybackState.Builder().setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_STOP or PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS)
            .setState(if(playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,offset.toLong(),rate).build())
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION,notification())
    }
    override fun onDestroy() {
        playing=false; active=false; persist(true); utterance=""; serial++
        engine?.stop(); engine?.shutdown(); releaseFocus(); source?.close(); worker.shutdown(); media.release()
        if(live===this) live=null
        super.onDestroy()
    }
}
