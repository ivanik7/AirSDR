# Android-эмулятор для UI/synthetic smoke (debian-ai)

Эмулятор не заменяет SM-F936B с RTL-SDR Blog V4: здесь проверяются только Android-старт приложения, интерфейс, перестройка, DSP на синтетических IQ и отображение спектра/водопада. USB OTG/usbfs, эфир, слышимость/качество звука, производительность и Samsung-specific поведение проверять на физическом телефоне перед приёмкой hardware-dependent изменений. Телефон для этой процедуры не нужен и трогать его нельзя.

## Установка и доступ к KVM

```sh
source ~/prj/env.sh
sdkmanager 'emulator' 'system-images;android-35;default;x86_64'
avdmanager create avd --name sdr_api35 --package 'system-images;android-35;default;x86_64' --device pixel_4a
~/sdk/android/emulator/emulator -accel-check
```

На debian-ai образ и AVD уже установлены: Android 15/API 35, x86_64, Pixel 4a, `~/.android/avd/sdr_api35.avd`. В локальном `config.ini` настроено 720×1560 @320 dpi (360×780 dp), 2 GiB RAM и 4 GiB data. SDK/AVD остаются вне git. На этой ВМ есть `/dev/kvm` (`root:kvm`, `0660`), CPU поддерживает AMD-V, но пользователь `$USER` пока не состоит в группе `kvm`. Эмулятор с `-accel on` не запустится без исправления прав. Администратор должен выполнить `sudo gpasswd -a $USER kvm`, затем начать новую login-сессию для `$USER` (или запустить команды через `sg kvm -c '...'` после вступления в группу). Повторить `id` и `~/sdk/android/emulator/emulator -accel-check`: ожидать доступного KVM, а не заменять его программной эмуляцией. Автоматическое изменение группы в headless-запуске Hermes отклонено политикой подтверждения команд; smoke ниже остаётся НЕ ПРОВЕРЕН до исправления прав.

## Цикл разработки (после появления KVM)

В отдельном терминале (без GUI; `-no-snapshot` не оставляет тяжёлые quickboot-снимки):

```sh
source ~/prj/env.sh
~/sdk/android/emulator/emulator -avd sdr_api35 -port 5554 -no-window -no-audio -no-snapshot -gpu swiftshader_indirect -accel on
```

В другом терминале из каталога репозитория (серийный номер всегда указывать явно, чтобы не затронуть телефон):

```sh
source ~/prj/env.sh
adb -s emulator-5554 wait-for-device
adb -s emulator-5554 shell getprop sys.boot_completed  # ждать значения 1
adb devices -l
flutter run -d emulator-5554
```

Альтернатива `flutter run`: `flutter build apk --debug && adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-debug.apk && adb -s emulator-5554 shell am start -n net.ivanik.sdr_flutter/.MainActivity`. Debug APK содержит x86_64; release — только arm64-v8a, его сюда не ставить. Установка с `-r` сохраняет данные приложения. Последовательность smoke: вкладка «Приём» → в списке устройств выбрать `Synthetic signal generator` (не USB) → «Старт» → дождаться меняющегося спектра и новых строк водопада → изменить частоту цифровыми клавишами/шагом и режим демодуляции → вкладки «Пресеты» и «Настройки» → вернуться, «Стоп» → убедиться, что приём остановлен. Фиксировать фактические наблюдения, а не считать наличие экранов доказательством сигнала.

```sh
adb -s emulator-5554 logcat -d -v time -s flutter AndroidRuntime > emulator-logcat.txt
adb -s emulator-5554 exec-out screencap -p > emulator-receive.png
adb -s emulator-5554 shell uiautomator dump /sdcard/window.xml
adb -s emulator-5554 pull /sdcard/window.xml ./emulator-window.xml
adb -s emulator-5554 emu kill
```

Скриншот/логи сохранять в рабочем каталоге или в `~/prj/docs/screens/`, большие артефакты не коммитить. Если используется порт, отличный от 5554, заменить serial во ВСЕХ командах после проверки `adb devices -l`. Не оставлять эмулятор включённым между сессиями (ВМ имеет 11 GiB RAM). `flutter analyze`, `flutter test` и `flutter build apk --debug` — отдельные гейты: эмулятор не подменяет их.
