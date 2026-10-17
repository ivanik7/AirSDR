# Frequency-switch audio gap: Blog V4 host benchmark

Full methodology, raw-data index, code-path comparison, limitations, and test results: [docs/status/retune-gap.md](docs/status/retune-gap.md). Per-switch CSV timelines and sink/model WAVs: `/home/ivan/prj/docs/retune-gap/`.

| 40 switches at 2.4 MS/s | Dart WFM | Native WFM | Dart NFM | Native NFM |
| --- | ---: | ---: | ---: | ---: |
| Request to synchronous call return (Dart) / reported LO (native), p50 / p95 / max ms | 67.39 / 80.19 / 80.48 | 66.26 / 67.34 / 67.66 | 74.97 / 75.41 / 75.71 | 57.00 / 57.51 / 74.66 |
| Request to first *post-tune sink write*, p50 / p95 / max ms | 68.18 / 80.97 / 81.38 | 66.40 / 68.50 / 69.05 | 75.46 / 76.09 / 76.55 | 57.83 / 58.77 / 75.37 |
| **Modeled** 60 ms / 192-frame callback zero-fill per switch, p50 / p95 / max ms | 35.73 / 46.83 / 49.29 | 0 / 0 / 0 | 41.27 / 42.83 / 45.27 | 0 / 0 / 0 |

This is host sink production and a *modeled* callback, not actual playback. The first sink write is not identified as the new station; station-specific RF latency and audible Android results remain unverified. The Dart model does not reproduce the user's prior phone listening result. Transient tuner I2C `-9` errors occurred (especially on Dart) and are disclosed in the full report. The previously merged RDS filter-bank reset fix remains in place; no new receiver-path fix was necessary based on these host runs.
