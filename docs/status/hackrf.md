# STATUS — worker `hackrf` (branch `wip/hackrf`)

Dart port of the libhackrf RX subset over `UsbDeviceHandle` + int8→float converter,
checked with a host C oracle (real `hackrf.c` + fake libusb, trace diff).

## Done
- `lib/drivers/hackrf/hackrf.dart`: port of `~/prj/ref/hackrf/host/libhackrf/src/hackrf.c`
  @ 7f96cc8. The file header maps each function to its C line range.
  - Constants: `hackrf_error`, board ids/platforms, usb board ids, `rf_path_filter`, vendor requests,
    `TRANSFER_COUNT=4`, `TRANSFER_BUFFER_SIZE=262144`, `max2837_ft`.
  - Open: `hackrfOpenSetup(UsbDeviceHandle)` ≙ `hackrf_open_setup`. Steps: GET_CONFIGURATION → set config 1
    if it differs → claim interface 0 → `usb_api_version = bcdDevice` → GET_BUFFER_SIZE if API ≥ 0x0112.
  - `HackrfDevice` methods: `setTransceiverMode`, `setFreq`, `setFreqExplicit`, `setSampleRate`
    (IEEE-754 divider search via `ByteData`, 1:1 including the C `int` shift semantics),
    `setSampleRateManual` (+ auto BB filter), `setBasebandFilterBandwidth`, `setLnaGain`, `setVgaGain`
    (IN requests: 1-byte retval, 0 = invalid), `setAmpEnable`, `setAntennaEnable` (bias-T),
    `boardIdRead`, `versionStringRead`, `boardPartidSerialnoRead`, `usbApiVersionRead`, `boardRevRead`,
    `isStreaming`, `startRx`/`stopRx`/`close` (async), `getTransferBufferSize`/`QueueDepth`.
  - Free functions: `hackrfComputeBasebandFilterBw(_RoundDownLt)`, `hackrfErrorName` (with libusb strerror),
    `hackrfBoardIdName`, `hackrfBoardIdPlatform`, `hackrfUsbBoardIdName`, `hackrfFilterPathName`,
    `hackrfInit`/`hackrfExit`, `hackrfIsHackrfUsbId`.
  - Streaming: `openBulkIn(0x81, numBuffers: 4, bufferLength: 262144)`. Semantics of
    `hackrf_libusb_transfer_callback` are kept: the callback returns nonzero or the transfer fails →
    `streaming = false`, and no further callbacks happen. Every block is `release()`d after the callback.
    The callback gets a `HackrfTransfer` (`address`, `validLength`, `buffer`/`bufferInt8` views on native memory).
- `lib/drivers/hackrf/hackrf_convert.dart`: `hackrfConvertS8ToF32` (256-entry LUT fast path) and a reference
  `volk8iS32fConvert32f`. The two are bit-identical (scale 1/128 is exact). AOT x86 host throughput:
  LUT ≈ 2.1 GB/s, multiply ≈ 1.4 GB/s. The 20 MSPS requirement is 40 MB/s.
- Oracle `tool/oracle/hackrf/`:
  - `fake_libusb/{libusb.h,fake_libusb.c,fake_libusb.h}`: records CTRL / SET_CONFIGURATION / CLAIM / RELEASE /
    CLOSE / SUBMIT / CANCEL and serves scripted IN responses (board id 2, version string, part/serial,
    gain retvals with VGA 62 → 0, GET_BUFFER_SIZE, bcdDevice). Failures can be injected (`fail_req`, `short_req`).
  - `hackrf_oracle.c`: 5 scenarios.
    - `main`: open, reads, SR 2M/8M/20M/10.123456M + auto BB filter, freq 100M/433.92M/2.4G, freq_explicit
      (ok + invalid), LNA 16/39/41, VGA 20/21/62/63, amp on/off, bias on/off, start_rx/stop_rx/again,
      start_rx → close.
    - `oldfw`: API 0x0100, config already 1, Jawbreaker.
    - `errors`: pipe error, short write.
    - `openfail`: GET_BUFFER_SIZE fails.
    - `rates`: 24 sample rates including fractional ones, 22 BB-filter edge cases, all error/board names.
  - `build.sh` builds with gcc and regenerates `golden/*.trace` plus `golden/HACKRF_REV`. The goldens are committed.
- Tests in `test/drivers/hackrf/`:
  - `recording_usb_handle.dart`: own recording fake of `UsbDeviceHandle` + `FakeBulkInStream`.
  - `hackrf_oracle_test.dart`: Dart scenarios, identical to the C ones, must match the golden traces exactly.
    If gcc and `~/prj/ref/hackrf` are present, the test also rebuilds the oracle, re-runs C, and checks
    golden == fresh C == Dart.
  - `hackrf_test.dart`: streaming (endpoint/count/size, callback data + rxCtx, release, stop on nonzero,
    error → stopped, BUSY on double start, restart), closed-device behaviour, API version gating,
    fraction search, `hackrfExit`.
  - `hackrf_convert_test.dart`: LUT for all 256 values; bit-identical to the volk reference on 256 KiB of
    random data; partial `validLength`; range checks.

## Tests
```
source ~/prj/env.sh
flutter test test/drivers/hackrf/        # 00:00 +24: All tests passed!
flutter analyze lib/drivers/hackrf test/drivers/hackrf   # No issues found!
tool/oracle/hackrf/build.sh              # rebuild oracle + goldens (libhackrf 7f96cc8)
```
Mutation check: changing the LNA mask `~0x07` → `~0x03` fails the trace diff at line 58 (`wIndex 0020` vs `0024`).

## Deviations from C (forced by the contract; documented in the file header)
- There is no enumeration or `hackrf_open_by_serial`. The device is opened on a ready `UsbDeviceHandle` (Android fd).
- `libusb_get_configuration` is issued as the standard GET_CONFIGURATION request (0x80/0x08). The fake libusb in
  the oracle does the same, so the traces match.
- `detach_kernel_drivers` is a no-op, equivalent to libusb on Android returning NOT_SUPPORTED.
- The libusb event thread is replaced by `openBulkIn`, so `startRx`/`stopRx`/`close` return `Future<int>`.
- Once `streaming` drops to false, the driver still returns the slot to the reader, but no more data is
  delivered to the callback. In C the transfer is simply not resubmitted.
- TX, sweep, operacake, SPI flash, CPLD, FPGA and the si5351/max283x/rffc5071 register access are not ported
  (outside the RX subset).

## Remaining / for the integrator
- The SDR++ `hackrf_source` module (not my scope) should call, in order: `setSampleRate` →
  `setBasebandFilterBandwidth(bw or hackrfComputeBasebandFilterBw(sr))` → `setFreq` → `setAntennaEnable` →
  `setAmpEnable` → `setLnaGain` → `setVgaGain` → `startRx(cb)`. In the callback:
  `hackrfConvertS8ToF32(t.buffer, t.validLength, out)`, which returns the number of samples. Stop with `close()`.
- The callback runs on the isolate that called `startRx` (the `blocks` stream). The buffer is valid only
  during the callback.
- Not tested on real hardware or against the real usbfs transport (that worker is writing it in parallel).

## Questions about the contract
- None blocking. It would help to add `int getConfiguration()` to `UsbDeviceHandle`. For now the driver uses
  a control request, which behaves the same on usbfs.
