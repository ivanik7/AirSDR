// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/signal_path/vfo_manager.h (lines 1-66) and vfo_manager.cpp
// (lines 1-209) @8c9f5ee, plus the DSP-relevant part of `ImGui::WaterfallVFO`
// (gui/widgets/waterfall.cpp:1219-1293: setOffset/setCenterOffset/setBandwidth/setReference).
//
// `VFOManager::VFO` owned a `dsp::channel::RxVFO* dspVFO` and an `ImGui::WaterfallVFO* wtfVFO`.
// The waterfall VFO holds the reference→centre offset logic (docs/02 §2.4): the user-visible
// offset is `generalOffset`; the DSP always receives `centerOffset`. That model is kept here
// as [WaterfallVFO] (pure data, no drawing). Colours/snap/limits are stored for the UI only.
import '../core/event.dart';
import '../dsp/dsp.dart';
import 'iq_frontend.dart';

/// `WaterfallVFO::REF_LOWER/REF_CENTER/REF_UPPER` (waterfall.h:26-31). Same order as C++.
enum VFOReference { lower, center, upper }

/// Offset/bandwidth model of `ImGui::WaterfallVFO` (waterfall.cpp:1219-1293).
class WaterfallVFO {
  VFOReference reference = VFOReference.center;
  double generalOffset = 0;
  double centerOffset = 0;
  double lowerOffset = 0;
  double upperOffset = 0;
  double bandwidth = 0;
  double snapInterval = 5000;
  double minBandwidth = 0;
  double maxBandwidth = 0;
  bool bandwidthLocked = false;
  bool centerOffsetChanged = false;
  bool bandwidthChanged = false;
  int color = 0xFFFFFFFF;

  /// waterfall.cpp:1219.
  void setOffset(double offset) {
    generalOffset = offset;
    switch (reference) {
      case VFOReference.center:
        centerOffset = offset;
        lowerOffset = offset - (bandwidth / 2.0);
        upperOffset = offset + (bandwidth / 2.0);
      case VFOReference.lower:
        lowerOffset = offset;
        centerOffset = offset + (bandwidth / 2.0);
        upperOffset = offset + bandwidth;
      case VFOReference.upper:
        upperOffset = offset;
        centerOffset = offset - (bandwidth / 2.0);
        lowerOffset = offset - bandwidth;
    }
    centerOffsetChanged = true;
  }

  /// waterfall.cpp:1241.
  void setCenterOffset(double offset) {
    switch (reference) {
      case VFOReference.center:
        generalOffset = offset;
      case VFOReference.lower:
        generalOffset = offset - (bandwidth / 2.0);
      case VFOReference.upper:
        generalOffset = offset + (bandwidth / 2.0);
    }
    centerOffset = offset;
    lowerOffset = offset - (bandwidth / 2.0);
    upperOffset = offset + (bandwidth / 2.0);
    centerOffsetChanged = true;
  }

  /// waterfall.cpp:1261.
  void setBandwidth(double bw) {
    if (bandwidth == bw || bw < 0) {
      return;
    }
    bandwidth = bw;
    switch (reference) {
      case VFOReference.center:
        lowerOffset = centerOffset - (bandwidth / 2.0);
        upperOffset = centerOffset + (bandwidth / 2.0);
      case VFOReference.lower:
        centerOffset = lowerOffset + (bandwidth / 2.0);
        upperOffset = lowerOffset + bandwidth;
        centerOffsetChanged = true;
      case VFOReference.upper:
        centerOffset = upperOffset - (bandwidth / 2.0);
        lowerOffset = upperOffset - bandwidth;
        centerOffsetChanged = true;
    }
    bandwidthChanged = true;
  }

  /// waterfall.cpp:1284.
  void setReference(VFOReference ref) {
    if (reference == ref) {
      return;
    }
    reference = ref;
    setOffset(generalOffset);
  }

  void setSnapInterval(double interval) => snapInterval = interval;
}

/// `VFOManager::VFO` (vfo_manager.cpp:4-91).
class VFO {
  VFO._(this._manager, this.name, VFOReference reference, double offset, double bandwidth, double sampleRate,
      double minBandwidth, double maxBandwidth, bool bandwidthLocked) {
    _bandwidth = bandwidth;
    dspVFO = _manager.iqFrontEnd.addVFO(name, sampleRate, bandwidth, offset)!;
    wtfVFO = WaterfallVFO();
    wtfVFO.setReference(reference);
    wtfVFO.setBandwidth(bandwidth);
    wtfVFO.setOffset(offset);
    wtfVFO.minBandwidth = minBandwidth;
    wtfVFO.maxBandwidth = maxBandwidth;
    wtfVFO.bandwidthLocked = bandwidthLocked;
    // C++ creates the RxVFO with the *general* offset and relies on updateFromWaterfall() to
    // push centerOffset on the next frame. Without a GUI frame loop we apply it right away.
    _syncOffset();
  }

  final VFOManager _manager;
  final String name;
  late final RxVFO dspVFO;
  late final WaterfallVFO wtfVFO;
  late double _bandwidth;

  void _syncOffset() {
    if (wtfVFO.centerOffsetChanged) {
      wtfVFO.centerOffsetChanged = false;
      dspVFO.setOffset(wtfVFO.centerOffset);
    }
  }

  /// Binds the consumer of this VFO's output (C++ `vfo->output` stream).
  set output(VFOOutputHandler? handler) => _manager.iqFrontEnd.setVFOOutput(name, handler);

  /// vfo_manager.cpp:29.
  void setOffset(double offset) {
    wtfVFO.setOffset(offset);
    wtfVFO.centerOffsetChanged = false;
    dspVFO.setOffset(wtfVFO.centerOffset);
  }

