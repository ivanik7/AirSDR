// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/module.h (lines 31-103) and module.cpp (lines 1-186) @8c9f5ee,
// without dlopen (docs/01 §1.6, docs/10 decision 7).
//
// A C++ module .so exports five symbols (_INFO_, _INIT_, _CREATE_INSTANCE_, _DELETE_INSTANCE_,
// _END_). In Dart a [ModuleFactory] object provides the same five entry points, and
// `loadModule(path)` becomes [ModuleManager.loadModule] taking a factory from a static registry.
// Return codes (0 / -1) and the error cases are kept 1:1; errors are reported through
// [ModuleManager.log] instead of flog.
import 'event.dart';

/// `ModuleManager::ModuleInfo_t` (module.h:33-41).
class ModuleInfo {
  const ModuleInfo({
    required this.name,
    required this.description,
    required this.author,
    this.versionMajor = 0,
    this.versionMinor = 1,
    this.versionBuild = 0,
    this.maxInstances = 0,
  });

  final String name;
  final String description;
  final String author;
  final int versionMajor;
  final int versionMinor;
  final int versionBuild;

  /// `> 0` limits the number of instances; `<= 0` means unlimited (module.cpp:95).
  final int maxInstances;
}

/// `ModuleManager::Instance` (module.h:43-50).
abstract class ModuleInstance {
  void postInit();
  void enable();
  void disable();
  bool isEnabled();

  /// C++ destructor (called by `_DELETE_INSTANCE_`).
  void dispose() {}
}

/// The five exported symbols of a module (.so) — `ModuleManager::Module_t` (module.h:52-73).
abstract class ModuleFactory {
  /// `_INFO_`.
  ModuleInfo get info;

  /// `_INIT_`: module-global init (typically loads the module's own config file).
  void init() {}

  /// `_CREATE_INSTANCE_`.
  ModuleInstance createInstance(String name);

  /// `_DELETE_INSTANCE_`.
  void deleteInstance(ModuleInstance instance) => instance.dispose();

  /// `_END_`: module-global teardown (typically saves config).
  void end() {}
}

/// `ModuleManager::Instance_t` (module.h:75-78).
class InstanceEntry {
  InstanceEntry(this.module, this.instance);
  final ModuleFactory module;
  final ModuleInstance instance;
}

/// `ModuleManager`.
class ModuleManager {
  ModuleManager({void Function(String message)? log}) : log = log ?? ((_) {});

  /// Replaces flog::error / flog::info.
  final void Function(String message) log;

  /// module.h:100 — key = `info.name`.
  final Map<String, ModuleFactory> modules = <String, ModuleFactory>{};

  /// module.h:101 — key = instance name.
  final Map<String, InstanceEntry> instances = <String, InstanceEntry>{};

  final Event<String> onInstanceCreated = Event<String>();
  final Event<String> onInstanceDelete = Event<String>();
  final Event<String> onInstanceDeleted = Event<String>();

  /// module.cpp:5-84 without the dlopen/dlsym part: rejects a duplicate module name, returns
  /// the already-registered factory if the same object is loaded twice, else calls
  /// `init()` and registers it. Returns null on error (C++ returns a Module_t with NULL handle).
  ModuleFactory? loadModule(ModuleFactory mod) {
    final existing = modules[mod.info.name];
    if (existing != null) {
      if (identical(existing, mod)) return existing; // "same handle" (module.cpp:76)
      log('Module with name ${mod.info.name} already loaded');
      return null;
    }
    mod.init();
    modules[mod.info.name] = mod;
    return mod;
  }

  /// module.cpp:86-106.
  int createInstance(String name, String module) {
    final mod = modules[module];
    if (mod == null) {
      log("Module '$module' doesn't exist");
      return -1;
    }
    if (instances.containsKey(name)) {
      log("A module instance with the name '$name' already exists");
      return -1;
    }
    final maxCount = mod.info.maxInstances;
    if (countModuleInstances(module) >= maxCount && maxCount > 0) {
      log("Maximum number of instances reached for '$module'");
      return -1;
    }
    final inst = InstanceEntry(mod, mod.createInstance(name));
    instances[name] = inst;
    onInstanceCreated.emit(name);
    return 0;
  }

  /// module.cpp:108-119.
  int deleteInstance(String name) {
    final inst = instances[name];
    if (inst == null) {
      log("Tried to remove non-existent instance '$name'");
      return -1;
    }
    onInstanceDelete.emit(name);
    inst.module.deleteInstance(inst.instance);
    instances.remove(name);
    onInstanceDeleted.emit(name);
    return 0;
  }

  /// module.cpp:126-132.
  int enableInstance(String name) {
    final inst = instances[name];
    if (inst == null) {
      log("Cannot enable '$name', instance doesn't exist");
      return -1;
    }
    inst.instance.enable();
    return 0;
  }

  /// module.cpp:134-140.
  int disableInstance(String name) {
    final inst = instances[name];
    if (inst == null) {
      log("Cannot disable '$name', instance doesn't exist");
      return -1;
    }
    inst.instance.disable();
    return 0;
  }

  /// module.cpp:142-148.
  bool instanceEnabled(String name) {
    final inst = instances[name];
    if (inst == null) {
      log("Cannot check if '$name' is enabled, instance doesn't exist");
      return false;
    }
    return inst.instance.isEnabled();
  }

  /// module.cpp:150-156.
  void postInit(String name) {
    final inst = instances[name];
    if (inst == null) {
      log("Cannot post-init '$name', instance doesn't exist");
      return;
    }
    inst.instance.postInit();
  }

  /// module.cpp:158-164.
  String getInstanceModuleName(String name) {
    final inst = instances[name];
    if (inst == null) {
      log("Cannot get module name of'$name', instance doesn't exist");
      return '';
    }
    return inst.module.info.name;
  }

  /// module.cpp:166-177.
  int countModuleInstances(String module) {
    final mod = modules[module];
    if (mod == null) {
      log("Cannot count instances of '$module', Module doesn't exist");
      return -1;
    }
    int count = 0;
    for (final inst in instances.values) {
      if (identical(inst.module, mod)) count++;
    }
    return count;
  }

  /// module.cpp:179-185.
  void doPostInitAll() {
    for (final e in instances.entries) {
      log('Running post-init for ${e.key}');
      e.value.instance.postInit();
    }
  }

  /// Instantiates the `moduleInstances` section of the core config
  /// (gui/main_window.cpp:135-143): `{name: {module, enabled}}`.
  void createInstancesFromConfig(Map<String, dynamic> moduleInstances) {
    for (final e in moduleInstances.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final module = v['module'];
      if (module is! String) continue;
      if (createInstance(e.key, module) != 0) continue;
      if (v['enabled'] == false) disableInstance(e.key);
    }
  }

  /// core.cpp:406-418 shutdown: `end()` every module.
  void endAll() {
    for (final name in instances.keys.toList()) {
      deleteInstance(name);
    }
    for (final m in modules.values) {
      m.end();
    }
  }
}
