#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# ZirconOSAero — procedural Aero system sounds (ffmpeg).
# Writes only the five wallpaper-aligned theme dirs: Architecture, Characters,
# Landscapes, Nature, Scenes (no legacy alias folders).

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOUNDS = REPO_ROOT / "src/desktop/aero/resources/sounds"
SR = 44100

THEMES = ("Architecture", "Characters", "Landscapes", "Nature", "Scenes")

# f_mul: pitch scale; delays/decays: stereo aecho; bright: output gain into loudnorm;
# startup_stretch: multiplies startup phrase note lengths; shutdown_tail: fade-out start (s).
THEME_PARAMS: dict[str, dict[str, float | str]] = {
    "Architecture": {
        "f_mul": 1.12,
        "delays": "10|18",
        "decays": "0.28|0.22",
        "bright": 1.05,
        "startup_stretch": 0.88,
        "shutdown_tail": 2.05,
    },
    "Characters": {
        "f_mul": 0.90,
        "delays": "24|40",
        "decays": "0.44|0.40",
        "bright": 0.94,
        "startup_stretch": 1.12,
        "shutdown_tail": 2.25,
    },
    "Landscapes": {
        "f_mul": 1.0,
        "delays": "18|44",
        "decays": "0.38|0.42",
        "bright": 0.98,
        "startup_stretch": 1.08,
        "shutdown_tail": 2.15,
    },
    "Nature": {
        "f_mul": 0.88,
        "delays": "20|32",
        "decays": "0.36|0.34",
        "bright": 0.92,
        "startup_stretch": 1.15,
        "shutdown_tail": 2.35,
    },
    "Scenes": {
        "f_mul": 1.05,
        "delays": "30|54",
        "decays": "0.50|0.54",
        "bright": 1.0,
        "startup_stretch": 1.0,
        "shutdown_tail": 1.95,
    },
}

# Order matches per-theme Desktop.ini
WAV_NAMES: list[str] = [
    "ZirconOS Balloon.wav",
    "ZirconOS Battery Critical.wav",
    "ZirconOS Battery Low.wav",
    "ZirconOS Critical Stop.wav",
    "ZirconOS Default.wav",
    "ZirconOS Ding.wav",
    "ZirconOS Error.wav",
    "ZirconOS Exclamation.wav",
    "ZirconOS Hardware Fail.wav",
    "ZirconOS Hardware Insert.wav",
    "ZirconOS Hardware Remove.wav",
    "ZirconOS Logoff Sound.wav",
    "ZirconOS Logon Sound.wav",
    "ZirconOS Startup.wav",
    "ZirconOS Notify.wav",
    "ZirconOS Print complete.wav",
    "ZirconOS Shutdown.wav",
    "ZirconOS Navigation Start.wav",
    "ZirconOS Information Bar.wav",
    "ZirconOS Pop-up Blocked.wav",
    "ZirconOS User Account Control.wav",
]

DESKTOP_INI_BODY = """[LocalizedFileNames]
ZirconOS Balloon.wav=Balloon
ZirconOS Battery Critical.wav=Battery Critical
ZirconOS Battery Low.wav=Battery Low
ZirconOS Critical Stop.wav=Critical Stop
ZirconOS Default.wav=Default
ZirconOS Ding.wav=Ding
ZirconOS Error.wav=Error
ZirconOS Exclamation.wav=Exclamation
ZirconOS Hardware Fail.wav=Hardware Fail
ZirconOS Hardware Insert.wav=Hardware Insert
ZirconOS Hardware Remove.wav=Hardware Remove
ZirconOS Logoff Sound.wav=Logoff Sound
ZirconOS Logon Sound.wav=Logon Sound
ZirconOS Startup.wav=Startup
ZirconOS Notify.wav=Notify
ZirconOS Print complete.wav=Print Complete
ZirconOS Shutdown.wav=Shutdown
ZirconOS Navigation Start.wav=Navigation Start
ZirconOS Information Bar.wav=Information Bar
ZirconOS Pop-up Blocked.wav=Pop-up Blocked
ZirconOS User Account Control.wav=User Account Control
"""


