// Host golden-reference generator: compiles the *real* SDR++ DSP headers
// (~/prj/sdrpp/core/src/dsp, header-only) against a scalar VOLK stub and dumps inputs/outputs
// of the blocks as raw little-endian float32 files for the Dart golden tests.
//
// Build & run: tool/oracle/run_oracle.sh  (writes test/sdrpp/dsp/golden/*.f32 + index.txt)
#include <cstdio>
#include <cstdint>
#include <string>
#include <vector>
#include <cmath>

#include <dsp/types.h>
#include <dsp/window/nuttall.h>
#include <dsp/window/blackman.h>
#include <dsp/window/blackman_harris.h>
#include <dsp/window/blackman_nuttall.h>
#include <dsp/window/hamming.h>
#include <dsp/window/hann.h>
#include <dsp/taps/low_pass.h>
#include <dsp/taps/high_pass.h>
#include <dsp/taps/band_pass.h>
#include <dsp/filter/fir.h>
#include <dsp/filter/decimating_fir.h>
#include <dsp/filter/deephasis.h>
#include <dsp/multirate/polyphase_bank.h>
#include <dsp/multirate/polyphase_resampler.h>
#include <dsp/multirate/power_decimator.h>
#include <dsp/multirate/rational_resampler.h>
#include <dsp/channel/rx_vfo.h>
#include <dsp/correction/dc_blocker.h>
#include <dsp/loop/agc.h>
#include <dsp/loop/pll.h>
#include <dsp/demod/quadrature.h>
#include <dsp/demod/fm.h>
#include <dsp/demod/broadcast_fm.h>
#include <dsp/demod/am.h>
#include <dsp/demod/ssb.h>
#include <dsp/demod/cw.h>
#include <dsp/noise_reduction/noise_blanker.h>
#include <dsp/noise_reduction/power_squelch.h>

static std::string outDir;
static FILE* indexFile;

static void dump(const std::string& name, const float* data, size_t nFloats) {
    std::string path = outDir + "/" + name + ".f32";
    FILE* f = fopen(path.c_str(), "wb");
    fwrite(data, sizeof(float), nFloats, f);
    fclose(f);
    fprintf(indexFile, "%s %zu\n", name.c_str(), nFloats);
}
template <class T>
static void dumpT(const std::string& name, const T* data, size_t n) { dump(name, (const float*)data, n * sizeof(T) / sizeof(float)); }

// Deterministic generator (xorshift32 -> [-1, 1))
static uint32_t rngState = 12345;
static float rnd() {
    rngState ^= rngState << 13; rngState ^= rngState >> 17; rngState ^= rngState << 5;
    return (float)((rngState >> 8) * (1.0 / 16777216.0)) * 2.0f - 1.0f;
}

// Runs a block's process() over the input in fixed chunks (as a source would push).
template <class Blk, class I, class O>
static int runChunks(Blk& b, const I* in, int n, O* out, int chunk) {
    int o = 0;
    for (int i = 0; i < n; i += chunk) {
        int c = std::min(chunk, n - i);
        o += b.process(c, (I*)&in[i], &out[o]);
    }
    return o;
}

