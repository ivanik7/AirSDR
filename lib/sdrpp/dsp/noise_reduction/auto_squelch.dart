// SPDX-License-Identifier: GPL-3.0-or-later
//
// Automatic squelch. NOT a port: SDR++ (@8c9f5ee) only has the manual PowerSquelch
// (power_squelch.h) and a CTCSS squelch; this block is an app extension that lives next to
// them and leaves them untouched. It follows what hardware receivers do (AOR AR-DV10
// `SQL N/L` AUTO: noise squelch for FM, level squelch for AM/SSB/CW):
//
//  * [AutoSquelchDetector.noise] (NFM) — noise squelch, as in FM radios / scanners
//    (en.wikipedia.org/wiki/Squelch; KA7OEI's mcHF implementation). The FM discriminator
//    output is high-passed ABOVE the voice band; its rectified, smoothed level is the
//    "discriminator noise". A carrier quiets the discriminator (FM quieting: the noise
//    falls as the carrier-to-noise ratio rises), audio-band voice/tones don't reach the
//    detector. The level is compared to the noise of an empty channel of the same
//    bandwidth ([noiseReference], calibrated offline, see tool/auto_squelch_calibrate.dart):
//    `quieting = 20·log10(reference / level)` dB. The FM discriminator output is
//    independent of the IF amplitude, so neither the RF gain nor the absolute noise level
//    change the threshold.
//
//  * [AutoSquelchDetector.level] (AM, USB, LSB, DSB, CW) — level squelch with an automatic
//    threshold: the channel noise floor is a low percentile of the in-channel power over a
//    sliding window, learnt while the squelch is closed (a transmission does not raise its
//    own floor); `threshold = floor + margin`. If the squelch stays open longer than
//    [AutoSquelchTuning.floorFreezeMs], the level is taken as the new floor (the noise floor
//    itself rose: band noise, interference) and the squelch closes — it never sticks open.
//    Consequence: a continuous carrier (AM broadcast, ATIS) is treated as the floor; for
//    those use the manual squelch or Off.
//
// Both detectors use a comparator with hysteresis (open at threshold + H, close below the
// threshold) and a hang time before closing; [gate] fades the audio in/out over a few ms so
// that opening/closing does not click.
//
// Threshold offset ([offsetDb], the UI "sensitivity" slider): added to the automatic
// threshold. Positive = needs a stronger signal (tighter), negative = opens earlier.
import 'dart:math' as math;
import 'dart:typed_data';

/// Which automatic detector a demodulator uses.
enum AutoSquelchDetector { noise, level }

/// Tuning constants (see STATUS-auto-squelch.md for the reasoning and measurements).
abstract final class AutoSquelchTuning {
  // ---- noise squelch (NFM) ----
  /// Discriminator high-pass: 4th-order Butterworth corner (Hz). Above the 300–3000 Hz voice
  /// band (and its 1st harmonic region) so speech/tones don't reach the detector.
  static const double noiseHighPassHz = 5000.0;

  /// For narrow channels the corner moves down to this fraction of the bandwidth, otherwise
  /// the detector would look outside the channel (bw 1–10 kHz: corner 0.4·bw).
  static const double noiseHighPassBwRatio = 0.4;

  /// Smoothing of the rectified HF noise (one-pole, symmetric). 10 ms keeps the estimate
  /// within ~±0.5 dB on an empty channel and reacts within ~2τ when a carrier appears; the
  /// slow close is done by [hangMs], not by the smoother (an asymmetric per-sample smoother
  /// would follow the noise valleys and open falsely).
  static const double noiseSmoothMs = 10.0;

  /// Quieting (dB below the empty-channel noise) at which the squelch closes; it opens at
  /// [noiseOpenDb] + [hysteresisDb].
  static const double noiseOpenDb = 6.0;

  // ---- level squelch (AM/SSB/DSB/CW) ----
  /// Smoothing of the in-channel power for the decision (one-pole, symmetric, on the mean
  /// power so that it is comparable with the floor, which is a percentile of mean powers).
  static const double levelSmoothMs = 20.0;

  /// For narrow channels the smoother is lengthened to average ≥ ~40 independent noise
  /// samples: τ ≥ [levelSmoothBwProduct] / bandwidth (CW 200 Hz → 100 ms), capped at
  /// [levelSmoothMaxMs]. Otherwise the noise-power fluctuations reach the margin.
  static const double levelSmoothBwProduct = 20.0;
  static const double levelSmoothMaxMs = 400.0;

  /// Noise-floor tracker: segment length, window (number of segments) and percentile of
  /// the segments measured while the squelch is closed. The floor is frozen while open (a
  /// transmission must not become its own floor) for up to [floorFreezeMs]; the engine also
  /// calls [AutoSquelch.reset] on retune / gain / bandwidth / mode / source changes.
  static const double floorSegmentMs = 50.0;
  static const int floorSegments = 40; // 40 × 50 ms = 2 s
  static const double floorPercentile = 0.2;

