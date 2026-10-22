// SPDX-License-Identifier: GPL-3.0-or-later
#include "recorder.h"
#include "sdrcore_decoder_v1.h"
#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <iomanip>
#include <map>
#include <sstream>
#include <utility>
#include <nlohmann/json.hpp>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace sdrcore::record {
namespace {
constexpr size_t kIqBudget = 8u * 1024 * 1024;
constexpr size_t kAudioBudget = 2u * 1024 * 1024;
constexpr size_t kLogBudget = 1024 * 1024;
constexpr size_t kLogLineMax = 16 * 1024;
// Persist only known metadata for packet decoders. Never serialize packet
// bodies, addresses, channel names, keys or arbitrary future schema fields.
nlohmann::json safe_payload(const std::string& id, const nlohmann::json& input) {
  nlohmann::json result = nlohmann::json::object();
  auto copy = [&](const nlohmann::json& source, nlohmann::json& target,
                  std::initializer_list<const char*> names) {
    for (const char* name : names) {
      auto it = source.find(name);
      if (it != source.end() && (it->is_string() || it->is_number() || it->is_boolean()))
        target[name] = *it;
    }
  };
  if (id == "meshtastic" || id == "meshcore") {
    copy(input, result, {"mode", "schema", "protocol", "length", "timestamp_utc"});
    auto phy = input.find("phy");
    if (phy != input.end() && phy->is_object()) {
      nlohmann::json fields = nlohmann::json::object();
      copy(*phy, fields, {"snr", "snr_db", "level", "level_db", "bw", "bw_khz",
                          "sf", "cr", "crc", "fec", "duration_ms", "frequency_hz"});
      result["phy"] = std::move(fields);
    }
  } else if (id == "rds") {
    copy(input, result, {"source", "version", "event", "frequency_hz", "rbds", "sync", "reason"});
    auto fields = input.find("fields");
    if (fields != input.end() && fields->is_object()) {
      nlohmann::json safe = nlohmann::json::object();
      copy(*fields, safe, {"pi", "ps", "pty", "pty_name", "rt", "radiotext", "tp", "ta"});
      result["fields"] = std::move(safe);
    }
  } else if (id == "sstv") {
    copy(input, result, {"source", "version", "frame_id", "vis", "sstv_mode", "width", "height",
                         "timestamp_utc", "frequency_hz", "underlying", "row", "phase", "line",
                         "pixels_bgr_base64", "padded", "received_lines", "padded_lines",
                         "status", "reason"});
  } else if (id == "adsb") {
    copy(input, result, {"icao", "last_seen_ms", "messages", "rssi", "callsign", "squawk",
                         "altitude_ft", "ground_speed_kt", "track_deg", "vertical_rate_fpm",
                         "latitude", "longitude"});
  } else if (id == "dmr") {
    copy(input, result, {"schema", "protocol", "slot", "voice", "sync", "type", "color_code",
                         "duration_ms"});
  } else if (id == "rtl_433") {
    copy(input, result, {"model", "type", "time", "temperature_C", "humidity", "battery_ok",
                         "pressure_hPa", "wind_avg_km_h", "wind_dir_deg", "rain_mm"});
  }
  return result;
}
// Maximum even-sized data chunk while RIFF size (36 + data size) fits uint32.
constexpr uint64_t kWavDataMax = UINT32_MAX - 36u - ((UINT32_MAX - 36u) % 4u);
struct Provider { SdrRecordCreateFile fn; void* context; };
std::mutex& provider_mutex() { static std::mutex m; return m; }
std::map<std::string, Provider>& providers() {
  static std::map<std::string, Provider> p;
  return p;
}
int close_fd(int fd) {
#ifdef _WIN32
  return _close(fd);
#else
  return ::close(fd);
#endif
}
int64_t seek_fd(int fd, int64_t offset, int whence) {
#ifdef _WIN32
  return _lseeki64(fd, offset, whence);
#else
  return ::lseek(fd, offset, whence);
#endif
}
int write_fd(int fd, const void* bytes, size_t size) {
#ifdef _WIN32
  return _write(fd, bytes, static_cast<unsigned>(std::min<size_t>(size, 1u << 30)));
#else
  return static_cast<int>(::write(fd, bytes, std::min<size_t>(size, 1u << 30)));
#endif
}
int32_t error_code(int e) {
  if (e == ENOSPC || e == EFBIG
#ifdef EDQUOT
      || e == EDQUOT
#endif
      ) return SDR_RECORD_NO_SPACE;
  if (e == ENOENT || e == ENOTDIR || e == EACCES || e == EPERM || e == EROFS)
    return SDR_RECORD_FOLDER_UNAVAILABLE;
  if (e == ESPIPE) return SDR_RECORD_NOT_SEEKABLE;
  if (e == EEXIST) return SDR_RECORD_EXISTS;
  return SDR_IO_ERROR;
}
int32_t create_file(const std::string& folder, const std::string& name,
                    const char* mime, int* fd) {
  if (folder.compare(0, 5, "file:") == 0) {
    try {
      std::filesystem::path dir = std::filesystem::u8path(folder.substr(5));
      if (!dir.is_absolute()) return SDR_RECORD_FOLDER_UNAVAILABLE;
      const auto path = dir / std::filesystem::u8path(name);
#ifdef _WIN32
      *fd = _wopen(path.c_str(), _O_CREAT | _O_EXCL | _O_RDWR | _O_BINARY,
                   _S_IREAD | _S_IWRITE);
#else
      *fd = ::open(path.c_str(), O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0644);
#endif
      return *fd < 0 ? error_code(errno) : SDR_OK;
    } catch (const std::filesystem::filesystem_error&) {
      return SDR_RECORD_FOLDER_UNAVAILABLE;
    }
  }
  auto colon = folder.find(':');
  if (colon == std::string::npos) return SDR_UNSUPPORTED;
  std::lock_guard<std::mutex> guard(provider_mutex());
  const auto it = providers().find(folder.substr(0, colon));
  if (it == providers().end()) return SDR_UNSUPPORTED;
  int32_t out = -1;
  int32_t result = SDR_INTERNAL_ERROR;
  try {
    result = it->second.fn(it->second.context, folder.c_str(),
                            static_cast<uint32_t>(folder.size()), name.c_str(),
                            static_cast<uint32_t>(name.size()), mime, &out);
  } catch (...) {
    if (out >= 0) close_fd(out);
    return SDR_INTERNAL_ERROR;
  }
  if (result != SDR_OK) {
    if (out >= 0) close_fd(out);
    return result;
  }
  if (out < 0) return SDR_IO_ERROR;
  *fd = out;
  return SDR_OK;
}
void put16(uint8_t* p, uint16_t n) { p[0] = uint8_t(n); p[1] = uint8_t(n >> 8); }
void put32(uint8_t* p, uint32_t n) {
  for (int i = 0; i < 4; ++i) p[i] = uint8_t(n >> (i * 8));
}
std::array<uint8_t, 44> wav_header(uint32_t channels, uint32_t bytes) {
  std::array<uint8_t, 44> b{};
  std::memcpy(b.data(), "RIFF", 4); put32(b.data() + 4, bytes + 36);
  std::memcpy(b.data() + 8, "WAVEfmt ", 8); put32(b.data() + 16, 16);
  put16(b.data() + 20, 1); put16(b.data() + 22, static_cast<uint16_t>(channels));
  put32(b.data() + 24, 48000); put32(b.data() + 28, 48000 * channels * 2);
  put16(b.data() + 32, static_cast<uint16_t>(channels * 2)); put16(b.data() + 34, 16);
  std::memcpy(b.data() + 36, "data", 4); put32(b.data() + 40, bytes);
  return b;
}
std::tm utc_tm(time_t seconds) {
  std::tm t{};
#ifdef _WIN32
  gmtime_s(&t, &seconds);
#else
  gmtime_r(&seconds, &t);
#endif
  return t;
}
int64_t wall_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::system_clock::now().time_since_epoch()).count();
}
std::string iso_time(int64_t ms) {
  auto t = utc_tm(static_cast<time_t>(ms / 1000));
  char buf[40];
  std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S", &t);
  char fraction[8];
  std::snprintf(fraction, sizeof(fraction), ".%03dZ",
                static_cast<int>((ms % 1000 + 1000) % 1000));
  return std::string(buf) + fraction;
}
std::string safe_mode(const std::string& value) {
  std::string out;
  for (unsigned char c : value) {
    if (out.size() == 20) break;
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || c == '-') out += static_cast<char>(c);
  }
  return out.empty() ? "UNKNOWN" : out;
}
} // namespace

