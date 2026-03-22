#!/usr/bin/env bash
# ZirconOSFonts 字体下载 / 更新脚本
# 从上游 GitHub 仓库下载开源字体到 fonts/ 目录
#
# 用法：./fetch-fonts.sh [--update] [--cjk-only] [--western-only]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FONTS_DIR="$ROOT_DIR/src/fonts"
TMP_DIR="${TMPDIR:-/tmp}/zirconos-fonts-$$"

usage() {
    echo "用法: $0 [选项]"
    echo "  --update         更新已有字体（重新下载）"
    echo "  --cjk-only       仅下载 CJK 中文字体"
    echo "  --western-only   仅下载西文字体"
    echo "  --clean          清理临时文件"
    echo "  -h, --help       显示帮助"
}

UPDATE=0
CJK_ONLY=0
WESTERN_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --update) UPDATE=1 ;;
        --cjk-only) CJK_ONLY=1 ;;
        --western-only) WESTERN_ONLY=1 ;;
        --clean) rm -rf "${TMPDIR:-/tmp}"/zirconos-fonts-*; echo "临时文件已清理"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

command -v wget >/dev/null 2>&1 || { echo "错误: 需要 wget" >&2; exit 1; }
command -v 7z >/dev/null 2>&1 || command -v unzip >/dev/null 2>&1 || { echo "错误: 需要 7z 或 unzip" >&2; exit 1; }

mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

extract() {
    local archive="$1" dest="$2"
    mkdir -p "$dest"
    if command -v 7z >/dev/null 2>&1; then
        7z x "$archive" -o"$dest" -y >/dev/null 2>&1
    else
        unzip -o "$archive" -d "$dest" >/dev/null 2>&1
    fi
}

download_font() {
    local name="$1" url="$2" dest_dir="$3" pattern="$4"
    local target="$FONTS_DIR/$dest_dir"

    if [[ "$UPDATE" -eq 0 ]] && find "$target" -name "$pattern" 2>/dev/null | head -1 | grep -q .; then
        echo "  跳过 $name（已存在，使用 --update 可更新）"
        return
    fi

    echo "  下载 $name ..."
    mkdir -p "$target"
    local archive="$TMP_DIR/$(basename "$url")"
    wget -q "$url" -O "$archive" || { echo "  ✗ $name 下载失败" >&2; return 1; }

    local extract_dir="$TMP_DIR/${name}-extract"
    extract "$archive" "$extract_dir"
    find "$extract_dir" \( -name "*.ttf" -o -name "*.otf" \) -exec cp {} "$target/" \;
    find "$extract_dir" \( -iname "LICENSE*" -o -iname "OFL*" \) -exec cp {} "$target/" \; 2>/dev/null || true
    local count
    count=$(find "$target" \( -name "*.ttf" -o -name "*.otf" \) | wc -l)
    echo "  ✓ $name — $count 个字体文件"
}

