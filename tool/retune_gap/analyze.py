#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Summarize host Blog V4 audio production and a 60-ms/192-frame callback model.

The model is not actual device output: neither WAV nor Dart sink captures an
AAudio callback. Per-frequency RMS is RF-dependent and cannot prove switching
continuity across different stations.
"""
import csv
import json
import math
import struct
import sys
import wave
from array import array
from pathlib import Path

ROOT = Path(sys.argv[1])
RATE = 48000
BURST = 192
PREFILL = 60 * RATE // 1000


def percentile(values, fraction):
    values = sorted(values)
    return values[round((len(values) - 1) * fraction)] if values else 0.0


def load(kind, mode):
    path = ROOT / f'{kind}-{mode}.jsonl'
    events = [json.loads(s) for s in path.read_text().splitlines() if s.startswith('{')]
    if kind == 'native':
        applied = [x for x in events if x['event'] == 'applied']
        assert len(applied) == len([x for x in events if x['event'] == 'switch'])
        assert all(x['applied_ms'] >= 0 for x in applied), 'missing LO snapshot'
        switches = [dict(x, **{'applied_ms': applied[i]['applied_ms'],
                               'dropped_samples': applied[i]['dropped_samples'],
                               'audio_dropped_frames': applied[i]['audio_dropped_frames']})
                    for i, x in enumerate(x for x in events if x['event'] == 'switch')]
        # Align requests to the native poller's monotonic clock (t0).
        for i, item in enumerate(switches):
            item['t_us'] = round(applied[i]['t_ms'] * 1000)
        log = (ROOT / f'native-{mode}.log').read_text()
        timeline = [line.split(',') for line in
                    (ROOT / f'native-{mode}-timeline.csv').read_text().splitlines()]
        writes = []
        for prev, cur in zip(timeline, timeline[1:]):
            delta = int(cur[1]) - int(prev[1])
            if delta:
                writes.append({'t_us': round(float(cur[0]) * 1000), 'frames': delta})
        with wave.open(str(ROOT / f'native-{mode}.wav')) as wav:
            frame_count = wav.getnframes()
            raw = wav.readframes(frame_count)
            samples = struct.unpack('<' + 'h' * (len(raw) // 2), raw)[::2]
            samples = [s / 32768 for s in samples]
        return switches, writes, samples, log
    switches = [x for x in events if x['event'] == 'switch']
    writes = [x for x in events if x['event'] == 'write']
    raw = (ROOT / f'dart-{mode}.f32').read_bytes()
    samples = struct.unpack('<' + 'f' * (len(raw) // 4), raw)[::2]
    return switches, writes, samples, ''


def model(switches, writes, samples, output):
    start = switches[0]['t_us']
    # Do not invent callback ticks after the recorded producer has stopped.
    end = min(switches[-1]['t_us'] + 350000, writes[-1]['t_us'])
    level = PREFILL
    produced = 0
    zeros = 0
    underflows = 0
    minimum = PREFILL
    writer = 0
    per_switch = [0] * len(switches)
    switch_index = 0
    played = array('h')
    playhead = max(0, switches[0]['frame'] - PREFILL)
    for t in range(start + 4000, end, 4000):
        while switch_index + 1 < len(switches) and t >= switches[switch_index + 1]['t_us']:
            switch_index += 1
        while writer < len(writes) and writes[writer]['t_us'] <= t:
            if writes[writer]['t_us'] >= start:
                produced += writes[writer]['frames']
            writer += 1
        level += produced
        produced = 0
        take = min(level, BURST)
        played.extend(max(-32768, min(32767, round(sample * 32767)))
                      for sample in samples[playhead:playhead + take])
        playhead += take
        if level < BURST:
            zeros += BURST - level
            per_switch[switch_index] += BURST - level
            underflows += 1
            played.extend([0] * (BURST - level))
            level = 0
        else:
            level -= BURST
        minimum = min(minimum, level)
    with wave.open(str(output), 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes(played.tobytes())
    return zeros, underflows, minimum * 1000 / RATE, per_switch


def rms(values):
    return math.sqrt(sum(v * v for v in values) / len(values)) if values else 0


def rms_hole(samples, frame):
    # Produced samples (not RF-station identification). Compare with the
    # 50 ms directly before the request; 2 ms windows over the next 100 ms.
    baseline = rms(samples[max(0, frame - 2400):frame])
    if baseline < .001:
        return None
    current = longest = 0
    for start in range(frame, min(len(samples) - 96, frame + 4800), 96):
        if rms(samples[start:start + 96]) < baseline * .25:
            current += 2
            longest = max(longest, current)
        else:
            current = 0
    return longest


def summary(kind, mode):
    switches, writes, samples, log = load(kind, mode)
    assert len(switches) == 40, f'{kind} {mode}: incomplete switch sequence'
    assert all(x['frame'] < len(samples) for x in switches)
    print(f'\n{kind} {mode}: {len(switches)} switches, {len(samples)} sink frames')
    if kind == 'native':
        apply = [x['applied_ms'] for x in switches]
        print('request->reported-LO median/p95/max ms:', *(round(percentile(apply, p), 2) for p in (0.5, 0.95, 1)))
        print('ring model 60-ms prefill:', [s for s in log.splitlines() if 'prefill=60ms' in s])
        print('I2C -9:', log.count('r82xx_set_freq: failed=-9'))
        print('IQ/sink drops latest:', switches[-1]['dropped_samples'], switches[-1]['audio_dropped_frames'])
    else:
        call = [(x['done_us'] - x['t_us']) / 1000 for x in switches]
        print('Dart tune call median/p95/max ms:', *(round(percentile(call, p), 2) for p in (0.5, 0.95, 1)))
        print('I2C -9:', (ROOT / f'dart-{mode}-run.log').read_text().count('r82xx_set_freq: failed=-9'))
    zeros, underflows, min_ms, per_switch = model(
        switches, writes, samples, ROOT / f'model-{kind}-{mode}.wav')
    print('60-ms callback MODEL (not actual): zeros, underflows, min cushion ms:', zeros, underflows, round(min_ms, 2))
    print('model zero-fill per switch p50/p95/max ms:',
          *(round(percentile(per_switch, p) * 1000 / RATE, 2)
            for p in (0.5, 0.95, 1)))
    print('model zero frames per switch:', per_switch)
    holes = [rms_hole(samples, int(x['frame'])) for x in switches]
    # A sink write is not proof that the new RF station has arrived. This
    # measures producer scheduling only, using the reported LO snapshot on
    # native and the end of the synchronous tune call on historical Dart.
    post_tune_write = []
    for x in switches:
        end_us = (x['t_us'] + round(x['applied_ms'] * 1000)
                  if kind == 'native' else x['done_us'])
        next_write = next((w['t_us'] for w in writes if w['t_us'] >= end_us), None)
        post_tune_write.append((next_write - x['t_us']) / 1000
                               if next_write is not None else None)
    delays = [x for x in post_tune_write if x is not None]
    print('request->first post-tune write p50/p95/max ms (NOT new-station audio):',
          *(round(percentile(delays, p), 2) for p in (0.5, 0.95, 1)))
    print('produced RMS holes p50/p95/max ms:',
          *(percentile([h for h in holes if h is not None], p)
            for p in (0.5, 0.95, 1)))
    with (ROOT / f'switches-{kind}-{mode}.csv').open('w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(('index', 'center_hz', 'request_us', 'reported_apply_ms',
                         'tune_call_ms', 'sink_frame_at_request',
                         'first_post_tune_write_ms', 'model_zero_frames',
                         'produced_rms_hole_ms'))
        for i, (x, zeros_at_switch, hole, delay) in enumerate(
                zip(switches, per_switch, holes, post_tune_write)):
            writer.writerow((i, x['center'], x['t_us'], x.get('applied_ms', ''),
                             round((x['done_us'] - x['t_us']) / 1000, 3)
                             if kind == 'dart' else '', x['frame'], delay,
                             zeros_at_switch, hole))
    # Station-dependent RMS windows, after 120ms settling (from frame anchored
    # at switch) to the next switch, and quiet windows just before each switch.
    per = []
    for x in switches:
        frame = x['frame']
        a = max(0, frame - int(0.09 * RATE))
        b = max(0, frame - int(0.02 * RATE))
        c = min(len(samples), frame + int(0.12 * RATE))
        d = min(len(samples), frame + int(0.25 * RATE))
        per.append((rms(samples[a:b]), rms(samples[c:d])))
    print('pre/post RMS first 10:', [(round(a, 4), round(b, 4)) for a,b in per[:10]])
    print('RMS post zero stations:', sum(b < .0001 for _, b in per))


for mode in ('wfm', 'nfm'):
    for kind in ('dart', 'native'):
        summary(kind, mode)
