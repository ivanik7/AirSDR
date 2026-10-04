// SPDX-License-Identifier: GPL-3.0-or-later
//
// N2 host oracle harness for the ABI v3 radio contract
// (native/include/sdrcore_v3.h, docs/native-n2-adr.md).
//
// The library under test is loaded with dlopen() so that an incomplete build
// (no v3 exports, or sdr_version() still 2) is REPORTED as missing
// implementation hooks instead of failing to link. Expected behavior is never
// relaxed for missing hooks: a case that cannot run is MISSING, which is a
// non-passing outcome (exit code 2).
//
// Subcommands:
//   n2_oracle suite --lib <libsdrcore.so> [--json out.json] [--allow-version-2]
//             [--perf-seconds N] [--only substr] [--keep-fixtures]
//       Phone-free synthetic/file/pipe/socket oracles (see docs/native-n2-oracles.md).
//   n2_oracle hw --lib <libsdrcore.so> [--json out.json] [--allow-version-2]
//             [--seconds N] [--freq HZ] [--wav-dir DIR]
//             [--rtl-lost-bytes N --rtl-seconds S]
//       Opt-in Linux-host acceptance soak with the attached RTL-SDR Blog V4.
//   n2_oracle demod-file --lib <libsdrcore.so> --file in.cu8 --rate R --lo HZ
//             --offset HZ --mode M --bw HZ --wav out.wav [--json out.json]
//             [--fft-width W] [--view-offset HZ] [--view-bw HZ] [--allow-version-2]
//       Replays one CU8 fixture through the native receiver into a WAV sink and
//       writes counters plus the latest FFT row as JSON; used by the Dart
//       parity test (test/n2_oracle/native_parity_test.dart).
//
// Exit codes: 0 all PASS (SKIP allowed), 1 any FAIL, 2 no FAIL but MISSING,
// 3 usage error / library not loadable.
#include "sdrcore_host.h"
#include "sdrcore_v3.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>

#include <linux/usbdevice_fs.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
constexpr double kPi = 3.14159265358979323846;

// ---------------------------------------------------------------------------
// Library binding
// ---------------------------------------------------------------------------
struct Api {
  void* lib = nullptr;
  std::string path;
  decltype(&sdr_version) version = nullptr;
  decltype(&sdr_create) create = nullptr;
  decltype(&sdr_destroy) destroy = nullptr;
  decltype(&sdr_v2_open_file) open_file = nullptr;
  decltype(&sdr_v2_open_synthetic) open_synthetic = nullptr;
  decltype(&sdr_v2_open_usb) open_usb = nullptr;
  decltype(&sdr_v2_configure) v2_configure = nullptr;
  decltype(&sdr_v2_start) v2_start = nullptr;
  decltype(&sdr_v2_stop) v2_stop = nullptr;
  decltype(&sdr_v2_close) close = nullptr;
  decltype(&sdr_v2_stats) v2_stats = nullptr;
  decltype(&sdr_v3_set_controls) set_controls = nullptr;
  decltype(&sdr_v3_set_display) set_display = nullptr;
  decltype(&sdr_v3_set_audio_sink) set_audio_sink = nullptr;
  decltype(&sdr_v3_start) start = nullptr;
  decltype(&sdr_v3_stop) stop = nullptr;
  decltype(&sdr_v3_snapshot) snapshot = nullptr;
  decltype(&sdr_v3_read_fft) read_fft = nullptr;
  decltype(&sdr_host_usb_list) host_list = nullptr;
  decltype(&sdr_host_open_usb) host_open = nullptr;
  std::vector<std::string> missing_v2, missing_v3;

  template <typename T>
  void bind(T& slot, const char* name, std::vector<std::string>* missing) {
    slot = reinterpret_cast<T>(dlsym(lib, name));
    if (!slot && missing) missing->push_back(name);
  }
  bool load(const std::string& p, std::string* error) {
    path = p;
    lib = dlopen(p.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!lib) { *error = dlerror(); return false; }
    bind(version, "sdr_version", &missing_v2);
    bind(create, "sdr_create", &missing_v2);
    bind(destroy, "sdr_destroy", &missing_v2);
    bind(open_file, "sdr_v2_open_file", &missing_v2);
    bind(open_synthetic, "sdr_v2_open_synthetic", &missing_v2);
    bind(open_usb, "sdr_v2_open_usb", &missing_v2);
    bind(v2_configure, "sdr_v2_configure", &missing_v2);
    bind(v2_start, "sdr_v2_start", &missing_v2);
    bind(v2_stop, "sdr_v2_stop", &missing_v2);
    bind(close, "sdr_v2_close", &missing_v2);
    bind(v2_stats, "sdr_v2_stats", &missing_v2);
    bind(set_controls, "sdr_v3_set_controls", &missing_v3);
    bind(set_display, "sdr_v3_set_display", &missing_v3);
    bind(set_audio_sink, "sdr_v3_set_audio_sink", &missing_v3);
    bind(start, "sdr_v3_start", &missing_v3);
    bind(stop, "sdr_v3_stop", &missing_v3);
    bind(snapshot, "sdr_v3_snapshot", &missing_v3);
    bind(read_fft, "sdr_v3_read_fft", &missing_v3);
    bind(host_list, "sdr_host_usb_list", nullptr);
    bind(host_open, "sdr_host_open_usb", nullptr);
    return true;
  }
  bool v3_symbols() const { return missing_v2.empty() && missing_v3.empty(); }
};

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------
enum class Status { kPass, kFail, kMissing, kSkip };
const char* status_name(Status s) {
  switch (s) {
    case Status::kPass: return "PASS";
    case Status::kFail: return "FAIL";
    case Status::kMissing: return "MISSING";
    case Status::kSkip: return "SKIP";
  }
  return "?";
}

std::string format(const char* fmt, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  return buf;
}

std::string json_escape(const std::string& s) {
  std::string out;
  for (char c : s) {
    if (c == '"' || c == '\\') { out += '\\'; out += c; }
    else if (c == '\n') out += "\\n";
    else if (static_cast<unsigned char>(c) < 0x20) out += format("\\u%04x", c);
    else out += c;
  }
  return out;
}

struct CaseResult {
  std::string name;
  std::string requirement;
  Status status = Status::kPass;
  std::vector<std::string> notes;
  std::vector<std::pair<std::string, double>> metrics;
  double seconds = 0;
};

struct Reporter {
  std::vector<CaseResult> results;
  CaseResult* cur = nullptr;
  void fail(int line, const std::string& what) {
    if (cur->status != Status::kMissing) cur->status = Status::kFail;
    cur->notes.push_back(format("line %d: %s", line, what.c_str()));
  }
  void missing(const std::string& what) {
    if (cur->status == Status::kPass) cur->status = Status::kMissing;
    cur->notes.push_back("missing hook: " + what);
  }
  void skip(const std::string& why) {
    cur->status = Status::kSkip;
    cur->notes.push_back("skip: " + why);
  }
  void note(const std::string& what) { cur->notes.push_back(what); }
  void metric(const std::string& key, double value) { cur->metrics.emplace_back(key, value); }
};
Reporter R;

