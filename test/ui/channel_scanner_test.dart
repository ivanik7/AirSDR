import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/channels/channel_controller.dart';
import 'package:sdr_flutter/ui/channels/channel_scanner.dart';
import 'package:sdr_flutter/ui/channels/channels.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _Radio extends DemoRadioController {
  AutoSquelchStatus? status;
  final List<int> tuned = [];
  @override
  AutoSquelchStatus? get autoSquelchStatus => status;
  @override
  void setTuning({required double centerFrequency, required double vfoOffset}) {
    if (centerFrequency != this.centerFrequency) {
      tuned.add(centerFrequency.round());
      status = null;
    }
    super.setTuning(centerFrequency: centerFrequency, vfoOffset: vfoOffset);
  }

  void signal(bool open) {
    status = AutoSquelchStatus(
      open: open,
      metricDb: open ? 14 : 0,
      thresholdDb: 6,
    );
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'noise loops, signal stops, hang resumes; slots and selected stay intact',
    () async {
      final radio = _Radio();
      final receiver = CenteredReceiver(radio);
      final repo = ChannelsRepository();
      final a = repo.add(frequencyHz: 145500000, mode: DemodMode.nfm);
      final b = repo.add(frequencyHz: 433500000, mode: DemodMode.nfm);
      repo.activate(a.id);
      final ctl = ChannelController(
        radio: radio,
        receiver: receiver,
        channels: repo,
        favorites: FavoritesRepository(),
      );
      radio.addListener(ctl.onRadioChanged);
      ctl.attach();
      radio.setMuted(false);
      await radio.start();
      final scan = ChannelScanner(
        controller: ctl,
        noiseDwell: const Duration(milliseconds: 80),
        resumeDelay: const Duration(milliseconds: 150),
      );
      expect(scan.start(), isTrue);
      expect(radio.muted, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      radio.signal(false);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(scan.tunedChannelId, b.id);
      radio.signal(true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(scan.receivingChannelId, b.id);
      expect(radio.muted, isFalse);
      expect(repo.activeId, a.id);
      expect(repo.channels.map((c) => c.frequencyHz), [145500000, 433500000]);
      radio.signal(false);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(scan.tunedChannelId, b.id);
      radio.signal(true);
      await Future<void>.delayed(const Duration(milliseconds: 170));
      expect(
        scan.tunedChannelId,
        b.id,
        reason: 'hang cancelled by another transmission',
      );
      radio.signal(false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(scan.tunedChannelId, a.id);
      scan.stop();
      expect(radio.muted, isFalse);
      scan.dispose();
      radio.removeListener(ctl.onRadioChanged);
      receiver.dispose();
      radio.dispose();
      repo.dispose();
    },
  );

  test(
    'manual selection and stop cancel scan; unsupported slots skipped',
    () async {
      final radio = _Radio();
      final receiver = CenteredReceiver(radio);
      final repo = ChannelsRepository();
      final a = repo.add(frequencyHz: 145500000, mode: DemodMode.nfm);
      repo.add(frequencyHz: 100000000, mode: DemodMode.wfm);
      final b = repo.add(frequencyHz: 433500000, mode: DemodMode.nfm);
      repo.activate(a.id);
      final ctl = ChannelController(
        radio: radio,
        receiver: receiver,
        channels: repo,
        favorites: FavoritesRepository(),
      );
      radio.addListener(ctl.onRadioChanged);
      ctl.attach();
      await radio.start();
      final scan = ChannelScanner(
        controller: ctl,
        noiseDwell: const Duration(milliseconds: 80),
      );
      expect(scan.start(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      radio.signal(false);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(scan.tunedChannelId, b.id);
      expect(ctl.select(a.id), isTrue);
      expect(scan.active, isFalse);
      expect(radio.tunedFrequency, a.frequencyHz);
      expect(repo.channels[1].mode, DemodMode.wfm);
      expect(scan.start(), isTrue);
      await radio.stop();
      expect(scan.active, isFalse);
      scan.dispose();
      radio.removeListener(ctl.onRadioChanged);
      receiver.dispose();
      radio.dispose();
      repo.dispose();
    },
  );
}
