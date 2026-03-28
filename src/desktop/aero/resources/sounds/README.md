# ZirconOS Aero Sound Schemes

与 **壁纸分类一致** 的五套主题音效（`Architecture`、`Characters`、`Landscapes`、`Nature`、`Scenes`），WAV 由仓库内脚本 **ffmpeg** 合成，原创波形，非任何第三方 OS 随盘素材。

## 目录结构

```
sounds/
├── sound_scheme.conf   # 逻辑事件 → 默认 Nature/ 下路径（可改前缀换默认主题）
├── Desktop.ini         # 根级事件名映射 + 五主题文件夹显示名
├── README.md
├── Architecture/       # 每主题：Desktop.ini + 21 个 ZirconOS *.wav
├── Characters/
├── Landscapes/
├── Nature/
└── Scenes/
```

## 事件清单（每主题相同文件名）

含独立 **开机**（`ZirconOS Startup.wav`，较长分层琶音）与 **登录**（`ZirconOS Logon Sound.wav`，较短上行句），以及加长后的 **关机**（`ZirconOS Shutdown.wav`，三低弦混合 + 长渐弱）。其余提示音在时长与和声上相对早期版本更易辨识。

## 重新生成

依赖：**python3**、**ffmpeg**（lavfi + loudnorm）。

```bash
python3 tools/soundgen/generate_aero_sounds.py
# 或
zig build aero-sounds
```

脚本会 **覆盖** 五目录下全部 WAV，并重写各主题 `Desktop.ini`。

## 声学目标

- 采样率 44.1 kHz，立体声，16-bit PCM；loudnorm 目标约 **-18 LUFS** / **-1.5 dBTP**
- 五主题通过 `THEME_PARAMS`（`tools/soundgen/generate_aero_sounds.py`）调节音高比例、立体声回声与开机/关机渐弱起点

## Copyright

Copyright (C) 2024-2026 ZirconOS Project  
Licensed under GNU Lesser General Public License v2.1
