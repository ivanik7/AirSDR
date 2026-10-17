// SPDX-License-Identifier: GPL-3.0-or-later
//
// Link-time placeholders for rtl_433 symbols that only its CLI front end
// reaches. Built for macOS and Windows only.
//
// The in-process adapter (rtl433.cpp) uses r_api/r_flow, but never calls the
// output, dumper or SDR entry points of r_api.c (add_*_output, close_dumpers,
// r_free_cfg, get_mgr, ...). Those functions reference rtl_433's network
// outputs (mongoose), file writers and its own SDR layer, which are
// deliberately not compiled. On ELF targets --gc-sections drops the
// unreferenced functions together with their references. lld for COFF and
// Apple's ld64, however, resolve undefined symbols before dead stripping, so
// the references need definitions. Each placeholder aborts: reaching one
// would be a bug in the adapter, not a supported code path. On Linux the same
// set is provably unreachable, because libsdrcore.so links with no undefined
// rtl_433 symbols.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "http_server.h"
#include "output_file.h"
#include "output_influx.h"
#include "output_log.h"
#include "output_mqtt.h"
#include "output_rtltcp.h"
#include "output_trigger.h"
#include "output_udp.h"
#include "sdr.h"
#include "write_sigrok.h"

#include "mongoose.h"

static void unreachable(const char *name) {
  fprintf(stderr, "sdrcore: rtl_433 CLI-only symbol %s was called\n", name);
  abort();
}

#define UNREACHABLE(name) unreachable(#name)

struct data_output *data_output_csv_create(int log_level, char const *path) {
  (void)log_level; (void)path;
  UNREACHABLE(data_output_csv_create);
  return NULL;
}
struct data_output *data_output_json_create(int log_level, char const *path) {
  (void)log_level; (void)path;
  UNREACHABLE(data_output_json_create);
  return NULL;
}
struct data_output *data_output_kv_create(int log_level, char const *path) {
  (void)log_level; (void)path;
  UNREACHABLE(data_output_kv_create);
  return NULL;
}
struct data_output *data_output_log_create(int log_level, char const *path) {
  (void)log_level; (void)path;
  UNREACHABLE(data_output_log_create);
  return NULL;
}
struct data_output *data_output_syslog_create(int log_level, const char *host,
                                              const char *port) {
  (void)log_level; (void)host; (void)port;
  UNREACHABLE(data_output_syslog_create);
  return NULL;
}
struct data_output *data_output_mqtt_create(struct mg_mgr *mgr, char *param,
                                            char const *dev_hint) {
  (void)mgr; (void)param; (void)dev_hint;
  UNREACHABLE(data_output_mqtt_create);
  return NULL;
}
struct data_output *data_output_influx_create(struct mg_mgr *mgr, char *opts) {
  (void)mgr; (void)opts;
  UNREACHABLE(data_output_influx_create);
  return NULL;
}
struct data_output *data_output_http_create(struct mg_mgr *mgr, const char *host,
                                            const char *port, struct r_cfg *cfg) {
  (void)mgr; (void)host; (void)port; (void)cfg;
  UNREACHABLE(data_output_http_create);
  return NULL;
}
struct data_output *data_output_trigger_create(char const *path) {
  (void)path;
  UNREACHABLE(data_output_trigger_create);
  return NULL;
}
struct raw_output *raw_output_rtltcp_create(char const *host, char const *port,
                                            char const *opts, struct r_cfg *cfg) {
  (void)host; (void)port; (void)opts; (void)cfg;
  UNREACHABLE(raw_output_rtltcp_create);
  return NULL;
}
void mg_mgr_init(struct mg_mgr *mgr, void *user_data) {
  (void)mgr; (void)user_data;
  UNREACHABLE(mg_mgr_init);
}
void mg_mgr_free(struct mg_mgr *mgr) {
  (void)mgr;
  UNREACHABLE(mg_mgr_free);
}
// data_tag.c's gpsd client; the adapter never adds GPS data tags.
void mg_send(struct mg_connection *nc, const void *buf, int len) {
  (void)nc; (void)buf; (void)len;
  UNREACHABLE(mg_send);
}
void mbuf_remove(struct mbuf *mb, size_t data_size) {
  (void)mb; (void)data_size;
  UNREACHABLE(mbuf_remove);
}
struct mg_connection *mg_connect_opt(struct mg_mgr *mgr, const char *address,
                                     MG_CB(mg_event_handler_t handler,
                                           void *user_data),
                                     struct mg_connect_opts opts) {
  (void)mgr; (void)address; (void)handler; (void)opts;
  UNREACHABLE(mg_connect_opt);
  return NULL;
}
void write_sigrok(char const *filename, unsigned samplerate, unsigned probes,
                  unsigned analogs, char const *labels[]) {
  (void)filename; (void)samplerate; (void)probes; (void)analogs; (void)labels;
  UNREACHABLE(write_sigrok);
}
void open_pulseview(char const *filename) {
  (void)filename;
  UNREACHABLE(open_pulseview);
}
int sdr_close(sdr_dev_t *dev) {
  (void)dev;
  UNREACHABLE(sdr_close);
  return -1;
}
int sdr_deactivate(sdr_dev_t *dev) {
  (void)dev;
  UNREACHABLE(sdr_deactivate);
  return -1;
}
int sdr_set_center_freq(sdr_dev_t *dev, uint32_t freq, int verbose) {
  (void)dev; (void)freq; (void)verbose;
  UNREACHABLE(sdr_set_center_freq);
  return -1;
}
int sdr_set_freq_correction(sdr_dev_t *dev, int ppm, int verbose) {
  (void)dev; (void)ppm; (void)verbose;
  UNREACHABLE(sdr_set_freq_correction);
  return -1;
}
int sdr_set_tuner_gain(sdr_dev_t *dev, char const *gain_str, int verbose) {
  (void)dev; (void)gain_str; (void)verbose;
  UNREACHABLE(sdr_set_tuner_gain);
  return -1;
}
int sdr_set_sample_rate(sdr_dev_t *dev, uint32_t rate, int verbose) {
  (void)dev; (void)rate; (void)verbose;
  UNREACHABLE(sdr_set_sample_rate);
  return -1;
}