int32_t set_provider(const char* scheme, uint32_t bytes,
                     SdrRecordCreateFile fn, void* context) {
  if (!scheme || bytes < 1 || bytes > 16 || scheme[0] < 'a' || scheme[0] > 'z')
    return SDR_INVALID_ARGUMENT;
  for (uint32_t i = 1; i < bytes; ++i) {
    char c = scheme[i];
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
          c == '+' || c == '.' || c == '-')) return SDR_INVALID_ARGUMENT;
  }
  std::string key(scheme, bytes);
  if (key == "file") return SDR_UNSUPPORTED;
  std::lock_guard<std::mutex> lock(provider_mutex());
  if (fn) providers()[key] = {fn, context};
  else providers().erase(key);
  return SDR_OK;
}
bool supports_folder(const std::string& folder) {
  auto colon = folder.find(':');
  if (colon == std::string::npos || colon == folder.size() - 1) return false;
  if (folder.compare(0, 5, "file:") == 0)
    return std::filesystem::u8path(folder.substr(5)).is_absolute();
  std::lock_guard<std::mutex> lock(provider_mutex());
  return providers().count(folder.substr(0, colon)) != 0;
}

Recorder::Recorder() {
  status_.size = sizeof(status_); status_.revision = SDR_RECORD_REVISION;
  status_.state = SDR_RECORD_IDLE;
}
Recorder::~Recorder() {
  stop(SDR_RECORD_STOP_RECEIVER);
  set_notify(nullptr, nullptr);
}
uint64_t Recorder::elapsed(const std::chrono::steady_clock::time_point& start) {
  return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start).count());
}
int32_t Recorder::start(const SdrRecordConfig& c, const std::string& folder,
                        const std::string& log_ids) {
  if (c.size != sizeof(c) || c.revision != SDR_RECORD_REVISION ||
      !c.streams || (c.streams & ~uint32_t(SDR_RECORD_STREAM_MASK)) ||
      ((c.streams & (SDR_RECORD_AUDIO | SDR_RECORD_SQUELCH_AUDIO))
           ? (c.audio_format < SDR_RECORD_WAV || c.audio_format > SDR_RECORD_OPUS)
           : (c.audio_format != SDR_RECORD_FORMAT_NONE || c.audio_bitrate_kbps)) ||
      ((c.audio_format == SDR_RECORD_WAV || c.audio_format == SDR_RECORD_FLAC) && c.audio_bitrate_kbps) ||
      (c.audio_format == SDR_RECORD_MP3 &&
       !(c.audio_bitrate_kbps == 32 || c.audio_bitrate_kbps == 40 ||
         c.audio_bitrate_kbps == 48 || c.audio_bitrate_kbps == 56 ||
         c.audio_bitrate_kbps == 64 || c.audio_bitrate_kbps == 80 ||
         c.audio_bitrate_kbps == 96 || c.audio_bitrate_kbps == 112 ||
         c.audio_bitrate_kbps == 128 || c.audio_bitrate_kbps == 160 ||
         c.audio_bitrate_kbps == 192 || c.audio_bitrate_kbps == 224 ||
         c.audio_bitrate_kbps == 256 || c.audio_bitrate_kbps == 320)) ||
      (c.audio_format == SDR_RECORD_OPUS && (c.audio_bitrate_kbps < 6 || c.audio_bitrate_kbps > 256)) ||
      c.utc_offset_minutes < -840 || c.utc_offset_minutes > 840 ||
      c.start_unix_ms <= 0) return SDR_UNSUPPORTED;
  std::set<std::string> selected;
  if (c.streams & SDR_RECORD_DECODER_LOG) {
    if (log_ids.empty() || log_ids.size() > SDR_RECORD_MAX_LOG_IDS_BYTES) return SDR_INVALID_ARGUMENT;
    size_t begin = 0;
    while (begin < log_ids.size()) {
      const size_t end = log_ids.find(',', begin);
      const std::string id = log_ids.substr(begin, end == std::string::npos ? end : end - begin);
      if (id.empty() || id.size() > 31 ||
          !std::all_of(id.begin(), id.end(), [](char ch) {
            return (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_';
          }) || !selected.insert(id).second || selected.size() > SDR_RECORD_MAX_LOG_IDS)
        return SDR_INVALID_ARGUMENT;
      if (end == std::string::npos) break;
      begin = end + 1;
    }
    if (log_ids.back() == ',') return SDR_INVALID_ARGUMENT;
  } else if (!log_ids.empty()) return SDR_INVALID_ARGUMENT;
  for (uint32_t n : c.reserved) if (n) return SDR_INVALID_ARGUMENT;
  if (folder.empty() || folder.size() > SDR_RECORD_MAX_FOLDER_BYTES ||
      folder.find('\0') != std::string::npos || !supports_folder(folder)) return SDR_UNSUPPORTED;
  std::lock_guard<std::mutex> lock(mutex_);
  if (status_.state == SDR_RECORD_ACTIVE || worker_.joinable()) return SDR_INVALID_STATE;
  uint64_t id = status_.session_id + 1;
  status_ = {};
  status_.size = sizeof(status_); status_.revision = SDR_RECORD_REVISION;
  status_.state = SDR_RECORD_ACTIVE; status_.session_id = id;
  status_.streams = c.streams; status_.audio_format = c.audio_format;
  config_ = c; folder_ = folder; started_ = std::chrono::steady_clock::now();
  stopping_ = false; overflow_ = false; overflow_stream_ = 0;
  iq_queued_ = audio_queued_ = log_queued_ = 0; queue_.clear();
  log_ids_ = std::move(selected); log_files_.clear();
  segment_open_ = false; segment_initialized_ = false; segment_number_ = 0;
  try {
    worker_ = std::thread(&Recorder::run, this);
  } catch (...) {
    status_.state = SDR_RECORD_IDLE;
    status_.streams = status_.audio_format = 0;
    --status_.session_id;
    return SDR_INTERNAL_ERROR;
  }
  return SDR_OK;
}
SdrRecordStatus Recorder::status() const {
  std::lock_guard<std::mutex> lock(mutex_);
  auto snapshot = status_;
  if (snapshot.state == SDR_RECORD_ACTIVE) snapshot.elapsed_ms = elapsed(started_);
  return snapshot;
}
void Recorder::set_notify(SdrRecordNotify fn, void* context) {
  std::lock_guard<std::mutex> callback(callback_mutex_);
  std::lock_guard<std::mutex> lock(mutex_);
  notify_ = fn; notify_context_ = context;
}
void Recorder::notify_final(SdrRecordStatus snapshot) {
  std::lock_guard<std::mutex> callback(callback_mutex_);
  SdrRecordNotify fn;
  void* context;
  { std::lock_guard<std::mutex> lock(mutex_); fn = notify_; context = notify_context_; }
  if (fn) fn(context, &snapshot);
}
int32_t Recorder::stop(uint32_t reason) {
  std::thread worker;
  bool idle;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    idle = status_.state == SDR_RECORD_IDLE;
    if (!idle && status_.state == SDR_RECORD_ACTIVE) {
      stopping_ = true; status_.stop_reason = reason;
      cv_.notify_one();
    }
    if (worker_.joinable()) worker = std::move(worker_);
  }
  if (worker.joinable()) worker.join();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (status_.state == SDR_RECORD_FAILED) status_.state = SDR_RECORD_IDLE;
  }
  return idle ? SDR_INVALID_STATE : SDR_OK;
}
void Recorder::offer_iq(const uint8_t* bytes, size_t size, uint32_t rate,
                        uint64_t frequency, const std::string& mode) {
  if (!bytes || !size || (size & 1) || !rate) return;
  std::lock_guard<std::mutex> lock(mutex_);
  if (status_.state != SDR_RECORD_ACTIVE || !(status_.streams & SDR_RECORD_IQ) || stopping_) return;
  if (size > kIqBudget - iq_queued_) {
    status_.iq_dropped_samples += size / 2;
    overflow_ = true; overflow_stream_ = SDR_RECORD_IQ; cv_.notify_one(); return;
  }
  Item item{};
  item.kind = Kind::iq; item.iq.assign(bytes, bytes + size);
  item.rate = rate; item.frequency = frequency; item.mode = mode;
  item.captured_unix_ms = wall_ms();
  iq_queued_ += size; queue_.push_back(std::move(item)); cv_.notify_one();
}
void Recorder::offer_audio(const float* pcm, size_t frames, uint32_t channels,
                           const std::vector<Edge>& edges, uint64_t frequency,
                           const std::string& mode, bool squelch_open) {
  if (!pcm || !frames || (channels != 1 && channels != 2) ||
      frames > SIZE_MAX / (channels * sizeof(float))) return;
  std::lock_guard<std::mutex> lock(mutex_);
  if (status_.state != SDR_RECORD_ACTIVE || !(status_.streams & (SDR_RECORD_AUDIO | SDR_RECORD_SQUELCH_AUDIO)) || stopping_) return;
  size_t size = frames * channels * sizeof(float);
  if (size > kAudioBudget - audio_queued_) {
    status_.audio_dropped_frames += frames;
    overflow_ = true; overflow_stream_ = status_.streams & SDR_RECORD_AUDIO
        ? SDR_RECORD_AUDIO : SDR_RECORD_SQUELCH_AUDIO;
    cv_.notify_one(); return;
  }
  Item item{};
  item.kind = Kind::audio; item.pcm.assign(pcm, pcm + frames * channels);
  item.edges = edges; item.frames = frames; item.rate = 48000;
  if (!segment_initialized_ && (status_.streams & SDR_RECORD_SQUELCH_AUDIO)) {
    // A new recording can begin while the detector was already open. Its
    // transition list then contains no opening edge in this session.
    const bool initially_open = edges.empty() ? squelch_open :
                                edges.front().frame_offset > 0 && !edges.front().open;
    if (initially_open) item.edges.insert(item.edges.begin(), {0, true});
    segment_initialized_ = true;
  }
  item.channels = channels; item.frequency = frequency; item.mode = mode;
  item.captured_unix_ms = wall_ms();
  audio_queued_ += size; queue_.push_back(std::move(item)); cv_.notify_one();
}
void Recorder::offer_log(const std::string& id, uint32_t kind, uint64_t generation,
                         uint64_t frequency, const std::string& payload,
                         const std::string& mode) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (status_.state != SDR_RECORD_ACTIVE || stopping_ || !log_ids_.count(id)) return;
  if (payload.size() > SDR_DECODER_MAX_PAYLOAD || payload.size() > kLogBudget - log_queued_) {
    ++status_.log_dropped_events;
    // Oversized/invalid events are skipped; a full queue invalidates the
    // session rather than producing a deceptively complete log.
    if (payload.size() <= SDR_DECODER_MAX_PAYLOAD) {
      overflow_ = true; overflow_stream_ = SDR_RECORD_DECODER_LOG; cv_.notify_one();
    }
    return;
  }
  Item item{};
  item.kind = Kind::log; item.id = id; item.payload = payload;
  item.event_kind = kind; item.generation = generation;
  item.frequency = frequency; item.mode = mode; item.captured_unix_ms = wall_ms();
  log_queued_ += payload.size(); queue_.push_back(std::move(item)); cv_.notify_one();
}
void Recorder::fail(int32_t error, uint32_t stream) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!status_.last_error) { status_.last_error = error; status_.error_stream = stream; }
}
int32_t Recorder::create(File& file, const std::string& name, const char* mime,
                         uint32_t stream) {
  if (name.size() > SDR_RECORD_MAX_NAME_BYTES) { fail(SDR_RECORD_NAME_EXHAUSTED, stream); return SDR_RECORD_NAME_EXHAUSTED; }
  int fd = -1;
  int32_t result = create_file(folder_, name, mime, &fd);
  if (result != SDR_OK) { if (result != SDR_RECORD_EXISTS) fail(result, stream); return result; }
  if (seek_fd(fd, 0, SEEK_CUR) < 0 || seek_fd(fd, 0, SEEK_SET) < 0) {
    close_fd(fd); fail(SDR_RECORD_NOT_SEEKABLE, stream); return SDR_RECORD_NOT_SEEKABLE;
  }
  file.fd = fd; file.length = file.data = 0;
  { std::lock_guard<std::mutex> lock(mutex_); ++status_.files_created; }
  return SDR_OK;
}
bool Recorder::write(File& file, const void* bytes, size_t size, uint32_t stream) {
  auto p = static_cast<const uint8_t*>(bytes);
  while (size) {
    const int64_t position = seek_fd(file.fd, 0, SEEK_CUR);
    if (position < 0) { fail(error_code(errno), stream); return false; }
    int n = write_fd(file.fd, p, size);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) { fail(n < 0 ? error_code(errno) : SDR_IO_ERROR, stream); return false; }
    const uint64_t end = static_cast<uint64_t>(position) + static_cast<size_t>(n);
    const uint64_t growth = end > file.length ? end - file.length : 0;
    file.length += growth;
    { std::lock_guard<std::mutex> lock(mutex_); status_.bytes_written += growth; }
    p += n; size -= static_cast<size_t>(n);
  }
  return true;
}
std::string Recorder::stem(uint64_t frequency, const std::string& mode, bool segment) {
  auto ms = wall_ms() + int64_t(config_.utc_offset_minutes) * 60000;
  auto t = utc_tm(static_cast<time_t>(ms / 1000));
  char date[32];
  std::strftime(date, sizeof(date), "AirSDR_%Y-%m-%d_%H-%M-%S", &t);
  std::ostringstream name;
  name << date << '_' << std::fixed << std::setprecision(6)
       << (static_cast<double>(frequency) / 1e6) << '_' << safe_mode(mode);
  if (segment) name << "_sq" << ++segment_number_;
  return name.str();
}
bool Recorder::open_iq(const Item& item) {
  std::string base = stem(item.frequency, item.mode, false);
  for (int suffix = 1; suffix <= 99; ++suffix) {
    std::string candidate = base + (suffix == 1 ? "" : "_" + std::to_string(suffix));
    // For file: preflight the metadata sibling so a collision does not leave
    // an orphaned data file. Providers must enforce atomic exclusive names.
    if (folder_.compare(0, 5, "file:") == 0) {
      std::error_code ec;
      const bool taken = std::filesystem::exists(
          std::filesystem::u8path(folder_.substr(5)) /
              std::filesystem::u8path(candidate + ".sigmf-meta"), ec);
      if (ec) { fail(SDR_RECORD_FOLDER_UNAVAILABLE, SDR_RECORD_IQ); return false; }
      if (taken) continue;
    }
    File f;
    int32_t result = create(f, candidate + ".sigmf-data", "application/octet-stream", SDR_RECORD_IQ);
    if (result == SDR_RECORD_EXISTS) continue;
    if (result != SDR_OK) return false;
    File meta;
    // DocumentsProvider may append ".json" to application/json, changing the
    // requested SigMF sibling name. Keep the exact .sigmf-meta extension.
    result = create(meta, candidate + ".sigmf-meta", "application/octet-stream", SDR_RECORD_IQ);
    if (result != SDR_OK) {
      if (close_fd(f.fd) != 0) fail(error_code(errno), SDR_RECORD_IQ);
      // The fd bridge cannot remove SAF documents. For file: remove the
      // provisional empty data sibling before trying the next suffix.
      if (folder_.compare(0, 5, "file:") == 0) {
        std::error_code ec;
        if (std::filesystem::remove(std::filesystem::u8path(folder_.substr(5)) /
              std::filesystem::u8path(candidate + ".sigmf-data"), ec)) {
          std::lock_guard<std::mutex> lock(mutex_);
          --status_.files_created;
        }
      }
      if (result == SDR_RECORD_EXISTS) continue;
      return false;
    }
    f.stem = candidate; f.rate = item.rate; f.frequency = item.frequency;
    f.mode = item.mode;
    f.captured_unix_ms = item.captured_unix_ms;
    iq_file_ = std::move(f);
    iq_meta_file_ = std::move(meta);
    return true;
  }
  fail(SDR_RECORD_NAME_EXHAUSTED, SDR_RECORD_IQ);
  return false;
}
void Recorder::close_iq() {
  if (iq_file_.fd < 0) return;
  auto previous = std::move(iq_file_); iq_file_ = {};
  if (close_fd(previous.fd) != 0) fail(error_code(errno), SDR_RECORD_IQ);
  File meta = std::move(iq_meta_file_); iq_meta_file_ = {};
  std::ostringstream json;
  json << "{\"global\":{\"core:version\":\"1.0.0\",\"core:datatype\":\"cu8\",\"core:sample_rate\":"
       << previous.rate << ",\"core:recorder\":\"AirSDR\"},\"captures\":[{\"core:sample_start\":0,\"core:frequency\":"
       << previous.frequency << ",\"core:datetime\":\""
       << iso_time(previous.captured_unix_ms) << "\"}]}\n";
  std::string text = json.str();
  write(meta, text.data(), text.size(), SDR_RECORD_IQ);
  if (close_fd(meta.fd) != 0) fail(error_code(errno), SDR_RECORD_IQ);
}
bool Recorder::open_audio(const Item& item, bool segment) {
  std::string base = stem(item.frequency, item.mode, segment);
  const char* extension = ".wav";
  const char* mime = "audio/wav";
  if (config_.audio_format == SDR_RECORD_FLAC) { extension = ".flac"; mime = "audio/flac"; }
  if (config_.audio_format == SDR_RECORD_MP3) { extension = ".mp3"; mime = "audio/mpeg"; }
  if (config_.audio_format == SDR_RECORD_OPUS) { extension = ".opus"; mime = "audio/ogg"; }
  for (int suffix = 1; suffix <= 99; ++suffix) {
    std::string candidate = base + (suffix == 1 ? "" : "_" + std::to_string(suffix));
    File f;
    int32_t result = create(f, candidate + extension, mime,
                            segment ? SDR_RECORD_SQUELCH_AUDIO : SDR_RECORD_AUDIO);
    if (result == SDR_RECORD_EXISTS) continue;
    if (result != SDR_OK) return false;
    f.stem = candidate; f.channels = item.channels; f.rate = item.rate;
    f.frequency = item.frequency; f.mode = item.mode;
    audio_file_ = std::move(f);
    if (config_.audio_format == SDR_RECORD_WAV) {
      auto header = wav_header(item.channels, 0);
      if (!write(audio_file_, header.data(), header.size(),
                 segment ? SDR_RECORD_SQUELCH_AUDIO : SDR_RECORD_AUDIO)) return false;
    } else {
      const auto stream = segment ? SDR_RECORD_SQUELCH_AUDIO : SDR_RECORD_AUDIO;
      audio_file_.encoder = std::make_unique<AudioEncoder>(config_.audio_format,
          item.channels, config_.audio_bitrate_kbps,
          [this, stream](const uint8_t* bytes, size_t n) {
            return write(audio_file_, bytes, n, stream);
          },
          [this, stream](uint64_t position) {
            if (position > static_cast<uint64_t>(INT64_MAX) ||
                seek_fd(audio_file_.fd, static_cast<int64_t>(position), SEEK_SET) < 0) {
              fail(SDR_RECORD_NOT_SEEKABLE, stream); return false;
            }
            return true;
          },
          [this, stream](uint64_t* position) {
            const int64_t result = seek_fd(audio_file_.fd, 0, SEEK_CUR);
            if (result < 0) { fail(SDR_RECORD_NOT_SEEKABLE, stream); return false; }
            *position = static_cast<uint64_t>(result);
            return true;
          });
      if (!audio_file_.encoder->begin()) { fail(SDR_IO_ERROR, stream); return false; }
    }
    { std::lock_guard<std::mutex> lock(mutex_);
      status_.audio_sample_rate = item.rate; status_.audio_channels = item.channels;
      if (segment) status_.squelch_segment_open = 1;
    }
    return true;
  }
  fail(SDR_RECORD_NAME_EXHAUSTED, segment ? SDR_RECORD_SQUELCH_AUDIO : SDR_RECORD_AUDIO);
  return false;
}
void Recorder::close_audio(bool segment) {
  if (audio_file_.fd < 0) return;
  const uint32_t stream = segment ? SDR_RECORD_SQUELCH_AUDIO : SDR_RECORD_AUDIO;
  if (audio_file_.encoder && !audio_file_.encoder->finish()) fail(SDR_IO_ERROR, stream);
  File f = std::move(audio_file_); audio_file_ = {};
  if (!f.encoder && seek_fd(f.fd, 0, SEEK_SET) < 0) fail(SDR_RECORD_NOT_SEEKABLE, stream);
  else if (!f.encoder) {
    auto hdr = wav_header(f.channels, static_cast<uint32_t>(f.data));
    // Header rewrite does not change file length or bytes_written.
    size_t offset = 0;
    while (offset < hdr.size()) {
      int n = write_fd(f.fd, hdr.data() + offset, hdr.size() - offset);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) { fail(n < 0 ? error_code(errno) : SDR_IO_ERROR,
                        segment ? SDR_RECORD_SQUELCH_AUDIO : SDR_RECORD_AUDIO); break; }
      offset += static_cast<size_t>(n);
    }
  }
  if (close_fd(f.fd) != 0) fail(error_code(errno), segment ? SDR_RECORD_SQUELCH_AUDIO : SDR_RECORD_AUDIO);
  if (segment) {
    std::lock_guard<std::mutex> lock(mutex_);
    status_.squelch_segment_open = 0;
    ++status_.segments_completed;
  }
}
void Recorder::write_audio(const Item& item, size_t first, size_t last, bool segment) {
  if (first == last) return;
  const uint32_t stream = segment ? SDR_RECORD_SQUELCH_AUDIO : SDR_RECORD_AUDIO;
  // One session writer owns audio_file_. Both continuous and segmented audio
  // cannot use the same file slot; see separate segment output below.
  if (audio_file_.fd >= 0 && (audio_file_.channels != item.channels ||
      audio_file_.frequency != item.frequency || audio_file_.mode != item.mode)) close_audio(segment);
  if (status().last_error) return;
  size_t pos = first;
  while (pos < last) {
    if (audio_file_.fd < 0 && !open_audio(item, segment)) return;
    size_t count = config_.audio_format == SDR_RECORD_WAV
        ? std::min<uint64_t>(last - pos, (kWavDataMax - audio_file_.data) / (2 * item.channels))
        : std::min<size_t>(last - pos, 960);
    if (!count) {
      close_audio(segment);
      if (status().last_error) return;
      continue;
    }
    if (audio_file_.encoder) {
      if (!audio_file_.encoder->append(item.pcm.data() + pos * item.channels, count)) {
        fail(SDR_IO_ERROR, stream); return;
      }
    } else {
      std::vector<uint8_t> output(count * item.channels * 2);
      for (size_t i = 0; i < count * item.channels; ++i) {
        float v = item.pcm[(pos * item.channels) + i];
        if (!std::isfinite(v)) v = 0;
        int sample = static_cast<int>(std::lrint(std::clamp(v, -1.0f, 1.0f) * 32768.0f));
        sample = std::clamp(sample, -32768, 32767);
        put16(output.data() + i * 2, static_cast<uint16_t>(sample));
      }
      if (!write(audio_file_, output.data(), output.size(), stream)) return;
      audio_file_.data += output.size();
    }
    if (!segment) {
      std::lock_guard<std::mutex> lock(mutex_);
      status_.audio_frames_written += count;
    }
    pos += count;
  }
}
bool Recorder::open_log(const Item& item) {
  std::string base = stem(item.frequency, item.mode, false) + "_" + item.id;
  for (int suffix = 1; suffix <= 99; ++suffix) {
    std::string candidate = base + (suffix == 1 ? "" : "_" + std::to_string(suffix));
    File file;
    auto result = create(file, candidate + ".jsonl", "application/x-ndjson",
                         SDR_RECORD_DECODER_LOG);
    if (result == SDR_RECORD_EXISTS) continue;
    if (result != SDR_OK) return false;
    log_files_.emplace(item.id, std::move(file));
    return true;
  }
  fail(SDR_RECORD_NAME_EXHAUSTED, SDR_RECORD_DECODER_LOG);
  return false;
}
void Recorder::write_log(const Item& item) {
  if (item.payload.size() > SDR_DECODER_MAX_PAYLOAD) {
    std::lock_guard<std::mutex> lock(mutex_); ++status_.log_dropped_events; return;
  }
  auto payload = nlohmann::json::parse(item.payload, nullptr, false);
  if (payload.is_discarded() || !payload.is_object()) {
    std::lock_guard<std::mutex> lock(mutex_); ++status_.log_dropped_events; return;
  }
  nlohmann::json line = {{"timestamp_utc", iso_time(item.captured_unix_ms)},
                         {"decoder_id", item.id}, {"kind", item.event_kind},
                         {"stream_generation", item.generation},
                         {"frequency_hz", item.frequency},
                         {"payload", safe_payload(item.id, payload)}};
  std::string encoded = line.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
  if (encoded.size() + 1 > kLogLineMax) {
    std::lock_guard<std::mutex> lock(mutex_); ++status_.log_dropped_events; return;
  }
  encoded.push_back('\n');
  if (!log_files_.count(item.id) && !open_log(item)) return;
  if (write(log_files_.at(item.id), encoded.data(), encoded.size(), SDR_RECORD_DECODER_LOG)) {
    std::lock_guard<std::mutex> lock(mutex_); ++status_.log_events_written;
  }
}
void Recorder::process(const Item& item) {
  if (item.kind == Kind::log) {
    write_log(item);
  } else if (item.kind == Kind::iq) {
    if (iq_file_.fd >= 0 && (iq_file_.rate != item.rate || iq_file_.frequency != item.frequency ||
                             iq_file_.mode != item.mode)) close_iq();
    if (status().last_error) return;
    if (iq_file_.fd < 0 && !open_iq(item)) return;
    if (write(iq_file_, item.iq.data(), item.iq.size(), SDR_RECORD_IQ)) {
      iq_file_.data += item.iq.size();
      std::lock_guard<std::mutex> lock(mutex_);
      status_.iq_samples_written += item.iq.size() / 2;
    }
  } else {
    if (config_.streams & SDR_RECORD_AUDIO) write_audio(item, 0, item.frames, false);
    if (status().last_error) return;
    // Combined continuous+segmented output requires a separate file handle.
    if (config_.streams & SDR_RECORD_SQUELCH_AUDIO) {
      // The segment handle is swapped into the shared audio slot only while
      // processing squelch slices; continuous is preserved across this block.
      File continuous = std::move(audio_file_); audio_file_ = std::move(segment_file_);
      if (segment_open_ && audio_file_.fd >= 0 &&
          (audio_file_.channels != item.channels || audio_file_.frequency != item.frequency ||
           audio_file_.mode != item.mode)) {
        close_audio(true);
        // Preserve the detector's open state across a format/LO boundary.
        // The next PCM frame starts a new segment even without a new edge.
      }
      size_t cursor = 0;
      for (const auto& edge : item.edges) {
        if (edge.frame_offset < cursor || edge.frame_offset > item.frames) continue;
        if (segment_open_) write_audio(item, cursor, edge.frame_offset, true);
        if (segment_open_ && !edge.open) close_audio(true);
        segment_open_ = edge.open;
        cursor = edge.frame_offset;
      }
      if (segment_open_) write_audio(item, cursor, item.frames, true);
      segment_file_ = std::move(audio_file_); audio_file_ = std::move(continuous);
    }
  }
}
void Recorder::run() {
  while (true) {
    Item item;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      cv_.wait(lock, [&] { return stopping_ || overflow_ || !queue_.empty(); });
      if (overflow_) {
        if (!status_.last_error) {
          status_.last_error = SDR_IO_ERROR; status_.error_stream = overflow_stream_;
        }
        queue_.clear(); iq_queued_ = audio_queued_ = log_queued_ = 0;
        break;
      }
      if (queue_.empty()) { if (stopping_) break; continue; }
      item = std::move(queue_.front()); queue_.pop_front();
      if (item.kind == Kind::iq) iq_queued_ -= item.iq.size();
      else if (item.kind == Kind::audio) audio_queued_ -= item.pcm.size() * sizeof(float);
      else log_queued_ -= item.payload.size();
    }
    process(item);
    { std::lock_guard<std::mutex> lock(mutex_); if (status_.last_error) break; }
  }
  close_audio(false);
  audio_file_ = std::move(segment_file_);
  segment_file_ = {};
  close_audio(true);
  close_iq();
  for (auto& [id, file] : log_files_)
    if (close_fd(file.fd) != 0) fail(error_code(errno), SDR_RECORD_DECODER_LOG);
  log_files_.clear();
  SdrRecordStatus snapshot;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    status_.elapsed_ms = elapsed(started_);
    if (status_.last_error) {
      status_.state = SDR_RECORD_FAILED;
      status_.stop_reason = SDR_RECORD_STOP_ERROR;
    } else {
      status_.state = SDR_RECORD_IDLE;
      if (!status_.stop_reason) status_.stop_reason = SDR_RECORD_STOP_RECEIVER;
    }
    snapshot = status_;
  }
  notify_final(snapshot);
}
} // namespace sdrcore::record
