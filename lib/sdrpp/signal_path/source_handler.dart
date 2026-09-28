// Contract between SourceManager (signal path) and source modules.
// Port of SDR++ core/src/signal_path/source.h (SourceManager::SourceHandler).
//
// Differences from C++ (forced by the Dart runtime model, docs/10-architecture.md):
//  * No ImGui menuHandler: a source exposes declarative [SourceSetting]s instead.
//  * The output `dsp::stream<complex_t>*` becomes [SourceSink]: the source pushes
//    interleaved complex float32 blocks (re,im,re,im...) synchronously into the
//    DSP graph on the DSP isolate. The Float32List is only valid during the call.
//  * start/stop are async (USB streaming setup is async in Dart).

import 'dart:typed_data';

/// Receives IQ from a running source (SDR++: `stream.swap(count)`).
/// [iq] holds [count] complex samples interleaved (length >= 2*count).
typedef SourceSink = void Function(Float32List iq, int count);

/// Declarative replacement of an SDR++ source menu entry.
sealed class SourceSetting {
  final String id;
  final String label;
  const SourceSetting(this.id, this.label);
}

class ChoiceSetting extends SourceSetting {
  final List<String> options;
  final int selected;
  const ChoiceSetting(super.id, super.label, this.options, this.selected);
}

class SliderSetting extends SourceSetting {
  final double min, max, step, value;
  const SliderSetting(
    super.id,
    super.label, {
    required this.min,
    required this.max,
    required this.step,
    required this.value,
  });
}

class BoolSetting extends SourceSetting {
  final bool value;
  const BoolSetting(super.id, super.label, this.value);
}

/// SourceManager::SourceHandler equivalent. One instance per source module instance.
abstract class SourceHandler {
  /// Called when selected in the source list (SDR++ selectHandler):
  /// must call [SourceCore.setInputSampleRate] with the current rate.
  void select();

  /// SDR++ deselectHandler.
  void deselect();

  /// SDR++ startHandler: open device if needed and begin pushing to [sink].
  Future<void> start(SourceSink sink);

  /// SDR++ stopHandler.
  Future<void> stop();

  /// SDR++ tuneHandler (absolute RF frequency in Hz, offsets already applied by SourceManager).
  void tune(double frequencyHz);

  /// Menu replacement.
  List<SourceSetting> get settings;
  void applySetting(String id, Object value);
}

/// The subset of `core::` a source needs (core::setInputSampleRate etc.).
abstract class SourceCore {
  void setInputSampleRate(double sampleRate);
}