  /// A squelch open for longer than this lets its segments into the floor window again.
  static const double floorFreezeMs = 8000.0;

  /// Segments needed before the floor is trusted (squelch stays closed meanwhile).
  static const int floorMinSegments = 4; // 200 ms

  /// After [AutoSquelch.reset]/[AutoSquelch.configure] the detector stays closed and (level)
  /// the first segments are not used for the floor: a new demodulator/bandwidth rebuilds the
  /// VFO channel filter, whose history warms up for up to taps/rate (CW: ~1100 taps at
  /// 3 kHz ≈ 0.4 s) with too little power. NFM's filter is ~300 taps at 50 kHz (6 ms), so
  /// the noise squelch only waits for its HPF/smoother.
  static const double floorSettleMs = 500.0;
  static const double noiseSettleMs = 30.0;

  /// Threshold above the floor.
  static const double levelMarginDb = 6.0;

  // ---- both ----
  static const double hysteresisDb = 2.5;
  static const double hangMs = 250.0;
  static const double fadeMs = 5.0;
}

/// Empty-channel discriminator noise (mean |HPF(discriminator)|, rad/sample) versus the IF
/// bandwidth / IF sample rate ratio, for the [AutoSquelchTuning] detector parameters.
/// Generated by tool/auto_squelch_calibrate.dart (complex Gaussian noise through the RxVFO
/// low-pass, IF 50 kHz); checked against a fresh simulation by the unit tests.
/// Entries: (bandwidth / sampleRate, mean |hp|).
const List<(double, double)> noiseReferenceTable = <(double, double)>[
  (0.02, 0.033251),
  (0.05, 0.082216),
  (0.1, 0.16022),
  (0.15, 0.22968),
  (0.2, 0.29441),
  (0.25, 0.35141),
  (0.3, 0.43264),
  (0.4, 0.57986),
  (0.5, 0.72595),
  (0.6, 0.86801),
  (0.8, 1.1160),
  (1.0, 1.3276),
];

/// Interpolated (log-log) empty-channel noise for [bandwidth] at [sampleRate].
double noiseReference(double bandwidth, double sampleRate) {
  final t = noiseReferenceTable;
  final r = (bandwidth / sampleRate).clamp(t.first.$1, t.last.$1);
  for (var i = 1; i < t.length; i++) {
    if (r <= t[i].$1) {
      final (x0, y0) = t[i - 1];
      final (x1, y1) = t[i];
      final u = (math.log(r) - math.log(x0)) / (math.log(x1) - math.log(x0));
      return math.exp(math.log(y0) + u * (math.log(y1) - math.log(y0)));
    }
  }
  return t.last.$2;
}

/// Biquad (direct form I, double precision) — RBJ cookbook high-pass.
class _Biquad {
  _Biquad.highPass(double fc, double sr, double q) {
    final w0 = 2 * math.pi * fc / sr;
    final cw = math.cos(w0), sw = math.sin(w0);
    final alpha = sw / (2 * q);
    final a0 = 1 + alpha;
    b0 = (1 + cw) / 2 / a0;
    b1 = -(1 + cw) / a0;
    b2 = (1 + cw) / 2 / a0;
    a1 = -2 * cw / a0;
    a2 = (1 - alpha) / a0;
  }

  late final double b0, b1, b2, a1, a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  double process(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }

  void reset() => _x1 = _x2 = _y1 = _y2 = 0;
}

class AutoSquelch {
  AutoSquelch({
    AutoSquelchDetector detector = AutoSquelchDetector.level,
    double sampleRate = 48000,
    double bandwidth = 10000,
  }) {
    configure(detector: detector, sampleRate: sampleRate, bandwidth: bandwidth);
  }

  late AutoSquelchDetector _detector;
  late double _sr;
  late double _bw;

  /// User threshold offset (dB), see file header.
  double offsetDb = 0;

  /// Called on every open/close transition (after hysteresis and hang).
  void Function(bool open)? onChange;

  bool _open = false;
  int _hangLeft = 0; // samples until close, while the detector says "closed"
  int _hangSamples = 0;
  int transitions = 0;

  // noise
  late _Biquad _hp1, _hp2;
  double _prevRe = 0, _prevIm = 0;
  double _noise = 0;
  double _noiseRef = 1;
  late double _nAtt;

  // level
  double _pow = 0;
  bool _powInit = false;
  late double _lAtt;
  int _segLen = 1;
  int _segCount = 0;
  double _segSum = 0;
  bool _segClean = true;
  int _openSamples = 0;
  int _freezeSamples = 0;
  int _settleLeft = 0;
  final List<double> _segments = <double>[];

