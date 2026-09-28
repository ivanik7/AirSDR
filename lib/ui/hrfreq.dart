// SPDX-License-Identifier: GPL-3.0-or-later
//
// Human-readable frequency strings.
// Port of sdrpp/core/src/utils/hrfreq.cpp (SDR++ @8c9f5ee, lines 1-120).

/// `hrfreq::toString`: e.g. 145500000 → "145.5MHz".
String hrfreqToString(double freq) {
  // Determine the scale
  var maxDecimals = 0;
  var suffix = 'Hz';
  if (freq >= 1e9) {
    freq /= 1e9;
    maxDecimals = 9;
    suffix = 'GHz';
  } else if (freq >= 1e6) {
    freq /= 1e6;
    maxDecimals = 6;
    suffix = 'MHz';
  } else if (freq >= 1e3) {
    freq /= 1e3;
    maxDecimals = 3;
    suffix = 'KHz';
  }

  // Convert to string
  var numBuf = freq.toStringAsFixed(maxDecimals);

  // If there is a decimal point, remove the useless zeros
  if (maxDecimals != 0) {
    var end = numBuf.length;
    for (var i = numBuf.length - 1; i >= 0; i--) {
      final dot = numBuf[i] == '.';
      if (numBuf[i] != '0' && !dot) break;
      end = i;
      if (dot) break;
    }
    numBuf = numBuf.substring(0, end);
  }

  return '$numBuf$suffix';
}

bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;
bool _isAlpha(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
}

bool _isNumeric(String c) => _isDigit(c) || c == '+' || c == '-' || c == '.' || c == ',';

/// `hrfreq::fromString`: parses "145.5M", "7074k", "100000000", "1.2 GHz".
/// Returns null on failure (C++ returns false).
double? hrfreqFromString(String str) {
  // Skip non-numeric characters
  var i = 0;
  for (; i < str.length; i++) {
    if (_isNumeric(str[i])) break;
  }

  // Extract the numeric part
  final numeric = StringBuffer();
  for (; i < str.length; i++) {
    final c = str[i];
    // If it's a letter, stop
    if (_isAlpha(c)) break;
    // If isn't numeric, skip it
    if (!_isNumeric(c)) continue;
    // If it's a comma, skip it for now. This enforces a dot as a decimal point
    if (c == ',') continue;
    numeric.write(c);
  }

  // Attempt to parse the numeric part
  var num = double.tryParse(numeric.toString());
  if (num == null) return null;

  // If no more text is available, assume the numeric part gives a frequency in Hz
  if (i == str.length) return num;

  // Scale the numeric value depending on the first scale character
  switch (str[i].toUpperCase()) {
    case 'G':
      num *= 1e9;
    case 'M':
      num *= 1e6;
    case 'K':
      num *= 1e3;
    default:
      break;
  }
  return num;
}
