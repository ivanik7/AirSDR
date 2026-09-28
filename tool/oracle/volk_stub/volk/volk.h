// Minimal scalar stand-in for the VOLK API subset used by SDR++ core/src/dsp headers.
// Used only by the host golden-reference generator (tool/oracle/dsp_oracle.cpp).
#pragma once
#include <complex>
#include <cmath>
#include <cstdlib>
#include <cstring>

#define VOLK_VERSION 030100

typedef std::complex<float> lv_32fc_t;
static inline lv_32fc_t lv_cmake(float r, float i) { return lv_32fc_t(r, i); }

static inline size_t volk_get_alignment() { return 32; }
static inline void* volk_malloc(size_t size, size_t align) {
    void* p = nullptr;
    if (posix_memalign(&p, align, size ? size : align)) return nullptr;
    return p;
}
static inline void volk_free(void* p) { free(p); }

static inline void volk_32f_x2_dot_prod_32f(float* result, const float* a, const float* b, unsigned int n) {
    double s = 0;
    for (unsigned i = 0; i < n; i++) s += (double)a[i] * (double)b[i];
    *result = (float)s;
}
static inline void volk_32fc_32f_dot_prod_32fc(lv_32fc_t* result, const lv_32fc_t* a, const float* b, unsigned int n) {
    double re = 0, im = 0;
    for (unsigned i = 0; i < n; i++) { re += (double)a[i].real() * b[i]; im += (double)a[i].imag() * b[i]; }
    *result = lv_32fc_t((float)re, (float)im);
}
static inline void volk_32fc_x2_dot_prod_32fc(lv_32fc_t* result, const lv_32fc_t* a, const lv_32fc_t* b, unsigned int n) {
    double re = 0, im = 0;
    for (unsigned i = 0; i < n; i++) {
        double ar = a[i].real(), ai = a[i].imag(), br = b[i].real(), bi = b[i].imag();
        re += ar * br - ai * bi; im += ar * bi + ai * br;
    }
    *result = lv_32fc_t((float)re, (float)im);
}
// Double-precision phase, renormalised every 512 samples of the absolute count (matches the
// Dart Rotator); state kept in static storage keyed by the phase pointer for simplicity.
static inline void volk_32fc_s32fc_x2_rotator2_32fc(lv_32fc_t* out, const lv_32fc_t* in, const lv_32fc_t* phaseInc, lv_32fc_t* phase, unsigned int n) {
    std::complex<double> p(phase->real(), phase->imag()), d(phaseInc->real(), phaseInc->imag());
    for (unsigned i = 0; i < n; i++) {
        std::complex<double> x(in[i].real(), in[i].imag());
        std::complex<double> y = x * p;
        out[i] = lv_32fc_t((float)y.real(), (float)y.imag());
        p *= d;
    }
    p /= std::abs(p);
    *phase = lv_32fc_t((float)p.real(), (float)p.imag());
}
static inline void volk_32fc_magnitude_32f(float* out, const lv_32fc_t* in, unsigned int n) {
    for (unsigned i = 0; i < n; i++) out[i] = sqrtf(in[i].real() * in[i].real() + in[i].imag() * in[i].imag());
}
static inline void volk_32fc_deinterleave_real_32f(float* out, const lv_32fc_t* in, unsigned int n) {
    for (unsigned i = 0; i < n; i++) out[i] = in[i].real();
}
static inline void volk_32f_x2_interleave_32fc(lv_32fc_t* out, const float* a, const float* b, unsigned int n) {
    for (unsigned i = 0; i < n; i++) out[i] = lv_32fc_t(a[i], b[i]);
}
static inline void volk_32fc_conjugate_32fc(lv_32fc_t* out, const lv_32fc_t* in, unsigned int n) {
    for (unsigned i = 0; i < n; i++) out[i] = std::conj(in[i]);
}
static inline void volk_32fc_x2_multiply_32fc(lv_32fc_t* out, const lv_32fc_t* a, const lv_32fc_t* b, unsigned int n) {
    for (unsigned i = 0; i < n; i++) {
        float ar = a[i].real(), ai = a[i].imag(), br = b[i].real(), bi = b[i].imag();
        out[i] = lv_32fc_t(ar * br - ai * bi, ar * bi + ai * br);
    }
}
static inline void volk_32f_x2_add_32f(float* out, const float* a, const float* b, unsigned int n) { for (unsigned i = 0; i < n; i++) out[i] = a[i] + b[i]; }
static inline void volk_32f_x2_subtract_32f(float* out, const float* a, const float* b, unsigned int n) { for (unsigned i = 0; i < n; i++) out[i] = a[i] - b[i]; }
static inline void volk_32f_x2_multiply_32f(float* out, const float* a, const float* b, unsigned int n) { for (unsigned i = 0; i < n; i++) out[i] = a[i] * b[i]; }
static inline void volk_32f_s32f_multiply_32f(float* out, const float* a, const float s, unsigned int n) { for (unsigned i = 0; i < n; i++) out[i] = a[i] * s; }
static inline void volk_32f_accumulator_s32f(float* out, const float* a, unsigned int n) { float s = 0; for (unsigned i = 0; i < n; i++) s += a[i]; *out = s; }
