// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/config.h (lines 1-35) and config.cpp (lines 1-100) @8c9f5ee.
//
// Differences (docs/01 §1.5):
//  * `json conf` is a `Map<String, dynamic>` (JSON-compatible values only).
//  * acquire()/release() keep the C++ call shape but there is no mutex: a Dart isolate is
//    single-threaded. release(true) marks the config dirty.
//  * The C++ auto-save thread polls every 1 s. Dart uses a debounced [Timer]: the first
//    release(true) after a save schedules a save [autoSaveDelay] later (default 1 s), so a
//    burst of changes costs a single write, exactly as the C++ 1 s poll does.
//  * The path is injectable ([setPath]); a null path keeps the config in memory only (tests).
//  * Writes are atomic (write to `<path>.tmp`, then rename) so a crash never leaves a
//    truncated file — C++ writes in place; the file format (`dump(4)`) is the same.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ConfigManager {
  ConfigManager({this.autoSaveDelay = const Duration(seconds: 1)});

  /// Auto-save debounce period (C++: 1000 ms poll, config.cpp:92).
  final Duration autoSaveDelay;

  /// The JSON document (C++ `json conf`).
  Map<String, dynamic> conf = <String, dynamic>{};

  String? _path;
  bool _changed = false;
  bool _autoSaveEnabled = false;
  Timer? _timer;

  /// Number of completed saves (diagnostics / tests).
  int saveCount = 0;

  String? get path => _path;
  bool get changed => _changed;
  bool get autoSaveEnabled => _autoSaveEnabled;

  /// config.cpp:13 (`std::filesystem::absolute(file)`).
  void setPath(String? file) {
    _path = file == null ? null : File(file).absolute.path;
  }

  /// config.cpp:17-45: missing file → write [def]; unreadable/corrupt → reset to [def].
  /// [def] is deep-copied, so the caller's default map is never aliased.
  void load(Map<String, dynamic> def) {
    final p = _path;
    if (p == null) {
      conf = _deepCopy(def);
      return;
    }
    final f = File(p);
    if (!f.existsSync()) {
      // flog::warn("Config file '{0}' does not exist, creating it")
      conf = _deepCopy(def);
      save();
    }
    try {
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('top level is not an object');
      }
      conf = decoded;
    } catch (_) {
      // flog::error("Config file '{}' is corrupted, resetting it")
      conf = _deepCopy(def);
      save();
    }
  }

  /// config.cpp:47-53 (`file << conf.dump(4)`).
  void save() {
    final p = _path;
    if (p == null) {
      saveCount++;
      return;
    }
    final f = File(p);
    f.parent.createSync(recursive: true);
    final tmp = File('$p.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent('    ').convert(conf), flush: true);
    tmp.renameSync(p);
    saveCount++;
  }

  /// config.cpp:55.
  void enableAutoSave() {
    if (_autoSaveEnabled) return;
    _autoSaveEnabled = true;
    if (_changed) _schedule();
  }

  /// config.cpp:62. Pending changes are NOT written (C++ joins the thread, which may or may
  /// not have saved); call [save] explicitly, as `_END_` does.
  void disableAutoSave() {
    if (!_autoSaveEnabled) return;
    _autoSaveEnabled = false;
    _timer?.cancel();
    _timer = null;
  }

  /// config.cpp:73 — no-op (single-threaded isolate), kept for 1:1 call sites.
  void acquire() {}

  /// config.cpp:77.
  void release([bool modified = false]) {
    _changed |= modified;
    if (modified && _autoSaveEnabled) _schedule();
  }

  /// Saves now if dirty (used on shutdown and by tests).
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_changed) {
      _changed = false;
      save();
    }
  }

  void _schedule() {
    if (_timer != null) return;
    _timer = Timer(autoSaveDelay, () {
      _timer = null;
      if (!_autoSaveEnabled) return;
      if (_changed) {
        _changed = false;
        try {
          save();
        } catch (_) {
          // Keep dirty so the next change retries.
          _changed = true;
        }
      }
    });
  }

  /// Returns `conf[key]` as a JSON object, creating it if missing (C++ `conf[key]`
  /// auto-vivification).
  Map<String, dynamic> obj(String key, [Map<String, dynamic>? parent]) {
    final p = parent ?? conf;
    final v = p[key];
    if (v is Map<String, dynamic>) return v;
    final m = <String, dynamic>{};
    p[key] = m;
    return m;
  }

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> m) =>
      jsonDecode(jsonEncode(m)) as Map<String, dynamic>;
}