  // gate
  double _gain = 0;

  AutoSquelchDetector get detector => _detector;
  double get sampleRate => _sr;
  double get bandwidth => _bw;
  bool get open => _open;

  /// Noise detector: smoothed mean |HPF(discriminator)| (rad/sample).
  double get noiseLevel => _noise;

  /// Noise: quieting in dB (0 = empty channel, higher = stronger carrier).
  /// Level: smoothed in-channel power in dB. Null before the first sample.
  double? get metricDb {
    if (_detector == AutoSquelchDetector.noise) {
      if (_noise <= 0) return null;
      return 20 * math.log(_noiseRef / _noise) / math.ln10;
    }
    return _powInit ? _db(_pow) : null;
  }

  /// Level squelch: the current noise floor (dB), null while it is being learnt.
  double? get floorDb {
    if (_detector != AutoSquelchDetector.level ||
        _segments.length < AutoSquelchTuning.floorMinSegments) {
      return null;
    }
    final s = List<double>.of(_segments)..sort();
    final i = ((s.length - 1) * AutoSquelchTuning.floorPercentile).round();
    return s[i];
  }

  /// Retain the measured floor of a scanned channel across visits. Filter and
  /// audio state deliberately stay reset; only clean noise segments survive.
  List<double> get floorSnapshot => _detector == AutoSquelchDetector.level
      ? List<double>.of(_segments)
      : const [];

  void restoreFloor(List<double> segments) {
    if (_detector != AutoSquelchDetector.level || _open) return;
    _segments
      ..clear()
      ..addAll(
        segments.where((v) => v.isFinite).take(AutoSquelchTuning.floorSegments),
      );
  }

  /// Close threshold in the units of [metricDb] (open = threshold + hysteresis); null while
  /// the level squelch is still learning its floor.
  double? get thresholdDb {
    if (_detector == AutoSquelchDetector.noise) {
      return AutoSquelchTuning.noiseOpenDb + offsetDb;
    }
    final f = floorDb;
    return f == null ? null : f + AutoSquelchTuning.levelMarginDb + offsetDb;
  }

  void configure({
    required AutoSquelchDetector detector,
    required double sampleRate,
    required double bandwidth,
  }) {
    _detector = detector;
    _sr = sampleRate;
    _bw = bandwidth;
    double coef(double ms) => 1 - math.exp(-1000.0 / (ms * _sr));
    _nAtt = coef(AutoSquelchTuning.noiseSmoothMs);
    _lAtt = coef(
      math.max(
        AutoSquelchTuning.levelSmoothMs,
        math.min(
          AutoSquelchTuning.levelSmoothMaxMs,
          1000 * AutoSquelchTuning.levelSmoothBwProduct / _bw,
        ),
      ),
    );
    _hangSamples = (AutoSquelchTuning.hangMs * _sr / 1000).round();
    _segLen = math.max(
      1,
      (AutoSquelchTuning.floorSegmentMs * _sr / 1000).round(),
    );
    _freezeSamples = (AutoSquelchTuning.floorFreezeMs * _sr / 1000).round();
    // Butterworth 4th order = two biquads, Q = 1/(2·cos(π/8)), 1/(2·cos(3π/8)).
    final fc = math.min(
      math.min(
        AutoSquelchTuning.noiseHighPassHz,
        AutoSquelchTuning.noiseHighPassBwRatio * _bw,
      ),
      0.45 * _sr,
    );
    _hp1 = _Biquad.highPass(fc, _sr, 0.54119610);
    _hp2 = _Biquad.highPass(fc, _sr, 1.30656296);
    _noiseRef = noiseReference(_bw, _sr);
    reset();
  }

  /// New bandwidth: the noise reference changes, the level floor is relearnt.
  void setBandwidth(double bandwidth) {
    if (bandwidth == _bw) return;
    configure(detector: _detector, sampleRate: _sr, bandwidth: bandwidth);
  }

  /// Forget everything (retune, gain change, new source): closed, floor relearnt.
  void reset() {
    final wasOpen = _open;
    _open = false;
    _hangLeft = 0;
    _hp1.reset();
    _hp2.reset();
    _prevRe = _prevIm = 0;
    _noise = _noiseRef; // start from "empty channel": no false opening on the first block
    _pow = 0;
    _powInit = false;
    _segCount = 0;
    _segSum = 0;
    _segClean = true;
    _openSamples = 0;
    _settleLeft =
        ((_detector == AutoSquelchDetector.noise
                    ? AutoSquelchTuning.noiseSettleMs
                    : AutoSquelchTuning.floorSettleMs) *
                _sr /
                1000)
            .round();
    _segments.clear();
    if (wasOpen) {
      transitions++;
      onChange?.call(false);
    }
  }

