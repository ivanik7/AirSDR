# AirSDR

Карманный SDR-приёмник для Android с RTL-SDR и HackRF через USB OTG. Модули
[SDR++](https://github.com/AlexandreRouma/SDRPlusPlus) портированы на Dart близко к оригиналу
(1:1 по структуре). Этот рабочий путь сохраняется на время поэтапного перехода на C++/NDK
(план — `~/prj/docs/40-native-core-plan.md`). `native/` содержит ABI 2 с диагностическими
file/synthetic IQ источниками и исходниками нативных RTL-SDR/HackRF драйверов, но без DSP и аудио.
Аппаратный приём и UI по умолчанию по-прежнему работают через Dart; аппаратная проверка N1
не пройдена — подробности в `docs/native-n1-status.md`.

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

`android/app` собирает `native/CMakeLists.txt` через `externalNativeBuild` для arm64-v8a;
`lib/native/sdr_core.dart` загружает библиотеку по запросу, проверяет ABI 2 до
создания handle, требует явный `dispose()`; диагностический синтетический поток
не запускается автоматически и не воспроизводит звук. На Android arm64 используется
`libsdrcore.so` из APK, на Linux можно передать `libraryPath` в `SdrCore.open()`
или настроить путь загрузчика (Linux-приложение — см. раздел L1 ниже). На хосте с CMake 3.22+ каркас проверяется
командами `cmake -S native -B <build-dir>`, `cmake --build <build-dir>` и
`ctest --test-dir <build-dir> --output-on-failure`. Build-dir должен быть вне исходников.
`native/tests/abi_test.c` и `stream_test.cpp` проверяют ABI, состояния и fd.
Для реального вызова из
Flutter-теста на Linux задайте абсолютный путь к собранной host-библиотеке
(Android SDK содержит CMake 3.22.1, системный `cmake` не обязателен):

```sh
source ~/prj/env.sh
"$ANDROID_HOME/cmake/3.22.1/bin/cmake" -S native -B "$TMPDIR/sdrcore-host-build"
"$ANDROID_HOME/cmake/3.22.1/bin/cmake" --build "$TMPDIR/sdrcore-host-build"
"$ANDROID_HOME/cmake/3.22.1/bin/ctest" --test-dir "$TMPDIR/sdrcore-host-build" --output-on-failure
SDRCORE_HOST_LIBRARY="$TMPDIR/sdrcore-host-build/libsdrcore.so" \
  flutter test test/native/sdr_core_ffi_integration_test.dart
```

Без `SDRCORE_HOST_LIBRARY` интеграционный тест явно пропускается (обычный
`flutter test` не собирает CMake-библиотеку); с указанным неверным путём тест
падает, а не выдаёт подменённый ответ. Это проверка Linux host, не вызов FFI
на Android и не аппаратный приём.

### Linux desktop (L1, dev/test target)

`flutter build linux --debug` builds `native/` together with the runner and
puts `libsdrcore.so` into `build/linux/x64/debug/bundle/lib/`. On Linux the
app uses the native engine (`HostIqRadioController`, real RTL-SDR/HackRF via
`/dev/bus/usb`, IQ only until N2); the Dart receive engine is not used there.
If the library is missing, the app shows an honest "native core required"
state. The user needs rw access to `/dev/bus/usb/*` (plugdev + librtlsdr udev
rule). Real-RX checks: `sdrcore_host_rx_diag` (from a standalone `native/`
CMake build) and `SDR_HW_TEST=1 flutter test test/platform/host_iq_hw_test.dart`.
Details and results: `STATUS-linux-host.md`.

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

Быстрый UI/synthetic smoke на headless Android-эмуляторе (без телефона и USB-SDR):
[`docs/android-emulator.md`](docs/android-emulator.md). Аппаратный приём проверяется отдельно
на телефоне с донглом.

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

Не реализованы: FM IF NR, CTCSS, RDS-декодер. Фоновый приём через foreground service
описан в `STATUS-background.md` (проверен на SM-F936B с RTL-SDR Blog V4; слышимость в фоне не подтверждена).

## Лицензия

GPL-3.0-or-later (см. `LICENSE`). Основано на SDR++ (GPL-3.0), librtlsdr (GPL-2.0+) и
libhackrf (BSD-3-Clause).
