// SPDX-License-Identifier: GPL-3.0-or-later
#include "audio_encoder.h"
#include "sdrcore_record_v1.h"
#include <FLAC/stream_encoder.h>
#include <lame.h>
#include <ogg/ogg.h>
#include <opus.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

namespace sdrcore::record {
namespace {
int16_t pcm16(float v) {
  if (!std::isfinite(v)) v = 0;
  const int value = static_cast<int>(std::lrint(std::clamp(v, -1.0f, 1.0f) * 32768.0f));
  return static_cast<int16_t>(std::clamp(value, -32768, 32767));
}
void le32(uint8_t* p, uint32_t n) {
  for (int i = 0; i < 4; ++i) p[i] = static_cast<uint8_t>(n >> (i * 8));
}
} // namespace
struct AudioEncoder::Impl {
  uint32_t format, channels, bitrate;
  Writer writer;
  Seeker seeker;
  Teller teller;
  FLAC__StreamEncoder* flac = nullptr;
  lame_t lame = nullptr;
  OpusEncoder* opus = nullptr;
  ogg_stream_state ogg{};
  bool ogg_active = false;
  int64_t packet_number = 0;
  int64_t frames_encoded = 0;
  int64_t frames_actual = 0;
  int32_t preskip = 0;
  std::vector<float> pending;
  bool failed = false;
  Impl(uint32_t f, uint32_t c, uint32_t b, Writer w, Seeker s, Teller t)
      : format(f), channels(c), bitrate(b), writer(std::move(w)),
        seeker(std::move(s)), teller(std::move(t)) {}
  ~Impl() {
    if (flac) FLAC__stream_encoder_delete(flac);
    if (lame) lame_close(lame);
    if (opus) opus_encoder_destroy(opus);
    if (ogg_active) ogg_stream_clear(&ogg);
  }
  bool emit(const uint8_t* data, size_t size) {
    if (failed) return false;
    if (size && !writer(data, size)) { failed = true; return false; }
    return true;
  }
  static FLAC__StreamEncoderWriteStatus flac_write(const FLAC__StreamEncoder*,
      const FLAC__byte* data, size_t size, unsigned, unsigned, void* ctx) {
    return static_cast<Impl*>(ctx)->emit(data, size) ?
        FLAC__STREAM_ENCODER_WRITE_STATUS_OK : FLAC__STREAM_ENCODER_WRITE_STATUS_FATAL_ERROR;
  }
  static FLAC__StreamEncoderSeekStatus flac_seek(const FLAC__StreamEncoder*,
      FLAC__uint64 offset, void* ctx) {
    return static_cast<Impl*>(ctx)->seeker(offset) ?
        FLAC__STREAM_ENCODER_SEEK_STATUS_OK : FLAC__STREAM_ENCODER_SEEK_STATUS_ERROR;
  }
  static FLAC__StreamEncoderTellStatus flac_tell(const FLAC__StreamEncoder*,
      FLAC__uint64* offset, void* ctx) {
    uint64_t position = 0;
    if (!static_cast<Impl*>(ctx)->teller(&position))
      return FLAC__STREAM_ENCODER_TELL_STATUS_ERROR;
    *offset = position;
    return FLAC__STREAM_ENCODER_TELL_STATUS_OK;
  }
  bool page(bool flush) {
    ogg_page pg{};
    while ((flush ? ogg_stream_flush(&ogg, &pg) : ogg_stream_pageout(&ogg, &pg)) > 0) {
      if (!emit(pg.header, static_cast<size_t>(pg.header_len)) ||
          !emit(pg.body, static_cast<size_t>(pg.body_len))) return false;
    }
    return !failed;
  }
  bool packet(const uint8_t* bytes, size_t size, int64_t granule, bool eos, bool flush) {
    ogg_packet p{};
    p.packet = const_cast<unsigned char*>(bytes);
    p.bytes = static_cast<long>(size);
    p.b_o_s = packet_number == 0;
    p.e_o_s = eos;
    p.granulepos = granule;
    p.packetno = packet_number++;
    return ogg_stream_packetin(&ogg, &p) == 0 && page(flush);
  }
  bool begin() {
    if (format == SDR_RECORD_FLAC) {
      flac = FLAC__stream_encoder_new();
      if (!flac || !FLAC__stream_encoder_set_channels(flac, channels) ||
          !FLAC__stream_encoder_set_bits_per_sample(flac, 16) ||
          !FLAC__stream_encoder_set_sample_rate(flac, 48000) ||
          !FLAC__stream_encoder_set_compression_level(flac, 5)) return false;
      return FLAC__stream_encoder_init_stream(flac, flac_write, flac_seek, flac_tell,
          nullptr, this) == FLAC__STREAM_ENCODER_INIT_STATUS_OK;
    }
    if (format == SDR_RECORD_MP3) {
      lame = lame_init();
      if (!lame) return false;
      lame_set_in_samplerate(lame, 48000);
      lame_set_num_channels(lame, static_cast<int>(channels));
      lame_set_mode(lame, channels == 1 ? MONO : JOINT_STEREO);
      lame_set_brate(lame, static_cast<int>(bitrate));
      lame_set_quality(lame, 5);
      lame_set_bWriteVbrTag(lame, 0); // Streaming fd; no seek-back dependency.
      return lame_init_params(lame) >= 0;
    }
    if (format == SDR_RECORD_OPUS) {
      int error = 0;
      opus = opus_encoder_create(48000, static_cast<int>(channels), OPUS_APPLICATION_AUDIO, &error);
      if (!opus || error != OPUS_OK ||
          opus_encoder_ctl(opus, OPUS_SET_BITRATE(static_cast<int>(bitrate * 1000))) != OPUS_OK ||
          opus_encoder_ctl(opus, OPUS_GET_LOOKAHEAD(&preskip)) != OPUS_OK ||
          ogg_stream_init(&ogg, 0x41495253) != 0) return false;
      ogg_active = true;
      uint8_t head[19]{};
      std::memcpy(head, "OpusHead", 8);
      head[8] = 1; head[9] = static_cast<uint8_t>(channels);
      head[10] = static_cast<uint8_t>(preskip);
      head[11] = static_cast<uint8_t>(preskip >> 8);
      le32(head + 12, 48000);
      if (!packet(head, sizeof(head), 0, false, true)) return false;
      const char vendor[] = "AirSDR";
      uint8_t tags[8 + 4 + sizeof(vendor) - 1 + 4]{};
      std::memcpy(tags, "OpusTags", 8);
      le32(tags + 8, sizeof(vendor) - 1);
      std::memcpy(tags + 12, vendor, sizeof(vendor) - 1);
      return packet(tags, sizeof(tags), 0, false, true);
    }
    return false;
  }
  bool encode_opus(const float* samples, bool eos, int64_t granule) {
    uint8_t output[4000];
    int n = opus_encode_float(opus, samples, 960, output, sizeof(output));
    if (n <= 0) return false;
    frames_encoded += 960;
    return packet(output, static_cast<size_t>(n), granule, eos, eos);
  }
  bool append(const float* samples, size_t frames) {
    if (failed) return false;
    if (format == SDR_RECORD_FLAC) {
      // Bound temporary PCM to a single 20-ms packet, independent of caller block size.
      while (frames) {
        const size_t n = std::min<size_t>(frames, 960);
        std::vector<FLAC__int32> pcm(n * channels);
        for (size_t i = 0; i < pcm.size(); ++i) pcm[i] = pcm16(samples[i]);
        if (!FLAC__stream_encoder_process_interleaved(flac, pcm.data(), static_cast<unsigned>(n))) return false;
        samples += n * channels; frames -= n;
      }
      return true;
    }
    if (format == SDR_RECORD_MP3) {
      while (frames) {
        const size_t n = std::min<size_t>(frames, 960);
        std::vector<float> left(n), right(n);
        for (size_t i = 0; i < n; ++i) {
          left[i] = std::isfinite(samples[i * channels]) ? samples[i * channels] : 0;
          right[i] = channels == 2 && std::isfinite(samples[i * 2 + 1]) ? samples[i * 2 + 1] : left[i];
        }
        // LAME's documented upper bound: 1.25*n + 7200.
        std::vector<uint8_t> output(960 * 2 + 7200);
        int size = lame_encode_buffer_ieee_float(lame, left.data(), right.data(),
            static_cast<int>(n), output.data(), static_cast<int>(output.size()));
        if (size < 0 || !emit(output.data(), static_cast<size_t>(size))) return false;
        samples += n * channels; frames -= n;
      }
      return true;
    }
    if (format == SDR_RECORD_OPUS) {
      frames_actual += static_cast<int64_t>(frames);
      pending.insert(pending.end(), samples, samples + frames * channels);
      // Hold one final frame for the EOS packet, whose granulepos trims padding.
      while (pending.size() > 960 * channels) {
        if (!encode_opus(pending.data(), false, frames_encoded + 960)) return false;
        pending.erase(pending.begin(), pending.begin() + 960 * channels);
      }
      return true;
    }
    return false;
  }
  bool finish() {
    if (format == SDR_RECORD_FLAC) return FLAC__stream_encoder_finish(flac) && !failed;
    if (format == SDR_RECORD_MP3) {
      uint8_t output[7200];
      const int n = lame_encode_flush(lame, output, sizeof(output));
      return n >= 0 && emit(output, static_cast<size_t>(n));
    }
    if (format == SDR_RECORD_OPUS) {
      // Account for the encoder lookahead: one additional padded 20-ms packet
      // is necessary if the final input frame alone cannot cover preskip.
      if (frames_actual == 0) return packet(nullptr, 0, 0, true, true);
      const size_t samples = 960 * channels;
      while (frames_encoded + 960 < frames_actual + preskip) {
        pending.resize(samples, 0);
        if (!encode_opus(pending.data(), false, frames_encoded + 960)) return false;
        pending.clear();
      }
      pending.resize(samples, 0);
      return encode_opus(pending.data(), true, preskip + frames_actual);
    }
    return false;
  }
};
AudioEncoder::AudioEncoder(uint32_t format, uint32_t channels, uint32_t bitrate,
                           Writer writer, Seeker seeker, Teller teller)
    : p_(new Impl(format, channels, bitrate, std::move(writer),
                  std::move(seeker), std::move(teller))) {}
AudioEncoder::~AudioEncoder() = default;
bool AudioEncoder::begin() { return p_->begin(); }
bool AudioEncoder::append(const float* data, size_t frames) { return p_->append(data, frames); }
bool AudioEncoder::finish() { return p_->finish(); }
} // namespace sdrcore::record
