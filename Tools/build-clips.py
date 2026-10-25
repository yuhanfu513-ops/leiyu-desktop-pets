#!/usr/bin/env python3
"""Build per-speaker, per-dialogue-segment MP3 clips for the two desktop pets.

The source recording contains two voices.  Tools/lines.json holds the
dialogue-segment boundaries, speaker role and subtitle text that were derived
from speaker diarization plus the burned-in captions of the original video.
Some entries merge consecutive same-speaker sentences into one segment so a
single click plays that whole turn.

Run with the project virtualenv:

    Tools/venv/bin/python Tools/build-clips.py

Outputs:
    Assets/Clips/<role>-<id>.mp3
    Assets/clips.json          (consumed by the Swift app, with per-line timings)
    Assets/pairs.json          (8 Lei->Yu dialogue pairs for the near mode)
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import av
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Assets/encounter.m4a"
LINES = ROOT / "Tools/lines.json"
OUT_DIR = ROOT / "Assets/Clips"
OUT_JSON = ROOT / "Assets/clips.json"
OUT_PAIRS = ROOT / "Assets/pairs.json"
SAMPLE_RATE = 44_100
BIT_RATE = 128_000
FADE_SECONDS = 0.012


def decode_source() -> np.ndarray:
    container = av.open(str(SOURCE))
    stream = container.streams.audio[0]
    resampler = av.AudioResampler(format="flt", layout="mono", rate=SAMPLE_RATE)
    chunks: list[np.ndarray] = []
    for frame in container.decode(stream):
        for resampled in resampler.resample(frame):
            chunks.append(resampled.to_ndarray().reshape(-1))
    for resampled in resampler.resample(None):
        chunks.append(resampled.to_ndarray().reshape(-1))
    container.close()
    audio = np.concatenate(chunks).astype(np.float32)
    print(f"source: {len(audio) / SAMPLE_RATE:.3f}s @ {SAMPLE_RATE}Hz mono")
    return audio


def apply_fade(samples: np.ndarray) -> np.ndarray:
    n = min(int(FADE_SECONDS * SAMPLE_RATE), len(samples) // 4)
    if n < 2:
        return samples
    ramp = 0.5 - 0.5 * np.cos(np.linspace(0.0, np.pi, n, dtype=np.float32))
    samples = samples.copy()
    samples[:n] *= ramp
    samples[-n:] *= ramp[::-1]
    return samples


def speech_rms(samples: np.ndarray) -> float:
    frame = int(0.02 * SAMPLE_RATE)
    usable = len(samples) // frame * frame
    if usable == 0:
        return 0.0
    frames = samples[:usable].reshape(-1, frame)
    levels = np.sqrt((frames.astype(np.float64) ** 2).mean(axis=1))
    voiced = levels[levels > 0.01]
    return float(np.sqrt((voiced**2).mean())) if len(voiced) else float(levels.max())


def encode_mp3(samples: np.ndarray, path: Path) -> float:
    path.parent.mkdir(parents=True, exist_ok=True)
    container = av.open(str(path), "w", format="mp3")
    stream = container.add_stream("libmp3lame", rate=SAMPLE_RATE, layout="mono")
    stream.bit_rate = BIT_RATE
    frame_size = stream.codec_context.frame_size or 1152
    padded = np.pad(samples, (0, (-len(samples)) % frame_size))
    for start in range(0, len(padded), frame_size):
        chunk = padded[start : start + frame_size]
        frame = av.AudioFrame.from_ndarray(
            chunk.reshape(1, -1).astype(np.float32), format="fltp", layout="mono"
        )
        frame.sample_rate = SAMPLE_RATE
        frame.pts = start
        for packet in stream.encode(frame):
            container.mux(packet)
    for packet in stream.encode(None):
        container.mux(packet)
    container.close()

    # Read back the actual encoded duration so the app's self-test can rely on it.
    check = av.open(str(path))
    duration = float(check.duration / av.time_base) if check.duration else len(samples) / SAMPLE_RATE
    check.close()
    return round(duration, 3)


def main() -> int:
    if not SOURCE.exists():
        print(f"missing source: {SOURCE}", file=sys.stderr)
        return 1
    lines = json.loads(LINES.read_text(encoding="utf-8"))
    audio = decode_source()

    slices = [
        audio[int(round(line["start"] * SAMPLE_RATE)) : int(round(line["end"] * SAMPLE_RATE))]
        for line in lines
    ]
    # The source is a loud social-media mix whose decoded peaks overshoot 1.0.
    # Apply one global gain instead of per-clip normalisation so the two voices
    # and the background music keep their original balance.
    global_peak = max(float(np.max(np.abs(s))) for s in slices if len(s))
    global_gain = min(1.0, 0.97 / global_peak) if global_peak > 0 else 1.0
    print(f"global peak {global_peak:.3f}; applying gain {global_gain:.3f}")

    if OUT_DIR.exists():
        for stale in OUT_DIR.glob("*.mp3"):
            stale.unlink()

    clips = []
    counts = {"lei": 0, "yu": 0}
    for index, (line, samples) in enumerate(zip(lines, slices), start=1):
        role = line["role"]
        if role not in counts:
            print(f"line {index}: unknown role {role}", file=sys.stderr)
            return 1
        counts[role] += 1
        samples = apply_fade(samples * global_gain)
        peak = float(np.max(np.abs(samples))) if len(samples) else 0.0
        file_name = f"{role}-{counts[role]:02d}.mp3"
        duration = encode_mp3(samples, OUT_DIR / file_name)
        clip_lines = []
        for part in line.get("parts", []):
            start = max(0.0, part["start"] - line["start"])
            end = max(start, part["end"] - line["start"])
            clip_lines.append(
                {"start": round(start, 3), "end": round(min(end, duration), 3), "text": part["text"]}
            )
        if not clip_lines:
            clip_lines.append({"start": 0.0, "end": duration, "text": line["text"]})
        clips.append(
            {
                "id": index,
                "role": role,
                "text": line["text"],
                "file": file_name,
                "duration": duration,
                "lines": clip_lines,
            }
        )
        rms_db = 20 * np.log10(max(speech_rms(samples), 1e-9))
        label = line["text"].replace("\n", " / ")
        print(
            f"{index:2d} {role:3s} {line['start']:5.2f}-{line['end']:5.2f}"
            f" {duration:4.2f}s lines={len(clip_lines)} rms={rms_db:5.1f}dB peak={peak:.2f}  {label}"
        )

    OUT_JSON.write_text(json.dumps(clips, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    pair_roles: dict[int, dict[str, int]] = {}
    for index, line in enumerate(lines, start=1):
        pair_id = line.get("pair")
        if pair_id is None:
            continue
        slot = pair_roles.setdefault(int(pair_id), {})
        if line["role"] in slot:
            print(f"pair {pair_id}: duplicate {line['role']} clip", file=sys.stderr)
            return 1
        slot[line["role"]] = index
    pairs = []
    for pair_id in sorted(pair_roles):
        slot = pair_roles[pair_id]
        if "lei" not in slot or "yu" not in slot:
            print(f"pair {pair_id}: missing lei or yu clip", file=sys.stderr)
            return 1
        pairs.append({"id": pair_id, "lei": slot["lei"], "yu": slot["yu"]})
    OUT_PAIRS.write_text(json.dumps(pairs, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"\nwrote {len(clips)} clips to {OUT_DIR.relative_to(ROOT)}")
    print(f"wrote {OUT_JSON.relative_to(ROOT)} ({counts['lei']} lei, {counts['yu']} yu)")
    print(f"wrote {OUT_PAIRS.relative_to(ROOT)} ({len(pairs)} dialogue pairs)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