  /// vfo_manager.cpp:34.
  double getOffset() => wtfVFO.generalOffset;

  /// vfo_manager.cpp:38.
  void setCenterOffset(double offset) {
    wtfVFO.setCenterOffset(offset);
    wtfVFO.centerOffsetChanged = false;
    dspVFO.setOffset(offset);
  }

  /// vfo_manager.cpp:43.
  void setBandwidth(double bandwidth, [bool updateWaterfall = true]) {
    if (_bandwidth == bandwidth) {
      return;
    }
    _bandwidth = bandwidth;
    if (updateWaterfall) {
      wtfVFO.setBandwidth(bandwidth);
    }
    dspVFO.setBandwidth(bandwidth);
    // REF_LOWER/UPPER move the centre when the bandwidth changes (updateFromWaterfall).
    _syncOffset();
  }

  /// vfo_manager.cpp:50.
  void setSampleRate(double sampleRate, double bandwidth) {
    dspVFO.setOutSamplerate(sampleRate, bandwidth);
    wtfVFO.setBandwidth(bandwidth);
    _syncOffset();
  }

  /// vfo_manager.cpp:55.
  void setReference(VFOReference ref) {
    wtfVFO.setReference(ref);
    _syncOffset();
  }

  /// vfo_manager.cpp:59.
  void setSnapInterval(double interval) => wtfVFO.setSnapInterval(interval);

  /// vfo_manager.cpp:63.
  void setBandwidthLimits(double minBandwidth, double maxBandwidth, bool bandwidthLocked) {
    wtfVFO.minBandwidth = minBandwidth;
    wtfVFO.maxBandwidth = maxBandwidth;
    wtfVFO.bandwidthLocked = bandwidthLocked;
  }

  /// vfo_manager.cpp:69.
  bool getBandwidthChanged([bool erase = true]) {
    final val = wtfVFO.bandwidthChanged;
    if (erase) {
      wtfVFO.bandwidthChanged = false;
    }
    return val;
  }

  /// vfo_manager.cpp:75.
  double getBandwidth() => wtfVFO.bandwidth;

  /// vfo_manager.cpp:79.
  VFOReference getReference() => wtfVFO.reference;

  /// vfo_manager.cpp:83.
  void setColor(int color) => wtfVFO.color = color;

  String getName() => name;

  /// Centre offset actually applied to the DSP.
  double get centerOffset => wtfVFO.centerOffset;
}

/// `VFOManager`.
class VFOManager {
  VFOManager(this.iqFrontEnd);

  final IQFrontEnd iqFrontEnd;
  final Map<String, VFO> _vfos = <String, VFO>{};

  final Event<VFO> onVfoCreated = Event<VFO>();
  final Event<VFO> onVfoDelete = Event<VFO>();
  final Event<String> onVfoDeleted = Event<String>();

  /// vfo_manager.cpp:94.
  VFO? createVFO(String name, VFOReference reference, double offset, double bandwidth, double sampleRate,
      double minBandwidth, double maxBandwidth, bool bandwidthLocked) {
    if (_vfos.containsKey(name) || name == '') {
      return null;
    }
    final vfo = VFO._(this, name, reference, offset, bandwidth, sampleRate, minBandwidth, maxBandwidth, bandwidthLocked);
    _vfos[name] = vfo;
    onVfoCreated.emit(vfo);
    return vfo;
  }

  /// vfo_manager.cpp:104 (+ VFO destructor, vfo_manager.cpp:19-27).
  void deleteVFO(VFO vfo) {
    String name = '';
    for (final e in _vfos.entries) {
      if (identical(e.value, vfo)) {
        name = e.key;
        break;
      }
    }
    if (name == '') {
      return;
    }
    onVfoDelete.emit(vfo);
    _vfos.remove(name);
    iqFrontEnd.removeVFO(name);
    onVfoDeleted.emit(name);
  }

  VFO? operator [](String name) => _vfos[name];

  void setOffset(String name, double offset) => _vfos[name]?.setOffset(offset);

  double getOffset(String name) => _vfos[name]?.getOffset() ?? 0;

  void setCenterOffset(String name, double offset) => _vfos[name]?.setCenterOffset(offset);

  void setBandwidth(String name, double bandwidth, [bool updateWaterfall = true]) =>
      _vfos[name]?.setBandwidth(bandwidth, updateWaterfall);

  void setSampleRate(String name, double sampleRate, double bandwidth) =>
      _vfos[name]?.setSampleRate(sampleRate, bandwidth);

  void setReference(String name, VFOReference ref) => _vfos[name]?.setReference(ref);

  void setBandwidthLimits(String name, double minBandwidth, double maxBandwidth, bool bandwidthLocked) =>
      _vfos[name]?.setBandwidthLimits(minBandwidth, maxBandwidth, bandwidthLocked);

  bool getBandwidthChanged(String name, [bool erase = true]) => _vfos[name]?.getBandwidthChanged(erase) ?? false;

  double getBandwidth(String name) => _vfos[name]?.getBandwidth() ?? double.nan;

  /// Returns null where C++ returns -1.
  VFOReference? getReference(String name) => _vfos[name]?.getReference();

  void setColor(String name, int color) => _vfos[name]?.setColor(color);

  bool vfoExists(String name) => _vfos.containsKey(name);

  Iterable<String> get names => _vfos.keys;

  /// vfo_manager.cpp:202-209: push waterfall-side centre-offset changes into the DSP.
  void updateFromWaterfall() {
    for (final vfo in _vfos.values) {
      vfo._syncOffset();
    }
  }
}
