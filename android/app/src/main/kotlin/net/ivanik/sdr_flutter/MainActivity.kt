package net.ivanik.sdr_flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // USB permission + usbfs fd for the Dart ioctl transport (lib/usb/).
        // As an ActivityAware plugin it also receives onNewIntent
        // (USB_DEVICE_ATTACHED while the activity is running, launchMode singleTop).
        flutterEngine.plugins.add(UsbSdrPlugin())
    }
}