def _run(cmd: list[str]) -> None:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr or r.stdout or "ffmpeg failed\n")
        raise subprocess.CalledProcessError(r.returncode, cmd)


def _theme_tail(theme: dict[str, float | str]) -> str:
    return (
        f"aecho=0.82:0.88:{theme['delays']}:{theme['decays']},"
        f"highpass=f=50,lowpass=f=15000,"
        f"volume={float(theme['bright']):.3f},"
        "loudnorm=I=-18:TP=-1.5:LRA=11:linear=true"
    )


def _ff_single(
    out: Path,
    theme: dict[str, float | str],
    freq: float,
    duration: float,
    fade_in: float = 0.018,
    fade_out_start_ratio: float = 0.52,
) -> None:
    fm = freq * float(theme["f_mul"])
    dur = max(duration, 0.05)
    fos = dur * fade_out_start_ratio
    foe = max(dur - fos, 0.025)
    af = f"afade=t=in:st=0:d={fade_in:.4f},afade=t=out:st={fos:.4f}:d={foe:.4f}," + _theme_tail(theme)
    _run(
        [
            "ffmpeg",
            "-nostdin",
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency={fm:.4f}:sample_rate={SR}:duration={dur:.4f}",
            "-af",
            af,
            "-ar",
            str(SR),
            "-ac",
            "2",
            "-sample_fmt",
            "s16",
            str(out),
        ]
    )


def _ff_dual_tone(
    out: Path,
    theme: dict[str, float | str],
    f1: float,
    f2: float,
    duration: float,
    mix: str = "0.62|0.38",
) -> None:
    """Two sines amixed for mild harmonic color."""
    m = float(theme["f_mul"])
    fm1, fm2 = f1 * m, f2 * m
    dur = max(duration, 0.06)
    fos = dur * 0.5
    foe = max(dur - fos, 0.03)
    fc = (
        f"[0:a][1:a]amix=inputs=2:duration=first:weights={mix}[mx];"
        f"[mx]afade=t=in:st=0:d=0.02,afade=t=out:st={fos:.4f}:d={foe:.4f},"
        + _theme_tail(theme)
    )
    _run(
        [
            "ffmpeg",
            "-nostdin",
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency={fm1:.4f}:sample_rate={SR}:duration={dur:.4f}",
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency={fm2:.4f}:sample_rate={SR}:duration={dur:.4f}",
            "-filter_complex",
            fc,
            "-ar",
            str(SR),
            "-ac",
            "2",
            "-sample_fmt",
            "s16",
            str(out),
        ]
    )


def _ff_concat_sines(out: Path, theme: dict[str, float | str], freqs_durs: list[tuple[float, float]]) -> None:
    ins: list[str] = []
    labels: list[str] = []
    for i, (f0, d0) in enumerate(freqs_durs):
        fm = f0 * float(theme["f_mul"])
        ins.extend(["-f", "lavfi", "-i", f"sine=frequency={fm:.4f}:sample_rate={SR}:duration={d0:.4f}"])
        labels.append(f"[{i}:a]")
    n = len(freqs_durs)
    concat = "".join(labels) + f"concat=n={n}:v=0:a=1[ac];[ac]" + _theme_tail(theme)
    _run(["ffmpeg", "-nostdin", "-y", *ins, "-filter_complex", concat, "-ar", str(SR), "-ac", "2", "-sample_fmt", "s16", str(out)])