int main(int argc, char** argv) {
    outDir = argc > 1 ? argv[1] : ".";
    indexFile = fopen((outDir + "/index.txt").c_str(), "w");

    // ---------------- windows ----------------
    {
        const int N = 64;
        std::vector<float> w;
        for (int i = 0; i < N; i++) {
            double n = (double)i - N + 0.5; // same argument range as windowedSinc (t - half)
            w.push_back(dsp::window::nuttall(n, N));
            w.push_back(dsp::window::blackman(n, N));
            w.push_back(dsp::window::blackmanHarris(n, N));
            w.push_back(dsp::window::blackmanNuttall(n, N));
            w.push_back(dsp::window::hamming(n, N));
            w.push_back(dsp::window::hann(n, N));
        }
        dump("windows_64", w.data(), w.size());
    }

    // ---------------- taps ----------------
    struct LP { const char* name; double c, t, sr; bool odd; };
    LP lps[] = {
        { "lp_vfo_wfm", 75000, 7500, 250000, false },     // RxVFO WFM LPF 126
        { "lp_audio_wfm", 15000, 4000, 250000, false },    // BroadcastFM audio 237
        { "lp_nfm", 6250, 625, 50000, false },             // FM LPF
        { "lp_am", 5000, 500, 15000, false },
        { "lp_resamp_wfm", 125000, 12500, 1500000, false },// 2.4M->250k proto (300k*5)
        { "lp_resamp_af", 24000, 2400, 3000000, false },   // 250k->48k proto (62.5k*96... see test)
        { "lp_odd", 1000, 300, 48000, true },
    };
    for (auto& l : lps) {
        auto t = dsp::taps::lowPass(l.c, l.t, l.sr, l.odd);
        dump(std::string("taps_") + l.name, t.taps, t.size);
    }
    {
        auto t = dsp::taps::highPass(300, 100, 48000);
        dump("taps_hp_300", t.taps, t.size);
        auto b = dsp::taps::bandPass<float>(1000, 3000, 500, 48000);
        dump("taps_bp_float", b.taps, b.size);
        auto c = dsp::taps::bandPass<dsp::complex_t>(18750.0, 19250.0, 3000.0, 250000, true);
        dumpT("taps_bp_pilot", c.taps, c.size);
        auto c2 = dsp::taps::bandPass<dsp::complex_t>(1000, 3000, 500, 48000, false);
        dumpT("taps_bp_complex", c2.taps, c2.size);
    }
    // Polyphase bank (WFM VFO 5/6)
    {
        auto t = dsp::taps::lowPass(125000, 12500, 1500000);
        for (int i = 0; i < (int)t.size; i++) t.taps[i] *= 5.0f;
        auto pb = dsp::multirate::buildPolyphaseBank(5, t);
        std::vector<float> flat;
        for (int p = 0; p < pb.phaseCount; p++) for (int k = 0; k < pb.tapsPerPhase; k++) flat.push_back(pb.phases[p][k]);
        dump("polybank_5", flat.data(), flat.size());
    }

    // ---------------- inputs ----------------
    const int N = 12000;
    std::vector<dsp::complex_t> cin(N);
    for (int i = 0; i < N; i++) cin[i] = { rnd(), rnd() };
    dumpT("in_complex", cin.data(), N);
    std::vector<float> rin(N);
    for (int i = 0; i < N; i++) rin[i] = rnd();
    dump("in_real", rin.data(), N);

    std::vector<dsp::complex_t> cout(N * 8);
    std::vector<float> rout(N * 8);
    std::vector<dsp::stereo_t> sout(N * 8);

    // ---------------- FIR ----------------
    {
        auto t = dsp::taps::lowPass(75000, 7500, 250000);
        dsp::filter::FIR<dsp::complex_t, float> f(NULL, t);
        int n = runChunks(f, cin.data(), N, cout.data(), 1000);
        dumpT("fir_cr", cout.data(), n);
    }
    {
        auto t = dsp::taps::lowPass(15000, 4000, 250000);
        dsp::filter::FIR<float, float> f(NULL, t);
        int n = runChunks(f, rin.data(), N, rout.data(), 1000);
        dump("fir_rr", rout.data(), n);
    }
    {
        auto t = dsp::taps::bandPass<dsp::complex_t>(18750.0, 19250.0, 3000.0, 250000, true);
        dsp::filter::FIR<dsp::complex_t, dsp::complex_t> f(NULL, t);
        int n = runChunks(f, cin.data(), N, cout.data(), 1000);
        dumpT("fir_cc", cout.data(), n);
    }
    {
        // setTaps continuity: 126 taps -> 60 taps -> 200 taps mid-stream
        auto t1 = dsp::taps::lowPass(75000, 7500, 250000);
        auto t2 = dsp::taps::lowPass(75000, 16000, 250000);
        auto t3 = dsp::taps::lowPass(75000, 4750, 250000);
        dsp::filter::FIR<dsp::complex_t, float> f(NULL, t1);
        int o = f.process(3000, cin.data(), cout.data());
        f.setTaps(t2);
        o += f.process(3000, &cin[3000], &cout[o]);
        f.setTaps(t3);
        o += f.process(3000, &cin[6000], &cout[o]);
        dumpT("fir_settaps", cout.data(), o);
        fprintf(indexFile, "#fir_settaps taps %u %u %u\n", t1.size, t2.size, t3.size);
    }
    {
        auto t = dsp::taps::fromArray<float>(dsp::multirate::decim::fir_8_4_len, dsp::multirate::decim::fir_8_4_taps);
        dsp::filter::DecimatingFIR<dsp::complex_t, float> f(NULL, t, 4);
        int n = runChunks(f, cin.data(), N, cout.data(), 999);
        dumpT("decimfir_4", cout.data(), n);
    }

    // ---------------- Power decimator ----------------
    for (int ratio : { 2, 8, 32, 64, 256 }) {
        dsp::multirate::PowerDecimator<dsp::complex_t> d(NULL, ratio);
        int n = runChunks(d, cin.data(), N, cout.data(), 1200);
        dumpT("powerdecim_" + std::to_string(ratio), cout.data(), n);
    }

    // ---------------- Polyphase / rational resampler ----------------
    {
        auto t = dsp::taps::lowPass(125000, 12500, 1500000);
        for (int i = 0; i < (int)t.size; i++) t.taps[i] *= 5.0f;
        dsp::multirate::PolyphaseResampler<dsp::complex_t> r(NULL, 5, 6, t);
        int n = runChunks(r, cin.data(), N, cout.data(), 1000);
        dumpT("poly_5_6", cout.data(), n);
    }
    struct RR { const char* name; double in, out; };
    RR rrs[] = {
        { "rr_2400k_250k", 2400000, 250000 },
        { "rr_2400k_50k", 2400000, 50000 },
        { "rr_2400k_24k", 2400000, 24000 },
        { "rr_2048k_250k", 2048000, 250000 },
        { "rr_24k_48k", 24000, 48000 },
        { "rr_15k_48k", 15000, 48000 },
        { "rr_250k_48k", 250000, 48000 },
    };
    for (auto& r : rrs) {
        dsp::multirate::RationalResampler<dsp::complex_t>* rs = new dsp::multirate::RationalResampler<dsp::complex_t>(NULL, r.in, r.out);
        int n = runChunks(*rs, cin.data(), N, cout.data(), 1000);
        dumpT(r.name, cout.data(), n);
        delete rs;
    }
    {
        // stereo AF resampler 250k -> 48k
        dsp::multirate::RationalResampler<dsp::stereo_t> rs(NULL, 250000, 48000);
        int n = runChunks(rs, (dsp::stereo_t*)cin.data(), N, sout.data(), 1000);
        dumpT("rr_stereo_250k_48k", sout.data(), n);
    }

    // ---------------- RxVFO ----------------
    {
        dsp::channel::RxVFO* v = new dsp::channel::RxVFO(NULL, 2400000, 250000, 150000, 100000);
        int n = runChunks(*v, cin.data(), N, cout.data(), 1200);
        dumpT("rxvfo_wfm", cout.data(), n);
        delete v;
    }

    // ---------------- simple blocks ----------------
    {
        dsp::correction::DCBlocker<float> d(NULL, 100.0 / 15000.0);
        std::vector<float> x(N);
        for (int i = 0; i < N; i++) x[i] = rin[i] * 0.2f + 0.5f;
        dump("in_dc", x.data(), N);
        int n = runChunks(d, x.data(), N, rout.data(), 1000);
        dump("dcblock", rout.data(), n);
    }
    {
        dsp::filter::Deemphasis<dsp::stereo_t> d;
        d.init(NULL, 50e-6, 48000);
        int n = runChunks(d, (dsp::stereo_t*)cin.data(), N, sout.data(), 1000);
        dumpT("deemp_stereo", sout.data(), n);
    }
    {
        // AGC with slowly varying envelope + a burst that triggers the look-ahead
        std::vector<float> x(N);
        for (int i = 0; i < N; i++) {
            float env = 0.01f + 0.5f * (1.0f + sinf(i * 0.001f));
            if (i >= 6000 && i < 6100) env = 50.0f;
            x[i] = env * sinf(i * 0.05f);
        }
        dump("in_agc", x.data(), N);
        dsp::loop::AGC<float> a(NULL, 1.0, 50.0 / 24000, 5.0 / 24000, 10e6, 10.0, INFINITY);
        int n = runChunks(a, x.data(), N, rout.data(), 1000);
        dump("agc_real", rout.data(), n);
    }
    {
        dsp::noise_reduction::NoiseBlanker nb(NULL, 500.0 / 24000.0, 5.0);
        int n = runChunks(nb, cin.data(), N, cout.data(), 1000);
        dumpT("noiseblanker", cout.data(), n);
    }

    // ---------------- FM signals ----------------
    // Complex baseband FM @ 250 kHz with a stereo MPX: L = 1 kHz tone, R = 0, pilot 19 kHz.
    const double fs = 250000;
    const int NF = 30000;
    std::vector<dsp::complex_t> fmIn(NF);
    {
        double ph = 0;
        for (int i = 0; i < NF; i++) {
            double t = i / fs;
            double L = sin(2 * M_PI * 1000 * t), R = 0;
            double mpx = 0.45 * (L + R) + 0.45 * (L - R) * sin(2 * M_PI * 38000 * t) + 0.1 * sin(2 * M_PI * 19000 * t);
            ph += 2 * M_PI * 75000 * mpx / fs;
            fmIn[i] = { (float)cos(ph), (float)sin(ph) };
        }
        dumpT("in_fm_stereo", fmIn.data(), NF);
    }
    {
        dsp::demod::Quadrature q(NULL, 75000, fs);
        int n = runChunks(q, fmIn.data(), NF, rout.data(), 1000);
        dump("quadrature", rout.data(), n);
    }
    {
        dsp::demod::BroadcastFM* b = new dsp::demod::BroadcastFM();
        b->init(NULL, 75000, fs, true, true, false);
        int o = 0;
        for (int i = 0; i < NF; i += 1000) {
            int rc = 0;
            o += b->process(std::min(1000, NF - i), &fmIn[i], &sout[o], rc, NULL);
        }
        dumpT("bfm_stereo", sout.data(), o);
        delete b;
    }
    {
        dsp::demod::BroadcastFM* b = new dsp::demod::BroadcastFM();
        b->init(NULL, 75000, fs, false, true, false);
        int o = 0;
        for (int i = 0; i < NF; i += 1000) {
            int rc = 0;
            o += b->process(std::min(1000, NF - i), &fmIn[i], &sout[o], rc, NULL);
        }
        dumpT("bfm_mono", sout.data(), o);
        delete b;
    }
    {
        // PLL on the pilot-filtered signal
        auto t = dsp::taps::bandPass<dsp::complex_t>(18750.0, 19250.0, 3000.0, fs, true);
        dsp::filter::FIR<dsp::complex_t, dsp::complex_t> f(NULL, t);
        std::vector<dsp::complex_t> c(NF), p(NF);
        std::vector<float> mpx(NF);
        dsp::demod::Quadrature q(NULL, 75000, fs);
        q.process(NF, fmIn.data(), mpx.data());
        for (int i = 0; i < NF; i++) c[i] = { mpx[i], 0 };
        f.process(NF, c.data(), p.data());
        dumpT("pilot_filtered", p.data(), NF);
        dsp::loop::PLL pll;
        pll.init(NULL, 25000.0 / fs, 0.0, dsp::math::hzToRads(19000.0, fs), dsp::math::hzToRads(18750.0, fs), dsp::math::hzToRads(19250.0, fs));
        int n = runChunks(pll, p.data(), NF, cout.data(), 1000);
        dumpT("pll_vco", cout.data(), n);
    }
    // NFM: FM<stereo> 50 kHz, bw 12.5 kHz with a 1 kHz tone, dev 2.5 kHz
    {
        const double fsn = 50000;
        const int NN = 20000;
        std::vector<dsp::complex_t> x(NN);
        double ph = 0;
        for (int i = 0; i < NN; i++) {
            ph += 2 * M_PI * 2500 * sin(2 * M_PI * 1000 * i / fsn) / fsn;
            x[i] = { (float)cos(ph), (float)sin(ph) };
        }
        dumpT("in_nfm", x.data(), NN);
        dsp::demod::FM<dsp::stereo_t>* fm = new dsp::demod::FM<dsp::stereo_t>(NULL, fsn, 12500, true);
        int n = runChunks(*fm, x.data(), NN, sout.data(), 1000);
        dumpT("nfm", sout.data(), n);
        delete fm;
    }
    // AM 15 kHz, 1 kHz tone m = 0.5 with a carrier offset phase
    {
        const double fsa = 15000;
        const int NA = 15000;
        std::vector<dsp::complex_t> x(NA);
        for (int i = 0; i < NA; i++) {
            double a = 0.3 * (1.0 + 0.5 * sin(2 * M_PI * 1000 * i / fsa));
            x[i] = { (float)(a * cos(0.3)), (float)(a * sin(0.3)) };
        }
        dumpT("in_am", x.data(), NA);
        dsp::demod::AM<dsp::stereo_t>* am = new dsp::demod::AM<dsp::stereo_t>(NULL, dsp::demod::AM<dsp::stereo_t>::AUDIO, 10000, 50.0 / fsa, 5.0 / fsa, 100.0 / fsa, fsa);
        int n = runChunks(*am, x.data(), NA, sout.data(), 1000);
        dumpT("am_audio", sout.data(), n);
        delete am;
        am = new dsp::demod::AM<dsp::stereo_t>(NULL, dsp::demod::AM<dsp::stereo_t>::CARRIER, 10000, 50.0 / fsa, 5.0 / fsa, 100.0 / fsa, fsa);
        n = runChunks(*am, x.data(), NA, sout.data(), 1000);
        dumpT("am_carrier", sout.data(), n);
        delete am;
    }
    // SSB/CW on complex input @ 24k / 3k
    {
        const double fss = 24000;
        const int NS = 24000;
        std::vector<dsp::complex_t> x(NS);
        for (int i = 0; i < NS; i++) {
            // USB-centred VFO: carrier at -1400 Hz, tone at +1000 Hz above carrier -> -400 Hz
            double f = -400;
            x[i] = { (float)(0.2 * cos(2 * M_PI * f * i / fss)), (float)(0.2 * sin(2 * M_PI * f * i / fss)) };
        }
        dumpT("in_ssb", x.data(), NS);
        for (int m = 0; m < 3; m++) {
            auto* s = new dsp::demod::SSB<dsp::stereo_t>(NULL, (dsp::demod::SSB<dsp::stereo_t>::Mode)m, 2800, fss, 50.0 / fss, 5.0 / fss);
            int n = runChunks(*s, x.data(), NS, sout.data(), 1000);
            dumpT(std::string("ssb_") + (m == 0 ? "usb" : m == 1 ? "lsb" : "dsb"), sout.data(), n);
            delete s;
        }
        const double fsc = 3000;
        std::vector<dsp::complex_t> y(6000);
        for (int i = 0; i < 6000; i++) y[i] = { 0.1f, 0.0f };
        auto* cw = new dsp::demod::CW<dsp::stereo_t>(NULL, 800, 100.0 / fsc, 5.0 / fsc, fsc);
        int n = runChunks(*cw, y.data(), 6000, sout.data(), 500);
        dumpT("cw", sout.data(), n);
        delete cw;
    }

    fclose(indexFile);
    printf("oracle done -> %s\n", outDir.c_str());
    return 0;
}