#define CHECK(cond, ...)                                                  \
  do {                                                                    \
    if (!(cond)) R.fail(__LINE__, std::string(#cond) + " -- " + format(__VA_ARGS__)); \
  } while (0)
#define CHECK_RC(expr, expected)                                          \
  do {                                                                    \
    const int32_t rc_ = (expr);                                           \
    if (rc_ != (expected))                                                \
      R.fail(__LINE__, format("%s returned %d, expected %d", #expr, rc_, static_cast<int>(expected))); \
  } while (0)

struct Options {
  std::string lib;
  std::string json;
  std::string only;
  bool allow_v2 = false;
  bool keep = false;
  double perf_seconds = 10;
  // hw
  double hw_seconds = 600;  // ADR acceptance: >= 10 minutes at 2.4 MS/s
  uint64_t hw_freq = 100500000;
  std::string wav_dir;
  double rtl_lost_bytes = -1, rtl_seconds = 0;
  // demod-file
  std::string file, wav;
  std::string fixture = "modes";
  double gen_seconds = 0;
  uint32_t rate = 0, mode = 0, bw = 0, fft_width = 1024, view_bw = 0;
  uint64_t lo = 100000000;
  int64_t offset = 0, view_offset = 0;
};
Options O;
Api A;
std::string g_tmpdir;

// ---------------------------------------------------------------------------
// Process probes (CPU, RSS, fds, threads)
// ---------------------------------------------------------------------------
double cpu_seconds() {
  rusage u{};
  getrusage(RUSAGE_SELF, &u);
  return u.ru_utime.tv_sec + u.ru_utime.tv_usec * 1e-6 + u.ru_stime.tv_sec + u.ru_stime.tv_usec * 1e-6;
}
long status_kib(const char* key) {
  std::ifstream in("/proc/self/status");
  std::string line;
  const size_t n = strlen(key);
  while (std::getline(in, line))
    if (line.compare(0, n, key) == 0) return std::atol(line.c_str() + n + 1);
  return -1;
}
long rss_kib() { return status_kib("VmRSS"); }
long thread_count() { return status_kib("Threads"); }
long fd_count() {
  long n = 0;
  if (DIR* d = opendir("/proc/self/fd")) {
    while (readdir(d)) ++n;
    closedir(d);
  }
  return n - 3;  // ".", ".." and the DIR's own fd.
}
double seconds_since(Clock::time_point t) {
  return std::chrono::duration<double>(Clock::now() - t).count();
}
void sleep_ms(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

// ---------------------------------------------------------------------------
// Fixtures: deterministic CU8 IQ generator (centered at 127.5, scale 127.5)
// ---------------------------------------------------------------------------
enum class Mod { kCarrier, kFm, kAm, kUsb, kLsb };
struct Carrier {
  Mod mod;
  double offset_hz;    // From LO. For USB/LSB the suppressed carrier (dial).
  double amplitude;    // Peak complex amplitude, full scale 1.
  double tone_hz = 1000;
  double deviation_hz = 0;
  double mod_index = 0.5;
};

std::vector<uint8_t> make_cu8(uint32_t rate, double seconds, const std::vector<Carrier>& carriers,
                              double noise_rms, uint64_t seed) {
  const size_t pairs = static_cast<size_t>(seconds * rate);
  std::vector<uint8_t> out(2 * pairs);
  std::vector<double> phase(carriers.size(), 0.0);
  uint64_t s = seed ? seed : 1;
  auto uniform = [&s]() {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17;
    return (static_cast<double>(s >> 11) + 0.5) / 9007199254740992.0;
  };
  const double sigma = noise_rms / std::sqrt(2.0);
  for (size_t n = 0; n < pairs; ++n) {
    const double t = static_cast<double>(n) / rate;
    double i = 0, q = 0;
    for (size_t k = 0; k < carriers.size(); ++k) {
      const Carrier& c = carriers[k];
      const double tone = std::sin(2 * kPi * c.tone_hz * t);
      double amp = c.amplitude, f = c.offset_hz;
      switch (c.mod) {
        case Mod::kCarrier: break;
        case Mod::kFm: f += c.deviation_hz * tone; break;
        case Mod::kAm: amp *= 1 + c.mod_index * tone; break;
        case Mod::kUsb: f += c.tone_hz; break;
        case Mod::kLsb: f -= c.tone_hz; break;
      }
      phase[k] += 2 * kPi * f / rate;
      if (phase[k] > kPi) phase[k] -= 2 * kPi;
      if (phase[k] < -kPi) phase[k] += 2 * kPi;
      i += amp * std::cos(phase[k]);
      q += amp * std::sin(phase[k]);
    }
    if (noise_rms > 0) {
      const double r = std::sqrt(-2 * std::log(uniform())), th = 2 * kPi * uniform();
      i += sigma * r * std::cos(th);
      q += sigma * r * std::sin(th);
    }
    auto quant = [](double v) {
      return static_cast<uint8_t>(std::clamp(std::lround(127.5 + 127.5 * v), 0L, 255L));
    };
    out[2 * n] = quant(i);
    out[2 * n + 1] = quant(q);
  }
  return out;
}

struct TempFile {
  std::string path;
  bool owned = true;
  // Wraps an existing caller-owned file; it is never unlinked.
  static TempFile borrow(const std::string& p) {
    TempFile t;
    t.owned = false;
    t.path = p;
    return t;
  }
  TempFile() = default;
  TempFile(TempFile&& o) noexcept : path(std::move(o.path)), owned(o.owned) { o.owned = false; }
  explicit TempFile(const std::string& name, const std::vector<uint8_t>& bytes) {
    path = g_tmpdir + format("/n2_oracle_%d_", getpid()) + name;
    FILE* f = fopen(path.c_str(), "wb");
    if (f) { fwrite(bytes.data(), 1, bytes.size(), f); fclose(f); }
  }
  explicit TempFile(const std::string& name) { path = g_tmpdir + format("/n2_oracle_%d_", getpid()) + name; }
  ~TempFile() { if (owned && !O.keep && !path.empty()) unlink(path.c_str()); }
};

// ---------------------------------------------------------------------------
// Signal analysis
// ---------------------------------------------------------------------------
void fft_inplace(std::vector<std::complex<double>>& a) {
  const size_t n = a.size();
  for (size_t i = 1, j = 0; i < n; ++i) {
    size_t bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap(a[i], a[j]);
  }
  for (size_t len = 2; len <= n; len <<= 1) {
    const auto w = std::polar(1.0, -2 * kPi / len);
    for (size_t b = 0; b < n; b += len) {
      std::complex<double> x{1, 0};
      for (size_t j = 0; j < len / 2; ++j) {
        const auto u = a[b + j], v = a[b + j + len / 2] * x;
        a[b + j] = u + v;
        a[b + j + len / 2] = u - v;
        x *= w;
      }
    }
  }
}

struct Tone { double hz = 0; double rms = 0; double peak_db = -200; };
// Peak frequency of the last n samples (Hann + parabolic interpolation),
// mirroring test/sdrpp/signal_path/harness.dart peakOf().
Tone tone_of(const std::vector<float>& x, double fs, size_t n = 16384, double min_hz = 50) {
  Tone t;
  if (x.size() < n) return t;
  std::vector<std::complex<double>> a(n);
  double sum2 = 0;
  const size_t start = x.size() - n;
  for (size_t i = 0; i < n; ++i) {
    const double w = 0.5 - 0.5 * std::cos(2 * kPi * i / n);
    sum2 += static_cast<double>(x[start + i]) * x[start + i];
    a[i] = x[start + i] * w;
  }
  fft_inplace(a);
  const size_t kmin = static_cast<size_t>(std::ceil(min_hz * n / fs));
  size_t best = kmin;
  for (size_t k = kmin; k < n / 2 - 1; ++k)
    if (std::abs(a[k]) > std::abs(a[best])) best = k;
  double delta = 0;
  if (best > 0) {
    const double l = std::abs(a[best - 1]), c = std::abs(a[best]), r = std::abs(a[best + 1]);
    const double d = l - 2 * c + r;
    if (d != 0) delta = 0.5 * (l - r) / d;
  }
  t.hz = (best + delta) * fs / n;
  t.rms = std::sqrt(sum2 / n);
  t.peak_db = 20 * std::log10(std::abs(a[best]) / (n / 4.0) + 1e-30);
  return t;
}

struct Wav {
  bool ok = false;
  uint32_t rate = 0;
  uint16_t channels = 0, bits = 0;
  std::vector<float> left, right;
};
Wav read_wav(const std::string& path) {
  Wav w;
  std::ifstream in(path, std::ios::binary);
  std::vector<uint8_t> b((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  if (b.size() < 12 || memcmp(b.data(), "RIFF", 4) || memcmp(b.data() + 8, "WAVE", 4)) return w;
  auto u32 = [&](size_t p) { uint32_t v; memcpy(&v, b.data() + p, 4); return v; };
  auto u16 = [&](size_t p) { uint16_t v; memcpy(&v, b.data() + p, 2); return v; };
  for (size_t p = 12; p + 8 <= b.size();) {
    const uint32_t size = u32(p + 4);
    if (!memcmp(b.data() + p, "fmt ", 4) && p + 24 <= b.size()) {
      w.channels = u16(p + 10);
      w.rate = u32(p + 12);
      w.bits = u16(p + 22);
    } else if (!memcmp(b.data() + p, "data", 4)) {
      if (w.channels != 2 || w.bits != 16) return w;
      const size_t end = std::min(b.size(), p + 8 + static_cast<size_t>(size));
      for (size_t q = p + 8; q + 4 <= end; q += 4) {
        int16_t l, r;
        memcpy(&l, b.data() + q, 2);
        memcpy(&r, b.data() + q + 2, 2);
        w.left.push_back(l / 32768.0f);
        w.right.push_back(r / 32768.0f);
      }
      w.ok = true;
      return w;
    }
    p += 8 + size + (size & 1);
  }
  return w;
}

// ---------------------------------------------------------------------------
// v3 helpers
// ---------------------------------------------------------------------------
SdrV3Controls controls(uint64_t lo, int64_t offset, uint32_t rate, uint32_t mode, uint32_t bw) {
  SdrV3Controls c{};
  c.size = sizeof c;
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = lo;
  c.vfo_offset_hz = offset;
  c.sample_rate = rate;
  c.mode = mode;
  c.bandwidth_hz = bw;
  c.gain_tenths_db = 200;
  c.squelch = SDR_V3_SQUELCH_OFF;
  c.squelch_level_db = -50;
  c.volume = 1;
  c.muted = 0;
  return c;
}
SdrV3Display display(int64_t view_offset, uint32_t view_bw, uint32_t width) {
  SdrV3Display d{};
  d.size = sizeof d;
  d.revision = SDR_V3_REVISION;
  d.view_offset_hz = view_offset;
  d.view_bandwidth_hz = view_bw;
  d.width = width;
  return d;
}
SdrV3Snapshot snap(SdrHandle* h, int32_t* rc_out = nullptr) {
  SdrV3Snapshot s{};
  s.size = sizeof s;
  s.revision = SDR_V3_REVISION;
  const int32_t rc = A.snapshot(h, &s);
  if (rc_out) *rc_out = rc;
  else if (rc != SDR_OK) R.fail(__LINE__, format("sdr_v3_snapshot returned %d", rc));
  return s;
}
struct Row {
  int32_t rc = SDR_V3_NO_DATA;
  SdrV3Fft meta{};
  std::vector<float> bins;
};
Row read_row(SdrHandle* h, uint64_t after, uint32_t capacity = SDR_V3_MAX_FFT_WIDTH) {
  Row r;
  r.meta.size = sizeof r.meta;
  r.meta.revision = SDR_V3_REVISION;
  r.bins.assign(capacity, -999.0f);
  r.rc = A.read_fft(h, after, &r.meta, capacity ? r.bins.data() : nullptr, capacity);
  if (r.rc == SDR_OK) r.bins.resize(r.meta.width);
  return r;
}
int32_t setc(SdrHandle* h, SdrV3Controls c) { return A.set_controls(h, &c); }
int32_t setd(SdrHandle* h, SdrV3Display d) { return A.set_display(h, &d); }
int32_t set_sink(SdrHandle* h, const std::string& spec) {
  return A.set_audio_sink(h, spec.data(), static_cast<uint32_t>(spec.size()));
}

// Owns one native handle; destroys it at scope exit.
struct Handle {
  SdrHandle* h = nullptr;
  Handle() { h = A.create(); }
  ~Handle() { if (h) A.destroy(h); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
};

int open_fixture(SdrHandle* h, const TempFile& f, uint32_t rate) {
  const int fd = ::open(f.path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) return SDR_IO_ERROR;
  const int rc = A.open_file(h, fd, rate);
  ::close(fd);  // The library owns a dup per the ABI-2 fd contract.
  return rc;
}

// Waits until the paced file source has been fully processed (or timeout),
// polling FFT at <=30 Hz and the snapshot at 50 Hz like a UI would.
struct RunStats {
  SdrV3Snapshot last{};
  Row latest;
  uint64_t rows = 0;
};
RunStats run_until(SdrHandle* h, uint64_t pairs, double timeout_s, bool poll_fft = true) {
  RunStats st;
  const auto t0 = Clock::now();
  auto next_fft = t0;
  uint64_t seq = 0;
  while (seconds_since(t0) < timeout_s) {
    st.last = snap(h);
    if (poll_fft && Clock::now() >= next_fft) {
      Row r = read_row(h, seq);
      if (r.rc == SDR_OK) { seq = r.meta.sequence; st.latest = r; ++st.rows; }
      next_fft += std::chrono::milliseconds(33);
    }
    if (st.last.processed_samples >= pairs || st.last.state != SDR_RUNNING) break;
    sleep_ms(20);
  }
  return st;
}

// ---------------------------------------------------------------------------
// Case runner
// ---------------------------------------------------------------------------
struct CaseDef {
  const char* name;
  const char* requirement;
  bool needs_v3;
  std::function<void()> body;
};

bool v3_gate(bool needs_v3) {
  if (!needs_v3) return true;
  if (!A.v3_symbols()) {
    R.missing(format("%zu sdr_v3_* exports absent (listed under abi_version)", A.missing_v3.size()));
    return false;
  }
  if (A.version() != 3 && !O.allow_v2) {
    R.missing(format("sdr_version()=%u; v3 runtime not advertised (use --allow-version-2 to probe "
                     "a worker branch)", A.version()));
    return false;
  }
  return true;
}

void run_cases(const std::vector<CaseDef>& cases) {
  for (const auto& c : cases) {
    if (!O.only.empty() && std::string(c.name).find(O.only) == std::string::npos) continue;
    R.results.push_back(CaseResult{});
    R.cur = &R.results.back();
    R.cur->name = c.name;
    R.cur->requirement = c.requirement;
    const auto t0 = Clock::now();
    if (v3_gate(c.needs_v3)) {
      try { c.body(); } catch (const std::exception& e) { R.fail(0, std::string("exception: ") + e.what()); }
    }
    R.cur->seconds = seconds_since(t0);
    std::printf("[%-7s] %-44s %6.2fs\n", status_name(R.cur->status), c.name, R.cur->seconds);
    for (const auto& n : R.cur->notes) std::printf("            %s\n", n.c_str());
    for (const auto& m : R.cur->metrics) std::printf("            %s = %.6g\n", m.first.c_str(), m.second);
    std::fflush(stdout);
  }
}

int finish(const char* suite) {
  int pass = 0, fail = 0, missing = 0, skip = 0;
  for (const auto& r : R.results) {
    if (r.status == Status::kPass) ++pass;
    if (r.status == Status::kFail) ++fail;
    if (r.status == Status::kMissing) ++missing;
    if (r.status == Status::kSkip) ++skip;
  }
  std::printf("\n%s: %d pass, %d fail, %d missing, %d skip (library %s, sdr_version=%u)\n", suite, pass,
              fail, missing, skip, A.path.c_str(), A.version ? A.version() : 0);
  if (!O.json.empty()) {
    std::ofstream out(O.json);
    out << "{\"suite\":\"" << suite << "\",\"library\":\"" << json_escape(A.path)
        << "\",\"sdr_version\":" << (A.version ? A.version() : 0) << ",\"missing_symbols\":[";
    bool first = true;
    for (const auto* v : {&A.missing_v2, &A.missing_v3})
      for (const auto& s : *v) { out << (first ? "" : ",") << '"' << s << '"'; first = false; }
    out << "],\"summary\":{\"pass\":" << pass << ",\"fail\":" << fail << ",\"missing\":" << missing
        << ",\"skip\":" << skip << "},\"cases\":[";
    for (size_t i = 0; i < R.results.size(); ++i) {
      const auto& r = R.results[i];
      out << (i ? "," : "") << "{\"name\":\"" << r.name << "\",\"requirement\":\""
          << json_escape(r.requirement) << "\",\"status\":\"" << status_name(r.status)
          << "\",\"seconds\":" << r.seconds << ",\"notes\":[";
      for (size_t j = 0; j < r.notes.size(); ++j)
        out << (j ? "," : "") << '"' << json_escape(r.notes[j]) << '"';
      out << "],\"metrics\":{";
      for (size_t j = 0; j < r.metrics.size(); ++j)
        out << (j ? "," : "") << '"' << r.metrics[j].first << "\":"
            << (std::isfinite(r.metrics[j].second) ? format("%.9g", r.metrics[j].second) : "null");
      out << "}}";
    }
    out << "]}\n";
  }
  if (fail) return 1;
  if (missing) return 2;
  return 0;
}

// ---------------------------------------------------------------------------
// Shared constants for the mode oracles (one multi-carrier fixture)
// ---------------------------------------------------------------------------
constexpr uint32_t kModeRate = 1024000;
constexpr uint64_t kLo = 100000000;
constexpr double kToneTolHz = 3.0;  // Same tolerance as the Dart radio_module_test.
// SDR++/Dart CW beat tone default (lib/sdrpp/modules/radio/demodulators/cw.dart: tone = 800).
constexpr double kCwToneHz = 800.0;

struct ModeCase {
  const char* name;
  uint32_t mode;
  int64_t offset;  // VFO reference (dial) offset from LO
  uint32_t bw;     // Dart demodParams default bandwidth
  double tone_hz;  // Expected audio tone
};
const ModeCase kModeCases[] = {
    {"wfm", SDR_V3_WFM, 250000, 150000, 1000},
    {"nfm", SDR_V3_NFM, -150000, 12500, 1250},
    {"am", SDR_V3_AM, 400000, 10000, 700},
    {"usb", SDR_V3_USB, 60000, 2800, 1500},
    {"lsb", SDR_V3_LSB, -60000, 2800, 1200},
    {"cw", SDR_V3_CW, -300000, 200, kCwToneHz},
};
std::vector<Carrier> mode_carriers() {
  return {
      {Mod::kFm, 250000, 0.25, 1000, 75000},
      {Mod::kFm, -150000, 0.2, 1250, 3000},
      {Mod::kAm, 400000, 0.2, 700, 0, 0.6},
      {Mod::kUsb, 60000, 0.05, 1500},
      {Mod::kLsb, -60000, 0.05, 1200},
      {Mod::kCarrier, -300000, 0.05},
  };
}

// UI contract: lib/ui/radio_controller.dart demodParams (min, default, max).
struct UiBand { uint32_t mode; const char* name; uint32_t min, def, max; };
const UiBand kUiBands[] = {
    {SDR_V3_WFM, "wfm", 50000, 150000, 250000}, {SDR_V3_NFM, "nfm", 1000, 12500, 50000},
    {SDR_V3_AM, "am", 1000, 10000, 15000},      {SDR_V3_USB, "usb", 500, 2800, 12000},
    {SDR_V3_LSB, "lsb", 500, 2800, 12000},      {SDR_V3_DSB, "dsb", 1000, 4600, 12000},
    {SDR_V3_CW, "cw", 50, 200, 500},            {SDR_V3_RAW, "raw", 48000, 48000, 48000},
};

// Runs one mode through the native WAV sink and returns the left channel.
struct DemodRun {
  bool ok = false;
  SdrV3Snapshot snap{};
  Wav wav;
  Row row;
  double wall = 0;
};
DemodRun demod_fixture(const TempFile& fixture, uint32_t rate, uint64_t pairs, const SdrV3Controls& c,
                       const SdrV3Display& d, const std::string& wav_path) {
  DemodRun out;
  Handle hd;
  SdrHandle* h = hd.h;
  CHECK_RC(open_fixture(h, fixture, rate), SDR_OK);
  CHECK_RC(A.set_controls(h, &c), SDR_OK);
  CHECK_RC(A.set_display(h, &d), SDR_OK);
  CHECK_RC(set_sink(h, "wav:" + wav_path), SDR_OK);
  const auto t0 = Clock::now();
  const int32_t rc = A.start(h);
  CHECK(rc == SDR_OK, "start rc=%d", rc);
  if (rc != SDR_OK) return out;
  RunStats st = run_until(h, pairs, 3.0 + 2.0 * pairs / rate);
  out.wall = seconds_since(t0);
  CHECK_RC(A.stop(h), SDR_OK);
  out.snap = snap(h);
  out.row = st.latest;
  CHECK_RC(A.close(h), SDR_OK);
  out.wav = read_wav(wav_path);
  out.ok = out.wav.ok;
  return out;
}

// ---------------------------------------------------------------------------
// Suite cases
// ---------------------------------------------------------------------------
void case_abi_version() {
  const uint32_t v = A.version();
  R.metric("sdr_version", v);
  if (!A.missing_v3.empty()) {
    for (const auto& s : A.missing_v3) R.missing(s);
    return;
  }
  if (v != 3) R.missing(format("all v3 symbols exported but sdr_version()=%u; integrator must advance it to 3", v));
}

void case_struct_validation() {
  Handle hd;
  SdrHandle* h = hd.h;
  CHECK_RC(A.open_synthetic(h, 240000), SDR_OK);
  // Snapshot size/revision mismatch leaves output untouched.
  SdrV3Snapshot s;
  memset(&s, 0x5a, sizeof s);
  s.size = sizeof s - 8;
  s.revision = SDR_V3_REVISION;
  SdrV3Snapshot copy = s;
  CHECK_RC(A.snapshot(h, &s), SDR_INVALID_ARGUMENT);
  CHECK(!memcmp(&s, &copy, sizeof s), "snapshot output modified on size mismatch");
  s.size = sizeof s;
  s.revision = 2;
  copy = s;
  CHECK_RC(A.snapshot(h, &s), SDR_INVALID_ARGUMENT);
  CHECK(!memcmp(&s, &copy, sizeof s), "snapshot output modified on revision mismatch");
  // Fresh open: OPEN, counters zero, generation 0, no error.
  const SdrV3Snapshot o = snap(h);
  CHECK(o.state == SDR_OPEN && o.source == SDR_SYNTHETIC, "state=%u source=%u", o.state, o.source);
  CHECK(o.last_error == 0 && o.error_sequence == 0, "error %d seq %llu", o.last_error,
        static_cast<unsigned long long>(o.error_sequence));
  CHECK(o.stream_generation == 0 && o.input_samples == 0, "gen %llu input %llu",
        static_cast<unsigned long long>(o.stream_generation), static_cast<unsigned long long>(o.input_samples));
  CHECK(o.reserved == 0, "reserved=%u", o.reserved);
  // read_fft argument validation.
  Row bad;
  bad.meta.size = sizeof bad.meta + 4;
  bad.meta.revision = SDR_V3_REVISION;
  float bins[4];
  CHECK_RC(A.read_fft(h, 0, &bad.meta, bins, 4), SDR_INVALID_ARGUMENT);
  SdrV3Fft meta{};
  meta.size = sizeof meta;
  meta.revision = SDR_V3_REVISION;
  CHECK_RC(A.read_fft(h, 0, &meta, nullptr, 16), SDR_INVALID_ARGUMENT);
  CHECK_RC(A.read_fft(h, 0, &meta, bins, SDR_V3_MAX_FFT_WIDTH + 1), SDR_INVALID_ARGUMENT);
  CHECK_RC(A.read_fft(h, 0, &meta, bins, 4), SDR_V3_NO_DATA);  // OPEN: no row.
  // Start before any controls is INVALID_STATE (no implicit configuration).
  CHECK_RC(A.start(h), SDR_INVALID_STATE);
  CHECK(snap(h).state == SDR_OPEN, "state changed after rejected start");
  CHECK_RC(A.stop(h), SDR_INVALID_STATE);
  // Commands on an IDLE handle.
  Handle idle;
  SdrV3Controls c = controls(kLo, 0, 240000, SDR_V3_NFM, 12500);
  CHECK_RC(A.set_controls(idle.h, &c), SDR_INVALID_STATE);
  CHECK_RC(A.start(idle.h), SDR_INVALID_STATE);
  CHECK_RC(set_sink(idle.h, "null"), SDR_INVALID_STATE);
  CHECK(snap(idle.h).state == SDR_IDLE, "idle snapshot state");
  // NULL handles never crash.
  CHECK_RC(A.set_controls(nullptr, &c), SDR_INVALID_ARGUMENT);
  CHECK_RC(A.start(nullptr), SDR_INVALID_ARGUMENT);
  CHECK_RC(A.stop(nullptr), SDR_INVALID_ARGUMENT);
  CHECK_RC(A.snapshot(nullptr, &s), SDR_INVALID_ARGUMENT);
}

void case_controls_validation() {
  Handle hd;
  SdrHandle* h = hd.h;
  const uint32_t rate = 2400000;
  CHECK_RC(A.open_synthetic(h, rate), SDR_OK);
  SdrV3Controls good = controls(kLo, 0, rate, SDR_V3_NFM, 12500);
  CHECK_RC(A.set_controls(h, &good), SDR_OK);
  CHECK_RC(set_sink(h, "null"), SDR_OK);
  CHECK_RC(A.start(h), SDR_OK);
  const SdrV3Snapshot before = snap(h);
  struct Bad { const char* what; std::function<void(SdrV3Controls&)> edit; int32_t expect; };
  const std::vector<Bad> bad = {
      {"size", [](SdrV3Controls& c) { c.size -= 4; }, SDR_INVALID_ARGUMENT},
      {"revision", [](SdrV3Controls& c) { c.revision = 2; }, SDR_INVALID_ARGUMENT},
      {"reserved", [](SdrV3Controls& c) { c.reserved = 1; }, SDR_INVALID_ARGUMENT},
      {"mode 8", [](SdrV3Controls& c) { c.mode = 8; }, SDR_INVALID_ARGUMENT},
      {"squelch 3", [](SdrV3Controls& c) { c.squelch = 3; }, SDR_INVALID_ARGUMENT},
      {"muted 2", [](SdrV3Controls& c) { c.muted = 2; }, SDR_INVALID_ARGUMENT},
      {"volume NaN", [](SdrV3Controls& c) { c.volume = NAN; }, SDR_INVALID_ARGUMENT},
      {"volume 1.5", [](SdrV3Controls& c) { c.volume = 1.5f; }, SDR_INVALID_ARGUMENT},
      {"volume -0.1", [](SdrV3Controls& c) { c.volume = -0.1f; }, SDR_INVALID_ARGUMENT},
      {"squelch level +5", [](SdrV3Controls& c) { c.squelch_level_db = 5; }, SDR_INVALID_ARGUMENT},
      {"squelch level inf", [](SdrV3Controls& c) { c.squelch_level_db = INFINITY; }, SDR_INVALID_ARGUMENT},
      {"auto offset 30", [](SdrV3Controls& c) { c.auto_squelch_offset_db = 30; }, SDR_INVALID_ARGUMENT},
      {"rate 999", [](SdrV3Controls& c) { c.sample_rate = 999; }, SDR_INVALID_ARGUMENT},
      {"rate 20000001", [](SdrV3Controls& c) { c.sample_rate = 20000001; }, SDR_INVALID_ARGUMENT},
      {"bandwidth 0", [](SdrV3Controls& c) { c.bandwidth_hz = 0; }, SDR_INVALID_ARGUMENT},
      {"WFM 10 kHz", [](SdrV3Controls& c) { c.mode = SDR_V3_WFM; c.bandwidth_hz = 10000; }, SDR_INVALID_ARGUMENT},
      {"offset outside band", [](SdrV3Controls& c) { c.vfo_offset_hz = 1200001; }, SDR_INVALID_ARGUMENT},
      {"channel edge outside band", [](SdrV3Controls& c) { c.vfo_offset_hz = -1199000; }, SDR_INVALID_ARGUMENT},
      {"LO 7.3 GHz", [](SdrV3Controls& c) { c.center_frequency_hz = 7300000000ULL; }, SDR_INVALID_ARGUMENT},
      {"tune below 0 Hz", [](SdrV3Controls& c) { c.center_frequency_hz = 1000; c.vfo_offset_hz = -500000; }, SDR_INVALID_ARGUMENT},
      {"gain 200 dB", [](SdrV3Controls& c) { c.gain_tenths_db = 2000; }, SDR_INVALID_ARGUMENT},
      {"agc 2", [](SdrV3Controls& c) { c.agc = 2; }, SDR_INVALID_ARGUMENT},
      {"auto squelch on WFM", [](SdrV3Controls& c) { c.mode = SDR_V3_WFM; c.bandwidth_hz = 150000; c.squelch = SDR_V3_SQUELCH_AUTO; }, SDR_INVALID_ARGUMENT},
      {"auto squelch on RAW", [](SdrV3Controls& c) { c.mode = SDR_V3_RAW; c.bandwidth_hz = 48000; c.squelch = SDR_V3_SQUELCH_AUTO; }, SDR_INVALID_ARGUMENT},
  };
  for (const auto& b : bad) {
    SdrV3Controls c = good;
    b.edit(c);
    const int32_t rc = A.set_controls(h, &c);
    CHECK(rc == b.expect || (rc < 0 && b.expect == SDR_INVALID_ARGUMENT && rc == SDR_UNSUPPORTED),
          "%s: rc=%d expected %d", b.what, rc, b.expect);
  }
  // Hardware AGC: either applied or explicitly unsupported, never a silent no-op.
  SdrV3Controls agc = good;
  agc.agc = 1;
  const int32_t agc_rc = A.set_controls(h, &agc);
  CHECK(agc_rc == SDR_OK || agc_rc == SDR_UNSUPPORTED, "agc rc=%d", agc_rc);
  R.metric("agc_rc", agc_rc);
  if (agc_rc == SDR_OK) CHECK_RC(A.set_controls(h, &good), SDR_OK);
  const SdrV3Snapshot after = snap(h);
  // Rejected commands leave applied state and sequences untouched; stream keeps running.
  CHECK(after.state == SDR_RUNNING, "state=%u", after.state);
  if (agc_rc != SDR_OK) {
    CHECK(after.control_sequence == before.control_sequence, "control_sequence %llu -> %llu",
          static_cast<unsigned long long>(before.control_sequence),
          static_cast<unsigned long long>(after.control_sequence));
    CHECK(after.stream_generation == before.stream_generation, "generation changed");
  }
  CHECK(after.center_frequency_hz == kLo && after.mode == SDR_V3_NFM && after.bandwidth_hz == 12500,
        "applied lo=%llu mode=%u bw=%u", static_cast<unsigned long long>(after.center_frequency_hz),
        after.mode, after.bandwidth_hz);
  CHECK(after.last_error == 0 && after.error_sequence == 0, "validation poisoned stream: err=%d",
        after.last_error);
  // Display validation.
  struct BadD { const char* what; SdrV3Display d; };
  SdrV3Display ok_d = display(0, rate, 512);
  const std::vector<BadD> bad_d = {
      {"width 0", display(0, rate, 0)},
      {"width 2049", display(0, rate, 2049)},
      {"view bw 0", display(0, 0, 512)},
      {"view bw > rate", display(0, rate + 1, 512)},
      {"view outside band", display(1100000, 400000, 512)},  // [900k, 1.3M] vs +-1.2M
  };
  const uint64_t seq0 = snap(h).control_sequence;
  for (const auto& b : bad_d) CHECK(A.set_display(h, &b.d) == SDR_INVALID_ARGUMENT, "display %s accepted", b.what);
  SdrV3Display rev = ok_d;
  rev.revision = 2;
  CHECK_RC(A.set_display(h, &rev), SDR_INVALID_ARGUMENT);
  CHECK(snap(h).control_sequence == seq0, "rejected display advanced control_sequence");
  CHECK_RC(A.set_display(h, &ok_d), SDR_OK);
  CHECK(snap(h).control_sequence == seq0 + 1, "display did not advance control_sequence");
  CHECK_RC(A.stop(h), SDR_OK);
}

void case_ui_bandwidth_contract() {
  // Every bandwidth the existing UI can send (demodParams min/default/max) must be
  // accepted for a centered VFO; otherwise the native adapter cannot preserve the
  // RadioController contract.
  Handle hd;
  SdrHandle* h = hd.h;
  const uint32_t rate = 2400000;
  CHECK_RC(A.open_synthetic(h, rate), SDR_OK);
  for (const auto& b : kUiBands) {
    for (uint32_t bw : {b.min, b.def, b.max}) {
      SdrV3Controls c = controls(kLo, 0, rate, b.mode, bw);
      const int32_t rc = A.set_controls(h, &c);
      CHECK(rc == SDR_OK, "%s bandwidth %u Hz (UI demodParams) rejected rc=%d", b.name, bw, rc);
    }
  }
  // Auto squelch is allowed exactly where the Dart receiver offers it.
  for (uint32_t mode : {SDR_V3_NFM, SDR_V3_AM, SDR_V3_USB, SDR_V3_LSB, SDR_V3_DSB}) {
    SdrV3Controls c = controls(kLo, 0, rate, mode, mode == SDR_V3_NFM ? 12500 : mode == SDR_V3_AM ? 10000 : 2800);
    c.squelch = SDR_V3_SQUELCH_AUTO;
    CHECK(A.set_controls(h, &c) == SDR_OK, "auto squelch rejected for mode %u", mode);
  }
}

void case_mode_tones() {
  const double secs = 1.2;
  const uint64_t pairs = static_cast<uint64_t>(secs * kModeRate);
  TempFile fixture("modes_1024k.cu8", make_cu8(kModeRate, secs, mode_carriers(), 0.003, 7));
  for (const auto& m : kModeCases) {
    TempFile wav(std::string("mode_") + m.name + ".wav");
    DemodRun r = demod_fixture(fixture, kModeRate, pairs, controls(kLo, m.offset, kModeRate, m.mode, m.bw),
                               display(0, kModeRate, 1024), wav.path);
    CHECK(r.ok, "%s: WAV unreadable", m.name);
    if (!r.ok) continue;
    CHECK(r.wav.rate == 48000, "%s: WAV rate %u", m.name, r.wav.rate);
    const Tone t = tone_of(r.wav.left, r.wav.rate);
    const Tone tr = tone_of(r.wav.right, r.wav.rate);
    R.metric(std::string(m.name) + "_tone_hz", t.hz);
    R.metric(std::string(m.name) + "_rms", t.rms);
    CHECK(std::fabs(t.hz - m.tone_hz) <= kToneTolHz, "%s: tone %.1f Hz, expected %.1f", m.name, t.hz, m.tone_hz);
    CHECK(t.rms > 0.02 && t.rms < 1.5, "%s: rms %.4f outside (0.02, 1.5)", m.name, t.rms);
    CHECK(std::fabs(tr.hz - m.tone_hz) <= kToneTolHz, "%s: right tone %.1f", m.name, tr.hz);
    // Audio sample-rate oracle: 48 kHz stereo frames per processed IQ second.
    const double expected = 48000.0 * r.snap.processed_samples / kModeRate;
    CHECK(std::fabs(static_cast<double>(r.snap.audio_frames) - expected) <= 0.005 * expected + 64,
          "%s: audio frames %llu, expected %.0f (48 kHz)", m.name,
          static_cast<unsigned long long>(r.snap.audio_frames), expected);
    CHECK(r.wav.left.size() == r.snap.audio_frames, "%s: WAV frames %zu != audio_frames %llu", m.name,
          r.wav.left.size(), static_cast<unsigned long long>(r.snap.audio_frames));
    CHECK(r.snap.processed_samples + r.snap.dropped_samples == r.snap.input_samples,
          "%s: processed+dropped != input", m.name);
    // Files loop at EOF like the Dart FileSource (file_eof_parity), so the run
    // stops after at least one full pass; overshoot is bounded by the 20 ms poll
    // plus one 8 KiB ring slot (integrator reconciliation, t_848e6a1c).
    CHECK(r.snap.processed_samples >= pairs &&
              r.snap.processed_samples <= pairs + kModeRate / 10,
          "%s: processed %llu of %llu", m.name,
          static_cast<unsigned long long>(r.snap.processed_samples), static_cast<unsigned long long>(pairs));
    // File replay is paced at the declared complex rate (+-10% wall clock).
    CHECK(r.wall > 0.9 * secs && r.wall < 1.5 * secs + 0.5, "%s: replay wall %.2fs for %.2fs of IQ", m.name, r.wall, secs);
  }
}

void case_wfm_stereo_parity() {
  // Dart WFM decodes the 19 kHz pilot/MPX stereo when the 'stereo' option is on
  // (radio_module_test 'WFM stereo'). ABI v3 has no stereo control; mono WFM must
  // still be identical on L and R. Stereo separation is an explicit parity gap.
  const double secs = 1.0;
  TempFile fixture("wfm_mono.cu8", make_cu8(kModeRate, secs, {{Mod::kFm, 0, 0.3, 1000, 75000}}, 0.003, 9));
  TempFile wav("wfm_mono.wav");
  DemodRun r = demod_fixture(fixture, kModeRate, static_cast<uint64_t>(secs * kModeRate),
                             controls(kLo, 0, kModeRate, SDR_V3_WFM, 150000), display(0, kModeRate, 512), wav.path);
  CHECK(r.ok, "WAV unreadable");
  if (!r.ok) return;
  double diff = 0;
  for (size_t i = 0; i < r.wav.left.size(); ++i) diff = std::max(diff, double(std::fabs(r.wav.left[i] - r.wav.right[i])));
  CHECK(diff < 1e-4, "mono WFM L/R differ by %.5f", diff);
  R.note("GAP (not asserted by ABI v3): no WFM stereo pilot/MPX decode; Dart offers it as a demod option.");
}

void case_fft_spectrum() {
  const double secs = 1.0;
  const uint32_t rate = kModeRate;
  const double f0 = 200500;
  TempFile fixture("fft_carrier.cu8", make_cu8(rate, secs, {{Mod::kCarrier, f0, 0.25}}, 0.01, 11));
  Handle hd;
  SdrHandle* h = hd.h;
  CHECK_RC(open_fixture(h, fixture, rate), SDR_OK);
  CHECK_RC(setc(h, controls(kLo, 0, rate, SDR_V3_NFM, 12500)), SDR_OK);
  CHECK_RC(setd(h, display(0, rate, 1024)), SDR_OK);
  CHECK_RC(set_sink(h, "null"), SDR_OK);
  CHECK_RC(A.start(h), SDR_OK);
  sleep_ms(300);
  Row full = read_row(h, 0);
  CHECK(full.rc == SDR_OK, "no FFT row after 300 ms rc=%d", full.rc);
  if (full.rc == SDR_OK) {
    const auto& m = full.meta;
    CHECK(m.width == 1024 && full.bins.size() == 1024, "width %u", m.width);
    CHECK(m.low_hz == int64_t(kLo) - int64_t(rate / 2) && m.high_hz == int64_t(kLo) + int64_t(rate / 2),
          "full-band low/high %lld/%lld", (long long)m.low_hz, (long long)m.high_hz);
    CHECK(m.reserved == 0 && m.size == sizeof m && m.revision == SDR_V3_REVISION, "metadata header");
    const size_t peak = std::max_element(full.bins.begin(), full.bins.end()) - full.bins.begin();
    const double col_w = double(m.high_hz - m.low_hz) / m.width;
    const double peak_hz = m.low_hz + (peak + 0.5) * col_w - double(kLo);
    std::vector<float> sorted = full.bins;
    std::sort(sorted.begin(), sorted.end());
    const double floor_db = sorted[sorted.size() / 2];
    R.metric("full_peak_offset_hz", peak_hz);
    R.metric("full_peak_db", full.bins[peak]);
    R.metric("full_median_floor_db", floor_db);
    CHECK(std::fabs(peak_hz - f0) <= col_w, "peak at %.0f Hz, expected %.0f +- %.0f", peak_hz, f0, col_w);
    CHECK(full.bins[peak] - floor_db >= 25, "peak-to-floor %.1f dB < 25", full.bins[peak] - floor_db);
    bool finite = true;
    for (float v : full.bins) finite &= std::isfinite(v);
    CHECK(finite, "non-finite bins");
  }
  // Zoomed view: 102.4 kHz around +200 kHz in 512 columns.
  CHECK_RC(setd(h, display(200000, 102400, 512)), SDR_OK);
  const uint64_t ctl = snap(h).control_sequence;
  Row zoom;
  for (int i = 0; i < 30 && zoom.rc != SDR_OK; ++i) { sleep_ms(33); zoom = read_row(h, full.meta.sequence); }
  CHECK(zoom.rc == SDR_OK, "no zoomed row rc=%d", zoom.rc);
  if (zoom.rc == SDR_OK) {
    const auto& m = zoom.meta;
    CHECK(m.control_sequence == ctl, "row control_sequence %llu != %llu", (unsigned long long)m.control_sequence,
          (unsigned long long)ctl);
    CHECK(m.low_hz == int64_t(kLo) + 200000 - 51200 && m.high_hz == int64_t(kLo) + 200000 + 51200,
          "zoom low/high %lld/%lld", (long long)m.low_hz, (long long)m.high_hz);
    const size_t peak = std::max_element(zoom.bins.begin(), zoom.bins.end()) - zoom.bins.begin();
    const double col_w = double(m.high_hz - m.low_hz) / m.width;
    const double peak_hz = m.low_hz + (peak + 0.5) * col_w - double(kLo);
    R.metric("zoom_peak_offset_hz", peak_hz);
    // Dart default FFT (8192 bins at 1.024 MS/s = 125 Hz) localizes within 1 kHz.
    CHECK(std::fabs(peak_hz - f0) <= 1000, "zoom peak at %.0f Hz, expected %.0f", peak_hz, f0);
  }
  CHECK_RC(A.stop(h), SDR_OK);
}

void case_fft_rate_latest_wins() {
  Handle hd;
  SdrHandle* h = hd.h;
  const uint32_t rate = 2400000;
  CHECK_RC(A.open_synthetic(h, rate), SDR_OK);
  CHECK_RC(setc(h, controls(kLo, 0, rate, SDR_V3_WFM, 150000)), SDR_OK);
  CHECK_RC(setd(h, display(0, rate, 640)), SDR_OK);
  CHECK_RC(set_sink(h, "null"), SDR_OK);
  CHECK_RC(A.start(h), SDR_OK);
  sleep_ms(200);
  // Row rate: count distinct rows polled at 100 Hz over 2 s.
  uint64_t seq = 0, rows = 0, first = 0, last = 0;
  const auto t0 = Clock::now();
  while (seconds_since(t0) < 2.0) {
    Row r = read_row(h, seq);
    if (r.rc == SDR_OK) {
      CHECK(r.meta.sequence > seq, "sequence not monotonic");
      if (!first) first = r.meta.sequence;
      last = seq = r.meta.sequence;
      ++rows;
    }
    sleep_ms(10);
  }
  const double rows_per_s = (last - first) / 2.0;
  R.metric("fft_rows_per_s", rows_per_s);
  // Contract: <= 30 rows/s. Parity floor: Dart default fftRate is 20 rows/s.
  CHECK(rows_per_s <= 30.5, "%.1f rows/s exceeds 30", rows_per_s);
  CHECK(rows_per_s >= 15, "%.1f rows/s below 15 (Dart default 20)", rows_per_s);
  // NO_DATA leaves outputs unchanged.
  Row nd;
  nd.meta.size = sizeof nd.meta;
  nd.meta.revision = SDR_V3_REVISION;
  nd.meta.sequence = 0xdeadbeef;
  nd.meta.width = 77;
  std::vector<float> sentinel(1024, -999.0f);
  int32_t rc = A.read_fft(h, UINT64_MAX, &nd.meta, sentinel.data(), 1024);
  CHECK(rc == SDR_V3_NO_DATA, "after=UINT64_MAX rc=%d", rc);
  CHECK(nd.meta.sequence == 0xdeadbeef && nd.meta.width == 77, "NO_DATA modified metadata");
  CHECK(std::all_of(sentinel.begin(), sentinel.end(), [](float v) { return v == -999.0f; }), "NO_DATA modified bins");
  // BUFFER_SMALL reports width only.
  sleep_ms(80);
  SdrV3Fft small{};
  small.size = sizeof small;
  small.revision = SDR_V3_REVISION;
  small.sequence = 0xabcdef;
  small.low_hz = 12345;
  rc = A.read_fft(h, seq, &small, sentinel.data(), 639);
  CHECK(rc == SDR_V3_BUFFER_SMALL, "capacity 639 rc=%d", rc);
  CHECK(small.width == 640, "BUFFER_SMALL width=%u", small.width);
  CHECK(small.sequence == 0xabcdef && small.low_hz == 12345, "BUFFER_SMALL modified other metadata");
  CHECK(std::all_of(sentinel.begin(), sentinel.end(), [](float v) { return v == -999.0f; }), "BUFFER_SMALL modified bins");
  Row ok = read_row(h, seq, 640);
  CHECK(ok.rc == SDR_OK && ok.meta.width == 640, "bounded retry rc=%d", ok.rc);
  // Latest-wins: a lagging poller sees only the newest row and overwrites are counted.
  const uint64_t over0 = snap(h).fft_overwrites;
  sleep_ms(500);
  const SdrV3Snapshot s = snap(h);
  Row latest = read_row(h, ok.rc == SDR_OK ? ok.meta.sequence : seq);
  CHECK(latest.rc == SDR_OK, "no row after 500 ms");
  CHECK(s.fft_overwrites >= over0 + 5, "overwrites %llu -> %llu after 500 ms unpolled",
        (unsigned long long)over0, (unsigned long long)s.fft_overwrites);
  if (latest.rc == SDR_OK && ok.rc == SDR_OK)
    CHECK(latest.meta.sequence >= ok.meta.sequence + 5, "latest row %llu is not newest",
          (unsigned long long)latest.meta.sequence);
  Row again = read_row(h, latest.meta.sequence);
  CHECK(again.rc == SDR_V3_NO_DATA || again.meta.sequence > latest.meta.sequence, "row re-delivered");
  // Header: "Poll only the latest completed FFT row newer than after_sequence".
  // A second poller asking for after_sequence=0 must still get the latest row.
  Row reread = read_row(h, 0);
  CHECK(reread.rc == SDR_OK, "read(after=0) of an already-read latest row rc=%d (header: newer than after_sequence)",
        reread.rc);
  CHECK_RC(A.stop(h), SDR_OK);
}

void case_generation_semantics() {
  Handle hd;
  SdrHandle* h = hd.h;
  const uint32_t rate = 2400000;
  CHECK_RC(A.open_synthetic(h, rate), SDR_OK);
  SdrV3Controls c = controls(kLo, 0, rate, SDR_V3_NFM, 12500);
  CHECK_RC(A.set_controls(h, &c), SDR_OK);
  CHECK_RC(setd(h, display(0, rate, 512)), SDR_OK);
  CHECK_RC(set_sink(h, "null"), SDR_OK);
  CHECK_RC(A.start(h), SDR_OK);
  CHECK(snap(h).stream_generation == 1, "first start generation %llu", (unsigned long long)snap(h).stream_generation);
  auto expect_change = [&](const char* what, std::function<void(SdrV3Controls&)> edit, bool restart) {
    const SdrV3Snapshot b = snap(h);
    edit(c);
    const int32_t rc = A.set_controls(h, &c);
    CHECK(rc == SDR_OK, "%s rc=%d", what, rc);
    const SdrV3Snapshot a = snap(h);
    CHECK(a.state == SDR_RUNNING, "%s: state %u", what, a.state);
    CHECK(a.control_sequence > b.control_sequence, "%s: control_sequence did not advance", what);
    CHECK(a.stream_generation == b.stream_generation + (restart ? 1 : 0), "%s: generation %llu -> %llu (restart=%d)",
          what, (unsigned long long)b.stream_generation, (unsigned long long)a.stream_generation, restart);
    CHECK(a.center_frequency_hz == c.center_frequency_hz && a.vfo_offset_hz == c.vfo_offset_hz &&
              a.mode == c.mode && a.bandwidth_hz == c.bandwidth_hz && a.gain_tenths_db == c.gain_tenths_db &&
              a.sample_rate == c.sample_rate,
          "%s: snapshot does not show applied controls", what);
    // Rows after the change carry the new generation/control sequence.
    Row r;
    for (int i = 0; i < 40 && r.rc != SDR_OK; ++i) {
      sleep_ms(25);
      Row t = read_row(h, 0);
      if (t.rc == SDR_OK && t.meta.control_sequence == a.control_sequence) r = t;
    }
    CHECK(r.rc == SDR_OK, "%s: no row with new control_sequence within 1 s", what);
    if (r.rc == SDR_OK) CHECK(r.meta.stream_generation == a.stream_generation, "%s: row generation stale", what);
    // Input keeps flowing.
    const uint64_t in0 = snap(h).input_samples;
    sleep_ms(100);
    CHECK(snap(h).input_samples > in0, "%s: input stalled", what);
  };
  expect_change("VFO offset (drag)", [](SdrV3Controls& x) { x.vfo_offset_hz = 300000; }, false);
  expect_change("mode NFM->AM", [](SdrV3Controls& x) { x.mode = SDR_V3_AM; x.bandwidth_hz = 10000; }, false);
  expect_change("bandwidth", [](SdrV3Controls& x) { x.bandwidth_hz = 8000; }, false);
  expect_change("squelch manual", [](SdrV3Controls& x) { x.squelch = SDR_V3_SQUELCH_MANUAL; x.squelch_level_db = -40; }, false);
  expect_change("volume+mute", [](SdrV3Controls& x) { x.volume = 0.3f; x.muted = 1; }, false);
  expect_change("drag end: LO retune + recenter", [](SdrV3Controls& x) { x.center_frequency_hz += 300000; x.vfo_offset_hz = 0; }, true);
  expect_change("gain", [](SdrV3Controls& x) { x.gain_tenths_db = 300; }, true);
  expect_change("sample rate", [](SdrV3Controls& x) { x.sample_rate = 1024000; }, true);
  // Identical controls are idempotent (no restart).
  expect_change("identical controls", [](SdrV3Controls&) {}, false);
  CHECK_RC(A.stop(h), SDR_OK);
}

void case_mute_volume() {
  const double secs = 1.0;
  const uint64_t pairs = static_cast<uint64_t>(secs * kModeRate);
  TempFile fixture("mute_nfm.cu8", make_cu8(kModeRate, secs, {{Mod::kFm, 0, 0.3, 1000, 3000}}, 0.003, 13));
  auto run = [&](float volume, uint32_t muted, const char* tag) {
    TempFile wav(std::string("mute_") + tag + ".wav");
    SdrV3Controls c = controls(kLo, 0, kModeRate, SDR_V3_NFM, 12500);
    c.volume = volume;
    c.muted = muted;
    return demod_fixture(fixture, kModeRate, pairs, c, display(0, kModeRate, 256), wav.path);
  };
  DemodRun muted = run(1, 1, "muted");
  DemodRun zero = run(0, 0, "vol0");
  DemodRun half = run(0.5f, 0, "vol05");
  DemodRun full = run(1, 0, "vol1");
  // Muted/zero volume: sink still receives frames (clock continuity) but all silent.
  CHECK(muted.snap.audio_frames > 40000, "muted run produced %llu frames", (unsigned long long)muted.snap.audio_frames);
  CHECK(muted.snap.audio_nonsilent_frames == 0, "muted: %llu non-silent frames",
        (unsigned long long)muted.snap.audio_nonsilent_frames);
  CHECK(zero.snap.audio_nonsilent_frames == 0, "volume 0: %llu non-silent frames",
        (unsigned long long)zero.snap.audio_nonsilent_frames);
  CHECK(full.snap.audio_nonsilent_frames > 40000, "unmuted: %llu non-silent", (unsigned long long)full.snap.audio_nonsilent_frames);
  // Volume law volume^2: 0.5 -> -12.04 dB.
  if (half.ok && full.ok) {
    const double ratio_db = 20 * std::log10(tone_of(half.wav.left, 48000).rms / tone_of(full.wav.left, 48000).rms);
    R.metric("volume_0.5_gain_db", ratio_db);
    CHECK(std::fabs(ratio_db + 12.04) <= 1.0, "volume 0.5 gain %.2f dB, expected -12.04 (volume^2)", ratio_db);
  }
  // Live unmute on a running stream: same generation, audio becomes non-silent.
  Handle hd;
  SdrHandle* h = hd.h;
  CHECK_RC(open_fixture(h, fixture, kModeRate), SDR_OK);
  SdrV3Controls c = controls(kLo, 0, kModeRate, SDR_V3_NFM, 12500);
  c.muted = 1;
  CHECK_RC(A.set_controls(h, &c), SDR_OK);
  CHECK_RC(set_sink(h, "null"), SDR_OK);
  CHECK_RC(A.start(h), SDR_OK);
  sleep_ms(300);
  const SdrV3Snapshot m = snap(h);
  CHECK(m.audio_nonsilent_frames == 0, "muted stream non-silent %llu", (unsigned long long)m.audio_nonsilent_frames);
  c.muted = 0;
  CHECK_RC(A.set_controls(h, &c), SDR_OK);
  sleep_ms(300);
  const SdrV3Snapshot u = snap(h);
  CHECK(u.stream_generation == m.stream_generation, "unmute restarted the stream");
  CHECK(u.audio_nonsilent_frames > 4800, "unmute: %llu non-silent frames in 300 ms",
        (unsigned long long)u.audio_nonsilent_frames);
  CHECK_RC(A.stop(h), SDR_OK);
}

void case_squelch() {
  const double secs = 1.0;
  const uint64_t pairs = static_cast<uint64_t>(secs * kModeRate);
  TempFile noise("sq_noise.cu8", make_cu8(kModeRate, secs, {}, 0.003, 17));
  TempFile signal("sq_signal.cu8", make_cu8(kModeRate, secs, {{Mod::kFm, 0, 0.3, 1000, 3000}}, 0.003, 19));
  for (uint32_t sq : {SDR_V3_SQUELCH_MANUAL, SDR_V3_SQUELCH_AUTO}) {
    const char* tag = sq == SDR_V3_SQUELCH_MANUAL ? "manual" : "auto";
    SdrV3Controls c = controls(kLo, 0, kModeRate, SDR_V3_NFM, 12500);
    c.squelch = sq;
    c.squelch_level_db = -30;
    TempFile w1(std::string("sq_noise_") + tag + ".wav"), w2(std::string("sq_sig_") + tag + ".wav");
    DemodRun closed = demod_fixture(noise, kModeRate, pairs, c, display(0, kModeRate, 256), w1.path);
    DemodRun open = demod_fixture(signal, kModeRate, pairs, c, display(0, kModeRate, 256), w2.path);
    R.metric(std::string(tag) + "_noise_nonsilent", closed.snap.audio_nonsilent_frames);
    R.metric(std::string(tag) + "_signal_nonsilent", open.snap.audio_nonsilent_frames);
    // Closed squelch: at most one 5 ms ramp of residual audio.
    CHECK(closed.snap.audio_nonsilent_frames <= 480, "%s: noise passed %llu non-silent frames", tag,
          (unsigned long long)closed.snap.audio_nonsilent_frames);
    CHECK(open.snap.audio_nonsilent_frames >= 36000, "%s: signal gated: %llu non-silent frames", tag,
          (unsigned long long)open.snap.audio_nonsilent_frames);
    CHECK(open.snap.squelch_ready == 0, "%s: squelch_ready must reset after stop", tag);
    if (open.ok) {
      const Tone t = tone_of(open.wav.left, 48000);
      CHECK(std::fabs(t.hz - 1000) <= kToneTolHz, "%s: open tone %.1f", tag, t.hz);
    }
  }
}

void case_scan_simulation() {
  // ChannelScanner visits saved channels on the one receiver. Within the band it
  // is a VFO move; out of band it is an LO retune + restart. Readiness must reset
  // on each tune so dwell never sees stale squelch status.
  const double secs = 6.0;
  const uint32_t rate = kModeRate;
  TempFile fixture("scan.cu8",
                   make_cu8(rate, secs, {{Mod::kFm, -200000, 0.3, 1000, 3000}, {Mod::kFm, 150000, 0.3, 1000, 3000}},
                            0.003, 23));
  Handle hd;
  SdrHandle* h = hd.h;
  CHECK_RC(open_fixture(h, fixture, rate), SDR_OK);
  SdrV3Controls c = controls(kLo, -200000, rate, SDR_V3_NFM, 12500);
  c.squelch = SDR_V3_SQUELCH_AUTO;
  CHECK_RC(A.set_controls(h, &c), SDR_OK);
  CHECK_RC(set_sink(h, "null"), SDR_OK);
  CHECK_RC(A.start(h), SDR_OK);
  struct Step { uint64_t lo; int64_t off; bool carrier; };
  const Step steps[] = {{kLo, -200000, true}, {kLo, -50000, false}, {kLo, 150000, true}, {kLo, 300000, false},
                        {kLo + 1000000, 0, false}, {kLo, -200000, true}};
  for (const auto& s : steps) {
    const SdrV3Snapshot b = snap(h);
    c.center_frequency_hz = s.lo;
    c.vfo_offset_hz = s.off;
    const int32_t rc = A.set_controls(h, &c);
    CHECK(rc == SDR_OK, "tune rc=%d", rc);
    const SdrV3Snapshot a = snap(h);
    CHECK(a.squelch_ready == 0, "step lo=%llu off=%lld: squelch_ready not cleared on tune",
          (unsigned long long)s.lo, (long long)s.off);
    if (s.lo != b.center_frequency_hz)
      CHECK(a.stream_generation == b.stream_generation + 1, "LO step did not restart");
    // Dwell (scanner default dwell is a few hundred ms).
    SdrV3Snapshot d{};
    const auto t0 = Clock::now();
    while (seconds_since(t0) < 0.8) {
      d = snap(h);
      if (d.squelch_ready && seconds_since(t0) > 0.4) break;
      sleep_ms(20);
    }
    CHECK(d.squelch_ready == 1, "lo=%llu off=%lld: auto squelch not ready within dwell",
          (unsigned long long)s.lo, (long long)s.off);
    // The file content does not move with LO; carrier presence is defined by offset only.
    const bool expect_open = s.carrier && s.lo == kLo;
    CHECK(d.squelch_open == (expect_open ? 1u : 0u), "lo=%llu off=%lld: squelch_open=%u expected %d",
          (unsigned long long)s.lo, (long long)s.off, d.squelch_open, expect_open);
  }
  CHECK_RC(A.stop(h), SDR_OK);
}

void case_lifecycle_restart() {
  Handle hd;
  SdrHandle* h = hd.h;
  const uint32_t rate = 2400000;
  CHECK_RC(A.open_synthetic(h, rate), SDR_OK);
  CHECK_RC(setc(h, controls(kLo, 0, rate, SDR_V3_WFM, 150000)), SDR_OK);
  CHECK_RC(setd(h, display(0, rate, 512)), SDR_OK);
  CHECK_RC(set_sink(h, "null"), SDR_OK);
  // Warm one cycle so lazy allocations are excluded from the leak baseline.
  CHECK_RC(A.start(h), SDR_OK);
  sleep_ms(150);
  CHECK_RC(A.stop(h), SDR_OK);
  const long fds0 = fd_count(), thr0 = thread_count(), rss0 = rss_kib();
  uint64_t last_seq = 0, last_frames = snap(h).audio_frames, last_input = snap(h).input_samples;
  const int cycles = 20;
  for (int i = 0; i < cycles; ++i) {
    CHECK_RC(A.start(h), SDR_OK);
    CHECK_RC(A.start(h), SDR_INVALID_STATE);
    CHECK_RC(set_sink(h, "null"), SDR_INVALID_STATE);  // sink selection only in OPEN
    sleep_ms(120);
    Row r = read_row(h, last_seq);
    const SdrV3Snapshot s = snap(h);
    CHECK(s.state == SDR_RUNNING && s.stream_generation == uint64_t(i + 2), "cycle %d gen %llu", i,
          (unsigned long long)s.stream_generation);
    if (r.rc == SDR_OK) {
      CHECK(r.meta.stream_generation == s.stream_generation, "cycle %d: stale-generation row", i);
      last_seq = r.meta.sequence;
    }
    CHECK_RC(A.stop(h), SDR_OK);
    CHECK_RC(A.stop(h), SDR_INVALID_STATE);
    const SdrV3Snapshot st = snap(h);
    CHECK(st.state == SDR_OPEN, "cycle %d state after stop %u", i, st.state);
    CHECK(st.squelch_ready == 0, "cycle %d squelch_ready after stop", i);
    CHECK(read_row(h, 0).rc == SDR_V3_NO_DATA, "cycle %d: FFT row survived stop", i);
    // Counters are cumulative since open; stop joins and drains.
    CHECK(st.audio_frames >= last_frames && st.input_samples > last_input, "cycle %d counters not cumulative", i);
    CHECK(st.processed_samples + st.dropped_samples == st.input_samples, "cycle %d: stop did not drain", i);
    last_frames = st.audio_frames;
    last_input = st.input_samples;
  }
  const long fds1 = fd_count(), thr1 = thread_count(), rss1 = rss_kib();
  R.metric("fd_delta", fds1 - fds0);
  R.metric("thread_delta", thr1 - thr0);
  R.metric("rss_delta_kib", rss1 - rss0);
  CHECK(fds1 == fds0, "fd leak %ld -> %ld", fds0, fds1);
  CHECK(thr1 == thr0, "thread leak %ld -> %ld", thr0, thr1);
  CHECK(rss1 - rss0 <= 1024, "RSS grew %ld KiB over %d restarts (limit 1024)", rss1 - rss0, cycles);
  // Close while RUNNING tears down synchronously.
  CHECK_RC(A.start(h), SDR_OK);
  sleep_ms(100);
  CHECK_RC(A.close(h), SDR_OK);
  const SdrV3Snapshot closed = snap(h);
  CHECK(closed.state == SDR_IDLE && closed.source == SDR_NONE, "close: state %u source %u", closed.state, closed.source);
  CHECK(read_row(h, 0).rc != SDR_OK, "FFT row readable after close");
  CHECK(thread_count() == thr0, "threads after close %ld (baseline %ld)", thread_count(), thr0);
  // Reopen clears counters; generation restarts per contract ("except generation").
  CHECK_RC(A.open_synthetic(h, rate), SDR_OK);
  const SdrV3Snapshot re = snap(h);
  CHECK(re.input_samples == 0 && re.audio_frames == 0 && re.last_error == 0, "reopen counters not reset");
  // Destroy while RUNNING from a fresh handle.
  {
    SdrHandle* d = A.create();
    CHECK_RC(A.open_synthetic(d, rate), SDR_OK);
    CHECK_RC(setc(d, controls(kLo, 0, rate, SDR_V3_WFM, 150000)), SDR_OK);
    CHECK_RC(set_sink(d, "null"), SDR_OK);
    CHECK_RC(A.start(d), SDR_OK);
    sleep_ms(100);
    A.destroy(d);
  }
  CHECK(thread_count() == thr0, "threads after destroy-while-running %ld", thread_count());
  CHECK(fd_count() == fds0, "fds after destroy-while-running %ld", fd_count());
}

void case_sink_selection() {
  Handle hd;
  SdrHandle* h = hd.h;
  CHECK_RC(A.open_synthetic(h, 240000), SDR_OK);
  CHECK_RC(setc(h, controls(kLo, 0, 240000, SDR_V3_NFM, 12500)), SDR_OK);
  CHECK_RC(set_sink(h, "pulse"), SDR_INVALID_ARGUMENT);
  CHECK(A.set_audio_sink(h, "null", 0) == SDR_INVALID_ARGUMENT, "empty spec accepted");
  CHECK(A.set_audio_sink(h, "nu\0ll", 5) == SDR_INVALID_ARGUMENT, "embedded NUL accepted");
  CHECK(A.set_audio_sink(h, nullptr, 4) == SDR_INVALID_ARGUMENT, "NULL spec accepted");
  const std::string huge = "wav:" + std::string(SDR_V3_MAX_SINK_SPEC_BYTES, 'x');
  CHECK_RC(set_sink(h, huge), SDR_INVALID_ARGUMENT);
  const int32_t aaudio = set_sink(h, "aaudio");
  CHECK(aaudio == SDR_UNSUPPORTED, "aaudio on Linux rc=%d (expected UNSUPPORTED)", aaudio);
  // A sink whose backend fails to open must fail start and leave OPEN.
  CHECK_RC(set_sink(h, "wav:/nonexistent-dir-n2/x.wav"), SDR_OK);
  const uint64_t gen0 = snap(h).stream_generation;
  const int32_t rc = A.start(h);
  CHECK(rc < 0, "start with unwritable WAV rc=%d", rc);
  const SdrV3Snapshot s = snap(h);
  CHECK(s.state == SDR_OPEN, "state after failed start %u", s.state);
  CHECK(s.stream_generation == gen0, "failed start advanced generation");
  CHECK(s.last_error == 0, "synchronous start failure became sticky async error %d", s.last_error);
  if (rc == SDR_OK) A.stop(h);
  // The spec is copied: mutate caller memory after the call.
  char buf[] = "null";
  CHECK_RC(A.set_audio_sink(h, buf, 4), SDR_OK);
  memcpy(buf, "xxxx", 4);
  CHECK_RC(A.start(h), SDR_OK);
  CHECK_RC(A.stop(h), SDR_OK);
}

void case_v2_coexistence() {
  // v2 diagnostic and v3 sessions on separate handles run concurrently; v2 calls
  // never operate on an active v3 session.
  Handle diag, radio;
  CHECK_RC(A.open_synthetic(diag.h, 2400000), SDR_OK);
  CHECK_RC(A.v2_configure(diag.h, kLo, 2400000, 100), SDR_OK);
  CHECK_RC(A.v2_start(diag.h), SDR_OK);
  CHECK_RC(A.open_synthetic(radio.h, 2400000), SDR_OK);
  CHECK_RC(setc(radio.h, controls(kLo, 0, 2400000, SDR_V3_WFM, 150000)), SDR_OK);
  CHECK_RC(set_sink(radio.h, "null"), SDR_OK);
  CHECK_RC(A.start(radio.h), SDR_OK);
  CHECK_RC(A.v2_start(radio.h), SDR_INVALID_STATE);
  CHECK_RC(A.v2_stop(radio.h), SDR_INVALID_STATE);
  CHECK_RC(A.v2_configure(radio.h, kLo, 2400000, 100), SDR_INVALID_STATE);
  // v3 calls against a running v2 diagnostic session are rejected.
  CHECK_RC(setc(diag.h, controls(kLo, 0, 2400000, SDR_V3_WFM, 150000)),
           SDR_INVALID_STATE);
  CHECK_RC(A.start(diag.h), SDR_INVALID_STATE);
  CHECK_RC(A.stop(diag.h), SDR_INVALID_STATE);
  sleep_ms(300);
  SdrStats st{};
  st.size = sizeof st;
  st.revision = 2;
  CHECK_RC(A.v2_stats(diag.h, &st), SDR_OK);
  CHECK(st.state == SDR_RUNNING && st.input_samples > 0, "diag not streaming");
  const SdrV3Snapshot s = snap(radio.h);
  CHECK(s.state == SDR_RUNNING && s.audio_frames > 0, "v3 radio not producing audio");
  // v2 stats on a v3 handle stay readable and consistent.
  SdrStats rs{};
  rs.size = sizeof rs;
  rs.revision = 2;
  CHECK_RC(A.v2_stats(radio.h, &rs), SDR_OK);
  CHECK(rs.state == SDR_RUNNING, "v2 view of v3 session state %u", rs.state);
  CHECK_RC(A.v2_stop(diag.h), SDR_OK);
  CHECK_RC(A.stop(radio.h), SDR_OK);
}

void case_concurrent_polling() {
  // snapshot/read_fft may run concurrently with serialized commands.
  Handle hd;
  SdrHandle* h = hd.h;
  const uint32_t rate = 2400000;
  CHECK_RC(A.open_synthetic(h, rate), SDR_OK);
  SdrV3Controls c = controls(kLo, 0, rate, SDR_V3_NFM, 12500);
  CHECK_RC(A.set_controls(h, &c), SDR_OK);
  CHECK_RC(set_sink(h, "null"), SDR_OK);
  std::atomic<bool> done{false};
  std::atomic<uint64_t> polls{0}, incoherent{0};
  std::thread poller([&] {
    uint64_t seq = 0;
    while (!done) {
      int32_t rc;
      const SdrV3Snapshot s = snap(h, &rc);
      if (rc != SDR_OK || s.state > SDR_ERROR || s.processed_samples + s.dropped_samples > s.input_samples ||
          s.size != sizeof s)
        ++incoherent;
      Row r = read_row(h, seq);
      if (r.rc == SDR_OK) {
        if (r.meta.width != r.bins.size() || r.meta.high_hz <= r.meta.low_hz) ++incoherent;
        seq = r.meta.sequence;
      }
      ++polls;
    }
  });
  for (int i = 0; i < 30; ++i) {
    CHECK_RC(A.start(h), SDR_OK);
    c.vfo_offset_hz = (i % 5) * 100000 - 200000;
    CHECK_RC(A.set_controls(h, &c), SDR_OK);
    SdrV3Display d = display(0, rate / (1 + i % 3), 64 + 32 * (i % 7));
    CHECK_RC(A.set_display(h, &d), SDR_OK);
    c.center_frequency_hz = kLo + (i % 2) * 500000;
    CHECK_RC(A.set_controls(h, &c), SDR_OK);
    sleep_ms(15);
    CHECK_RC(A.stop(h), SDR_OK);
  }
  done = true;
  poller.join();
  R.metric("concurrent_polls", polls);
  CHECK(incoherent == 0, "%llu incoherent snapshots/rows", (unsigned long long)incoherent.load());
  CHECK(polls > 100, "poller made only %llu calls", (unsigned long long)polls.load());
}

void case_detach_sticky_error() {
  // Simulated transport loss: a TCP peer resets the connection mid-stream; the
  // reader sees ECONNRESET, as a disappearing USB fd surfaces ENODEV/EIO.
  const int listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  socklen_t len = sizeof addr;
  CHECK(bind(listener, reinterpret_cast<sockaddr*>(&addr), sizeof addr) == 0 && listen(listener, 1) == 0 &&
            getsockname(listener, reinterpret_cast<sockaddr*>(&addr), &len) == 0,
        "loopback listener");
  const int client = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  CHECK(connect(client, reinterpret_cast<sockaddr*>(&addr), sizeof addr) == 0, "connect");
  const int server = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
  ::close(listener);
  const uint32_t rate = 240000;
  Handle hd;
  SdrHandle* h = hd.h;
  CHECK_RC(A.open_file(h, server, rate), SDR_OK);
  ::close(server);
  CHECK_RC(setc(h, controls(kLo, 0, rate, SDR_V3_NFM, 12500)), SDR_OK);
  CHECK_RC(set_sink(h, "null"), SDR_OK);
  CHECK_RC(A.start(h), SDR_OK);
  const std::vector<uint8_t> block = make_cu8(rate, 0.25, {{Mod::kFm, 0, 0.3, 1000, 3000}}, 0.003, 29);
  CHECK(write(client, block.data(), block.size()) == ssize_t(block.size()), "write fixture to socket");
  sleep_ms(400);
  CHECK(snap(h).input_samples > 0, "no input before detach");
  // Unread data + SO_LINGER{1,0} close => RST => ECONNRESET at the reader.
  CHECK(write(client, block.data(), 4096) == 4096, "write tail");
  linger lg{1, 0};
  setsockopt(client, SOL_SOCKET, SO_LINGER, &lg, sizeof lg);
  ::close(client);
  SdrV3Snapshot s{};
  const auto t0 = Clock::now();
  while (seconds_since(t0) < 2.0) {
    s = snap(h);
    if (s.state == SDR_ERROR) break;
    sleep_ms(20);
  }
  R.metric("detach_to_error_ms", seconds_since(t0) * 1000);
  CHECK(s.state == SDR_ERROR, "state %u after transport reset (expected ERROR)", s.state);
  CHECK(s.last_error == SDR_IO_ERROR || s.last_error == SDR_DEVICE_GONE, "last_error %d", s.last_error);
  CHECK(s.error_sequence >= 1, "error_sequence %llu", (unsigned long long)s.error_sequence);
  CHECK(read_row(h, 0).rc != SDR_OK, "FFT row readable in ERROR");
  SdrV3Controls c = controls(kLo + 1000, 0, rate, SDR_V3_NFM, 12500);
  CHECK_RC(A.set_controls(h, &c), SDR_INVALID_STATE);
  CHECK_RC(A.stop(h), SDR_OK);  // ERROR -> OPEN joins workers
  const SdrV3Snapshot after = snap(h);
  CHECK(after.state == SDR_OPEN, "state after stop %u", after.state);
  CHECK(after.last_error == s.last_error && after.error_sequence == s.error_sequence, "error not sticky across stop");
  CHECK_RC(A.close(h), SDR_OK);
  CHECK_RC(A.open_synthetic(h, rate), SDR_OK);
  const SdrV3Snapshot reopened = snap(h);
  CHECK(reopened.last_error == 0 && reopened.error_sequence == 0, "error not cleared by successful open");
}

void case_file_eof_parity() {
  // Dart FileSource loops at EOF (wavreader.h readSamples) and rewinds on stop.
  // A native file session must not sit RUNNING with frozen input after EOF.
  const uint32_t rate = 240000;
  const double secs = 0.5;
  TempFile fixture("eof.cu8", make_cu8(rate, secs, {{Mod::kFm, 0, 0.3, 1000, 3000}}, 0.003, 31));
  Handle hd;
  SdrHandle* h = hd.h;
  CHECK_RC(open_fixture(h, fixture, rate), SDR_OK);
  CHECK_RC(setc(h, controls(kLo, 0, rate, SDR_V3_NFM, 12500)), SDR_OK);
  CHECK_RC(set_sink(h, "null"), SDR_OK);
  CHECK_RC(A.start(h), SDR_OK);
  sleep_ms(1200);
  const SdrV3Snapshot s = snap(h);
  const uint64_t once = uint64_t(secs * rate);
  R.metric("input_after_2x_duration", s.input_samples);
  const bool loops = s.state == SDR_RUNNING && s.input_samples > once + rate / 4;
  const bool reports_end = s.state != SDR_RUNNING;
  CHECK(loops || reports_end, "after EOF: state RUNNING with input frozen at %llu pairs (Dart loops)",
        (unsigned long long)s.input_samples);
  if (s.state == SDR_RUNNING || s.state == SDR_ERROR) A.stop(h);
  CHECK_RC(A.start(h), SDR_OK);
  sleep_ms(300);
  const SdrV3Snapshot r = snap(h);
  CHECK(r.input_samples > s.input_samples, "restart after EOF produced no input (Dart rewinds on stop)");
  A.stop(h);
}

void case_perf(bool detached) {
  const uint32_t rate = 2400000;
  const double secs = detached ? std::max(3.0, O.perf_seconds / 2) : O.perf_seconds;
  Handle hd;
  SdrHandle* h = hd.h;
  CHECK_RC(A.open_synthetic(h, rate), SDR_OK);
  SdrV3Controls c = controls(kLo, 0, rate, SDR_V3_WFM, 150000);
  CHECK_RC(A.set_controls(h, &c), SDR_OK);
  CHECK_RC(setd(h, display(0, rate, 1024)), SDR_OK);
  CHECK_RC(set_sink(h, "null"), SDR_OK);
  CHECK_RC(A.start(h), SDR_OK);
  sleep_ms(1000);  // warm-up excluded from CPU/RSS
  const SdrV3Snapshot s0 = snap(h);
  const double cpu0 = cpu_seconds();
  const long rss0 = rss_kib();
  const auto t0 = Clock::now();
  uint64_t seq = 0, rows = 0;
  auto next_snap = t0;
  while (seconds_since(t0) < secs) {
    if (!detached) {
      Row r = read_row(h, seq, 1024);
      if (r.rc == SDR_OK) { seq = r.meta.sequence; ++rows; }
      if (Clock::now() >= next_snap) { snap(h); next_snap += std::chrono::milliseconds(200); }
    }
    sleep_ms(33);
  }
  const double wall = seconds_since(t0);
  const double cpu = (cpu_seconds() - cpu0) / wall;
  const SdrV3Snapshot s1 = snap(h);
  const long rss1 = rss_kib();
  CHECK_RC(A.stop(h), SDR_OK);
  const SdrV3Snapshot sf = snap(h);
  const double in_rate = (s1.input_samples - s0.input_samples) / wall;
  const double audio_rate = (s1.audio_frames - s0.audio_frames) / wall;
  R.metric("seconds", wall);
  R.metric("cpu_cores", cpu);
  R.metric("input_rate", in_rate);
  R.metric("audio_rate", audio_rate);
  R.metric("dropped_samples", sf.dropped_samples);
  R.metric("audio_dropped_frames", sf.audio_dropped_frames);
  R.metric("rss_kib", rss1);
  R.metric("rss_growth_kib", rss1 - rss0);
  R.metric("fft_rows_per_s", rows / wall);
  R.metric("fft_overwrites", sf.fft_overwrites);
  CHECK(std::fabs(in_rate - rate) <= 0.01 * rate, "input rate %.0f vs %u", in_rate, rate);
  CHECK(sf.dropped_samples == 0, "%llu IQ ring drops on synthetic 2.4 MS/s",
        (unsigned long long)sf.dropped_samples);
  CHECK(sf.processed_samples + sf.dropped_samples == sf.input_samples, "stop did not drain");
  CHECK(std::fabs(audio_rate - 48000) <= 480, "audio rate %.0f frames/s (48000 +-1%%)", audio_rate);
  CHECK(sf.audio_dropped_frames == 0, "null sink dropped %llu frames", (unsigned long long)sf.audio_dropped_frames);
  CHECK(cpu <= 0.5, "CPU %.3f cores > 0.5 at 2.4 MS/s WFM", cpu);
  CHECK(rss1 <= 64 * 1024, "RSS %ld KiB > 64 MiB", rss1);
  if (detached) {
    // No UI poller: nothing may queue up.
    CHECK(rss1 - rss0 <= 256, "detached RSS grew %ld KiB (limit 256)", rss1 - rss0);
    CHECK(s1.fft_overwrites - s0.fft_overwrites >= uint64_t(15 * wall), "overwrites not counted while detached");
  } else {
    CHECK(rss1 - rss0 <= 1024, "RSS grew %ld KiB over %.0f s (limit 1024)", rss1 - rss0, wall);
    CHECK(rows / wall >= 15 && rows / wall <= 30.5, "UI received %.1f rows/s", rows / wall);
  }
}

int run_suite() {
  std::vector<CaseDef> cases = {
      {"abi_version", "sdr_version()==3 and all seven sdr_v3_* exports present", false, case_abi_version},
      {"struct_validation", "size/revision rejection leaves outputs untouched; state machine guards", true,
       case_struct_validation},
      {"controls_validation", "whole-request validation; rejected controls do not change applied state", true,
       case_controls_validation},
      {"ui_bandwidth_contract", "every RadioController demodParams bandwidth/auto-squelch is accepted", true,
       case_ui_bandwidth_contract},
      {"mode_tones", "WFM/NFM/AM/USB/LSB/CW demod tone, level and 48 kHz audio rate vs analytic oracle", true,
       case_mode_tones},
      {"wfm_mono_lr", "mono WFM identical L/R; stereo MPX parity is an explicit gap", true, case_wfm_stereo_parity},
      {"fft_spectrum", "FFT peak location, low/high metadata, zoomed view", true, case_fft_spectrum},
      {"fft_rate_latest_wins", "<=30 rows/s, NO_DATA/BUFFER_SMALL semantics, overwrite counting", true,
       case_fft_rate_latest_wins},
      {"generation_semantics", "VFO/mode/filter/audio: same generation; LO/rate/gain: restart", true,
       case_generation_semantics},
      {"mute_volume", "mute and volume^2 law; live unmute without restart", true, case_mute_volume},
      {"squelch", "manual and auto squelch gate noise, pass signal; readiness resets", true, case_squelch},
      {"scan_simulation", "sequential scanner on one receiver: readiness reset, open/closed per channel", true,
       case_scan_simulation},
      {"lifecycle_restart", "20x start/stop, close/destroy while running: no fd/thread/RSS leak", true,
       case_lifecycle_restart},
      {"sink_selection", "sink spec validation, copy semantics, failed sink leaves OPEN", true, case_sink_selection},
      {"v2_coexistence", "v2 diagnostic and v3 radio handles coexist; cross-mode calls rejected", true,
       case_v2_coexistence},
      {"concurrent_polling", "snapshot/read_fft concurrent with commands stay coherent", true,
       case_concurrent_polling},
      {"detach_sticky_error", "transport loss -> sticky ERROR across stop; cleared by next open", true,
       case_detach_sticky_error},
      {"file_eof_parity", "file EOF loops or reports end; restart replays (Dart FileSource parity)", true,
       case_file_eof_parity},
      {"perf_2400k_wfm", "2.4 MS/s WFM + 30 Hz FFT: CPU<=0.5 core, 0 drops, 48 kHz, RSS growth<=1 MiB", true,
       [] { case_perf(false); }},
      {"perf_detached_ui", "no UI poller: bounded memory, latest-wins overwrites", true, [] { case_perf(true); }},
  };
  run_cases(cases);
  return finish("suite");
}

// ---------------------------------------------------------------------------
// Hardware acceptance soak (opt-in)
// ---------------------------------------------------------------------------
bool find_rtl(SdrHostUsbDevice* out) {
  if (!A.host_list) return false;
  std::vector<SdrHostUsbDevice> devs(32);
  for (auto& d : devs) d.size = sizeof d;
  uint32_t count = 0;
  if (A.host_list(devs.data(), devs.size(), &count) != SDR_OK) return false;
  for (uint32_t i = 0; i < std::min<uint32_t>(count, devs.size()); ++i)
    if (devs[i].vendor_id == 0x0bda && (devs[i].product_id == 0x2838 || devs[i].product_id == 0x2832)) {
      *out = devs[i];
      return true;
    }
  return false;
}

void case_hw_soak() {
  SdrHostUsbDevice dev{};
  if (!A.host_open) { R.missing("sdr_host_open_usb (Linux host extension)"); return; }
  if (!find_rtl(&dev)) { R.skip("no RTL-SDR (0bda:2838) attached"); return; }
  R.note(format("device %s %s %s", dev.path, dev.manufacturer, dev.product));
  Handle hd;
  SdrHandle* h = hd.h;
  CHECK_RC(A.host_open(h, dev.bus, dev.address, SDR_RTLSDR), SDR_OK);
  // Global claim: a second native handle cannot open the same hardware.
  {
    Handle second;
    const int32_t rc = A.host_open(second.h, dev.bus, dev.address, SDR_RTLSDR);
    CHECK(rc != SDR_OK, "second handle claimed the same USB device");
    R.metric("second_claim_rc", rc);
  }
  const uint32_t rate = 2400000;
  const std::string dir = O.wav_dir.empty() ? g_tmpdir : O.wav_dir;
  const std::string wav = dir + "/n2_hw_wfm.wav";
  SdrV3Controls c = controls(O.hw_freq, 0, rate, SDR_V3_WFM, 150000);
  c.gain_tenths_db = 300;
  CHECK_RC(A.set_controls(h, &c), SDR_OK);
  CHECK_RC(setd(h, display(0, rate, 1024)), SDR_OK);
  CHECK_RC(set_sink(h, "wav:" + wav), SDR_OK);
  CHECK_RC(A.start(h), SDR_OK);
  R.note("WFM WAV: " + wav);
  // Mode plan: each phase is (mode, bw, offset); phases repeat until --seconds.
  struct Phase { const char* name; uint32_t mode, bw; int64_t lo_delta; int32_t gain; };
  const Phase plan[] = {{"wfm", SDR_V3_WFM, 150000, 0, 300},   {"nfm", SDR_V3_NFM, 12500, 0, 300},
                        {"am", SDR_V3_AM, 10000, 0, 300},      {"usb", SDR_V3_USB, 2800, 0, 300},
                        {"lsb", SDR_V3_LSB, 2800, 0, 300},     {"cw", SDR_V3_CW, 200, 0, 300},
                        {"wfm_retune", SDR_V3_WFM, 150000, -1000000, 380}, {"wfm", SDR_V3_WFM, 150000, 0, 300}};
  const double phase_s = std::max(5.0, O.hw_seconds / 24);
  std::map<std::string, uint64_t> nonsilent;
  const double cpu0 = cpu_seconds();
  const long rss_start = rss_kib();
  const auto t0 = Clock::now();
  uint64_t seq = 0, rows = 0;
  size_t p = 0;
  bool restarted = false;
  bool wav_only_first = true;
  SdrV3Snapshot s{};
  while (seconds_since(t0) < O.hw_seconds) {
    const Phase& ph = plan[p++ % (sizeof plan / sizeof plan[0])];
    c.mode = ph.mode;
    c.bandwidth_hz = ph.bw;
    c.center_frequency_hz = O.hw_freq + ph.lo_delta;
    c.gain_tenths_db = ph.gain;
    const int32_t rc = A.set_controls(h, &c);
    CHECK(rc == SDR_OK, "phase %s set_controls rc=%d", ph.name, rc);
    const uint64_t ns0 = snap(h).audio_nonsilent_frames;
    const auto pt = Clock::now();
    while (seconds_since(pt) < phase_s && seconds_since(t0) < O.hw_seconds) {
      Row r = read_row(h, seq, 1024);
      if (r.rc == SDR_OK) { seq = r.meta.sequence; ++rows; }
      s = snap(h);
      if (s.state != SDR_RUNNING) break;
      sleep_ms(33);
    }
    nonsilent[ph.name] += snap(h).audio_nonsilent_frames - ns0;
    CHECK(s.state == SDR_RUNNING, "phase %s: state %u err %d", ph.name, s.state, s.last_error);
    if (s.state != SDR_RUNNING) break;
    // One stop/restart halfway through (switches the WAV to null after the first WFM cut).
    if (!restarted && seconds_since(t0) > O.hw_seconds / 2) {
      CHECK_RC(A.stop(h), SDR_OK);
      if (wav_only_first) CHECK_RC(set_sink(h, "null"), SDR_OK);
      wav_only_first = false;
      CHECK_RC(A.start(h), SDR_OK);
      restarted = true;
    }
  }
  const double wall = seconds_since(t0);
  const double cpu = (cpu_seconds() - cpu0) / wall;
  CHECK_RC(A.stop(h), SDR_OK);
  const SdrV3Snapshot f = snap(h);
  CHECK_RC(A.close(h), SDR_OK);
  const double in_rate = f.input_samples / wall;
  const double drop_ratio = f.input_samples ? double(f.dropped_samples) / f.input_samples : 1;
  R.metric("seconds", wall);
  R.metric("input_samples", f.input_samples);
  R.metric("input_rate", in_rate);
  R.metric("dropped_samples", f.dropped_samples);
  R.metric("drop_ratio", drop_ratio);
  R.metric("audio_frames", f.audio_frames);
  R.metric("audio_nonsilent_frames", f.audio_nonsilent_frames);
  R.metric("audio_dropped_frames", f.audio_dropped_frames);
  R.metric("fft_rows_per_s", rows / wall);
  R.metric("cpu_cores", cpu);
  R.metric("rss_growth_kib", rss_kib() - rss_start);
  R.metric("generations", f.stream_generation);
  for (const auto& kv : nonsilent) {
    R.metric("nonsilent_" + kv.first, kv.second);
    CHECK(kv.second > 0, "mode %s produced no non-silent audio", kv.first.c_str());
  }
  CHECK(restarted || O.hw_seconds < 20, "stop/restart not exercised");
  CHECK(f.last_error == 0, "async error %d during soak", f.last_error);
  CHECK(std::fabs(in_rate - rate) <= 0.02 * rate, "average input %.0f S/s vs %u (incl. retune gaps)", in_rate, rate);
  CHECK(rows / wall >= 15, "FFT rows %.1f/s", rows / wall);
  CHECK(cpu <= 0.6, "CPU %.3f cores (limit 0.6 incl. libusb)", cpu);
  CHECK(rss_kib() - rss_start <= 2048, "RSS growth %ld KiB", rss_kib() - rss_start);
  // Drops vs rtl_test baseline (bytes lost / 2 = IQ pairs).
  if (O.rtl_lost_bytes >= 0 && O.rtl_seconds > 0) {
    const double rtl_ratio = (O.rtl_lost_bytes / 2) / (rate * O.rtl_seconds);
    R.metric("rtl_test_drop_ratio", rtl_ratio);
    CHECK(drop_ratio <= std::max(2 * rtl_ratio, 1e-6), "native drop ratio %.3g vs rtl_test %.3g", drop_ratio, rtl_ratio);
  } else {
    CHECK(drop_ratio <= 1e-5, "native drop ratio %.3g (no rtl_test baseline supplied)", drop_ratio);
  }
  Wav w = read_wav(wav);
  CHECK(w.ok && w.left.size() > 48000 * 3, "WFM WAV %s: %zu frames", wav.c_str(), w.left.size());
}

void case_hw_detach() {
  // Simulated hot-unplug: USBDEVFS_RESET from a second usbfs fd re-enumerates the
  // device under the running session. The kernel may refuse (EBUSY/EACCES) while
  // another fd holds a claimed interface; that is reported as SKIP.
  SdrHostUsbDevice dev{};
  if (!A.host_open) { R.missing("sdr_host_open_usb"); return; }
  if (!find_rtl(&dev)) { R.skip("no RTL-SDR attached"); return; }
  Handle hd;
  SdrHandle* h = hd.h;
  CHECK_RC(A.host_open(h, dev.bus, dev.address, SDR_RTLSDR), SDR_OK);
  SdrV3Controls c = controls(O.hw_freq, 0, 2400000, SDR_V3_WFM, 150000);
  CHECK_RC(A.set_controls(h, &c), SDR_OK);
  CHECK_RC(set_sink(h, "null"), SDR_OK);
  CHECK_RC(A.start(h), SDR_OK);
  sleep_ms(1000);
  const int fd = ::open(dev.path, O_RDWR | O_CLOEXEC);
  if (fd < 0) { R.skip(format("open %s: %s", dev.path, strerror(errno))); A.stop(h); return; }
  const int rc = ioctl(fd, USBDEVFS_RESET, 0);
  const int err = errno;
  ::close(fd);
  if (rc != 0) { R.skip(format("USBDEVFS_RESET refused: %s", strerror(err))); A.stop(h); return; }
  SdrV3Snapshot s{};
  const auto t0 = Clock::now();
  while (seconds_since(t0) < 3) {
    s = snap(h);
    if (s.state == SDR_ERROR) break;
    sleep_ms(20);
  }
  R.metric("reset_to_error_ms", seconds_since(t0) * 1000);
  // A reset may either be survived (stream continues) or surface a sticky error.
  if (s.state == SDR_ERROR) {
    CHECK(s.last_error == SDR_DEVICE_GONE || s.last_error == SDR_IO_ERROR, "last_error %d", s.last_error);
    CHECK_RC(A.stop(h), SDR_OK);
    CHECK(snap(h).last_error == s.last_error, "error not sticky after stop");
  } else {
    const uint64_t in0 = snap(h).input_samples;
    sleep_ms(500);
    CHECK(snap(h).input_samples > in0, "RUNNING after reset but input frozen (zombie session)");
    A.stop(h);
  }
  CHECK_RC(A.close(h), SDR_OK);
  sleep_ms(1500);
  SdrHostUsbDevice again{};
  CHECK(find_rtl(&again), "device did not re-enumerate after reset");
}

int run_hw() {
  std::vector<CaseDef> cases = {
      {"hw_soak", "Blog V4 2.4 MS/s soak: modes, retune/gain, stop/restart, drops vs rtl_test, WAV", true,
       case_hw_soak},
      {"hw_detach_reset", "USB reset under a running session: sticky error or survived, no zombie", true,
       case_hw_detach},
  };
  run_cases(cases);
  return finish("hw");
}

// ---------------------------------------------------------------------------
// demod-file: one fixture -> WAV + JSON for the Dart parity test
// ---------------------------------------------------------------------------
int run_demod_file() {
  R.results.push_back(CaseResult{});
  R.cur = &R.results.back();
  R.cur->name = "demod_file";
  if (!v3_gate(true)) return finish("demod-file");
  FILE* f = fopen(O.file.c_str(), "rb");
  if (!f) { R.fail(__LINE__, "cannot open " + O.file); return finish("demod-file"); }
  fseek(f, 0, SEEK_END);
  const uint64_t pairs = ftell(f) / 2;
  fclose(f);
  const TempFile fixture = TempFile::borrow(O.file);
  const uint32_t view_bw = O.view_bw ? O.view_bw : O.rate;
  DemodRun r = demod_fixture(fixture, O.rate, pairs, controls(O.lo, O.offset, O.rate, O.mode, O.bw),
                             display(O.view_offset, view_bw, O.fft_width), O.wav);
  R.metric("input_samples", r.snap.input_samples);
  R.metric("processed_samples", r.snap.processed_samples);
  R.metric("dropped_samples", r.snap.dropped_samples);
  R.metric("audio_frames", r.snap.audio_frames);
  R.metric("audio_nonsilent_frames", r.snap.audio_nonsilent_frames);
  R.metric("wall_seconds", r.wall);
  if (r.ok) {
    const Tone l = tone_of(r.wav.left, r.wav.rate ? r.wav.rate : 48000);
    R.metric("wav_rate", r.wav.rate);
    R.metric("wav_frames", r.wav.left.size());
    R.metric("left_tone_hz", l.hz);
    R.metric("left_rms", l.rms);
    R.metric("left_peak_db", l.peak_db);
  }
  CHECK(r.ok, "WAV not written");
  CHECK(r.row.rc == SDR_OK, "no FFT row");
  for (const auto& m : R.cur->metrics) std::printf("  %s = %.9g\n", m.first.c_str(), m.second);
  for (const auto& n : R.cur->notes) std::printf("  %s\n", n.c_str());
  int rc = finish("demod-file");
  if (!O.json.empty() && r.row.rc == SDR_OK) {
    // Append the FFT row as a sibling file for simple parsing.
    std::ofstream out(O.json + ".fft.json");
    out << "{\"low_hz\":" << r.row.meta.low_hz << ",\"high_hz\":" << r.row.meta.high_hz
        << ",\"width\":" << r.row.meta.width << ",\"bins\":[";
    for (size_t i = 0; i < r.row.bins.size(); ++i) out << (i ? "," : "") << format("%.3f", r.row.bins[i]);
    out << "]}\n";
  }
  return rc;
}

int usage() {
  std::fprintf(stderr,
               "usage: n2_oracle {suite|hw|demod-file} --lib <libsdrcore.so> [options]\n"
               "       n2_oracle gen --fixture {modes|carrier|noise} --rate R --seconds S --file out.cu8\n"
               "  see the header of native/tests/n2/n2_oracle.cpp\n");
  return 3;
}

// Writes a deterministic CU8 fixture so that the Dart reference path and the
// native library consume byte-identical IQ (test/n2_oracle/native_parity_test.dart).
int run_gen() {
  if (O.file.empty() || !O.rate || O.gen_seconds <= 0) return usage();
  std::vector<Carrier> carriers;
  double noise = 0.003;
  if (O.fixture == "modes") carriers = mode_carriers();
  else if (O.fixture == "carrier") { carriers.push_back({Mod::kCarrier, 200500, 0.25}); noise = 0.01; }
  else if (O.fixture == "noise") carriers.clear();
  else return usage();
  const std::vector<uint8_t> bytes = make_cu8(O.rate, O.gen_seconds, carriers, noise, 7);
  FILE* f = fopen(O.file.c_str(), "wb");
  if (!f || fwrite(bytes.data(), 1, bytes.size(), f) != bytes.size()) return 3;
  fclose(f);
  std::printf("wrote %zu IQ pairs to %s\n", bytes.size() / 2, O.file.c_str());
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) return usage();
  const std::string cmd = argv[1];
  for (int i = 2; i < argc; ++i) {
    const std::string a = argv[i];
    auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : ""; };
    if (a == "--lib") O.lib = next();
    else if (a == "--json") O.json = next();
    else if (a == "--only") O.only = next();
    else if (a == "--allow-version-2") O.allow_v2 = true;
    else if (a == "--keep-fixtures") O.keep = true;
    else if (a == "--perf-seconds") O.perf_seconds = std::atof(next().c_str());
    else if (a == "--seconds" && cmd == "gen") O.gen_seconds = std::atof(next().c_str());
    else if (a == "--seconds") O.hw_seconds = std::atof(next().c_str());
    else if (a == "--freq") O.hw_freq = std::strtoull(next().c_str(), nullptr, 10);
    else if (a == "--wav-dir") O.wav_dir = next();
    else if (a == "--rtl-lost-bytes") O.rtl_lost_bytes = std::atof(next().c_str());
    else if (a == "--rtl-seconds") O.rtl_seconds = std::atof(next().c_str());
    else if (a == "--file") O.file = next();
    else if (a == "--wav") O.wav = next();
    else if (a == "--rate") O.rate = std::strtoul(next().c_str(), nullptr, 10);
    else if (a == "--lo") O.lo = std::strtoull(next().c_str(), nullptr, 10);
    else if (a == "--offset") O.offset = std::strtoll(next().c_str(), nullptr, 10);
    else if (a == "--mode") O.mode = std::strtoul(next().c_str(), nullptr, 10);
    else if (a == "--bw") O.bw = std::strtoul(next().c_str(), nullptr, 10);
    else if (a == "--fft-width") O.fft_width = std::strtoul(next().c_str(), nullptr, 10);
    else if (a == "--view-offset") O.view_offset = std::strtoll(next().c_str(), nullptr, 10);
    else if (a == "--view-bw") O.view_bw = std::strtoul(next().c_str(), nullptr, 10);
    else if (a == "--fixture") O.fixture = next();
    else return usage();
  }
  const char* tmp = std::getenv("TMPDIR");
  g_tmpdir = tmp && *tmp ? tmp : "/tmp";
  if (cmd == "gen") return run_gen();
  if (O.lib.empty()) return usage();
  std::string error;
  if (!A.load(O.lib, &error)) {
    std::fprintf(stderr, "cannot load %s: %s\n", O.lib.c_str(), error.c_str());
    return 3;
  }
  if (!A.missing_v2.empty()) {
    std::fprintf(stderr, "library lacks ABI-2 symbols; not an sdrcore build\n");
    return 3;
  }
  std::printf("library %s: sdr_version()=%u, v3 symbols %s\n", O.lib.c_str(), A.version(),
              A.missing_v3.empty() ? "present" : "MISSING");
  if (cmd == "suite") return run_suite();
  if (cmd == "hw") return run_hw();
  if (cmd == "demod-file") {
    if (O.file.empty() || O.wav.empty() || !O.rate || !O.bw) return usage();
    return run_demod_file();
  }
  return usage();
}
