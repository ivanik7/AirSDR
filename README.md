# SDR Flutter

Android-приложение на Flutter: приёмник для USB SDR-донглов. Модули
[SDR++](https://github.com/AlexandreRouma/SDRPlusPlus) портированы на Dart близко к оригиналу
(1:1 по структуре), без C/NDK в собственном коде.

Путь сигнала: USB OTG → драйвер RTL-SDR/HackRF (Dart, через usbfs `ioctl`) → сигнальный путь
SDR++ (IQ-фронтенд, FFT, VFO) → демодуляторы (WFM/NFM/AM/USB/LSB/DSB/CW/RAW) → звук, спектр
и водопад.

## Архитектура

Подробности и принятые решения — в `~/prj/docs/`: `10-architecture.md` (решения), `01`–`04`
(разбор SDR++, DSP, GUI, аналогов). Статусы и API слоёв лежат в корне репозитория в файлах
`STATUS-*.md`.

| Слой | Каталог | Что там |
|---|---|---|
| USB | `lib/usb/` | Kotlin-плагин `UsbSdrPlugin.kt` отдаёт только fd; весь ввод-вывод — Dart `dart:ffi` → `ioctl(USBDEVFS_*)`; bulk-стриминг в отдельном изоляте. Здесь же `UsbDeviceProvider` (список, права, attach/detach). |
| Драйверы | `lib/drivers/rtlsdr`, `lib/drivers/hackrf` | Построчный порт librtlsdr (R820T/R828D, E4000, FC0012, FC0013, Blog V4) и libhackrf (RX). |
| DSP | `lib/sdrpp/dsp` | Блоки SDR++ (`process()` 1:1), граф синхронный, interleaved `Float32List`. |
| Сигнальный путь | `lib/sdrpp/signal_path`, `lib/sdrpp/core`, `lib/sdrpp/modules` | SourceManager, IQFrontEnd, VFO, SinkManager, модуль radio, источники rtl_sdr/hackrf/file/synth. |
| Рантайм | `lib/runtime` | DSP-изолят (`DspEngine`), протокол UI↔DSP, `SdrRadioController`, реестр источников (`device_sources.dart`: регистрация `'usb'`), вывод звука (`mp_audio_stream`/miniaudio). |
| UI | `lib/ui` | Водопад/спектр, выбор частоты, режимы, панель настроек устройства. |

Потоки: UI-изолят ↔ DSP-изолят (драйвер + граф) ↔ USB-reader-изолят. Буферы между reader и
DSP передаются слотами нативного пула.

## Сборка

Тулчейн (Flutter, JDK, Android SDK) установлен в `~/sdk`, sudo не нужен:

```sh
source ~/prj/env.sh
flutter pub get
flutter build apk --debug
flutter build apk --release --target-platform android-arm64   # основная цель — arm64-v8a
```

APK лежат в `build/app/outputs/flutter-apk/`. Release подписан debug-ключом (свой keystore
пока не настроен).

Поддерживается только **arm64-v8a**: usbfs-транспорт рассчитан на 64-битный процесс. В
32-битной сборке USB-устройство не откроется, приложение покажет ошибку «needs a 64-bit
(arm64-v8a) build». Встроенный синтетический источник работает везде.

## Тесты

```sh
source ~/prj/env.sh
flutter analyze
flutter test                      # весь набор, железо не нужно
flutter test test/runtime         # DSP-изолят, интеграция USB-источников
tool/oracle/sources/build.sh      # пересобрать golden-трассы из настоящих C-библиотек (gcc)
```

Проверка без железа:
- драйверы сверяются с оригинальными C-библиотеками (librtlsdr, libhackrf), собранными на
  хосте с фейковым libusb: каждый control-трансфер Dart должен совпасть с C
  (`tool/oracle/`, `test/drivers/`);
- DSP и демодуляторы гоняются сквозным тестом synth → radio → 48 кГц;
- UI проверяется виджет-тестами.

## Поддерживаемые устройства

- **RTL2832U** с тюнерами R820T/R820T2, R828D, E4000, FC0012, FC0013. Отдельно поддержан
  **RTL-SDR Blog V4** (R828D с апконвертером). Все 42 VID:PID из `known_devices[]` librtlsdr.
- **HackRF One** (а также Jawbreaker и rad1o), только приём.
- Airspy / Airspy HF+ распознаются, но драйвера нет — будет показана ошибка.
- Тюнер FC2580 не портирован.

Если подключить донгл при закрытом приложении, Android предложит его открыть
(`USB_DEVICE_ATTACHED`), и устройство выберется автоматически.

## Что не проверено на железе

Реального телефона и донглов при разработке не было. Не проверялись:
- usbfs-транспорт и bulk-стриминг на настоящем устройстве (проверены на фейковом ядре, а
  чтение дескрипторов — на root hub хоста);
- работа RTL-SDR и HackRF с реальным радиотрактом, в том числе усиление, AGC и скорость;
- звук через `mp_audio_stream` (AAudio/OpenSL ES через miniaudio) на Android;
- производительность на телефоне. Замеры на хосте есть в `STATUS-sigpath.md`: WFM stereo на
  2.4 MSPS идёт примерно в 8 раз быстрее реального времени на одном ядре Ryzen;
- путь Impeller `decodeImageFromPixelsSync` для водопада.

Не реализованы: FM IF NR, CTCSS, RDS-декодер, foreground service для фонового приёма.

## Лицензия

GPL-3.0-or-later (см. `LICENSE`). Основано на SDR++ (GPL-3.0), librtlsdr (GPL-2.0+) и
libhackrf (BSD-3-Clause).
