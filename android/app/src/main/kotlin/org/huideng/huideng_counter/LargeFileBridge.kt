package org.huideng.huideng_counter

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Large files for 文件传输助手 without copying them into the app cache
 * (file_picker would duplicate a 5 GB video before sending). The document is
 * read in place with random access, so a transfer can resume at any offset,
 * and the read permission is persisted so it survives an app restart.
 */
class LargeFileBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "org.huideng.counter/large_files")
    private val io = Executors.newSingleThreadExecutor()
    private val open = HashMap<String, Pair<ParcelFileDescriptor, FileInputStream>>()
    private var pickResult: MethodChannel.Result? = null
    val requestCode = 6231

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pick" -> pick(result)
                "size" -> background(result) { sizeOf(Uri.parse(call.argument<String>("uri")!!)) }
                "read" -> {
                    val uri = call.argument<String>("uri")!!
                    val offset = (call.argument<Number>("offset")!!).toLong()
                    val length = (call.argument<Number>("length")!!).toInt()
                    if (length < 0 || length > 16 * 1024 * 1024 || offset < 0) {
                        result.error("INVALID_RANGE", "Invalid range", null)
                    } else background(result) { read(uri, offset, length) }
                }
                "close" -> background(result) { close(call.argument<String>("uri")!!); null }
                else -> result.notImplemented()
            }
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                activity.runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                activity.runOnUiThread { result.error("IO_FAILED", e.message, null) }
            }
        }
    }

    private fun pick(result: MethodChannel.Result) {
        if (pickResult != null) { result.error("BUSY", "Picker already open", null); return }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        pickResult = result
        try { activity.startActivityForResult(intent, requestCode) }
        catch (e: Exception) { pickResult = null; result.error("UNAVAILABLE", e.message, null) }
    }

    fun onActivityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        val pending = pickResult ?: return true
        pickResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { pending.success(null); return true }
        io.execute {
            try {
                try {
                    activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } catch (_: SecurityException) { /* not persistable: still readable now */ }
                var name = "file"
                activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) name = it.getString(0) ?: name
                }
                val size = sizeOf(uri)
                activity.runOnUiThread {
                    pending.success(mapOf("uri" to uri.toString(), "name" to name, "size" to size))
                }
            } catch (e: Exception) {
                activity.runOnUiThread { pending.error("IO_FAILED", e.message, null) }
            }
        }
        return true
    }

    // 64-bit sizes: Long throughout, never Int.
    private fun sizeOf(uri: Uri): Long {
        activity.contentResolver.openFileDescriptor(uri, "r")?.use { return it.statSize }
        return -1L
    }

    private fun read(key: String, offset: Long, length: Int): ByteArray {
        val (_, stream) = open.getOrPut(key) {
            val pfd = activity.contentResolver.openFileDescriptor(Uri.parse(key), "r")
                ?: throw IllegalStateException("SOURCE_UNAVAILABLE")
            Pair(pfd, FileInputStream(pfd.fileDescriptor))
        }
        val file = stream.channel
        val buffer = ByteBuffer.allocate(length)
        var position = offset
        while (buffer.hasRemaining()) {
            val n = file.read(buffer, position)
            if (n < 0) break
            position += n
        }
        return buffer.array().copyOf(buffer.position())
    }

    private fun close(key: String) {
        open.remove(key)?.let { (pfd, stream) ->
            try { stream.close() } catch (_: Exception) {}
            try { pfd.close() } catch (_: Exception) {}
        }
    }

    fun destroy() {
        for (key in open.keys.toList()) close(key)
        pickResult?.error("CANCELLED", "Closed", null)
        pickResult = null
        io.shutdown()
    }
}