  /// Analyses [count] complex IF samples ([iq] is not modified) and updates [open].
  bool analyze(int count, Float32List iq) {
    if (count <= 0) return _open;
    if (_detector == AutoSquelchDetector.noise) {
      _analyzeNoise(count, iq);
    } else {
      _analyzeLevel(count, iq);
    }
    return _open;
  }

  void _decide(double metric, double? threshold, int count) {
    bool detect;
    if (threshold == null) {
      detect = false;
    } else if (_open || _hangLeft > 0) {
      detect = metric >= threshold;
    } else {
      detect = metric >= threshold + AutoSquelchTuning.hysteresisDb;
    }
    if (detect) {
      _hangLeft = _hangSamples;
      if (!_open) {
        _open = true;
        transitions++;
        onChange?.call(true);
      }
    } else if (_open) {
      _hangLeft -= count;
      if (_hangLeft <= 0) {
        _hangLeft = 0;
        _open = false;
        transitions++;
        onChange?.call(false);
      }
    }
  }

  /// Decisions are made every [_step] samples (~1 ms) so that hang/attack timing does not
  /// depend on the block size.
  int get _step => math.max(1, (_sr / 1000).round());

  void _analyzeNoise(int count, Float32List iq) {
    double pr = _prevRe, pi = _prevIm, n = _noise;
    final a1 = _nAtt;
    final step = _step;
    var k = 0;
    for (var i = 0; i < count; i++) {
      final re = iq[2 * i], im = iq[2 * i + 1];
      // Exact zeros carry no phase (cold channel filter, blanked/stopped input): no update,
      // otherwise the "silent" discriminator would read as full quieting and open.
      if ((re != 0 || im != 0) && (pr != 0 || pi != 0)) {
        // Discriminator: arg(x[n]·conj(x[n−1])), rad/sample.
        final d = math.atan2(im * pr - re * pi, re * pr + im * pi);
        final a = _hp2.process(_hp1.process(d)).abs();
        n += a1 * (a - n);
      }
      pr = re;
      pi = im;
      if (++k == step || i == count - 1) {
        _noise = n;
        final q = n > 0 ? 20 * math.log(_noiseRef / n) / math.ln10 : 99.0;
        if (_settleLeft > 0) {
          // Channel filter / HPF / smoother settling after a reset: stay closed.
          _settleLeft -= k;
        } else {
          _decide(q, thresholdDb, k);
        }
        k = 0;
      }
    }
    _prevRe = pr;
    _prevIm = pi;
    _noise = n;
  }

  void _analyzeLevel(int count, Float32List iq) {
    double p = _pow;
    final a1 = _lAtt;
    final step = _step;
    var k = 0;
    for (var i = 0; i < count; i++) {
      final re = iq[2 * i], im = iq[2 * i + 1];
      final x = re * re + im * im;
      if (!_powInit) {
        p = x;
        _powInit = true;
      } else {
        p += a1 * (x - p);
      }
      _segSum += x;
      if (++_segCount == _segLen) {
        final stuck = _open && _openSamples >= _freezeSamples;
        if (_settleLeft > 0) {
          _settleLeft -= _segCount;
        } else if ((_segClean && !_open) || stuck) {
          _segments.add(_db(_segSum / _segCount));
          if (_segments.length > AutoSquelchTuning.floorSegments) {
            _segments.removeAt(0);
          }
        }
        _segCount = 0;
        _segSum = 0;
        _segClean = !_open;
      }
      if (++k == step || i == count - 1) {
        _pow = p;
        _decide(_db(p), thresholdDb, k);
        if (_open) {
          _segClean = false;
          _openSamples += k;
        } else {
          _openSamples = 0;
        }
        k = 0;
      }
    }
    _pow = p;
  }

  static double _db(double p) => p > 0 ? 10 * math.log(p) / math.ln10 : -200.0;

  /// Applies the squelch to [frames] interleaved stereo frames at [afSampleRate], in place:
  /// gain ramps linearly between 0 and 1 over [AutoSquelchTuning.fadeMs].
  void gate(int frames, Float32List stereo, double afSampleRate) {
    final target = _open ? 1.0 : 0.0;
    if (_gain == target) {
      if (target == 0) stereo.fillRange(0, 2 * frames, 0.0);
      return;
    }
    final stepG = 1000.0 / (AutoSquelchTuning.fadeMs * afSampleRate);
    var g = _gain;
    for (var i = 0; i < frames; i++) {
      if (g < target) {
        g = math.min(target, g + stepG);
      } else if (g > target) {
        g = math.max(target, g - stepG);
      }
      stereo[2 * i] *= g;
      stereo[2 * i + 1] *= g;
    }
    _gain = g;
  }
}
