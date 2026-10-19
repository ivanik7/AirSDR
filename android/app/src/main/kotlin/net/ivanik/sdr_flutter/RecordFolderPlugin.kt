// SPDX-License-Identifier: GPL-3.0-or-later
package net.ivanik.sdr_flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.IOException

/** SAF folder capability; all document operations run on the caller (native writer or IO thread). */
class RecordFolderPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private var app: Context? = null
    private var activity: Activity? = null
    private var channel: MethodChannel? = null
    private var pending: MethodChannel.Result? = null
    private var binding: ActivityPluginBinding? = null
    private val requestCode = 8642

    private external fun registerProvider(): Boolean

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        app = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "sdr/record_folder").also {
            it.setMethodCallHandler(this)
        }
        try {
            System.loadLibrary("sdrcore")
            // Native registration is optional until the recording ABI is linked.
            registerProvider()
        } catch (_: UnsatisfiedLinkError) {
            // choose/validate still work; the UI must probe native capabilities.
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        pending?.error("unavailable", "Recording folder picker closed", null)
        pending = null
        channel?.setMethodCallHandler(null)
        channel = null
        app = null
        // A native session must stop before engine destruction. The provider
        // retains its application context until process exit, never an Activity.
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)
    override fun onDetachedFromActivity() {
        detachActivity()
        pending?.error("unavailable", "Recording folder picker closed", null)
        pending = null
    }

    private fun detachActivity() {
        binding?.removeActivityResultListener(this)
        binding = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "choose" -> {
                val current = activity
                if (current == null || pending != null) {
                    result.error("unavailable", "Recording folder picker is unavailable", null)
                    return
                }
                pending = result
                try {
                    current.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    }, requestCode)
                } catch (e: Exception) {
                    pending = null
                    result.error("unavailable", e.message, null)
                }
            }
            "validate" -> {
                val locator = call.arguments as? String
                val context = app
                if (locator == null || context == null) {
                    result.success(false)
                } else {
                    Thread {
                        val valid = validate(context, locator.removePrefix("content:"), locator.startsWith("content:"))
                        android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(valid) }
                    }.start()
                }
            }
            "release" -> {
                val locator = call.arguments as? String
                val context = app
                if (locator == null || !locator.startsWith("content:content://") || context == null) {
                    result.error("unavailable", "Invalid recording tree", null)
                    return
                }
                val uri = Uri.parse(locator.removePrefix("content:"))
                try {
                    if (hasGrant(context, uri)) {
                        context.contentResolver.releasePersistableUriPermission(
                            uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    }
                    result.success(null)
                } catch (e: SecurityException) {
                    result.error("unavailable", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onActivityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        val result = pending ?: return true
        pending = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return true
        }
        val context = app
        val uri = data.data!!
        if (context == null || uri.scheme != "content") {
            result.error("unavailable", "Invalid recording tree", null)
            return true
        }
        val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        if (flags != (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) {
            result.error("unavailable", "Read and write access is required", null)
            return true
        }
        val alreadyGranted = hasGrant(context, uri)
        try {
            context.contentResolver.takePersistableUriPermission(uri, flags)
            val root = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
            val name = context.contentResolver.query(root, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: uri.lastPathSegment ?: "Selected folder"
            result.success(mapOf("locator" to "content:$uri", "displayName" to name))
        } catch (e: Exception) {
            // A failed metadata lookup must not leave a grant for a rejected
            // tree. Do not drop an older selection of the same tree, though.
            if (!alreadyGranted) {
                try {
                    context.contentResolver.releasePersistableUriPermission(uri, flags)
                } catch (_: Exception) {}
            }
            result.error("unavailable", e.message ?: "Cannot persist tree access", null)
        }
        return true
    }

    private fun hasGrant(ctx: Context, uri: Uri): Boolean = ctx.contentResolver.persistedUriPermissions.any {
        it.uri == uri && it.isReadPermission && it.isWritePermission
    }

    // Called by the native recorder writer thread through JNI. The returned fd
    // belongs to the writer; ParcelFileDescriptor.detachFd transfers ownership.
    @Suppress("unused")
    fun createFile(locator: String, displayName: String, mimeType: String): Int {
        val ctx = app ?: return -22
        if (!locator.startsWith("content:")) return -22
        val tree = try { Uri.parse(locator.removePrefix("content:")) } catch (_: Exception) { return -22 }
        if (!hasGrant(ctx, tree) || displayName.isEmpty() || displayName.contains('/') ||
            displayName.contains('\\') || displayName == "." || displayName == "..") return -22
        val resolver = ctx.contentResolver
        try {
            val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            // SAF providers may silently rename on collisions. Check both before
            // create and the actual returned name; never truncate a sibling.
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) if (cursor.getString(0) == displayName) return -20
            } ?: return -22
            val child = DocumentsContract.createDocument(resolver, parent, mimeType, displayName) ?: return -22
            try {
                val actual = resolver.query(child, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) it.getString(0) else null
                }
                if (actual == null) {
                    DocumentsContract.deleteDocument(resolver, child)
                    return -22
                }
                if (actual != displayName) {
                    DocumentsContract.deleteDocument(resolver, child)
                    return -20
                }
                val pfd = resolver.openFileDescriptor(child, "rw") ?: run {
                    DocumentsContract.deleteDocument(resolver, child)
                    return -22
                }
                val fd = try {
                    Os.lseek(pfd.fileDescriptor, 0, OsConstants.SEEK_CUR)
                    pfd.detachFd()
                } catch (e: ErrnoException) {
                    pfd.close()
                    DocumentsContract.deleteDocument(resolver, child)
                    return -23
                }
                return fd
            } catch (e: Exception) {
                try { DocumentsContract.deleteDocument(resolver, child) } catch (_: Exception) {}
                throw e
            }
        } catch (_: SecurityException) { return -22 }
          catch (e: ErrnoException) { return if (e.errno == OsConstants.ENOSPC || e.errno == OsConstants.EDQUOT) -21 else -4 }
          catch (e: IOException) {
              val errno = (e.cause as? ErrnoException)?.errno
              return if (errno == OsConstants.ENOSPC || errno == OsConstants.EDQUOT) -21 else -4
          }
          catch (_: Exception) { return -22 }
    }

    private fun validate(ctx: Context, uriString: String, correctPrefix: Boolean): Boolean {
        if (!correctPrefix) return false
        val tree = try { Uri.parse(uriString) } catch (_: Exception) { return false }
        if (!hasGrant(ctx, tree)) return false
        val name = ".airsdr-probe-${System.nanoTime()}"
        val fd = createFile("content:$tree", name, "application/octet-stream")
        if (fd < 0) return false
        var child: Uri? = null
        val pfd = ParcelFileDescriptor.adoptFd(fd)
        try {
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            ctx.contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) if (cursor.getString(1) == name) {
                    child = DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0))
                    break
                }
            }
            pfd.use {
                val bytes = byteArrayOf(0x5a)
                Os.write(it.fileDescriptor, bytes, 0, 1)
                Os.lseek(it.fileDescriptor, 0, OsConstants.SEEK_SET)
                val read = byteArrayOf(0)
                if (Os.read(it.fileDescriptor, read, 0, 1) != 1 || read[0] != bytes[0]) return false
            }
            return child != null
        } catch (_: Exception) { return false }
        finally {
            try { pfd.close() } catch (_: Exception) {}
            child?.let { try { DocumentsContract.deleteDocument(ctx.contentResolver, it) } catch (_: Exception) {} }
        }
    }
}
