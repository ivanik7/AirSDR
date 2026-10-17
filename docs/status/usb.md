# STATUS-usb — Android USB layer (worker `usb`, branch `wip/usb`)

## Сделано
| Файл | Что |
|---|---|
| `lib/usb/usbfs_abi.dart` | `_IOC` кодирование, `USBDEVFS_*` номера (через `sizeOf<>` структур), `struct usbdevfs_ctrltransfer/_bulktransfer/_urb` (dart:ffi `Struct`), `USBFS_CAP_*`, URB флаги/типы, errno. `usbfsAbiSupported` (только 64-bit). |
| `lib/usb/usbfs_sys.dart` | libc `ioctl` (VarArgs), `lseek`+`read`, errno (`__errno_location` glibc / `__errno` bionic) из `DynamicLibrary.process()`. Интерфейс `UsbfsSys` (возвращает `-errno`), чтобы гонять транспорт на фейковом ядре. |
| `lib/usb/usbfs_transport.dart` | `UsbfsDeviceHandle implements UsbDeviceHandle` поверх fd (порт `linux_usbfs.c`: `op_wrap_sys_device/initialize_device/initialize_handle`, `op_set_configuration`, `claim/release_interface`, `op_clear_halt`, `op_reset_device` с re-claim). GET_CAPABILITIES (ENOTTY→fallback `CAP_BULK_CONTINUATION` как libusb; ENODEV→noDevice). Дескриптор устройства: `lseek(0)+read()` из fd как libusb, fallback GET_DESCRIPTOR(DEVICE) по EP0. Sync CONTROL/BULK ioctl (bulk режется на 16 KiB без `CAP_NO_PACKET_SIZE_LIM`). Маппинг errno→`UsbError`. fd не закрывает (владелец — Kotlin). Не-64-bit → `UsbException(notSupported)`. |
| `lib/usb/usbfs_bulk_stream.dart` | `UsbfsBulkInStream`: reader-изолят, N URB + (N+spare) слотов `malloc`, блокирующий REAPURB, передача `(slot<<32)|len` через SendPort, возврат слотов `release()`→SendPort; нет свободного слота → дроп + счётчик (в общей нативной памяти), URB тут же ресубмитится. `cancel()`: stop-флаг + DISCARDURB всех URB из потребляющего изолята (повтор каждые 50 мс до выхода reader'а), reader дренирует (reap) все URB, потом память освобождается. ENODEV/ESHUTDOWN (статус URB, REAPURB, SUBMITURB) → ошибка стрима `UsbException(noDevice)` и закрытие. EPIPE/EOVERFLOW/EPROTO… → URB «уходит на пенсию» (как `_libusb_callback`: ресубмит только COMPLETED); когда все ушли — ошибка pipe/overflow/io. Параметр `spareBulkSlots` у `UsbfsDeviceHandle.wrap` (по умолчанию = numBuffers). |
| `lib/usb/usb_descriptors.dart` | `parseDeviceDescriptor`, порт `libusb_get_string_descriptor_ascii` (langid из индекса 0, не-ASCII → '?'). |
| `lib/usb/mock_transport.dart` | `MockUsbDeviceHandle`: trace всех вызовов (`UsbTraceEntry`: type/req/value/index/wLength/data; стабильный текстовый формат `C 40 00 2000 0110 0002 0102` для diff с C-оракулом), IN-ответы через колбэк `onControlIn(req, resp)`, `onControlOut`, `onBulk`, строки, `unplug()`. `MockBulkInStream`: `push/pushAll/end/addError`, данные копируются в malloc-слоты (тот же контракт `UsbBlock`), дроп при занятых слотах. |
| `lib/usb/android_usb.dart` | Обёртка каналов: `listDevices`, `open`→`{fd,vid,pid}` (PlatformException→`UsbException`), `close`, `hasPermission`, `initialDevice`, `events` (attached/detached). |
| `android/.../UsbSdrPlugin.kt` | FlutterPlugin+ActivityAware: `sdr/usb` (listDevices/open/close/hasPermission/initialDevice), `sdr/usb/events`. Permission: `PendingIntent.getBroadcast(Intent(ACTION).setPackage(pkg), FLAG_MUTABLE on S+)`, receiver через `ContextCompat.registerReceiver(..., RECEIVER_NOT_EXPORTED)` (permission + ATTACHED + DETACHED). Несколько одновременных open() одного устройства ждут один диалог. `UsbDeviceConnection` хранятся в map до close()/detach. `USB_DEVICE_ATTACHED` при запуске и через `onNewIntent` → `initialDevice` + событие attached. Serial через try/catch SecurityException. |
| `MainActivity.kt` | регистрирует `UsbSdrPlugin` в `configureFlutterEngine`. |
| `AndroidManifest.xml` | `uses-feature usb.host required=false`, intent-filter `USB_DEVICE_ATTACHED` + meta-data `@xml/device_filter`. |
| `res/xml/device_filter.xml` | 42 RTL из `known_devices[]` (сгенерировано из librtlsdr.c) + HackRF One/Jawbreaker/rad1o + Airspy R2/Mini + Airspy HF+ = 47, десятичные ID. |
| `tool/usbfs_abi_oracle.c` | C-оракул номеров ioctl/оффсетов (тест собирает его gcc). |

## Тесты
`source ~/prj/env.sh && flutter test test/usb` → **All tests passed** (45 тестов):
- `usbfs_abi_test.dart` — номера ioctl, размеры/оффсеты полей (пробой нативной памяти), сверка с gcc-оракулом `<linux/usbdevice_fs.h>`.
- `usbfs_sys_test.dart` — **реальный libc**: VarArgs ioctl на /dev/null → -ENOTTY, bad fd → -EBADF, чтение дескрипторов root hub `/dev/bus/usb/001/001` (vid 1d6b).
- `usbfs_transport_test.dart` — на `FakeUsbfsKernel` (декодирует настоящие ioctl/структуры): wrap/caps/дескриптор/fallback EP0, control IN/OUT, errno-маппинг, bulk split 16 KiB, cfg/claim/release/halt, reset с re-claim, string descriptors.
- `usbfs_bulk_stream_test.dart` — настоящий reader-изолят + URB в нативной памяти: порядок блоков, непрерывность данных, дропы = пропуски, нет дропов при успевающем потребителе, ENODEV (reap) → noDevice, -ESHUTDOWN → noDevice, -EPIPE на всех → pipe, короткие URB, cancel идемпотентен и реапит все URB, close() отменяет стримы. Прогнан 3× подряд — стабильно.
- `mock_transport_test.dart`, `android_usb_test.dart` (моки каналов + device_filter ⊇ known_devices[] из librtlsdr.c).

`flutter analyze lib/usb test/usb` → 0 errors/warnings (1 info в контрактном `usb_transport.dart:74` — `Pointer<Uint8>` в doc-комментарии; файл не мой).

Kotlin: `cd android && ./gradlew --offline --no-daemon :app:compileDebugKotlin` → **BUILD SUCCESSFUL** (0 ошибок/предупреждений в UsbSdrPlugin.kt). `gradlew` + `gradle-wrapper.jar` в worktree нет (gitignore) — скопированы локально из `~/prj/sdr_flutter/android`, не закоммичены.

## Не сделано / ограничения
- Не проверено на реальном телефоне/донгле (нет железа). Интеграция с dummy_hcd не делалась (не требовалась).
- armv7 (32-bit) не поддержан: `wrap()` бросает `notSupported`. Структуры объявлены через dart:ffi, так что для 32-bit layout бы пересчитался сам, но не тестировался.
- Ядра без `USBFS_CAP_NO_PACKET_SIZE_LIM` (< 3.3): sync bulk режется на 16 KiB; стриминг с буфером > 16 KiB → `notSupported` (libusb бы делил на несколько URB с BULK_CONTINUATION).
- Нет таймаута на URB стриминга (как usbfs: у URB нет таймаута; librtlsdr BULK_TIMEOUT=0 тоже).
- errno читается сразу после FFI-вызова (не-leaf); теоретически VM может затереть errno при safepoint-переходе — на практике не наблюдается (тест ENOTTY/EBADF проходит).
- Foreground service (`mediaPlayback`) из docs/04 §8 не добавлен — не в рамках задачи.

## Вопросы к контракту (`usb_transport.dart` не менял)
1. Нет способа задать число запасных слотов пула в `openBulkIn` — сделано параметром `spareBulkSlots` в `UsbfsDeviceHandle.wrap` / `MockUsbDeviceHandle`. Возможно, стоит добавить в контракт `{int spareBuffers}`.
2. `UsbBlock.address` валиден только до `cancel()`; после `cancel()` `release()` игнорируется — стоит зафиксировать в doc-комментарии.
3. Doc-комментарий `usb_transport.dart:74` даёт lint info (угловые скобки) — поправить обратными кавычками.
