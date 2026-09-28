// Tests for lib/ui/frequency_select.dart (port of SDR++ gui/widgets/frequency_select.cpp).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/frequency_select.dart';

void main() {
  group('FrequencyDigits (incrementDigit/decrementDigit)', () {
    test('setFrequency / frequency round trip', () {
      final d = FrequencyDigits(145500000);
      expect(d.frequency, 145500000);
      expect(d.digits, [0, 0, 0, 1, 4, 5, 5, 0, 0, 0, 0, 0]);
      expect(d.firstNonZero, 3);
      d.setFrequency(999999999999);
      expect(d.frequency, 999999999999);
    });

    test('increment carries 9 -> 0 into higher digits', () {
      final d = FrequencyDigits(99999);
      d.incrementDigit(11);
      expect(d.frequency, 100000);
      expect(d.frequencyChanged, isTrue);
    });

    test('increment of middle digit carries', () {
      final d = FrequencyDigits(1990000);
      d.incrementDigit(7); // weight 10^4
      expect(d.frequency, 2000000);
    });

    test('increment at max wraps the top digit to 0 (SDR++ behaviour)', () {
      final d = FrequencyDigits(999999999999);
      d.incrementDigit(11);
      expect(d.frequency, 0);
    });

    test('decrement borrows 0 -> 9 from higher digits', () {
      final d = FrequencyDigits(100000);
      d.decrementDigit(11);
      expect(d.frequency, 99999);
    });

    test('decrement never goes below zero', () {
      final d = FrequencyDigits(5);
      d.decrementDigit(10); // tens digit is 0, nothing above -> no-op
      expect(d.frequency, 5);
      expect(d.frequencyChanged, isFalse);
      final z = FrequencyDigits(0);
      z.decrementDigit(11);
      expect(z.frequency, 0);
      expect(z.frequencyChanged, isFalse);
      z.decrementDigit(0);
      expect(z.frequency, 0);
    });

    test('decrement of a middle digit with borrow', () {
      final d = FrequencyDigits(100000000);
      d.decrementDigit(8); // weight 1000
      expect(d.frequency, 99999000);
    });

    test('zeroFrom clears this and all lower digits', () {
      final d = FrequencyDigits(145678901);
      d.zeroFrom(6);
      expect(d.frequency, 145000000);
    });
  });

  group('parseFrequencyEntry', () {
    test('units and plain numbers', () {
      expect(parseFrequencyEntry('145.5M'), 145500000);
      expect(parseFrequencyEntry('7074k'), 7074000);
      expect(parseFrequencyEntry('1.2 GHz'), 1200000000);
      expect(parseFrequencyEntry('100000000'), 100000000);
      expect(parseFrequencyEntry('433.92'), closeTo(433920000, 1e-3)); // bare decimal = MHz
      expect(parseFrequencyEntry(''), isNull);
      expect(parseFrequencyEntry('abc'), isNull);
    });
  });

  group('FrequencySelect widget', () {
    Future<List<int>> pumpSelect(WidgetTester tester, int freq) async {
      final changes = <int>[];
      var current = freq;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 700,
              child: FrequencySelect(
                frequency: current,
                onChanged: (f) => setState(() {
                  current = f;
                  changes.add(f);
                }),
              ),
            ),
          ),
        ),
      ));
      return changes;
    }

    Rect digitRect(WidgetTester tester, int i) => tester.getRect(find.byKey(ValueKey<String>('freqDigit_$i')));

    testWidgets('tap upper half increments with carry', (tester) async {
      final changes = await pumpSelect(tester, 99999);
      final r = digitRect(tester, 11);
      await tester.tapAt(Offset(r.center.dx, r.top + r.height * 0.2));
      await tester.pump();
      expect(changes, [100000]);
    });

    testWidgets('tap lower half decrements with borrow', (tester) async {
      final changes = await pumpSelect(tester, 100000);
      final r = digitRect(tester, 11);
      await tester.tapAt(Offset(r.center.dx, r.bottom - r.height * 0.2));
      await tester.pump();
      expect(changes, [99999]);
      // Tapping again continues from the new value.
      await tester.tapAt(Offset(r.center.dx, r.bottom - r.height * 0.2));
      await tester.pump();
      expect(changes, [99999, 99998]);
    });

    testWidgets('vertical swipe steps a digit repeatedly', (tester) async {
      final changes = await pumpSelect(tester, 100000000);
      final r = digitRect(tester, 8); // kHz digit
      // Swipe up: each 14 logical px = +1 (widget is scaled by FittedBox; the
      // gesture delta is in local coordinates so compute with the scale).
      final scale = r.height / 40.0;
      await tester.dragFrom(r.center, Offset(0, -(3 * 14 + 7) * scale - kDragSlopDefault));
      await tester.pump();
      expect(changes.isNotEmpty, isTrue);
      expect(changes.last, greaterThanOrEqualTo(100003000));
      expect(changes.last % 1000, 0);
      final up = changes.last;
      changes.clear();
      await tester.dragFrom(r.center, Offset(0, (2 * 14 + 7) * scale + kDragSlopDefault));
      await tester.pump();
      expect(changes.last, lessThanOrEqualTo(up - 2000));
    });

    testWidgets('long-press zeroes this and lower digits', (tester) async {
      final changes = await pumpSelect(tester, 145678901);
      await tester.longPress(find.byKey(const ValueKey<String>('freqDigit_6')));
      await tester.pump();
      expect(changes.last, 145000000);
    });

    testWidgets('entry dialog sets frequency', (tester) async {
      final changes = await pumpSelect(tester, 100000000);
      await tester.tap(find.byKey(const ValueKey<String>('freqEdit')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey<String>('freqEntryField')), '145.5M');
      await tester.tap(find.byKey(const ValueKey<String>('freqEntryOk')));
      await tester.pumpAndSettle();
      expect(changes, [145500000]);
      expect(find.text('Frequency'), findsNothing);
    });

    testWidgets('clamps to maxFreq when limitFreq', (tester) async {
      final changes = <int>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            child: FrequencySelect(frequency: 1766000000, maxFreq: 1766000000, onChanged: changes.add),
          ),
        ),
      ));
      final r = digitRect(tester, 2); // 10^9 digit... index 2 = 10^9
      await tester.tapAt(Offset(r.center.dx, r.top + r.height * 0.2));
      await tester.pump();
      expect(changes, [1766000000]);
    });
  });
}
