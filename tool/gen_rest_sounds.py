#!/usr/bin/env python3
"""Generate the two rest-timer cue WAVs bundled in assets/sounds/.

Run from the package root:  python3 tool/gen_rest_sounds.py

The cues are deliberately quiet and short: the tick is a low-amplitude 880 Hz
blip, the "go" tone is a rising two-note figure. Amplitude is baked into the
samples so the cues stay modest even on a device that ignores per-stream
volume. Mono 16-bit PCM at 44.1 kHz, no dependencies beyond the stdlib.
"""

import math
import os
import struct
import wave

RATE = 44100
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "sounds")


def tone(freq, ms, peak, attack_ms=4.0, release_ms=None):
    """One note: sine with a short attack and an exponential decay tail."""
    n = int(RATE * ms / 1000)
    attack = max(1, int(RATE * attack_ms / 1000))
    release = max(1, int(RATE * (release_ms if release_ms is not None else ms * 0.6) / 1000))
    samples = []
    for i in range(n):
        env = 1.0
        if i < attack:
            env = i / attack
        tail_start = n - release
        if i >= tail_start:
            env *= math.exp(-4.0 * (i - tail_start) / release)
        samples.append(peak * env * math.sin(2 * math.pi * freq * i / RATE))
    return samples


def silence(ms):
    return [0.0] * int(RATE * ms / 1000)


def write_wav(name, samples):
    path = os.path.join(OUT_DIR, name)
    os.makedirs(OUT_DIR, exist_ok=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = b"".join(
            struct.pack("<h", max(-32768, min(32767, int(round(s * 32767)))))
            for s in samples
        )
        w.writeframes(frames)
    print(f"{path}: {len(samples) / RATE * 1000:.0f} ms, {os.path.getsize(path)} bytes")


def main():
    # 5s warning: one short, quiet tick.
    write_wav("rest_tick.wav", tone(880, 70, 0.16, attack_ms=3.0, release_ms=45.0))
    # Rest over: rising two-note "go" figure, clearly brighter than the tick.
    go = tone(1000, 90, 0.30, attack_ms=3.0, release_ms=25.0)
    go += silence(8)
    go += tone(1400, 130, 0.32, attack_ms=3.0, release_ms=90.0)
    write_wav("rest_go.wav", go)


if __name__ == "__main__":
    main()
