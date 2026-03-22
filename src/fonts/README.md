# ZirconOSFonts — ZirconOS 开源字体集

本项目为 ZirconOS 操作系统提供全套 **开源字体**，替代所有闭源字体依赖。
涵盖西文衬线 / 无衬线 / 等宽字体，以及中文宋体、黑体、楷体、仿宋的开源替代方案。

---

## 目录结构

```
src/fonts/
├── western/                # 西文字体（NotoSans、Lato、SourceCodePro 等）
├── cjk/                    # CJK（思源黑体/宋体、霞鹜文楷、朱雀仿宋等）
├── symbol/                 # 符号字体（Symbola 等）
└── licenses/               # 许可证副本
```

字体下载：`scripts/fonts/fetch-fonts.sh`（输出到本目录）。

## 字体对照表

### 西文字体

| 字体名称 | 类型 | 许可证 | 来源 |
|----------|------|--------|------|
| DejaVu Sans Mono | 等宽 | Bitstream Vera + Public Domain | [DejaVu Fonts](https://dejavu-fonts.github.io/) |
| Embed Serif | 衬线 | SIL OFL 1.1 | [open-fonts](https://github.com/kiwi0fruit/open-fonts) |
| Inconsolata Sugar | 等宽 | SIL OFL 1.1 | [open-fonts](https://github.com/kiwi0fruit/open-fonts) |
| Lato | 无衬线 | SIL OFL 1.1 | [Lato Fonts](http://www.latofonts.com/) |
| Libertinus Serif | 衬线 / 数学 | SIL OFL 1.1 | [Libertinus Fonts](https://github.com/alerque/libertinus) |
| Noto Sans | 无衬线 | SIL OFL 1.1 | [Google Noto Fonts](https://fonts.google.com/noto) |
| Noto Sans Mono | 等宽 | SIL OFL 1.1 | [Google Noto Fonts](https://fonts.google.com/noto) |
| Noto Serif | 衬线 | SIL OFL 1.1 | [Google Noto Fonts](https://fonts.google.com/noto) |
| Robotization Mono | 等宽 | Apache 2.0 | [open-fonts](https://github.com/kiwi0fruit/open-fonts) |
| Source Code Pro | 等宽 | SIL OFL 1.1 | [Adobe Source Code Pro](https://github.com/adobe-fonts/source-code-pro) |
| Source Sans Pro | 无衬线 | SIL OFL 1.1 | [Adobe Source Sans](https://github.com/adobe-fonts/source-sans) |
| XITS (STIX fork) | 数学 / 科学 | SIL OFL 1.1 | [XITS](https://github.com/aliftype/xits) |

### CJK 中文字体（闭源字体替代方案）

| 字体名称 | 替代目标 | 许可证 | 来源 |
|----------|---------|--------|------|
| 思源黑体 (Noto Sans CJK SC) | **黑体** | SIL OFL 1.1 | [notofonts/noto-cjk](https://github.com/notofonts/noto-cjk) Sans2.004 |
| 思源宋体 (Noto Serif CJK SC) | **宋体** | SIL OFL 1.1 | [notofonts/noto-cjk](https://github.com/notofonts/noto-cjk) Serif2.003 |
| 霞鹜文楷 (LXGW WenKai) | **楷体** | SIL OFL 1.1 | [lxgw/LxgwWenKai](https://github.com/lxgw/LxgwWenKai) v1.522 |
| 朱雀仿宋 (ZhuQue FangSong) | **仿宋** | SIL OFL 1.1 | [TrionesType/zhuque](https://github.com/TrionesType/zhuque) v0.212 |

### 符号字体

| 字体名称 | 类型 | 许可证 | 来源 |
|----------|------|--------|------|
| Symbola | Unicode 符号 | Public Domain | [Symbola](https://dn-works.com/ufas/) |

## 系统字体映射

在 ZirconOS 中，以下字体名称将自动映射到对应的开源字体：

| 系统字体名 | 映射到 |
|-----------|--------|
| SimSun / 宋体 | Noto Serif CJK SC |
| SimHei / 黑体 | Noto Sans CJK SC |
| KaiTi / 楷体 | LXGW WenKai |
| FangSong / 仿宋 | ZhuQue FangSong |
| Consolas | Source Code Pro |
| Arial | Noto Sans |
| Times New Roman | Noto Serif |
| Courier New | DejaVu Sans Mono |

## 使用方法

### 一键下载（推荐）

```bash
./scripts/fonts/fetch-fonts.sh
```

### 手动下载

若字体文件未包含在仓库中（如因体积限制），可使用下载脚本从上游获取：

```bash
./scripts/fonts/fetch-fonts.sh --update   # 更新已有字体
./scripts/fonts/fetch-fonts.sh --cjk-only  # 仅下载中文字体
```

## 与内核集成

字体通过 `gdi32.zig` 图形设备接口加载，支持 TTF 和 OTF 格式。

在 `src/config/desktop.conf` 中配置默认字体：

```ini
[fonts]
default_sans = NotoSansCJK-SC
default_serif = NotoSerifCJK-SC
default_mono = SourceCodePro
default_kai = LXGWWenKai
default_fangsong = ZhuQueFangSong
```

## 许可证

本项目中的所有字体均为开源字体，各自遵循其原始许可证（主要为 SIL OFL 1.1）。
各字体目录下包含对应的许可证文件，详见各子目录。

## 参考

- [kiwi0fruit/open-fonts](https://github.com/kiwi0fruit/open-fonts) — 开源字体集合
- [Google Noto Fonts](https://fonts.google.com/noto) — Google Noto 字体项目
- [notofonts/noto-cjk](https://github.com/notofonts/noto-cjk) — 思源黑体 / 宋体
- [lxgw/LxgwWenKai](https://github.com/lxgw/LxgwWenKai) — 霞鹜文楷
- [TrionesType/zhuque](https://github.com/TrionesType/zhuque) — 朱雀仿宋
