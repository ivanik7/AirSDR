package net.ivanik.sdr_flutter

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Android side of lib/runtime/background_reception.dart. No DSP/USB state lives here. */
class ReceptionPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private var context: Context? = null
    private var activity: Activity? = null
    private var channel: MethodChannel? = null
    private var notificationAsked = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "sdr/background").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        // Ask while the user is actually in the Activity, not several seconds later when
        // USB/DSP auto-connect completes (the screen may have gone to sleep by then).
        requestNotificationPermission()
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onDetachedFromActivity() { activity = null }

    private fun requestNotificationPermission() {
        val ctx = context ?: return
        if (Build.VERSION.SDK_INT >= 33 && !notificationAsked &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED) {
            activity?.let {
                notificationAsked = true
                ActivityCompat.requestPermissions(it,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS), 8103)
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: return result.error("NO_CONTEXT", "Engine detached", null)
        try {
            when (call.method) {
                "start" -> {
                    requestNotificationPermission()
                    ContextCompat.startForegroundService(ctx,
                        ReceptionService.intent(ctx, ReceptionService.START, call))
                    result.success(null)
                }
                "update" -> {
                    // Only an already running service should receive an update; don't start an
                    // FGS from a background retune or resurrect a stopped receiver.
                    ReceptionService.updateIfRunning(call)
                    result.success(null)
                }
                "stop" -> {
                    ctx.stopService(Intent(ctx, ReceptionService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("SERVICE", e.message, null)
        }
    }
}
