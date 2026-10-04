# ADR — N0 C ABI и владение нативным движком

Статус: принят для N0; раздел «Следующие этапы» — проектный контракт, **не реализованный API**.
Исторический документ N0: текущая частичная ABI 2 и ограничения N1 — `docs/native-n1-status.md`
и `native/include/sdrcore.h`; описанная ниже версия 1 относится только к N0.
For the integrated N1 ABI 2 contract, use `docs/native-n1-adr.md` and the public header;
the N0 version-1 table below is retained as historical context.
For the N2 ABI 3 radio contract, use `docs/native-n2-adr.md` and
`native/include/sdrcore_v3.h`. Since the N2 integration `sdr_version()` returns 3
and exports the `sdr_v3_*` symbols; ABI 2 symbols are unchanged.
Основание: `~/prj/docs/40-native-core-plan.md` (§ «Целевая схема», N0–N5),
`native/include/sdrcore.h`. При конфликте с прежним Dart-only описанием в
`~/prj/docs/10-architecture.md` приоритет у `AGENTS.md` и плана 40.

## Решение и граница N0

`native/` — общий C++17/CMake для Linux host и Android (`externalNativeBuild`,
`libsdrcore.so`). Единственная публичная бинарная граница — C ABI из
`native/include/sdrcore.h`; C++ классы и исключения её не пересекают.
N0 содержит **только инертный handle**: создание не открывает USB, не запускает
DSP, звук или поток приёма. Ни FFI-обёртка, ни нативный каркас не являются
заменой рабочего Dart-приёмника. UI и данные пользователя остаются на прежнем
пути до паритета на телефоне. `RadioController` (`lib/ui/radio_controller.dart`)
остаётся UI-контрактом при будущем переключении реализации.

Действующие экспортируемые функции (C linkage, `SDRCORE_API`):

| Сигнатура | Контракт N0 |
|---|---|
| `uint32_t sdr_version(void)` | Возвращает `1` — ревизию C ABI, а не версию приложения/SDR++ и не признак готового приёма. Не требует handle. |
| `SdrHandle* sdr_create(void)` | Создаёт новый непрозрачный инертный объект; `NULL` только при ошибке выделения памяти. Каждый успешный вызов передаёт вызывающему эксклюзивное владение отдельным handle. |
| `void sdr_destroy(SdrHandle* handle)` | Освобождает один ранее созданный handle; `NULL` допустим и ничего не делает. Для ненулевого указателя вызывается ровно один раз. |

N0 не возвращает диагностическую строку или код ошибки: отсутствие памяти
отличается по `NULL`; `sdr_version` не может сообщить ошибку; `sdr_destroy`
не возвращает результат. Передача чужого, уже освобождённого указателя или
двойное освобождение — нарушение контракта (не механизм идемпотентного stop).
После `destroy` запрещены все обращения к handle. Повторное создание допустимо.
Dart FFI обязан проверять версию **до** использования символов/handle, проверять
`NULL` после create и освобождать каждый успешный handle один раз (явный
`dispose` с защитой от повторного вызова); не полагаться исключительно на GC.
В N0 нет параллельных вызовов с одним handle: его создание и освобождение
сериализует владелец. Нет обещаний о потокобезопасности будущих операций.

Версия — целое число ревизии контракта: `1` сейчас. При расширении сначала
обновляются этот ADR и заголовок, затем реализация и биндинги/тесты.
Существующие символы и их значения/семантика не меняются молча; при
несовместимости повышается ревизия и биндинг отказывает до создания handle,
а не пробует работать с неизвестной ABI. Новые возможности не выводятся из
номера версии без проверки соответствующего контракта и наличия символов;
N0-клиент использует только три существующих символа. Номер версии не
означает поддержку команд, событий или устройств.

## Владение процессом и потоками — целевая модель (не реализована в N0)

Движок должен быть объектом **процесса приложения**, не `FlutterActivity` и не
Dart-изолята. Android `ReceptionService` отвечает за foreground-режим,
уведомление и wakelock; process-scoped владелец (например, компонент
`Application`, доступный Service) хранит единственный нативный handle и
сериализует команды. Activity/Flutter UI лишь подключается и отключается,
не создавая второй приёмник при пересоздании экрана. Service управляет
продолжением/остановкой приёма в фоне, но существующую реализацию
`ReceptionService` с Dart engine не заменять в N0. Уход UI не равен stop;
`onDestroy` Activity не освобождает работающий движок. Смерть Android-процесса
закрывает native ресурсы; автоматического возобновления без разрешений и
явной проверки foreground-ограничений не предусматривать. Не запускать
приём до успешного foreground-start; отказ запуска и запрос Stop обязаны
приводить к остановке, а не к невидимой работе.