def _ff_noise(out: Path, theme: dict[str, float | str], duration: float, hp: int, lp: int, am: float) -> None:
    dur = max(duration, 0.08)
    fos = dur * 0.52
    foe = max(dur - fos, 0.03)
    tail = (
        f"aecho=0.82:0.88:{theme['delays']}:{theme['decays']},"
        f"highpass=f=50,lowpass=f=15000,"
        f"volume={float(theme['bright']) * am:.3f},"
        "loudnorm=I=-18:TP=-1.5:LRA=11:linear=true"
    )
    af = f"afade=t=in:st=0:d=0.03,afade=t=out:st={fos:.4f}:d={foe:.4f},highpass=f={hp},lowpass=f={lp}," + tail
    _run(
        [
            "ffmpeg",
            "-nostdin",
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"anoisesrc=color=pink:sample_rate={SR}:duration={dur:.4f}:amplitude={am}",
            "-af",
            af,
            "-ar",
            str(SR),
            "-ac",
            "2",
            "-sample_fmt",
            "s16",
            str(out),
        ]
    )


def _ff_nav_whoosh(out: Path, theme: dict[str, float | str]) -> None:
    d = 0.32
    tail = (
        f"aecho=0.82:0.88:{theme['delays']}:{theme['decays']},"
        f"highpass=f=350,lowpass=f=6200,"
        f"volume={0.52 * float(theme['bright']):.3f},"
        "loudnorm=I=-18:TP=-1.5:LRA=11:linear=true"
    )
    af = f"afade=t=in:st=0:d=0.04,afade=t=out:st=0.18:d=0.12," + tail
    _run(
        [
            "ffmpeg",
            "-nostdin",
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"anoisesrc=color=white:sample_rate={SR}:duration={d}:amplitude=0.38",
            "-af",
            af,
            "-ar",
            str(SR),
            "-ac",
            "2",
            "-sample_fmt",
            "s16",
            str(out),
        ]
    )


def _ff_startup(out: Path, theme: dict[str, float | str]) -> None:
    """~3.5–4.2 s boot fanfare: layered C-major-ish phrase, length scaled per theme."""
    stretch = float(theme["startup_stretch"])
    # (Hz base, duration s) — bright rising line + resolution
    phrase: list[tuple[float, float]] = [
        (261.63, 0.42),
        (329.63, 0.38),
        (392.0, 0.42),
        (523.25, 0.52),
        (659.25, 0.55),
        (783.99, 0.58),
        (1046.5, 0.72),
    ]
    freqs_durs = [(f, d * stretch) for f, d in phrase]
    _ff_concat_sines(out, theme, freqs_durs)


def _ff_shutdown(out: Path, theme: dict[str, float | str]) -> None:
    t = theme
    tail_start = float(t["shutdown_tail"])
    total = 3.55
    fm1 = 196 * float(t["f_mul"])
    fm2 = 147 * float(t["f_mul"])
    fm3 = 123.47 * float(t["f_mul"])
    fc = (
        f"[0:a][1:a][2:a]amix=inputs=3:duration=longest:weights=0.5 0.45 0.35[mx];"
        f"[mx]afade=t=in:st=0:d=0.12,afade=t=out:st={tail_start:.2f}:d={total - tail_start:.2f},"
        f"aecho=0.82:0.88:{t['delays']}:{t['decays']},"
        f"highpass=f=45,lowpass=f=6500,volume={0.82 * float(t['bright']):.3f},"
        "loudnorm=I=-18:TP=-1.5:LRA=11:linear=true"
    )
    _run(
        [
            "ffmpeg",
            "-nostdin",
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency={fm1:.4f}:sample_rate={SR}:duration={total:.2f}",
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency={fm2:.4f}:sample_rate={SR}:duration={total:.2f}",
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency={fm3:.4f}:sample_rate={SR}:duration={total:.2f}",
            "-filter_complex",
            fc,
            "-ar",
            str(SR),
            "-ac",
            "2",
            "-sample_fmt",
            "s16",
            str(out),
        ]
    )


