// SPDX-License-Identifier: GPL-3.0-or-later
//
// SDR++-style 12-digit frequency selector.
//
// Port of sdrpp/core/src/gui/widgets/frequency_select.{h,cpp} (SDR++ @8c9f5ee):
//   * digits[12], incrementDigit / decrementDigit (lines 45-83)  → [FrequencyDigits]
//   * setFrequency / frequency sum + clamp (lines 229-257)       → [FrequencyDigits]
//   * draw(): leading zeros dimmed (alpha 0.3), "." after every 3 digits,
//     click on upper half = +1 (red highlight), lower half = −1 (blue),
//     right click / Delete = zero this and all lower digits      → [FrequencySelect]
// Touch replacements (docs/03 §4.6): vertical swipe on a digit = repeated ±1,
// long-press = zero this and lower digits (SDR++ right click), the edit button
// opens a dialog for direct entry parsed with hrfreq (SDR++ Ctrl+V).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'hrfreq.dart';

/// Pure digit model of `FrequencySelect`.
class FrequencyDigits {
  FrequencyDigits([int frequency = 0]) {
    setFrequency(frequency);
  }

  static const int count = 12;

  /// `digits[i]` has weight 10^(11−i).
  final List<int> digits = List<int>.filled(count, 0);

  /// Set by inc/dec/zero (SDR++ `frequencyChanged`).
  bool frequencyChanged = false;

  /// `FrequencySelect::incrementDigit` (frequency_select.cpp:45-57): 9 → 0 with carry.
  void incrementDigit(int i) {
    if (i < 0) {
      return;
    }
    if (digits[i] < 9) {
      digits[i]++;
    } else {
      digits[i] = 0;
      incrementDigit(i - 1);
    }
    frequencyChanged = true;
  }

  /// `FrequencySelect::decrementDigit` (frequency_select.cpp:59-83): 0 → 9 with
  /// borrow, but never below zero.
  void decrementDigit(int i) {
    if (i < 0) {
      return;
    }
    if (digits[i] > 0) {
      digits[i]--;
    } else {
      if (i == 0) {
        return;
      }

      // Check if there are non zero digits afterwards
      var otherNoneZero = false;
      for (var j = i - 1; j >= 0; j--) {
        if (digits[j] > 0) {
          otherNoneZero = true;
          break;
        }
      }
      if (!otherNoneZero) {
        return;
      }

      digits[i] = 9;
      decrementDigit(i - 1);
    }
    frequencyChanged = true;
  }

  /// Right click / Delete / Enter over digit i (frequency_select.cpp:161-167).
  void zeroFrom(int i) {
    for (var j = i; j < count; j++) {
      digits[j] = 0;
    }
    frequencyChanged = true;
  }

  /// Typing a digit over position i (frequency_select.cpp:185-192).
  void typeDigit(int i, int value) {
    digits[i] = value;
    frequencyChanged = true;
  }

  /// `FrequencySelect::setFrequency` (frequency_select.cpp:245-257).
  void setFrequency(int freq) {
    var i = count - 1;
    for (var f = freq; i >= 0; i--) {
      digits[i] = f % 10;
      f = f ~/ 10;
    }
  }

  /// Σ digits·10^(11−i) (frequency_select.cpp:229-232).
  int get frequency {
    var f = 0;
    for (var i = 0; i < count; i++) {
      f = f * 10 + digits[i];
    }
    return f;
  }

  /// Index of the first non-zero digit (digits before it are drawn dimmed).
  int get firstNonZero {
    for (var i = 0; i < count; i++) {
      if (digits[i] != 0) return i;
    }
    return count;
  }
}

/// 12-digit frequency selector widget.
class FrequencySelect extends StatefulWidget {
  const FrequencySelect({
    super.key,
    required this.frequency,
    required this.onChanged,
    this.minFreq = 0,
    this.maxFreq = 999999999999,
    this.limitFreq = true,
    this.digitHeight = 40,
    this.swipeStep = 14,
  });

  /// Displayed frequency, Hz.
  final int frequency;

  /// Called with the new frequency after a user edit (SDR++ `frequencyChanged`).
  final ValueChanged<int> onChanged;
  final int minFreq;
  final int maxFreq;

  /// Clamp to [minFreq, maxFreq] (SDR++ `limitFreq`).
  final bool limitFreq;

  /// Glyph height in logical pixels (the widget scales down to fit its width).
  final double digitHeight;

  /// Vertical swipe distance (logical px) per ±1 step.
  final double swipeStep;

  @override
  State<FrequencySelect> createState() => FrequencySelectState();
}

class FrequencySelectState extends State<FrequencySelect> {
  final FrequencyDigits _digits = FrequencyDigits();
  int? _pressedDigit;
  bool _pressedTop = true;
  double _swipeAccum = 0;

  @override
  void initState() {
    super.initState();
    _digits.setFrequency(widget.frequency);
  }