Один активный аппаратный источник, один VFO и один аудиопоток. Владение USB fd
и его дублирование/закрытие между Kotlin и C++ нужно зафиксировать отдельно
перед N1: не сохранять fd, жизненный цикл которого принадлежит Activity;
при потере USB разрешения/detach останавливать поток и возвращать ошибку.
Нативный движок владеет USB-reader, DSP и аудиопотоками. Их порядок завершения:
отменить входящие операции → остановить чтение/декодеры/DSP и аудио → дождаться
потоков → освободить их буферы и fd → освободить handle. `destroy` работающего
движка после N0 должен либо синхронно завершить все потоки до возврата,
либо требовать отдельного подтверждённого stop; выбор закрепить при
расширении ABI, прежде чем реализовывать. Не допускать callback после
освобождения handle или переиспользования его адреса.

## Следующие этапы: проектный контракт команд и событий

Ниже граница для N1–N3, **не набор экспортируемых сегодня функций**.
Не добавлять в Dart вызовов, которые отсутствуют в `sdrcore.h`.

- Команды управления идут UI → `RadioController` → FFI → нативный владелец:
  выбор источника, start/stop, перестройка частоты, режим/полоса, усиление,
  шумоподавитель и громкость. Требуются явные единицы (Hz, dB), типы фиксированной
  ширины, размер/ревизия структур и проверка диапазонов; один сериализованный
  поток команд на handle. Результат должен отличать `OK`, неверный аргумент,
  неверное состояние, несовместимую ABI, ошибку USB/разрешений/устройства,
  внутреннюю ошибку и неподдерживаемую функцию. Ошибка команды не выдаётся
  за успешную смену состояния в UI. События подтверждают асинхронные переходы
  start/stop и ошибки потока. Точные C-сигнатуры, коды и формат параметров
  фиксируются новым ADR/версией заголовка **до** параллельной реализации.
- Нативные события → UI: состояние, статистика/drops, декодированные
  сообщения/изображения и децимированные до ширины UI строки FFT. Для доставки
  допускается `Dart_PostCObject` (`dart_api_dl`) на актуальный `NativePort`
  или ограниченный кольцевой буфер с явным чтением. Нельзя хранить Dart port
  как бессрочную зависимость: attach/detach при пересоздании isolate,
  закрытии UI и ошибке постинга, с безопасным продолжением приёма без UI.
  События несут тип, длину, временную метку/последовательность и поколение
  handle, чтобы отбрасывать устаревшие события. Очередь ограничена;
  FFT/статистика могут терять старые кадры при перегрузке, ошибки и финальное
  состояние не должны тихо исчезать. Политику переполнения и формат
  сериализации фиксировать до ввода конкретного event API.
- Буферы IQ и аудиосэмплов **никогда не передавать через Dart** (в том числе
  в сообщениях isolate/`NativePort` и в callback FFI). Их память принадлежит
  нативным ступеням графа: производитель передаёт владение слотом следующему
  потребителю, возвращение в пул — только после окончания обработки; остановка
  дожидается всех занятых слотов. Для UI допустимы только небольшие
  самодостаточные события и подготовленные FFT-строки: при передаче копией
  получатель владеет своей копией, при чтении из кольца память принадлежит
  native до подтверждения чтения. Ни одна сторона не удерживает указатель на
  чужой временный буфер после завершения вызова. Формат кадра/изображения и
  освобождение памяти должны быть задокументированы в конкретном ABI.
- Декодеры (после N0) получают audio/baseband/raw IQ **внутри native графа**;
  наружу отдают только результаты. Широкополосные режимы с захватом всего
  тюнера взаимоисключают обычный приём, а не создают второй канал. Источники
  и лицензии — план 40 и `~/prj/docs/30-openwebrx-decoders-plan.md`.

## Проверка границы

Для N0: C test `native/tests/abi_test.c` проверяет ревизию, разные handle,
`destroy(NULL)` и повторное создание; host CMake/CTest и включение .so в APK
проверяются отдельно. FFI-вызов из Dart — отдельная downstream-задача.
Ни тест N0, ни сборка APK не подтверждают USB, DSP, звук, фон на устройстве
или слышимость: это отдельные гейты N1/N2 и аппаратная QA.

## N5 addendum: RTL-SDR tuner gain-list query (`sdr_v3_rtl_tuner_gains`)

Added for the N5 transition, after the Dart receive path (including
`RtlSdrSourceModule`/`RtlSdrDev.getTunerGains()`) was deleted. This is a pure
ABI-3 addition: `sdr_version()` stays 3, every existing `sdr_v3_*` signature
and struct layout is unchanged, and this symbol is additive-only in
`native/include/sdrcore_v3.h`.

