// SPDX-License-Identifier: GPL-3.0-or-later
// Device dropdown helpers shared by the legacy Receive screen and the SDR++-style main screen.
import 'radio_controller.dart';

/// Value for a `DropdownButton<SdrDeviceInfo>` whose items are [RadioController.devices].
///
/// DropdownButton asserts that its value matches exactly one item. The controller keeps
/// `selectedDevice ∈ devices` (SdrRadioController), but the list comes from USB hot-plug
/// events: never let a vanished dongle turn the whole screen into a red error box.
SdrDeviceInfo? dropdownDeviceValue(RadioController r) {
  final d = r.selectedDevice;
  if (d == null) return null;
  return r.devices.where((e) => e == d).length == 1 ? d : null;
}
