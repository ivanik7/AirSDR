import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('built-ins, filtering, toggling and persistence preserve order', () async {
    final repo = FavoritesRepository();
    await repo.load();
    expect(repo.entries.length, 12);
    expect(repo.filtered('AIR').length, 3);
    expect(repo.entries.first.name, 'Симплекс 2м');
    repo.toggle('builtin-0');
    repo.add(frequencyHz: 99500000, name: 'Своё FM', mode: DemodMode.wfm, category: 'FM');
    await repo.flush();
    final reopened = FavoritesRepository();
    await reopened.load();
    expect(reopened.entries.first.enabled, isFalse);
    expect(reopened.entries.last.name, 'Своё FM');
    expect(reopened.filtered('FM').last.frequencyHz, 99500000);
    reopened.edit(reopened.entries.last.id, name: 'Новая', mode: DemodMode.am, category: 'AIR');
    expect(reopened.filtered('AIR').last.mode, DemodMode.am);
    reopened.delete(reopened.entries.last.id);
    await reopened.flush();
    final again = FavoritesRepository();
    await again.load();
    expect(again.entries.length, 12);
  });

  test('rejects duplicate frequencies and invalid values', () async {
    final repo = FavoritesRepository();
    await repo.load();
    expect(() => repo.add(frequencyHz: 145500000, name: 'duplicate', mode: DemodMode.am, category: 'VHF'), throwsArgumentError);
    expect(() => repo.add(frequencyHz: -1, name: 'x', mode: DemodMode.am, category: 'VHF'), throwsArgumentError);
    expect(() => repo.add(frequencyHz: 99000000, name: ' ', mode: DemodMode.am, category: 'VHF'), throwsArgumentError);
    expect(() => repo.add(frequencyHz: 99000000, name: 'x', mode: DemodMode.am, category: 'wrong'), throwsArgumentError);
  });
}
