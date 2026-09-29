# Android-эмулятор для UI/synthetic smoke (debian-ai)

Эмулятор НЕ заменяет SM-F936B с RTL-SDR Blog V4. Здесь проверяются только старт приложения
на Android, интерфейс, перестройка/режимы, DSP на синтетических IQ и отрисовка спектра/водопада.
Для этой процедуры телефон не нужен, и трогать его нельзя.

| Проверяется на эмуляторе | Только на физическом телефоне с USB-SDR |
|---|---|
| установка/запуск debug APK, холодный старт | USB OTG, usbfs, разрешение USB, драйверы RTL-SDR/HackRF |
| вкладки Приём / Пресеты / Настройки, раскладка 360×780 dp | реальный эфир, чувствительность, gain/AGC тюнера, PPM |
| выбор `Synthetic signal generator`, Старт/Стоп | слышимость и качество звука (проверяется вручную) |
| частота (клавиатура, шаг ◀ ▶), центрирование, режимы WFM/NFM/AM/… | производительность и нагрев на arm64, release-сборка |
| живой спектр и водопад на синтетическом сигнале, отсутствие крэшей | фон/экран выключен, Samsung-специфика (One UI, Android 16) |

Перед приёмкой hardware-dependent изменений (драйверы, USB, источник, аудио, фоновой приём)
проверка на телефоне остаётся обязательной; прохождение эмулятора её не заменяет.

## Состояние хоста (проверено 2026-09-29)

- Emulator 37.1.11, образ `system-images;android-35;default;x86_64` (Android 15, без Play),
  AVD `sdr_api35` в `~/.android/avd/`: Pixel 4a, 720×1560 @320 dpi (360×780 dp), 2 GiB RAM,
  4 ядра, data 6 GiB. SDK/AVD вне git, в репозитории только скрипт и эта инструкция.
- KVM: `/dev/kvm` `root:kvm 0660`, `$USER` добавлен в группу `kvm` (`getent group kvm`).
  В login-сессии, начатой до этого (например, в процессе Hermes gateway), группы ещё нет;
  `tool/emulator.sh start` в таком случае сам запускает эмулятор через `sg kvm -c`.
  Проверка: `sg kvm -c '~/sdk/android/emulator/emulator -accel-check'` → `KVM ... is installed and usable`.
  Программную эмуляцию без KVM не используем.
- Холодная загрузка — 18–30 с до `sys.boot_completed=1`; эмулятор занимает около 2–3 GiB RAM.
  Между сессиями его не оставлять (у ВМ 11 GiB) и не запускать одновременно с Gradle-сборкой,
  если памяти мало.

Установка с нуля (уже выполнена на debian-ai):

```sh
source ~/prj/env.sh
sdkmanager 'emulator' 'system-images;android-35;default;x86_64'
avdmanager create avd --name sdr_api35 --package 'system-images;android-35;default;x86_64' --device pixel_4a
# в ~/.android/avd/sdr_api35.avd/config.ini: hw.lcd.width=720 hw.lcd.height=1560 hw.lcd.density=320 hw.ramSize=2G
```

## Цикл разработчика

Из корня репозитория (или worktree), `tool/emulator.sh` сам делает `source ~/prj/env.sh`:

```sh
tool/emulator.sh start        # headless: -no-window -no-audio -no-snapshot -gpu swiftshader_indirect -accel on
tool/emulator.sh wait         # ждёт sys.boot_completed=1
adb devices -l                # emulator-5554 ... model:Android_SDK_built_for_x86_64
flutter build apk --debug
tool/emulator.sh install      # adb install -r (данные приложения сохраняются) + запуск и проверка
tool/emulator.sh shot recv    # recv.png (+ recv.xml, дамп UI через uiautomator)
tool/emulator.sh logs         # emulator-logcat.txt: flutter, AndroidRuntime, libc/DEBUG
tool/emulator.sh stop         # adb emu kill
```

Вместо `build` + `install` можно `flutter run -d emulator-5554` (hot reload; проверено: первая
сборка + установка ≈ 1 мин). Debug APK содержит x86_64. Release собирается только под arm64-v8a,
на эмулятор его не ставить.
Serial всегда указывать явно (`-s emulator-5554`, `-d emulator-5554`): телефон тоже виден в
`adb devices`/`flutter devices` через Wi-Fi ADB. При другом `EMU_PORT` serial меняется.