```c
int32_t sdr_v3_rtl_tuner_gains(SdrHandle* handle, int32_t* gains,
                                 uint32_t capacity, uint32_t* count);
```

Contract (see the header comment for the authoritative text):

- Returns the RTL-SDR tuner's supported gain values in tenths of a dB,
  **sorted ascending**, through the handle's already-open `usb_adapter`
  (`RtlSdrAdapter::get_tuner_gains`, `native/src/usb_rtlsdr_adapter.cpp`).
  No second USB claim is ever made; the call only queries the existing
  rtlsdr device handle created by `sdr_v2_open_usb`/`sdr_host_open_usb`.
- This is an **exact migration** of the deleted Dart gain path: the old
  `rtl_sdr_source.dart` called `RtlSdrDev.getTunerGains()..sort()` and then
  indexed the sorted list by `gainId` to build its gain stepper UI. The
  native implementation calls librtlsdr's `rtlsdr_get_tuner_gains()` (which
  is not guaranteed sorted for every tuner table) and explicitly sorts
  ascending before returning, so a client reproducing the old
  `gainList[gainId]` index lookup gets byte-for-byte the same table and
  order as before deletion.
- `capacity == 0` with `gains == NULL` is a valid count-only probe: `count`
  receives the required capacity and the call returns `SDR_OK` without
  touching `gains`, regardless of how many gain steps exist (including 0,
  e.g. tuners with no adjustable gain such as FC2580).
- A nonzero but insufficient `capacity` returns `SDR_V3_BUFFER_SMALL`;
  `count` still reports the required capacity, and `gains` is left
  completely unmodified (verified by filling it with a sentinel before the
  call in both the white-box and real-hardware tests).
- A non-RTL-SDR source (file, synthetic, HackRF) or a handle without a USB
  claim returns `SDR_UNSUPPORTED` with `count = 0`. `IDLE` (never opened)
  returns `SDR_INVALID_STATE`. `NULL` handle or `NULL` `count`, or a nonzero
  `capacity` with a `NULL` `gains` pointer, returns `SDR_INVALID_ARGUMENT`.
- Thread-safe and serialized with the rest of the v3 control lifecycle: the
  implementation takes the handle's existing `mutex`, the same lock guarding
  `set_controls`/`start`/`stop`/`close`/`snapshot`; callers must still
  serialize this call with other commands on the handle per the existing v3
  ADR (`docs/native-n2-adr.md`), and it never races `destroy`.
- Internal seam: `UsbRxAdapter::get_tuner_gains` (`native/src/usb_adapter.h`)
  gained a virtual method with a default implementation (`SDR_UNSUPPORTED`,
  `count = 0`) so `HackRfAdapter` and any future adapter need no change
  unless they expose a real discoverable gain table.

Verification (host, `native/tests/`, wired into CMake/CTest):

- `rtl_gain_list_test.cpp` — white-box (includes `sdrcore.cpp` directly, no
  real USB device): full query against a deliberately **unsorted** fake
  gain table proves the sort is actually applied (not just a pre-sorted
  fixture passing by accident); count-only probe; `BUFFER_SMALL` with array
  non-modification; exact-capacity boundary; empty gain table is `SDR_OK`
  with `count=0` (not `SDR_UNSUPPORTED`); non-RTL source (synthetic/file) is
  `SDR_UNSUPPORTED`; an adapter that does not override the method falls back
  to the `UsbRxAdapter` default; `IDLE` handle is `SDR_INVALID_STATE`; `NULL`
  argument combinations are rejected; three threads concurrently querying a
  running handle all observe the identical sorted table.
- `host_rtl_gain_test.c` — real-hardware (opt-in by presence, SKIP+exit 0
  without attached hardware): opens the attached RTL-SDR Blog V4 through
  `sdr_host_open_usb`, confirms a second handle cannot claim the same
  bus/address while the first owns it (no second USB claim), then exercises
  the count-only probe, `BUFFER_SMALL`, exact and over-sized capacity, and
  ascending order against the real `rtlsdr_get_tuner_gains()` table, both in
  `OPEN` and while a v2 diagnostic stream is `RUNNING`.
- Both pass in this worktree's `native/tests/run_host_tests.sh` run,
  including against the physical Blog V4 on `debian-ai`: the R828D tuner
  reports 29 gain steps, ascending from 0 to 496 tenths dB (0.0–49.6 dB),
  matching librtlsdr's `r82xx_gains` table.

The N5 Dart FFI binding (`FfiNativeRadioApi.rtlTunerGains`) probes and copies
this list after USB open. `NativeRadioSettings` retains the legacy index and
device name until a serial-matched dongle opens; the controller selects that
exact sorted entry before the first start and writes the dB gain only after
successful start. Invalid index, missing serial or failed query leave the
index pending and use default gain. A manual gain adjustment replaces it.
