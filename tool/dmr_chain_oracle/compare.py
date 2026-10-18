#!/usr/bin/env python3
"""Compare pristine digiham and native Framing on the same synthetic dibits."""
from pathlib import Path
import subprocess
import sys


def observations(executable, dibits):
    proc = subprocess.run([str(executable)], input=dibits, capture_output=True,
                          check=True)
    voices = []
    states = {}
    transitions = []
    for line in proc.stdout.decode('utf-8').splitlines():
        kind, value = line.split(' ', 1)
        if kind == 'V':
            voices.append(bytes.fromhex(value))
        elif kind == 'M':
            fields = value.split(' ', 5)
            slot = fields[0]
            if states.get(slot) != fields:
                states[slot] = fields
                transitions.append(tuple(fields))
        else:
            raise ValueError(f"unexpected observation: {line}")
    return voices, transitions


def compare(ref, native):
    assert ref[0], 'fixture produced no voice frames'
    assert len(ref[0]) == len(native[0]), 'AMBE frame count differs'
    for index, (upstream, local) in enumerate(zip(ref[0], native[0])):
        assert upstream == local, f'AMBE frame {index} differs'
    assert ref[1], 'fixture produced no metadata'
    assert ref[1] == native[1], f'metadata transitions differ: {ref[1]} vs {native[1]}'
    assert len(ref[0]) >= 9 and len(ref[1]) >= 4, 'fixture did not exercise expected paths'
    return len(ref[0]), len(ref[1])


def main():
    build = Path(sys.argv[1])
    fixture = build / 'synthetic.dibits'
    subprocess.run([sys.executable, str(Path(__file__).with_name('generate.py')),
                    str(fixture)], check=True)
    dibits = fixture.read_bytes()
    ref = observations(build / 'pristine_replay', dibits)
    native = observations(build / 'native_replay', dibits)
    count, transitions = compare(ref, native)
    print(f'PASS: {count} AMBE frames byte-exact; {transitions} per-slot metadata transitions exact')
    # Ensure failures are meaningful instead of a vacuous always-pass comparator.
    mutated = ([b'\xff' * 9] + native[0][1:], native[1])
    try:
        compare(ref, mutated)
    except AssertionError:
        print('Comparator mutation (AMBE): rejected')
    else:
        raise AssertionError('comparator accepted corrupt voice frame')
    mutated = (native[0], native[1][:-1])
    try:
        compare(ref, mutated)
    except AssertionError:
        print('Comparator mutation (metadata): rejected')
    else:
        raise AssertionError('comparator accepted missing metadata')


if __name__ == '__main__':
    main()
