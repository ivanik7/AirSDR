import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/channels/channel_controller.dart';
import 'package:sdr_flutter/ui/channels/channels.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ChannelsRepository', () {
    test('add makes the new slot active; order and active persist', () async {
      final repo = ChannelsRepository();
      await repo.load();
      expect(repo.channels, isEmpty);
      expect(repo.active, isNull);
      final a = repo.add(frequencyHz: 101200000, mode: DemodMode.wfm);
      final b = repo.add(frequencyHz: 118100000, mode: DemodMode.am);
      final c = repo.add(
        frequencyHz: 145500000,
        mode: DemodMode.nfm,
        name: '2м',
      );
      expect(repo.activeId, c.id);
      repo.activate(b.id);
      repo.move(c.id, 0);
      expect(repo.channels.map((e) => e.id), [c.id, a.id, b.id]);
      expect(repo.activeId, b.id, reason: 'reorder keeps the active slot');
      await repo.flush();

      final again = ChannelsRepository();
      await again.load();
      expect(again.channels.map((e) => e.id), [c.id, a.id, b.id]);
      expect(again.channels.first.name, '2м');
      expect(again.channels.first.mode, DemodMode.nfm);
      expect(again.activeId, b.id);
      final d = again.add(frequencyHz: 446006000, mode: DemodMode.nfm);
      expect(
        [a.id, b.id, c.id],
        isNot(contains(d.id)),
        reason: 'ids stay unique across restarts',
      );
      repo.dispose();
      again.dispose();
    });

    test('updateActive touches only the active slot', () async {
      final repo = ChannelsRepository();
      final a = repo.add(frequencyHz: 101200000, mode: DemodMode.wfm);
      final b = repo.add(frequencyHz: 118100000, mode: DemodMode.am);
      expect(
        repo.updateActive(frequencyHz: 118125000, mode: DemodMode.nfm),
        isTrue,
      );
      expect(repo.channels[0].frequencyHz, 101200000);
      expect(repo.channels[0].mode, DemodMode.wfm);
      expect(repo.channels[1].frequencyHz, 118125000);
      expect(repo.channels[1].mode, DemodMode.nfm);
      expect(repo.channels[1].id, b.id);
      repo.activate(null);
      expect(repo.updateActive(frequencyHz: 1, mode: DemodMode.am), isFalse);
      expect(repo.channels.map((e) => e.frequencyHz), [101200000, 118125000]);
      expect(a.frequencyHz, 101200000);
      repo.dispose();
    });

    test('deleting the active slot activates a neighbour; last may go', () {
      final repo = ChannelsRepository();
      final a = repo.add(frequencyHz: 1000000, mode: DemodMode.am);
      final b = repo.add(frequencyHz: 2000000, mode: DemodMode.am);
      final c = repo.add(frequencyHz: 3000000, mode: DemodMode.am);
      repo.activate(b.id);
      repo.delete(b.id);
      expect(repo.activeId, c.id, reason: 'the next slot takes its place');
      repo.delete(c.id);
      expect(repo.activeId, a.id, reason: 'at the end: previous slot');
      repo.delete(a.id);
      expect(repo.channels, isEmpty);
      expect(repo.activeId, isNull);
      repo.dispose();
    });

    test('deleting an inactive slot keeps the active one', () {
      final repo = ChannelsRepository();
      final a = repo.add(frequencyHz: 1000000, mode: DemodMode.am);
      final b = repo.add(frequencyHz: 2000000, mode: DemodMode.am);
      repo.delete(a.id);
      expect(repo.activeId, b.id);
      repo.dispose();
    });

    test('rename validates, corrupt storage does not crash', () async {
      SharedPreferences.setMockInitialValues({
        ChannelsRepository.storageKey:
            '{"activeId":"ch-9","entries":[{"id":"ch-1","name":"x",'
            '"frequencyHz":100000000,"mode":"NOPE"},{"id":"ch-2","name":"ok",'
            '"frequencyHz":100500000,"mode":"NFM"}]}',
      });
      final repo = ChannelsRepository();
      await repo.load();
      expect(repo.channels.map((e) => e.id), ['ch-2']);
      expect(repo.activeId, 'ch-2', reason: 'unknown active -> first');
      expect(() => repo.rename('ch-2', '  '), throwsArgumentError);
      repo.rename('ch-2', ' Новое ');
      expect(repo.channels.single.name, 'Новое');
      expect(repo.add(frequencyHz: 1, mode: DemodMode.am).id, isNot('ch-2'));
      repo.dispose();
    });

    test('unparseable storage starts empty', () async {
      SharedPreferences.setMockInitialValues({
        ChannelsRepository.storageKey: 'garbage',
      });
      final broken = ChannelsRepository();
      await broken.load();
      expect(broken.channels, isEmpty);
      expect(broken.loaded, isTrue);
      broken.dispose();
    });
  });

  group('ChannelController', () {
    late DemoRadioController radio;
    late CenteredReceiver receiver;
    late ChannelsRepository repo;
    late FavoritesRepository favorites;
    late ChannelController ctl;

    setUp(() {
      radio = DemoRadioController();
      receiver = CenteredReceiver(radio);
      repo = ChannelsRepository();
      favorites = FavoritesRepository();
      ctl = ChannelController(
        radio: radio,
        receiver: receiver,
        channels: repo,
        favorites: favorites,
      );
      radio.addListener(ctl.onRadioChanged);
    });
    tearDown(() {
      radio.removeListener(ctl.onRadioChanged);
      radio.dispose();
      repo.dispose();
      favorites.dispose();
    });

    test('attach tunes the receiver to the restored active channel', () {
      repo.add(frequencyHz: 101200000, mode: DemodMode.wfm);
      repo.add(frequencyHz: 118100000, mode: DemodMode.am);
      radio.setTuning(centerFrequency: 90000000, vfoOffset: 0);
      expect(
        repo.active!.frequencyHz,
        118100000,
        reason: 'no write-back before attach',
      );
      ctl.attach();
      expect(radio.tunedFrequency, 118100000);
      expect(radio.centerFrequency, 118100000);
      expect(radio.vfoOffset, 0);
      expect(radio.mode, DemodMode.am);
    });

    test('tap selects: tune + mode of that channel, centered', () {
      ctl.attach();
      final fm = repo.add(frequencyHz: 101200000, mode: DemodMode.wfm);
      final air = repo.add(frequencyHz: 118100000, mode: DemodMode.am);
      expect(ctl.select(fm.id), isTrue);
      expect(repo.activeId, fm.id);
      expect(radio.tunedFrequency, 101200000);
      expect(radio.vfoOffset, 0);
      expect(radio.mode, DemodMode.wfm);
      expect(ctl.select(air.id), isTrue);
      expect(radio.tunedFrequency, 118100000);
      expect(radio.mode, DemodMode.am);
      // Channels themselves are untouched by switching.
      expect(repo.channels[0].frequencyHz, 101200000);
      expect(repo.channels[0].mode, DemodMode.wfm);
      // Tapping the active one again is harmless.
      expect(ctl.select(air.id), isTrue);
      expect(radio.tunedFrequency, 118100000);
      expect(repo.activeId, air.id);
    });

    test('retune / mode change is written into the active channel only', () {
      ctl.attach();
      final fm = repo.add(frequencyHz: 101200000, mode: DemodMode.wfm);
      final air = repo.add(frequencyHz: 118100000, mode: DemodMode.am);
      ctl.select(air.id);
      receiver.nudge(1);
      receiver.changeMode(DemodMode.nfm);
      final nudged = 118100000 + CenteredReceiver.steps[receiver.stepIndex];
      expect(repo.channels[1].frequencyHz, nudged.round());
      expect(repo.channels[1].mode, DemodMode.nfm);
      expect(repo.channels[0].frequencyHz, 101200000);
      expect(repo.channels[0].mode, DemodMode.wfm);
      receiver.apply(145500000, DemodMode.nfm); // preset
      expect(repo.active!.frequencyHz, 145500000);
      expect(
        repo.channels.firstWhere((c) => c.id == fm.id).frequencyHz,
        101200000,
      );
    });

    test('drag writes the channel once, on release', () {
      ctl.attach();
      final ch = repo.add(frequencyHz: 100000000, mode: DemodMode.nfm);
      ctl.select(ch.id);
      receiver.beginDrag();
      receiver.dragBy(25000);
      receiver.dragBy(25000);
      expect(radio.vfoOffset, isNot(0));
      expect(repo.active!.frequencyHz, 100000000, reason: 'not during drag');
      receiver.endDrag();
      expect(radio.vfoOffset, 0);
      expect(repo.active!.frequencyHz, 100050000);
    });

    test('without an active channel nothing is written', () {
      ctl.attach();
      receiver.tune(99000000);
      expect(repo.channels, isEmpty);
    });

    test('+ channel copies the current frequency/mode and activates it', () {
      ctl.attach();
      receiver.apply(145500000, DemodMode.nfm);
      final ch = ctl.add();
      expect(ch.frequencyHz, 145500000);
      expect(ch.mode, DemodMode.nfm);
      expect(ch.name, 'Симплекс 2м', reason: 'named after a matching preset');
      expect(repo.activeId, ch.id);
      // The new slot is active, so retuning is written into it.
      receiver.tune(99100000);
      expect(repo.channels.single.frequencyHz, 99100000);
      final other = ctl.add();
      expect(other.name, isNotEmpty);
      expect(other.frequencyHz, 99100000);
      expect(repo.activeId, other.id);
      receiver.tune(99500000);
      expect(repo.channels.first.frequencyHz, 99100000);
      expect(repo.channels.last.frequencyHz, 99500000);
    });

    test('deleting the active channel retunes to the neighbour', () {
      ctl.attach();
      final a = repo.add(frequencyHz: 101200000, mode: DemodMode.wfm);
      final b = repo.add(frequencyHz: 118100000, mode: DemodMode.am);
      ctl.select(a.id);
      ctl.delete(a.id);
      expect(repo.activeId, b.id);
      expect(radio.tunedFrequency, 118100000);
      expect(radio.mode, DemodMode.am);
      ctl.delete(b.id);
      expect(repo.activeId, isNull);
      expect(
        radio.tunedFrequency,
        118100000,
        reason: 'receiver stays where it was',
      );
      receiver.tune(99000000);
      expect(repo.channels, isEmpty);
    });

    test('out-of-range channel is not selected and not overwritten', () {
      ctl.attach();
      final ok = repo.add(frequencyHz: 101200000, mode: DemodMode.wfm);
      final far = repo.add(frequencyHz: 5000000000, mode: DemodMode.nfm);
      ctl.select(ok.id);
      expect(ctl.select(far.id), isFalse, reason: 'RTL tops out at 1.766 GHz');
      expect(repo.activeId, ok.id);
      expect(repo.channels[1].frequencyHz, 5000000000);
      expect(radio.tunedFrequency, 101200000);
    });

    test('save as preset adds a favorite; duplicate gives a reason', () {
      ctl.attach();
      final ch = repo.add(
        frequencyHz: 99912500,
        mode: DemodMode.wfm,
        name: 'Моё FM',
      );
      expect(ctl.saveAsPreset(ch.id), isNull);
      final f = favorites.entries.last;
      expect(f.frequencyHz, 99912500);
      expect(f.name, 'Моё FM');
      expect(f.mode, DemodMode.wfm);
      expect(f.category, 'FM');
      expect(ctl.saveAsPreset(ch.id), contains('уже есть'));
    });
  });
}
