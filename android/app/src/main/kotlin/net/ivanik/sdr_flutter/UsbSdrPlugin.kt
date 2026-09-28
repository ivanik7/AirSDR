// UsbSdrPlugin — Android USB host glue for sdr_flutter.
//
// Kotlin only does what Dart cannot: enumerate devices, obtain the user's
// permission and open the device to get a usbfs file descriptor. All USB I/O is
// done in Dart via dart:ffi ioctl(fd, USBDEVFS_*) (lib/usb/usbfs_transport.dart).
//
// Replaces SDR++ android/app/src/main/java/MainActivity.kt (single SDR_FD field,
// PendingIntent flags=0, unexported receiver without flags — only works with
// targetSdk 28) and core/backends/android/backend.cpp getDeviceFD() (:282-324)
// with a multi-device API. See docs/01 §3.4, §5.3-5.4 and docs/04 §1.1, §4, §7, §8.
//
// Channels (Dart side: lib/usb/android_usb.dart):
//   MethodChannel "sdr/usb":
//     listDevices()             -> [{deviceName, vid, pid, manufacturer, product, serial}]
//     open({deviceName})        -> {fd, vid, pid}   requests permission if needed
//     close({deviceName})       -> null             closes the UsbDeviceConnection (and fd)
//     hasPermission({deviceName}) -> Boolean
//     initialDevice()           -> device map or null (activity launched by USB_DEVICE_ATTACHED)
//   EventChannel "sdr/usb/events": {event: "attached"|"detached", device: {...}}
//
// UsbDeviceConnection objects are kept in [connections] for as long as Dart uses
// the fd: the connection's finalizer would otherwise close the fd under Dart.
//
// SPDX-License-Identifier: GPL-3.0-or-later