  @override
  void didUpdateWidget(FrequencySelect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.frequency != _digits.frequency) {
      _digits.setFrequency(widget.frequency);
    }
  }

  /// Applies SDR++'s clamp and reports the change (frequency_select.cpp:234-241).
  void _commit() {
    if (!_digits.frequencyChanged) return;
    _digits.frequencyChanged = false;
    var freq = _digits.frequency;
    final orig = freq;
    freq = freq.clamp(widget.minFreq, widget.maxFreq);
    if (freq != orig && widget.limitFreq) {
      _digits.setFrequency(freq);
    } else {
      freq = orig;
    }
    setState(() {});
    widget.onChanged(freq);
  }

  void _inc(int i) {
    _digits.incrementDigit(i);
    _commit();
  }

  void _dec(int i) {
    _digits.decrementDigit(i);
    _commit();
  }

  Future<void> showEntryDialog() async {
    final result = await showFrequencyEntryDialog(context, _digits.frequency);
    if (result == null || !mounted) return;
    _digits.setFrequency(result.abs().round().clamp(0, 999999999999));
    _digits.frequencyChanged = true;
    _commit();
  }

  Widget _digit(BuildContext context, int i, TextStyle style, TextStyle dimStyle) {
    final dim = i < _digits.firstNonZero;
    final pressed = _pressedDigit == i;
    final h = widget.digitHeight;
    final w = h * 0.62;
    return GestureDetector(
      key: ValueKey<String>('freqDigit_$i'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => setState(() {
        _pressedDigit = i;
        _pressedTop = d.localPosition.dy < h / 2;
      }),
      onTapUp: (d) {
        setState(() => _pressedDigit = null);
        if (d.localPosition.dy < h / 2) {
          _inc(i);
        } else {
          _dec(i);
        }
      },
      onTapCancel: () => setState(() => _pressedDigit = null),
      onLongPress: () {
        _digits.zeroFrom(i);
        _commit();
      },
      onVerticalDragStart: (_) => _swipeAccum = 0,
      onVerticalDragUpdate: (d) {
        _swipeAccum += d.delta.dy;
        while (_swipeAccum <= -widget.swipeStep) {
          _swipeAccum += widget.swipeStep;
          _inc(i);
        }
        while (_swipeAccum >= widget.swipeStep) {
          _swipeAccum -= widget.swipeStep;
          _dec(i);
        }
      },
      child: SizedBox(
        width: w,
        height: h,
        child: Stack(
          children: [
            if (pressed)
              Positioned(
                left: 0,
                right: 0,
                top: _pressedTop ? 0 : h / 2,
                height: h / 2,
                child: ColoredBox(
                  // IM_COL32(255,0,0,75) / IM_COL32(0,0,255,75)
                  color: _pressedTop ? const Color(0x4BFF0000) : const Color(0x4B0000FF),
                ),
              ),
            Center(child: Text('${_digits.digits[i]}', style: dim ? dimStyle : style)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.bodyLarge?.color ?? Colors.white;
    final style = TextStyle(
      fontSize: widget.digitHeight * 0.85,
      height: 1.0,
      color: base,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final dimStyle = style.copyWith(color: base.withValues(alpha: 0.3));
    final children = <Widget>[];
    final firstNz = _digits.firstNonZero;
    for (var i = 0; i < FrequencyDigits.count; i++) {
      children.add(_digit(context, i, style, dimStyle));
      if ((i + 1) % 3 == 0 && i < 11) {
        children.add(Text('.', style: i < firstNz ? dimStyle : style));
      }
    }
    children.add(IconButton(
      key: const ValueKey<String>('freqEdit'),
      tooltip: 'Enter frequency',
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.edit),
      onPressed: showEntryDialog,
    ));
    return Semantics(
      label: 'Frequency ${hrfreqToString(_digits.frequency.toDouble())}',
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// Dialog for direct numeric entry. Accepts hrfreq syntax ("145.5M",
/// "7074k", "100000000"); a bare number with a decimal point and no unit is
/// taken as MHz (convenience, not in SDR++). Returns Hz or null.
Future<double?> showFrequencyEntryDialog(BuildContext context, int current) {
  return showDialog<double>(
    context: context,
    builder: (ctx) => _FrequencyEntryDialog(initial: hrfreqToString(current.toDouble())),
  );
}

/// Parser used by the entry dialog (see [showFrequencyEntryDialog]).
double? parseFrequencyEntry(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final hasUnit = RegExp(r'[a-zA-Z]').hasMatch(t);
  final v = hrfreqFromString(t);
  if (v == null) return null;
  if (!hasUnit && t.contains('.')) return v * 1e6;
  return v;
}

class _FrequencyEntryDialog extends StatefulWidget {
  const _FrequencyEntryDialog({required this.initial});
  final String initial;

  @override
  State<_FrequencyEntryDialog> createState() => _FrequencyEntryDialogState();
}

class _FrequencyEntryDialogState extends State<_FrequencyEntryDialog> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = parseFrequencyEntry(_ctl.text);
    if (v == null || v < 0 || v > 999999999999) {
      setState(() => _error = 'e.g. 145.5M, 7074k, 100000000');
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Frequency'),
      content: TextField(
        key: const ValueKey<String>('freqEntryField'),
        controller: _ctl,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,+\-a-zA-Z ]'))],
        decoration: InputDecoration(helperText: 'Hz, or with unit: k / M / G', errorText: _error),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey<String>('freqEntryOk'), onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}