Эмулятор запускается в фоне (`nohup`). Если запускающий процесс убивается вместе с группой
(так бывает у агентских терминалов с таймаутом), эмулятор тоже умрёт. В этом случае нужно запускать
`tool/emulator.sh start` из отдельного постоянного shell/фоновой сессии.

## Synthetic smoke (выполнен 2026-09-29, коммит ветки на базе 406ba64)

Координаты — для 720×1560; актуальные bounds брать из `tool/emulator.sh shot` (xml) либо
`adb -s emulator-5554 exec-out uiautomator dump /dev/tty`. Элементы доступны по content-desc.

1. Первый запуск: системный диалог уведомлений → «Allow». Приём: «Нет устройства», статус
   «ожидание USB SDR». Synthetic не выбирается автоматически, и это правильно.
2. Выпадающий список устройств (tap 320 200) → `Synthetic signal generator` → статус «приём остановлен».
3. «Старт» (tap 80 200) → кнопка становится «Стоп», статус `2.40 MS/s · audio drops 0`.
   Спектр живой: несущие около 99.4 / 99.7 / 100.5 / 100.7 МГц, широкополосный горб около
   100.1–100.3 МГц. Водопад пополняется: два снимка с интервалом 3 с отличаются.
4. Шаг ▶ ×2 (tap 644 858) → 100.025 МГц. Режим NFM (tap 250 485) → `NFM · BW 12.5k`.
   Прокрутка вниз, на клавиатуре `1 0 0 . 7 OK` → 100.700 МГц. После прокрутки вверх несущая
   100.7 стоит под центральным маркером, ось 100–101.5M: центрирование работает.
5. Вкладки «Пресеты» (9 сохранено · один приёмный канал; фильтры Все/FM/AIR/VHF/MAR/UHF)
   и «Настройки» (устройство Synthetic, частота выборки 2.40 МГц, AGC, усиление RF, громкость)
   открываются. `uiautomator dump` на «Настройках» отвечает `could not get idle state`, поэтому
   там только скриншот.
6. «Приём» → «Стоп»: кнопка снова «Старт», статус «приём остановлен». Два снимка через 3 с идентичны:
   водопад остановлен.
7. Повторный цикл `stop/start/wait/install` через скрипт: частота/режим сохранились
   (`install -r`), Synthetic → Старт → AM (`AM · BW 10.0k`), спектр/водопад живые, Стоп.
   В `emulator-logcat.txt` исключений нет.

Скриншоты: `~/prj/docs/screens/emulator-synthetic-{wfm-100M,nfm-100.7M,am-100.7M}.png`.
Звук эмулятор не проверяет: он запущен с `-no-audio`, в приложении звук выключен.

## Известные проблемы эмулятора

- **Крэш при холодном старте (только эмулятор).** Периодически на старте падает с SIGSEGV в потоке
  `1.raster`. Символизированный стек (`symbols.zip` движка `af7e796e…` для android-x64,
  `llvm-symbolizer` из NDK): `impeller/renderer/backend/gles/blit_command_gles.cc:209`, путь
  `GPUSurfaceGLImpeller` → `AiksContext` → `ContentContext` → `BlitPass::EncodeCommands`. Падает
  инициализация Impeller (OpenGLES) на программном GLES эмулятора, до отрисовки кадров
  приложения; к коду приложения это не относится. Частота плавает: в серии сразу после загрузки
  было 7/8, позже 1/6 и 0/26. Минимальный `flutter create` при этом 0/10, так что уверенно
  разделить «приложение/движок» не удалось. `--ez enable-impeller false` на intent не помогает
  (Impeller остаётся включён). `tool/emulator.sh launch` ловит `Fatal signal` в logcat и делает
  один повторный запуск. Tombstones: `adb -s emulator-5554 root; adb -s emulator-5554 shell ls /data/tombstones`.
  На телефоне (arm64, свой GPU-драйвер) это отдельно не исследовалось; в предыдущих QA-сессиях
  такой крэш не фиксировали. Если появится там — это отдельная задача.
- `-gpu swangle` и `-gpu lavapipe` на этой ВМ: qemu молча завершается на первом кадре приложения.
  `-gpu swiftshader` работает так же, как `swiftshader_indirect` (по умолчанию).
- `uiautomator dump` не работает на постоянно анимированных экранах (`could not get idle state`).
