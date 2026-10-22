// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A recording destination. content: is a SAF tree, never a local path.
class RecordFolder {
  const RecordFolder(this.locator, this.displayName);
  final String locator;
  final String displayName;
}

class FolderAccessException implements Exception {
  const FolderAccessException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract interface class RecordFolderPlatform {
  /// Null means the system chooser was cancelled (leave the old selection).
  Future<RecordFolder?> choose();
  Future<bool> validate(String locator);
}

class AndroidRecordFolderPlatform implements RecordFolderPlatform {
  AndroidRecordFolderPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('sdr/record_folder');
  final MethodChannel _channel;

  @override
  Future<RecordFolder?> choose() async {
    final selected = await _channel.invokeMapMethod<String, String>('choose');
    if (selected == null) return null;
    final locator = selected['locator'];
    final name = selected['displayName'];
    if (locator == null ||
        !locator.startsWith('content:content://') ||
        name == null) {
      throw const FolderAccessException(
        'Invalid recording folder returned by Android',
      );
    }
    return RecordFolder(locator, name);
  }

  @override
  Future<bool> validate(String locator) async {
    if (!locator.startsWith('content:content://')) return false;
    return await _channel.invokeMethod<bool>('validate', locator) ?? false;
  }

  /// Drop only this tree's persisted grant, never another app capability.
  Future<void> release(String locator) async {
    if (!locator.startsWith('content:content://')) return;
    await _channel.invokeMethod<void>('release', locator);
  }
}

class DesktopRecordFolderPlatform implements RecordFolderPlatform {
  DesktopRecordFolderPlatform({Future<String?> Function()? chooseDirectory})
    : _chooseDirectory = chooseDirectory ?? getDirectoryPath;
  final Future<String?> Function() _chooseDirectory;

  @override
  Future<RecordFolder?> choose() async {
    final selected = await _chooseDirectory();
    if (selected == null) return null;
    final directory = Directory(selected).absolute;
    return RecordFolder(
      'file:${directory.path}',
      directory.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ??
          directory.path,
    );
  }

  @override
  Future<bool> validate(String locator) async {
    if (!locator.startsWith('file:')) return false;
    final path = locator.substring(5);
    if (!File(path).isAbsolute || !await Directory(path).exists()) return false;
    // Check the actual write/read/delete path, not just Directory.exists. A
    // successful probe does not guarantee a later writer cannot lose access.
    final file = File(
      '$path${Platform.pathSeparator}.airsdr-probe-${DateTime.now().microsecondsSinceEpoch}-$pid',
    );
    try {
      await file.create(exclusive: true);
      final sink = await file.open(mode: FileMode.write);
      try {
        await sink.writeByte(0x5a);
        await sink.flush();
      } finally {
        await sink.close();
      }
      final contents = await file.readAsBytes();
      return contents.length == 1 && contents[0] == 0x5a;
    } on FileSystemException {
      return false;
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // A subsequent validation will still fail if the folder is unavailable.
      }
    }
  }
}

/// A sandboxed macOS app cannot reopen a saved path without its scoped bookmark.
/// The native side retains the resolved scope for the lifetime of the writer.
class MacRecordFolderPlatform implements RecordFolderPlatform {
  MacRecordFolderPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('sdr/record_folder_macos');
  final MethodChannel _channel;
  final DesktopRecordFolderPlatform _desktop = DesktopRecordFolderPlatform();

  @override
  Future<RecordFolder?> choose() async {
    final selected = await _channel.invokeMapMethod<String, String>('choose');
    if (selected == null) return null;
    final locator = selected['locator'];
    final name = selected['displayName'];
    if (locator == null || !locator.startsWith('file:/') || name == null) {
      throw const FolderAccessException('Invalid recording folder returned by macOS');
    }
    return RecordFolder(locator, name);
  }

  @override
  Future<bool> validate(String locator) async {
    if (!locator.startsWith('file:/')) return false;
    if (await _channel.invokeMethod<bool>('validate', locator) != true) {
      return false;
    }
    return _desktop.validate(locator);
  }
}

class RecordFolderStore {
  RecordFolderStore({RecordFolderPlatform? platform})
    : platform =
          platform ??
          (Platform.isAndroid
              ? AndroidRecordFolderPlatform()
              : Platform.isMacOS
              ? MacRecordFolderPlatform()
              : DesktopRecordFolderPlatform());

  static const locatorKey = 'recording.folder.locator';
  static const displayNameKey = 'recording.folder.displayName';
  final RecordFolderPlatform platform;

  Future<RecordFolder?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final locator = prefs.getString(locatorKey);
    if (locator == null || locator.isEmpty) return null;
    return RecordFolder(locator, prefs.getString(displayNameKey) ?? locator);
  }

  Future<bool> isAccessible() async {
    final folder = await load();
    if (folder == null) return false;
    try {
      return await platform.validate(folder.locator);
    } on PlatformException {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  Future<RecordFolder?> choose() async {
    final candidate = await platform.choose();
    if (candidate == null) return load();
    final previous = await load();
    try {
      if (!await platform.validate(candidate.locator)) {
        throw const FolderAccessException(
          'The selected recording folder is not writable; choose another folder',
        );
      }
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(displayNameKey, candidate.displayName) ||
          !await prefs.setString(locatorKey, candidate.locator)) {
        throw const FolderAccessException(
          'Could not save the recording folder selection',
        );
      }
    } catch (_) {
      if (candidate.locator != previous?.locator &&
          platform is AndroidRecordFolderPlatform) {
        try {
          await (platform as AndroidRecordFolderPlatform).release(candidate.locator);
        } on PlatformException {
          // Preserve the original validation/persistence error.
        }
      }
      rethrow;
    }
    if (previous != null &&
        previous.locator != candidate.locator &&
        platform is AndroidRecordFolderPlatform) {
      await (platform as AndroidRecordFolderPlatform).release(previous.locator);
    }
    return candidate;
  }
}
