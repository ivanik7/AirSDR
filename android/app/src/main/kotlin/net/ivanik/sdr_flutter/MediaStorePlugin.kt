// SPDX-License-Identifier: GPL-3.0-or-later
package net.ivanik.sdr_flutter

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Saves decoded images (e.g. SSTV output) to Android shared storage.
 *
 * On API 29+ this writes through MediaStore into Pictures/<album>, visible to the
 * gallery and other apps, with no storage permission required. On API 26-28 it
 * falls back to app-specific external files storage (getExternalFilesDir), which is
 * NOT visible in the system gallery/Pictures app; this is a documented limitation of
 * the legacy path rather than requesting WRITE_EXTERNAL_STORAGE.
 */
class MediaStorePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var context: Context? = null
    private var channel: MethodChannel? = null
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "sdr/media").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveImage") {
            result.notImplemented()
            return
        }
        val ctx = context
        if (ctx == null) {
            result.error("save_failed", "Engine detached", null)
            return
        }

        val bytes = call.argument<ByteArray>("bytes")
        val displayName = call.argument<String>("displayName")
        val mimeType = call.argument<String>("mimeType") ?: "image/png"
        val album = call.argument<String>("album") ?: "AirSDR"

        if (bytes == null || bytes.isEmpty()) {
            result.error("invalid_argument", "bytes must not be empty", null)
            return
        }
        if (displayName == null || displayName.isEmpty() ||
            displayName.contains('/') || displayName.contains('\\')
        ) {
            result.error(
                "invalid_argument",
                "displayName must not be empty or contain path separators",
                null,
            )
            return
        }

        ioExecutor.execute {
            try {
                val location = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    saveViaMediaStore(ctx, bytes, displayName, mimeType, album)
                } else {
                    saveToAppExternalFiles(ctx, bytes, displayName, album)
                }
                mainHandler.post { result.success(location) }
            } catch (e: Exception) {
                val message = e.message ?: e.toString()
                mainHandler.post { result.error("save_failed", message, null) }
            }
        }
    }

    private fun saveViaMediaStore(
        ctx: Context,
        bytes: ByteArray,
        displayName: String,
        mimeType: String,
        album: String,
    ): String {
        val resolver = ctx.contentResolver
        val collection =
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val relativePath = Environment.DIRECTORY_PICTURES + "/" + album

        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, mimeType)
            put(MediaStore.Images.Media.RELATIVE_PATH, relativePath)
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }

        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore insert failed")

        try {
            resolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: throw IllegalStateException("Could not open output stream")

            val update = ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }
            resolver.update(uri, update, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }

        return "$relativePath/$displayName"
    }

    private fun saveToAppExternalFiles(
        ctx: Context,
        bytes: ByteArray,
        displayName: String,
        album: String,
    ): String {
        val baseDir = ctx.getExternalFilesDir(Environment.DIRECTORY_PICTURES)
            ?: throw IllegalStateException("External storage unavailable")
        val albumDir = File(baseDir, album)
        if (!albumDir.exists() && !albumDir.mkdirs()) {
            throw IllegalStateException("Could not create directory ${albumDir.absolutePath}")
        }
        val outFile = File(albumDir, displayName)
        outFile.writeBytes(bytes)
        return outFile.absolutePath
    }
}
