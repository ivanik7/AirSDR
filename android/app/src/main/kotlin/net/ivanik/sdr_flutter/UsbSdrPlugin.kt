// UsbSdrPlugin — Android USB host glue for sdr_flutter.
//
// Kotlin enumerates devices, requests permission and opens the UsbDeviceConnection that owns
// the usbfs fd. USB I/O is no longer all done in Dart: the default receiver still streams via
// Dart usbfs ioctls (lib/usb/usbfs_transport.dart) on the fd returned by "open", while the
// opt-in native sdrcore engine (native/include/sdrcore.h ABI 2) streams through source-built
// libusb/librtlsdr/libhackrf on a native dup() of the same connection's fd ("native*" calls).
// The Dart path and its "open"/"close"/"hasPermission"/"initialDevice" contract are unchanged
// and remain the default; nothing in this plugin activates the native engine by itself.
//
// Ownership and lifecycle (UsbDeviceLifecycle; docs/native-n1-android-lifecycle.md):
//   * One UsbDeviceConnection per device, owned and closed exactly once by UsbDeviceLifecycle.
//     Kotlin never dup()s or closes the raw fd; sdr_v2_open_usb() dup()s it and native closes
//     only its duplicate. The Java connection stays open until native close/destroy returns.
//   * Dart xor native per device: a device held by one side answers "BUSY" to the other, also
//     while a native teardown for that device is still in flight.
//   * sdrcore commands (stop/close may block on thread joins) run on one serial background
//     thread, never on the main thread; replies are posted back to the main thread.
//   * The FlutterEngine is application-owned (SdrApplication), so Activity detach/recreation
//     does not touch USB state. ReceptionService "Stop" also stops running native streams.
//     USB detach closes the native session first, then the Java connection. Engine detach
//     closes every native session and connection.
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
//     -- native-only, not called by lib/usb/android_usb.dart today --
//     nativeOpen({deviceName, source: "rtlsdr"|"hackrf"}) -> {vid, pid, result}
//     nativeConfigure({deviceName, frequencyHz, samplesPerSecond, gainTenthsDb}) -> {result}
//     nativeStart({deviceName})  -> {result}
//     nativeStop({deviceName})   -> {result}
//     nativeStats({deviceName})  -> stats map or null
//     nativeClose({deviceName})  -> {result}   stop+close+destroy, then closes the connection
//     `result` is the raw `enum SdrResult` code from native/include/sdrcore.h (SdrAbi.kt),
//     or SdrResult.BRIDGE_UNAVAILABLE's code (-1000) if JNI cannot load.
//     "BUSY" errors mean the other side (Dart vs native) currently holds the device or a
//     native teardown is in flight; reported honestly, never silently queued or overridden.
//   EventChannel "sdr/usb/events": {event: "attached"|"detached", device: {...}}
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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

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

    /** deviceName -> results waiting for the permission dialog, tagged with which side
     * (Dart/native) requested the open and, for native, the ABI source kind. */
    private val pendingOpens = HashMap<String, MutableList<PendingOpen>>()

    private data class PendingOpen(
        val result: MethodChannel.Result,
        val owner: UsbSessionOwnership.Owner,
        val nativeSource: SdrSource? = null,
    )

    /** Serial thread for every sdrcore command; created per engine attachment. */
    private var nativeExecutor: ExecutorService? = null

    /** Single owner of connections, Dart/native exclusivity and native session ordering.
     * Keeps each UsbDeviceConnection referenced while used (its finalizer would close the fd). */
    private var lifecycle: UsbDeviceLifecycle<UsbDeviceConnection>? = null

    /** Device that launched the activity via USB_DEVICE_ATTACHED (not consumed). */
    private var initialDevice: UsbDevice? = null

    // ------------------------------------------------------------------
    // FlutterPlugin
    // ------------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx = binding.applicationContext
        context = ctx
        usbManager = ctx.getSystemService(Context.USB_SERVICE) as UsbManager?
        val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "sdrcore-control") }
        nativeExecutor = executor
        lifecycle = UsbDeviceLifecycle(
            fdOf = { it.fileDescriptor },
            closeConnection = { c -> try { c.close() } catch (_: Exception) {} },
            sessions = NativeUsbSessionRegistry { JniSdrNativeBridge() },
            nativeExecutor = executor,
            mainExecutor = { r -> mainHandler.post(r) },
        )
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
            for (p in results) p.result.error("DETACHED", "plugin detached from engine", null)
        }
        pendingOpens.clear()
        // Native sessions are stopped/closed/destroyed on the control thread before the Java
        // connections they borrowed fds from are closed; Dart-held connections close now.
        lifecycle?.shutdown()
        lifecycle = null
        nativeExecutor?.shutdown() // queued teardown still runs
        nativeExecutor = null
        context = null
        usbManager = null
    }

    /** Stops every running native stream (sessions stay open). Used by ReceptionService's
     * notification "Stop" so a native stream never outlives the foreground service. */
    fun stopNativeStreams(done: () -> Unit) {
        val lc = lifecycle ?: return done()
        lc.stopAllNative(done)
    }

    /** Service-level Stop must close native sessions and Java USB connections, not just
     * pause playback. Completion arrives on main after the control-thread teardown. */
    fun closeNativeStreams(done: () -> Unit) {
        val lc = lifecycle ?: return done()
        lc.closeAllNative(done)
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

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        // Same launch intent as before the config change: don't re-emit "attached".
        activityBinding = binding
        binding.addOnNewIntentListener(this)
    }

    // Activity loss never closes USB: the engine (and any Dart or native stream, kept alive by
    // ReceptionService) outlives the Activity.
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
        // Dart-held: the connection closes now, so pending ioctls fail with ENODEV (they already
        // do once the device is gone); Dart handles that. Native-held: the native session is
        // stopped/closed on the control thread first, then the Java connection is closed. A
        // reconnect gets a new permission/open and a fresh session.
        val owned = lifecycle?.currentOwner(name) != null
        lifecycle?.onDeviceDetached(name)
        if (owned) ReceptionService.stopIfRunning()
        pendingOpens.remove(name)?.forEach {
            it.result.error("NOT_FOUND", "device $name detached", null)
        }
        if (initialDevice?.deviceName == name) initialDevice = null
        emit("detached", dev)
    }

    private fun onPermissionResult(name: String, dev: UsbDevice?, granted: Boolean) {
        val results = pendingOpens.remove(name) ?: return
        val device = dev ?: findDevice(name)
        if (!granted || device == null) {
            for (p in results) {
                lifecycle?.abandon(name, p.owner)
                p.result.error(
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
        val lc = lifecycle
        if (mgr == null || lc == null) {
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
                // Refuse to pull the fd out from under an active native session: exclusivity
                // means only the side that opened the device may close it (see nativeClose).
                if (!lc.dartClose(name)) {
                    result.error("BUSY", "device $name is in use by the native receiver", null)
                    return
                }
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
            "nativeOpen" -> nativeOpen(call, result)
            "nativeConfigure" -> nativeConfigure(call, result)
            "nativeStart" -> withNativeSession(call, result) { session -> session.start() }
            "nativeStop" -> withNativeSession(call, result) { session -> session.stop() }
            "nativeStats" -> nativeStats(call, result)
            "nativeClose" -> nativeClose(call, result)
            else -> result.notImplemented()
        }
    }

    private fun open(name: String, result: MethodChannel.Result) {
        val mgr = usbManager ?: return result.error("NO_USB_HOST", "no UsbManager", null)
        val lc = lifecycle ?: return result.error("NO_USB_HOST", "plugin detached", null)
        val dev = findDevice(name) ?: return result.error("NOT_FOUND", "no device $name", null)

        if (!lc.tryAcquire(name, UsbSessionOwnership.Owner.DART)) {
            result.error("BUSY", "device $name is in use by the native receiver", null)
            return
        }
        lc.connection(name)?.let { c ->
            // Already open: hand out the same fd (single owner of the connection).
            result.success(openResult(c, dev))
            return
        }
        requestOrOpen(mgr, dev, PendingOpen(result, UsbSessionOwnership.Owner.DART))
    }

    private fun requestOrOpen(mgr: UsbManager, dev: UsbDevice, pending: PendingOpen) {
        if (mgr.hasPermission(dev)) {
            openGranted(dev, mutableListOf(pending))
            return
        }
        val waiting = pendingOpens[dev.deviceName]
        if (waiting != null) {
            waiting.add(pending) // dialog already shown
            return
        }
        pendingOpens[dev.deviceName] = mutableListOf(pending)
        requestPermission(dev)
    }

    // ------------------------------------------------------------------
    // Native sdrcore control (additive; see the ownership notes at the top of this file)
    // ------------------------------------------------------------------

    private fun parseNativeSource(value: String?): SdrSource? = when (value) {
        "rtlsdr" -> SdrSource.RTLSDR
        "hackrf" -> SdrSource.HACKRF
        else -> null
    }

    private fun nativeOpen(call: MethodCall, result: MethodChannel.Result) {
        val mgr = usbManager ?: return result.error("NO_USB_HOST", "no UsbManager", null)
        val lc = lifecycle ?: return result.error("NO_USB_HOST", "plugin detached", null)
        val name = call.argument<String>("deviceName")
            ?: return result.error("BAD_ARGS", "deviceName required", null)
        val source = parseNativeSource(call.argument<String>("source"))
            ?: return result.error("BAD_ARGS", "source must be \"rtlsdr\" or \"hackrf\"", null)
        val dev = findDevice(name) ?: return result.error("NOT_FOUND", "no device $name", null)

        if (!lc.tryAcquire(name, UsbSessionOwnership.Owner.NATIVE)) {
            result.error("BUSY", "device $name is in use by the Dart receiver or closing", null)
            return
        }
        if (lc.connection(name) != null) {
            openNativeSession(dev, source, result)
            return
        }
        requestOrOpen(mgr, dev, PendingOpen(result, UsbSessionOwnership.Owner.NATIVE, source))
    }

    /** Hands the adopted connection's fd to sdr_v2_open_usb() on the control thread. Native
     * duplicates the fd itself (sdrcore.h). Idempotent for an already open session with the
     * same source; on failure the claim is dropped and the connection closed. */
    private fun openNativeSession(dev: UsbDevice, source: SdrSource, result: MethodChannel.Result) {
        val lc = lifecycle ?: return result.error("NO_USB_HOST", "plugin detached", null)
        lc.nativeOpen(dev.deviceName, source) { rc ->
            result.success(mapOf("vid" to dev.vendorId, "pid" to dev.productId, "result" to rc.code))
        }
    }

    private fun withNativeSession(
        call: MethodCall,
        result: MethodChannel.Result,
        action: (NativeUsbSession) -> SdrResult,
    ) {
        val lc = lifecycle ?: return result.error("NO_USB_HOST", "plugin detached", null)
        val name = call.argument<String>("deviceName")
            ?: return result.error("BAD_ARGS", "deviceName required", null)
        lc.nativeCommand(name, action) { rc ->
            if (rc == null) result.error("NOT_FOUND", "no native session for $name", null)
            else result.success(mapOf("result" to rc.code))
        }
    }

    private fun nativeConfigure(call: MethodCall, result: MethodChannel.Result) {
        val frequencyHz = call.argument<Number>("frequencyHz")?.toLong()
        val samplesPerSecond = call.argument<Number>("samplesPerSecond")?.toInt()
        val gainTenthsDb = call.argument<Number>("gainTenthsDb")?.toInt()
        if (frequencyHz == null || samplesPerSecond == null || gainTenthsDb == null) {
            result.error("BAD_ARGS", "frequencyHz, samplesPerSecond, gainTenthsDb required", null)
            return
        }
        withNativeSession(call, result) { session ->
            session.configure(frequencyHz, samplesPerSecond, gainTenthsDb)
        }
    }

    private fun nativeStats(call: MethodCall, result: MethodChannel.Result) {
        val lc = lifecycle ?: return result.error("NO_USB_HOST", "plugin detached", null)
        val name = call.argument<String>("deviceName")
            ?: return result.error("BAD_ARGS", "deviceName required", null)
        lc.nativeStats(name) { snapshot ->
            if (snapshot == null) {
                result.success(null)
                return@nativeStats
            }
            result.success(
                mapOf(
                    "state" to snapshot.state.code,
                    "source" to snapshot.source.code,
                    "lastError" to snapshot.lastError.code,
                    "sampleRate" to snapshot.sampleRate,
                    "frequencyHz" to snapshot.frequencyHz,
                    "gainTenthsDb" to snapshot.gainTenthsDb,
                    "inputSamples" to snapshot.inputSamples,
                    "processedSamples" to snapshot.processedSamples,
                    "droppedSamples" to snapshot.droppedSamples,
                    "checksum" to snapshot.checksum,
                ),
            )
        }
    }

    private fun nativeClose(call: MethodCall, result: MethodChannel.Result) {
        val lc = lifecycle ?: return result.error("NO_USB_HOST", "plugin detached", null)
        val name = call.argument<String>("deviceName")
            ?: return result.error("BAD_ARGS", "deviceName required", null)
        // stop/close/destroy return on the control thread before the Java connection is closed
        // and the device is released for Dart.
        lc.nativeClose(name) { rc -> result.success(mapOf("result" to rc.code)) }
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
                lifecycle?.abandon(dev.deviceName, it.owner)
                it.result.error("PERMISSION_DENIED", "requestPermission failed: ${e.message}", null)
            }
        }
    }

    private fun openGranted(dev: UsbDevice, results: List<PendingOpen>) {
        val lc = lifecycle
        val mgr = usbManager
        val name = dev.deviceName
        val conn = lc?.connection(name) ?: try {
            mgr?.openDevice(dev)
        } catch (e: Exception) {
            Log.w(TAG, "openDevice($name) failed", e)
            null
        }
        if (lc == null || conn == null) {
            for (p in results) {
                lc?.abandon(name, p.owner)
                p.result.error("OPEN_FAILED", "openDevice($name) returned null", null)
            }
            return
        }
        lc.adopt(name, conn)
        for (p in results) {
            if (p.owner == UsbSessionOwnership.Owner.NATIVE) {
                openNativeSession(dev, p.nativeSource!!, p.result)
            } else {
                p.result.success(openResult(conn, dev))
            }
        }
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