download_openfonts_repo() {
    echo "克隆 open-fonts 仓库..."
    local repo_dir="$TMP_DIR/open-fonts"
    git clone --depth 1 https://github.com/kiwi0fruit/open-fonts.git "$repo_dir" >/dev/null 2>&1

    local src="$repo_dir/Fonts"

    echo "复制 DejaVu..."
    mkdir -p "$FONTS_DIR/western/DejaVu"
    cp "$src/DejaVu/"*.ttf "$FONTS_DIR/western/DejaVu/" 2>/dev/null || true
    cp "$src/DejaVu/LICENSE" "$FONTS_DIR/western/DejaVu/" 2>/dev/null || true

    echo "复制 SourceCodePro..."
    mkdir -p "$FONTS_DIR/western/SourceCodePro"
    cp "$src/SourceCodePro/"*.ttf "$FONTS_DIR/western/SourceCodePro/" 2>/dev/null || true
    cp "$src/SourceCodePro/LICENSE.txt" "$FONTS_DIR/western/SourceCodePro/" 2>/dev/null || true

    echo "复制 SourceSansPro..."
    mkdir -p "$FONTS_DIR/western/SourceSansPro"
    cp "$src/SourceSansPro/"*.ttf "$FONTS_DIR/western/SourceSansPro/" 2>/dev/null || true
    cp "$src/SourceSansPro/LICENSE.md" "$FONTS_DIR/western/SourceSansPro/" 2>/dev/null || true

    echo "复制 Symbola..."
    mkdir -p "$FONTS_DIR/symbol/Symbola"
    cp "$src/Symbola/"*.ttf "$FONTS_DIR/symbol/Symbola/" 2>/dev/null || true
    cp "$src/Symbola/Symbola-PublicDomain.odt" "$FONTS_DIR/symbol/Symbola/" 2>/dev/null || true

    echo "解压 Lato..."
    download_font "Lato" "file://$src/Lato/Lato2OFL.zip" "western/Lato" "*.ttf" 2>/dev/null || {
        mkdir -p "$FONTS_DIR/western/Lato"
        extract "$src/Lato/Lato2OFL.zip" "$TMP_DIR/Lato-extract"
        find "$TMP_DIR/Lato-extract" -name "*.ttf" -exec cp {} "$FONTS_DIR/western/Lato/" \;
        find "$TMP_DIR/Lato-extract" -iname "OFL*" -exec cp {} "$FONTS_DIR/western/Lato/" \; 2>/dev/null || true
    }

    echo "解压 Inconsolata..."
    mkdir -p "$FONTS_DIR/western/Inconsolata"
    extract "$src/InconsolataSugar.zip" "$TMP_DIR/Inconsolata-extract"
    find "$TMP_DIR/Inconsolata-extract" -name "*.ttf" -exec cp {} "$FONTS_DIR/western/Inconsolata/" \;
    cp "$src/Inconsolata/LICENSE" "$FONTS_DIR/western/Inconsolata/" 2>/dev/null || true

    echo "解压 NotoSans..."
    download_font "NotoSans" "file://$src/NotoSans-hinted.zip" "western/NotoSans" "*.ttf" 2>/dev/null || {
        mkdir -p "$FONTS_DIR/western/NotoSans"
        extract "$src/NotoSans-hinted.zip" "$TMP_DIR/NotoSans-extract"
        find "$TMP_DIR/NotoSans-extract" -name "*.ttf" -exec cp {} "$FONTS_DIR/western/NotoSans/" \;
    }

    echo "解压 NotoSerif..."
    mkdir -p "$FONTS_DIR/western/NotoSerif"
    extract "$src/NotoSerif-hinted.zip" "$TMP_DIR/NotoSerif-extract"
    find "$TMP_DIR/NotoSerif-extract" -name "*.ttf" -exec cp {} "$FONTS_DIR/western/NotoSerif/" \;

    echo "解压 NotoSansMono..."
    mkdir -p "$FONTS_DIR/western/NotoSansMono"
    extract "$src/NotoSansMono-hinted.zip" "$TMP_DIR/NotoSansMono-extract"
    find "$TMP_DIR/NotoSansMono-extract" -name "*.ttf" -exec cp {} "$FONTS_DIR/western/NotoSansMono/" \;

    echo "解压 LibertinusSerif..."
    mkdir -p "$FONTS_DIR/western/LibertinusSerif"
    extract "$src/LibertinusSerif.zip" "$TMP_DIR/LibertinusSerif-extract"
    find "$TMP_DIR/LibertinusSerif-extract" -name "*.otf" -exec cp {} "$FONTS_DIR/western/LibertinusSerif/" \;

    echo "解压 EmbedSerif..."
    mkdir -p "$FONTS_DIR/western/EmbedSerif"
    extract "$src/EmbedSerif.zip" "$TMP_DIR/EmbedSerif-extract"
    find "$TMP_DIR/EmbedSerif-extract" -name "*.ttf" -exec cp {} "$FONTS_DIR/western/EmbedSerif/" \;
    find "$TMP_DIR/EmbedSerif-extract" -iname "*LICENSE*" -o -iname "*OFL*" | while read -r f; do cp "$f" "$FONTS_DIR/western/EmbedSerif/"; done 2>/dev/null || true

    echo "解压 RobotizationMono..."
    mkdir -p "$FONTS_DIR/western/RobotizationMono"
    extract "$src/RobotizationMono.zip" "$TMP_DIR/RobotizationMono-extract"
    find "$TMP_DIR/RobotizationMono-extract" -name "*.ttf" -o -name "*.otf" | while read -r f; do cp "$f" "$FONTS_DIR/western/RobotizationMono/"; done
    find "$TMP_DIR/RobotizationMono-extract" -iname "*LICENSE*" | while read -r f; do cp "$f" "$FONTS_DIR/western/RobotizationMono/"; done 2>/dev/null || true

    echo "解压 XITS (STIX)..."
    mkdir -p "$FONTS_DIR/western/STIX"
    extract "$src/XITSOne.zip" "$TMP_DIR/XITSOne-extract"
    extract "$src/XITSTwo.zip" "$TMP_DIR/XITSTwo-extract"
    find "$TMP_DIR/XITSOne-extract" "$TMP_DIR/XITSTwo-extract" -name "*.ttf" -exec cp {} "$FONTS_DIR/western/STIX/" \;
    cp "$src/STIX_2.0.2_license.txt" "$FONTS_DIR/western/STIX/" 2>/dev/null || true
}

download_cjk_fonts() {
    echo ""
    echo "=== 下载 CJK 中文字体 ==="

    download_font "思源黑体 (Noto Sans CJK SC)" \
        "https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/18_NotoSansSC.zip" \
        "cjk/NotoSansCJK-SC" "*.otf"

    download_font "思源宋体 (Noto Serif CJK SC)" \
        "https://github.com/notofonts/noto-cjk/releases/download/Serif2.003/14_NotoSerifSC.zip" \
        "cjk/NotoSerifCJK-SC" "*.otf"

    download_font "霞鹜文楷 (LXGW WenKai)" \
        "https://github.com/lxgw/LxgwWenKai/releases/download/v1.522/lxgw-wenkai-v1.522.zip" \
        "cjk/LXGWWenKai" "*.ttf"

    download_font "朱雀仿宋 (ZhuQue FangSong)" \
        "https://github.com/TrionesType/zhuque/releases/download/v0.212/ZhuqueFangsong-v0.212.zip" \
        "cjk/ZhuQueFangSong" "*.ttf"
}

echo "ZirconOSFonts 字体下载脚本"
echo "=========================="

if [[ "$CJK_ONLY" -eq 0 ]]; then
    echo ""
    echo "=== 下载西文字体 (from open-fonts) ==="
    download_openfonts_repo
fi

if [[ "$WESTERN_ONLY" -eq 0 ]]; then
    download_cjk_fonts
fi

echo ""
echo "=== 完成 ==="
total=$(find "$FONTS_DIR" \( -name "*.ttf" -o -name "*.otf" \) | wc -l)
size=$(du -sh "$FONTS_DIR" | awk '{print $1}')
echo "共 $total 个字体文件，总大小 $size"
echo "字体目录: $FONTS_DIR"