def generate_wav(name: str, theme_name: str, out: Path) -> None:
    t = THEME_PARAMS[theme_name]
    if name == "ZirconOS Balloon.wav":
        _ff_concat_sines(out, t, [(349.23, 0.14), (440.0, 0.14), (523.25, 0.2)])
    elif name == "ZirconOS Battery Critical.wav":
        _ff_concat_sines(out, t, [(98, 0.16), (73, 0.18), (98, 0.18), (73, 0.2)])
    elif name == "ZirconOS Battery Low.wav":
        _ff_concat_sines(out, t, [(130, 0.14), (110, 0.12), (130, 0.14)])
    elif name == "ZirconOS Critical Stop.wav":
        _ff_concat_sines(out, t, [(220, 0.1), (165, 0.14), (110, 0.18)])
    elif name == "ZirconOS Default.wav":
        _ff_dual_tone(out, t, 523.25, 392.0, 0.16)
    elif name == "ZirconOS Ding.wav":
        _ff_dual_tone(out, t, 783.99, 1174.66, 0.2, mix="0.58|0.32")
    elif name == "ZirconOS Error.wav":
        _ff_concat_sines(out, t, [(415, 0.12), (330, 0.12), (262, 0.14), (196, 0.16)])
    elif name == "ZirconOS Exclamation.wav":
        _ff_dual_tone(out, t, 440.0, 554.37, 0.14)
    elif name == "ZirconOS Hardware Fail.wav":
        _ff_noise(out, t, 0.24, hp=200, lp=7500, am=0.58)
    elif name == "ZirconOS Hardware Insert.wav":
        _ff_concat_sines(out, t, [(280, 0.07), (400, 0.07), (530, 0.08), (700, 0.09), (880, 0.12)])
    elif name == "ZirconOS Hardware Remove.wav":
        _ff_concat_sines(out, t, [(880, 0.07), (660, 0.07), (470, 0.08), (330, 0.1), (220, 0.12)])
    elif name == "ZirconOS Logoff Sound.wav":
        _ff_concat_sines(out, t, [(784, 0.18), (659, 0.18), (523, 0.2), (392, 0.22), (294, 0.28)])
    elif name == "ZirconOS Logon Sound.wav":
        _ff_concat_sines(out, t, [(349, 0.22), (440, 0.22), (523, 0.26), (659, 0.32), (784, 0.42)])
    elif name == "ZirconOS Startup.wav":
        _ff_startup(out, t)
    elif name == "ZirconOS Notify.wav":
        _ff_dual_tone(out, t, 659.25, 880.0, 0.2)
    elif name == "ZirconOS Print complete.wav":
        _ff_concat_sines(out, t, [(523.25, 0.1), (659.25, 0.08), (783.99, 0.14)])
    elif name == "ZirconOS Shutdown.wav":
        _ff_shutdown(out, t)
    elif name == "ZirconOS Navigation Start.wav":
        _ff_nav_whoosh(out, t)
    elif name == "ZirconOS Information Bar.wav":
        _ff_dual_tone(out, t, 349.23, 261.63, 0.16)
    elif name == "ZirconOS Pop-up Blocked.wav":
        _ff_concat_sines(out, t, [(587, 0.055), (523, 0.05), (587, 0.055), (523, 0.05), (587, 0.07)])
    elif name == "ZirconOS User Account Control.wav":
        _ff_concat_sines(out, t, [(392, 0.14), (523, 0.14), (659, 0.18)])
    else:
        raise ValueError(f"unknown sound {name}")


def write_desktop_ini(theme_dir: Path) -> None:
    (theme_dir / "Desktop.ini").write_text(DESKTOP_INI_BODY, encoding="utf-8")


def main() -> int:
    subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
    SOUNDS.mkdir(parents=True, exist_ok=True)

    for th in THEMES:
        d = SOUNDS / th
        d.mkdir(parents=True, exist_ok=True)
        write_desktop_ini(d)
        for w in WAV_NAMES:
            generate_wav(w, th, d / w)
        print(f"generated {len(WAV_NAMES)} files in {d.relative_to(REPO_ROOT)}")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as e:
        print("ffmpeg failed:", e, file=sys.stderr)
        raise SystemExit(1)
    except FileNotFoundError:
        print("ffmpeg not found; install ffmpeg and retry.", file=sys.stderr)
        raise SystemExit(1)