package net.ivanik.sdr_flutter

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class UsbSdrPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.NewIntentListener {

    companion object {
        private const val TAG = "UsbSdrPlugin"
        const val METHOD_CHANNEL = "sdr/usb"
        const val EVENT_CHANNEL = "sdr/usb/events"
    }

    private var context: Context? = null
    private var usbManager: UsbManager? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var receiverRegistered = false
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Unique per app install so another app can't spoof our permission broadcast. */
    private val actionUsbPermission: String
        get() = "${context?.packageName ?: "net.ivanik.sdr_flutter"}.USB_PERMISSION"

    /** deviceName -> open connection. Keeps the fd alive (do not let it be GC'd). */
    private val connections = HashMap<String, UsbDeviceConnection>()

    /** deviceName -> results waiting for the permission dialog. */
    private val pendingOpens = HashMap<String, MutableList<MethodChannel.Result>>()

    /** Device that launched the activity via USB_DEVICE_ATTACHED (not consumed). */
    private var initialDevice: UsbDevice? = null

    // ------------------------------------------------------------------
    // FlutterPlugin
    // ------------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx = binding.applicationContext
        context = ctx
        usbManager = ctx.getSystemService(Context.USB_SERVICE) as UsbManager?
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
        registerReceiver()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        eventSink = null
        unregisterReceiver()
        for ((_, results) in pendingOpens) {
            for (r in results) r.error("DETACHED", "plugin detached from engine", null)
        }
        pendingOpens.clear()
        for ((_, c) in connections) {
            try { c.close() } catch (_: Exception) {}
        }
        connections.clear()
        context = null
        usbManager = null
    }

    // ------------------------------------------------------------------
    // ActivityAware (USB_DEVICE_ATTACHED launch + onNewIntent)
    // ------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        handleIntent(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        return handleIntent(intent)
    }

    /** Returns true if the intent was a USB attach intent. */
    private fun handleIntent(intent: Intent?): Boolean {
        if (intent?.action != UsbManager.ACTION_USB_DEVICE_ATTACHED) return false
        val dev = deviceFromIntent(intent) ?: return false
        // Launched by the device filter: permission was granted with the
        // "open app when connected" dialog.
        initialDevice = dev
        emit("attached", dev)
        return true
    }

    // ------------------------------------------------------------------
    // Broadcasts: permission result, attach, detach
    // ------------------------------------------------------------------

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val dev = deviceFromIntent(intent)
            when (intent.action) {
                actionUsbPermission -> {
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    if (dev == null) {
                        // Some OEMs drop the device extra: retry all pending by name.
                        for (name in pendingOpens.keys.toList()) onPermissionResult(name, null, granted)
                    } else {
                        onPermissionResult(dev.deviceName, dev, granted)
                    }
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> if (dev != null) emit("attached", dev)
                UsbManager.ACTION_USB_DEVICE_DETACHED -> if (dev != null) onDetached(dev)
            }
        }
    }

    private fun registerReceiver() {
        val ctx = context ?: return
        if (receiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(actionUsbPermission)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        // Our own PendingIntent (explicit, setPackage) and system broadcasts are
        // delivered to a non-exported receiver.
        ContextCompat.registerReceiver(ctx, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        receiverRegistered = true
    }

    private fun unregisterReceiver() {
        if (!receiverRegistered) return
        try { context?.unregisterReceiver(receiver) } catch (_: Exception) {}
        receiverRegistered = false
    }

    private fun onDetached(dev: UsbDevice) {
        val name = dev.deviceName
        // Closing the connection makes pending ioctls on the fd fail with ENODEV
        // (they already do once the device is gone); Dart handles that.
        connections.remove(name)?.let { try { it.close() } catch (_: Exception) {} }
        pendingOpens.remove(name)?.forEach {
            it.error("NOT_FOUND", "device $name detached", null)
        }
        if (initialDevice?.deviceName == name) initialDevice = null
        emit("detached", dev)
    }

    private fun onPermissionResult(name: String, dev: UsbDevice?, granted: Boolean) {
        val results = pendingOpens.remove(name) ?: return
        val device = dev ?: findDevice(name)
        if (!granted || device == null) {
            for (r in results) {
                r.error(
                    if (device == null) "NOT_FOUND" else "PERMISSION_DENIED",
                    "USB permission for $name ${if (device == null) "device gone" else "denied"}",
                    null,
                )
            }
            return
        }
        openGranted(device, results)
    }

    // ------------------------------------------------------------------
    // EventChannel
    // ------------------------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emit(event: String, dev: UsbDevice) {
        val payload = mapOf("event" to event, "device" to deviceToMap(dev))
        mainHandler.post { eventSink?.success(payload) }
    }

    // ------------------------------------------------------------------
    // MethodChannel
    // ------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val mgr = usbManager
        if (mgr == null) {
            result.error("NO_USB_HOST", "UsbManager not available", null)
            return
        }
        when (call.method) {
            "listDevices" -> result.success(mgr.deviceList.values.map { deviceToMap(it) })
            "open" -> {
                val name = call.argument<String>("deviceName")
                if (name == null) {
                    result.error("BAD_ARGS", "deviceName required", null)
                    return
                }
                open(name, result)
            }
            "close" -> {
                val name = call.argument<String>("deviceName")
                if (name == null) {
                    result.error("BAD_ARGS", "deviceName required", null)
                    return
                }
                connections.remove(name)?.let { try { it.close() } catch (_: Exception) {} }
                result.success(null)
            }
            "hasPermission" -> {
                val name = call.argument<String>("deviceName")
                val dev = name?.let { findDevice(it) }
                result.success(dev != null && mgr.hasPermission(dev))
            }
            "initialDevice" -> {
                val dev = initialDevice?.let { findDevice(it.deviceName) }
                result.success(dev?.let { deviceToMap(it) })
            }
            else -> result.notImplemented()
        }
    }

    private fun open(name: String, result: MethodChannel.Result) {
        val mgr = usbManager ?: return result.error("NO_USB_HOST", "no UsbManager", null)
        val dev = findDevice(name) ?: return result.error("NOT_FOUND", "no device $name", null)

        connections[name]?.let { c ->
            // Already open: hand out the same fd (single owner of the connection).
            result.success(openResult(c, dev))
            return
        }
        if (mgr.hasPermission(dev)) {
            openGranted(dev, mutableListOf(result))
            return
        }
        val waiting = pendingOpens[name]
        if (waiting != null) {
            waiting.add(result) // dialog already shown
            return
        }
        pendingOpens[name] = mutableListOf(result)
        requestPermission(dev)
    }

    private fun requestPermission(dev: UsbDevice) {
        val ctx = context ?: return
        val mgr = usbManager ?: return
        // API 31+: must specify mutability; the system fills in extras, so it has
        // to be FLAG_MUTABLE. API 34+: mutable PendingIntents need an explicit
        // intent -> setPackage (RFAnalyzer does the same).
        val intent = Intent(actionUsbPermission).setPackage(ctx.packageName)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val pi = PendingIntent.getBroadcast(ctx, dev.deviceId, intent, flags)
        try {
            mgr.requestPermission(dev, pi)
        } catch (e: Exception) {
            pendingOpens.remove(dev.deviceName)?.forEach {
                it.error("PERMISSION_DENIED", "requestPermission failed: ${e.message}", null)
            }
        }
    }

    private fun openGranted(dev: UsbDevice, results: List<MethodChannel.Result>) {
        val mgr = usbManager
        val existing = connections[dev.deviceName]
        val conn = existing ?: try {
            mgr?.openDevice(dev)
        } catch (e: Exception) {
            Log.w(TAG, "openDevice(${dev.deviceName}) failed", e)
            null
        }
        if (conn == null) {
            for (r in results) r.error("OPEN_FAILED", "openDevice(${dev.deviceName}) returned null", null)
            return
        }
        connections[dev.deviceName] = conn
        val payload = openResult(conn, dev)
        for (r in results) r.success(payload)
    }

    private fun openResult(conn: UsbDeviceConnection, dev: UsbDevice): Map<String, Any> =
        mapOf("fd" to conn.fileDescriptor, "vid" to dev.vendorId, "pid" to dev.productId)

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private fun findDevice(name: String): UsbDevice? = usbManager?.deviceList?.get(name)

    private fun deviceFromIntent(intent: Intent): UsbDevice? =
        IntentCompat.getParcelableExtra(intent, UsbManager.EXTRA_DEVICE, UsbDevice::class.java)

    private fun deviceToMap(dev: UsbDevice): Map<String, Any?> {
        // Since API 29 getSerialNumber() throws SecurityException without
        // permission; the manufacturer/product strings are readable.
        fun safe(f: () -> String?): String? = try { f() } catch (_: SecurityException) { null }
        return mapOf(
            "deviceName" to dev.deviceName,
            "vid" to dev.vendorId,
            "pid" to dev.productId,
            "manufacturer" to safe { dev.manufacturerName },
            "product" to safe { dev.productName },
            "serial" to safe { dev.serialNumber },
        )
    }
}
