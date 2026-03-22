# ZirconOS Aero Sound Schemes

Original sound scheme definitions for ZirconOS Aero desktop.

## Structure

```
sounds/
├── sound_scheme.conf      # Main sound scheme configuration (event → WAV mappings)
├── Desktop.ini            # Root-level localized file name mappings
├── README.md              # This file
├── Afternoon/             # Afternoon sound scheme variant
│   └── Desktop.ini
├── Calligraphy/           # Calligraphy sound scheme variant
│   └── Desktop.ini
├── Characters/            # Characters sound scheme variant
│   └── Desktop.ini
├── Cityscape/             # Cityscape sound scheme variant
│   └── Desktop.ini
├── Delta/                 # Delta sound scheme variant
│   └── Desktop.ini
├── Festival/              # Festival sound scheme variant
│   └── Desktop.ini
├── Garden/                # Garden sound scheme variant
│   └── Desktop.ini
├── Heritage/              # Heritage sound scheme variant
│   └── Desktop.ini
├── Landscape/             # Landscape sound scheme variant
│   └── Desktop.ini
├── Quirky/                # Quirky sound scheme variant
│   └── Desktop.ini
├── Raga/                  # Raga sound scheme variant
│   └── Desktop.ini
├── Savanna/               # Savanna sound scheme variant
│   └── Desktop.ini
└── Sonata/                # Sonata sound scheme variant
    └── Desktop.ini
```

## Sound Scheme Philosophy

- **Crystal glass aesthetic:** Clean tones, subtle resonance, no harshness
- **Startup/shutdown:** 3-5 second ambient crystal chimes, layered harmonics
- **Errors/warnings:** Short tonal cues (< 1 second), distinct but not alarming
- **Navigation:** Micro-interactions (< 0.3 seconds), soft taps and slides
- **Window events:** Glass movement sounds, subtle whooshes
- **Device events:** Connection tones with ascending/descending pitch
- **Tonal palette:** Rooted in C major / A minor
- **Target loudness:** -18 LUFS (integrated), Peak: -1 dBTP

## Desktop.ini Format

Each subdirectory contains a `Desktop.ini` file that maps WAV filenames to
localized display names, following the NT6 shell desktop.ini convention:

```ini
[LocalizedFileNames]
ZirconOS Default.wav=Default
ZirconOS Error.wav=Error
```

## Implementation Status

WAV audio files are pending generation. The configuration infrastructure
and event mappings are fully defined in `sound_scheme.conf`.

## Copyright Notice

Copyright (C) 2024-2026 ZirconOS Project
Licensed under GNU Lesser General Public License v2.1

All sound designs will be original compositions, not derived from any
third-party operating system sound assets.
