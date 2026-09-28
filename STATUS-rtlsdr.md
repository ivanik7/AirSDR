# STATUS — worker `rtlsdr` (branch `wip/rtlsdr`)

This is a Dart port of librtlsdr: the RTL2832U core plus the R820T/R828D tuners, including RTL-SDR Blog V4 and V4 Lite. It runs over the `UsbDeviceHandle` contract. A host C oracle checks the port by diffing traces.

## Source that was ported
- **Upstream:** osmocom rtl-sdr **v2.0.3** (`~/prj/ref/rtl-sdr`, commit 797f814).
  - SDR++ CI builds its macOS/Linux jobs against osmocom master, and the Windows job uses the osmocom 2024-06 binaries. This is the same code line.
- **Blog V4 / V4L support** is already in osmocom 2.0.3, and it is ported:
  - R828D detection with `"RTLSDRBlog"`/`"Blog V4"` and a 28.8 MHz tuner xtal;
  - HF upconversion by +28.8 MHz;
  - notch control through reg 0x17 `open_d`;
  - HF/VHF/UHF input switching through regs 0x05/0x06 and GPIO5;
  - HF tracking-filter bypass through 0x1a/0x1b;
  - `vco_power_ref` on V4L.
- **rtlsdrblog fork:** cloned to `~/.hermes/cache/scratch/rtl-sdr-blog` (aed0ea1) for comparison only. Its extra hacks are **not** ported, because SDR++ does not use that fork:
  - auto direct-sampling below 24 MHz on R820T;
  - forced bias-T from an EEPROM bit;
  - the "offset tuning" button switching the bias-T;
  - max VCO current, a different PLL SDM calculator, `filt_gain` 0x30 and `loop_through` 0x80.

## Done
| File | What it contains |
|---|---|
| `lib/drivers/rtlsdr/librtlsdr.dart` | `RtlSdrDev` (≈ `struct rtlsdr_dev`) with all public API methods in camelCase: `open(UsbDeviceHandle)` without libusb enumeration, `close`, xtal/ppm, usb strings, EEPROM read/write, center freq, gains/gain mode/IF gain, `get_tuner_gains`, bandwidth, sample rate, testmode, AGC, direct sampling, offset tuning, bias tee / bias tee GPIO, `reset_buffer`, `read_sync`, and `readAsync`/`waitAsync`/`cancelAsync`. Also demod/block register access, I2C repeater, GPIO, FIR, baseband init/deinit, the `known_devices` table and the tuner iface table. |
| `lib/drivers/rtlsdr/tuner_r82xx.dart` | Full `tuner_r82xx.c`: shadow regs, chunked I2C writes, bitrev reads, `set_mux`, `set_pll`, `sysfreq_sel`, `set_tv_standard` + filter calibration, `set_gain`, `set_bandwidth`, `set_freq` (incl. V4/V4L), `standby`, `init`. Also `xtal_check` and `read_gain`, which are static/unused in C. |
| `lib/drivers/rtlsdr/rtl_sdr.dart` | `RtlSdrTuner` enum, `Errno`, and the `rtlsdrLog` hook that replaces `fprintf(stderr)`. |
| `lib/drivers/rtlsdr/rtlsdr_i2c.dart` | Tuner↔RTL glue interface (`rtlsdr_i2c.h`). |
| `tool/oracle/rtlsdr/` | Host oracle: real C librtlsdr + a fake libusb (`include/libusb.h`, `fake_libusb.c`) that records every call and simulates the RTL2832U regs, the I2C tuners (R82xx status bytes, lock bit, VCO fine-tune, filter-cal code), EEPROM, and a failing first write. `oracle_main.c` is a scenario interpreter; `build.sh` builds it and regenerates `golden/*.trace` (committed). |
| `test/drivers/rtlsdr/fake_rtl_usb.dart` | Recording fake `UsbDeviceHandle`. It is a Dart twin of `fake_libusb.c` with the same model and the same trace format, plus a fake `BulkInStream`. |

- **Async design.** `readAsync(cb, bufNum, bufLen)` → `devh.openBulkIn(0x81, numBuffers: 15, bufferLength: 16*32*512)` by default. `bufLen` must be a multiple of 512, as in C.
  - Each `UsbBlock` goes to `cb`, then is `release()`d (resubmitted) when `cb` returns, the same as the libusb callback.
  - `cancelAsync()` sets `CANCELING` and wakes the loop, which then cancels the stream.
  - `UsbError.noDevice`, or `xfer_errors >= buf_num`, sets `dev_lost`, and `readAsync` returns -1.
  - `close()` is async: it awaits `INACTIVE` instead of the C `usleep` loop.

