import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';

void main() {
  test(
    'keypad, arrows, favorite, every mode and start keep a single centered VFO',
    () async {
      final radio = DemoRadioController();
      radio.setTuning(centerFrequency: 100000000, vfoOffset: 20000);
      final receiver = CenteredReceiver(radio);
      receiver.resetOffset();
      expect(radio.vfoOffset, 0);
      for (final key in ['1', '2', '1', '.', '5', 'OK']) {
        receiver.pressKey(key);
      }
      expect(radio.tunedFrequency, 121500000);
      receiver.nudge(-1);
      expect(radio.vfoOffset, 0);
      receiver.apply(99500000, DemodMode.lsb);
      expect(radio.centerFrequency, 99500000);
      for (final mode in DemodMode.values) {
        receiver.changeMode(mode);
        expect(radio.vfoOffset, 0, reason: mode.label);
        expect(radio.tunedFrequency, radio.centerFrequency);
      }
      await receiver.start();
      expect(radio.vfoOffset, 0);
      radio.dispose();
    },
  );
}
