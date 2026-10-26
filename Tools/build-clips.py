#!/usr/bin/env python3
"""Build per-speaker, per-dialogue-segment MP3 clips for the two desktop pets.

The source recording contains two voices.  Tools/lines.json holds the
dialogue-segment boundaries, speaker role and subtitle text that were derived
from speaker diarization plus the burned-in captions of the original video.
Some entries merge consecutive same-speaker sentences into one segment so a
single click plays that whole turn.

Run with the project virtualenv:

    Tools/venv/bin/python Tools/build-clips.py

Add `--speed 1.5` for the "helium" (chipmunk) variant: every clip is
resampled to 1.5x speed *without* pitch preservation, so it plays 1.5x
faster and one perfect fifth (about +7 semitones) higher, and all subtitle
timings are divided by the same factor so captions stay in sync.

The project ships two matching sets used by the same two apps, switchable from
the right-click menu (声音模式):

    # 1.0x original (default)
    Tools/venv/bin/python Tools/build-clips.py

    # 1.5x helium
    Tools/venv/bin/python Tools/build-clips.py --speed 1.5

Outputs:
    Assets/Clips/<role>-<id>.mp3           normal voice
    Assets/clips.json                      normal manifest, with per-line timings
    Assets/Clips-helium/<role>-<id>.mp3    helium voice
    Assets/clips-helium.json               helium manifest, timings divided by speed
    Assets/pairs.json                      8 Lei->Yu dialogue pairs shared by both voices
"""

from __future__ import annotations

import argparse
import json
import sys
from fractions import Fraction
from pathlib import Path

import av
import numpy as np
from scipy.signal import resample_poly

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
    # Feed the final short frame as-is instead of zero-padding to a full frame:
    # lame handles the partial tail, and the encoded duration then matches the
    # resampled sample count exactly (important for the 1.5x timing maths).
    for start in range(0, len(samples), frame_size):
        chunk = samples[start : start + frame_size]
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


def helium(samples: np.ndarray, speed: float) -> np.ndarray:
    """Resample by `speed` without pitch preservation (faster *and* higher)."""
    if abs(speed - 1.0) < 1e-9:
        return samples
    ratio = Fraction(speed).limit_denominator(1000)
    # speed = numerator/denominator samples out per sample in -> swap for polyphase.
    out = resample_poly(samples, ratio.denominator, ratio.numerator)
    return out.astype(np.float32)


def main() -> int:
    parser = argparse.ArgumentParser(description="Slice dialogue clips out of the source recording.")
    parser.add_argument(
        "--speed",
        type=float,
        default=1.0,
        help="playback speed multiplier baked into the clips; pitch rises with it (1.5 = helium).",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=None,
        help="where the per-clip MP3s go (default: Assets/Clips, or Assets/Clips-helium for --speed 1.5).",
    )
    parser.add_argument(
        "--out-json",
        type=Path,
        default=None,
        help="where the clip manifest goes (default: Assets/clips.json, or Assets/clips-helium.json for --speed 1.5).",
    )
    args = parser.parse_args()
    speed = args.speed
    helium_default = abs(speed - 1.0) >= 1e-9
    out_dir = args.out_dir or (ROOT / "Assets/Clips-helium" if helium_default else OUT_DIR)
    out_json = args.out_json or (ROOT / "Assets/clips-helium.json" if helium_default else OUT_JSON)
    if not 0.25 <= speed <= 4.0:
        print(f"unsupported speed: {speed}", file=sys.stderr)
        return 1
    if not SOURCE.exists():
        print(f"missing source: {SOURCE}", file=sys.stderr)
        return 1
    lines = json.loads(LINES.read_text(encoding="utf-8"))
    audio = decode_source()
    print(f"speed: {speed:g}x")

    slices = [
        audio[int(round(line["start"] * SAMPLE_RATE)) : int(round(line["end"] * SAMPLE_RATE))]
        for line in lines
    ]
    slices = [helium(s, speed) for s in slices]
    # The source is a loud social-media mix whose decoded peaks overshoot 1.0.
    # Apply one global gain instead of per-clip normalisation so the two voices
    # and the background music keep their original balance.
    global_peak = max(float(np.max(np.abs(s))) for s in slices if len(s))
    global_gain = min(1.0, 0.97 / global_peak) if global_peak > 0 else 1.0
    print(f"global peak {global_peak:.3f}; applying gain {global_gain:.3f}")

    if out_dir.exists():
        for stale in out_dir.glob("*.mp3"):
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
        duration = encode_mp3(samples, out_dir / file_name)
        clip_lines = []
        for part in line.get("parts", []):
            start = max(0.0, (part["start"] - line["start"]) / speed)
            end = max(start, (part["end"] - line["start"]) / speed)
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

    out_json.write_text(json.dumps(clips, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

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

    print(f"\nwrote {len(clips)} clips to {out_dir.relative_to(ROOT) if out_dir.is_relative_to(ROOT) else out_dir}")
    print(f"wrote {out_json.relative_to(ROOT) if out_json.is_relative_to(ROOT) else out_json} ({counts['lei']} lei, {counts['yu']} yu)")
    print(f"wrote {OUT_PAIRS.relative_to(ROOT)} ({len(pairs)} dialogue pairs)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