## Tests
**Command:** `source ~/prj/env.sh && flutter test test/drivers/rtlsdr/`
**Result:** **32/32 passed.** `flutter analyze lib/drivers test/drivers`: **No issues found.**

- **`oracle_trace_test.dart` — full trace-diff.** Every CTRL/STR/CLAIM/RESET/RELEASE/CLOSE/BULK line and every API return value is **byte-identical** to the C library for 7 scenarios:
  - `r820t_sdrpp_start`: the exact SDR++ `start()` order from 01 §3.1: open, 2.4 MS/s, 100 MHz, ppm, bw 0, ds 0, bias 0, agc 0, gains, offset tuning, `reset_buffer`, `read_sync`, close.
  - `r820t_full` (1345 lines):
    - all rates, including invalid ones; 9 frequencies across `freq_ranges`;
    - all 29 gains plus out-of-range values; 8 bandwidths (all filter branches);
    - ppm ±, AGC, testmode, bias tee plus GPIO 3, direct sampling I/Q and back;
    - offset tuning, `set_xtal_freq`, EEPROM read/write/out-of-range.
  - `r828d_generic`: 16 MHz xtal and the 345 MHz Cable1/Air-In switch.
  - `blog_v4`: HF, notch-band edges, VHF/UHF band switching, GPIO5.
  - `blog_v4l`
  - `r820t_nolock`: PLL never locks, plus the first USB write fails, which exercises the reset path.
  - `no_tuner`: GPIO4 reset probe, falling back to direct sampling.
- **`oracle_trace_test.dart` — probe prefix-diff.** For 4 scenarios (e4000, fc0012, fc0013, fc2580) the open/probe sequence matches C up to the tuner init call, and the reported tuner type and gain table are identical.
- **`tuner_r82xx_test.dart`:** bitrev, init chunking, bandwidth→IF, gain index accumulation, shadow write suppression, no-lock handling, V4 band/GPIO switching, R828D input switch, standby.
- **`librtlsdr_test.dart`:**
  - open/probe, and claim failure (closes the handle);
  - sample-rate validation, ppm/xtal, `readSync`;
  - `readAsync`: delivery, release, cancel, the -2 "already running" result, buf_num/buf_len handling, device loss → -1;
  - close waits for async;
  - unported tuner → "unsupported tuner".
- **To regenerate the golden traces:** `tool/oracle/rtlsdr/build.sh` (needs gcc only; no libusb headers required).

## Bug found by the oracle
`r82xx_init_array` is declared `[NUM_REGS]` (30) with only 27 initialisers. C therefore writes 30 bytes (0x05..0x22), the last three being 0. The first Dart version wrote 27 bytes; this is now fixed and documented in the code.

## Not done / next
1. **E4000, FC0012, FC0013 and FC2580 tuner drivers are not ported.**
   - They are probed exactly like C (the GPIO4 reset and the GPIO6 output setup for FC0012 happen) and `tunerType` is set, but their `tuners[]` entries are empty. `open()` logs "…is not supported by the Dart port (unsupported tuner)", and `setCenterFreq` returns -1.
   - Sources: `tuner_e4k.c` (1000 lines), `tuner_fc0012.c`, `tuner_fc0013.c`, `tuner_fc2580.c`. The oracle already builds and links them; to verify a port, add scenarios to `scenarios/` and move the probe scenarios there.
2. **Enumeration is not ported:** `rtlsdr_get_device_count/name/usb_strings/index_by_serial`. Enumeration belongs to the Android plugin; `knownDevices` and `findKnownDevice` are exported for the VID:PID filter.
3. **`readAsync` has only been tested against the fake `BulkInStream`.** It needs an integration run with the real `usbfs_transport` from worker `usb`.
4. **Kernel-driver detach** (`DETACH_KERNEL_DRIVER`) is omitted because it does not apply on Android.

## Contract questions (`lib/usb/usb_transport.dart` is unchanged)
- `controlTransfer` throws `UsbException` instead of returning negative codes. The driver catches it and maps it back to the libusb return code, so this works as is.
- `readAsync` assumes `BulkInStream.blocks` reports transfer errors via `addError(UsbException(code))`, with `UsbError.noDevice` meaning unplug, and that the stream closes (`onDone`) only after `cancel()`. **The `usb` worker should confirm this.**
- `close()` is async (`Future<int>`) because it awaits a running `readAsync` on the same isolate.
