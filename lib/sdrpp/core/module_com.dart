// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/module_com.h (lines 1-22) and module_com.cpp (lines 1-51) @8c9f5ee.
//
// C++ handlers are `void handler(int code, void* in, void* out, void* ctx)`. In Dart the
// `in` pointer becomes an `Object?` argument and the `out` pointer becomes the return value
// (docs/01 §1.4). No mutex: single-threaded isolate.

typedef ModuleComHandler = Object? Function(int code, Object? input);

/// `ModuleComInterface`.
class ModuleComInterface {
  ModuleComInterface(this.moduleName, this.handler);
  final String moduleName;
  final ModuleComHandler handler;
}

/// `ModuleComManager`.
class ModuleComManager {
  ModuleComManager({void Function(String message)? log}) : _log = log ?? ((_) {});

  final void Function(String message) _log;
  final Map<String, ModuleComInterface> _interfaces = <String, ModuleComInterface>{};

  /// module_com.cpp:4-15.
  bool registerInterface(String moduleName, String name, ModuleComHandler handler) {
    if (_interfaces.containsKey(name)) {
      _log('Tried creating module interface with an existing name: $name');
      return false;
    }
    _interfaces[name] = ModuleComInterface(moduleName, handler);
    return true;
  }

  /// module_com.cpp:17-25.
  bool unregisterInterface(String name) {
    if (_interfaces.remove(name) == null) {
      _log('Tried to erase module interface with unknown name: $name');
      return false;
    }
    return true;
  }

  /// module_com.cpp:27-31.
  bool interfaceExists(String name) => _interfaces.containsKey(name);

  /// module_com.cpp:33-40.
  String getModuleName(String name) {
    final iface = _interfaces[name];
    if (iface == null) {
      _log('Tried to call unknown module interface: $name');
      return '';
    }
    return iface.moduleName;
  }

  /// module_com.cpp:42-51. Returns `(ok, out)`.
  (bool, Object?) callInterface(String name, int code, [Object? input]) {
    final iface = _interfaces[name];
    if (iface == null) {
      _log('Tried to call unknown module interface: $name');
      return (false, null);
    }
    return (true, iface.handler(code, input));
  }
}
