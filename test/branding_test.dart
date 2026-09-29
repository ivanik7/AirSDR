// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AirSDR is the installed app and foreground reception brand', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final service = File(
      'android/app/src/main/kotlin/net/ivanik/sdr_flutter/ReceptionService.kt',
    ).readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    expect(manifest, contains('android:label="AirSDR"'));
    expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
    expect(service, contains('.setContentTitle("AirSDR")'));
    expect(service, contains('.setSmallIcon(R.drawable.ic_stat_airsdr)'));
    expect(main, contains("title: 'AirSDR'"));
  });

  test('adaptive and legacy icons ship in every density', () {
    final res = Directory('android/app/src/main/res');
    final adaptive = File('${res.path}/mipmap-anydpi-v26/ic_launcher.xml')
        .readAsStringSync();
    expect(adaptive, contains('@drawable/ic_launcher_foreground'));
    expect(adaptive, contains('@drawable/ic_launcher_monochrome'));
    expect(adaptive, contains('@color/airsdr_icon_background'));
    final small = File('${res.path}/drawable/ic_stat_airsdr.xml')
        .readAsStringSync();
    expect(small, contains('#FFFFFFFF'));
    for (final density in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
      final png = File('${res.path}/mipmap-$density/ic_launcher.png')
          .readAsBytesSync();
      expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    }
  });

  test('launch window background matches the dark UI', () {
    final res = Directory('android/app/src/main/res');
    for (final path in [
      '${res.path}/drawable/launch_background.xml',
      '${res.path}/drawable-v21/launch_background.xml',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('@color/airsdr_background'),
      );
    }
    expect(
      File('${res.path}/values/colors.xml').readAsStringSync(),
      contains('#0B0D0F'),
    );
    expect(
      File('${res.path}/values-v31/styles.xml').readAsStringSync(),
      contains(
        'android:windowSplashScreenBackground">@color/airsdr_background',
      ),
    );
  });
}
