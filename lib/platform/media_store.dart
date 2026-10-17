// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';

/// Saves encoded image bytes to Android shared storage via MediaStorePlugin.kt.
class AndroidMediaStore {
  AndroidMediaStore({MethodChannel? channel})
    : _channel = channel ?? defaultChannel;

  static const MethodChannel defaultChannel = MethodChannel('sdr/media');

  final MethodChannel _channel;

  /// Saves [bytes] as [displayName] under Pictures/[album] (Android MediaStore
  /// on API 29+, app-specific external files on API 26-28).
  ///
  /// Returns the saved location reported by the platform. Throws [StateError]
  /// if the platform returned null/empty, and lets [PlatformException] propagate.
  Future<String> saveImage({
    required Uint8List bytes,
    required String displayName,
    String mimeType = 'image/png',
    String album = 'AirSDR',
  }) async {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'must not be empty');
    }
    if (displayName.isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'must not be empty',
      );
    }
    if (displayName.contains('/') || displayName.contains('\\')) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'must not contain path separators',
      );
    }

    final location = await _channel.invokeMethod<String>(
      'saveImage',
      <String, Object>{
        'bytes': bytes,
        'displayName': displayName,
        'mimeType': mimeType,
        'album': album,
      },
    );

    if (location == null || location.isEmpty) {
      throw StateError('Platform returned no saved location');
    }
    return location;
  }
}
