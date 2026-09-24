#!/usr/bin/env bash
# ===========================================================================
#  install-harmony-sans-home.sh
#  把鸿蒙字体(HarmonyOS Sans)装成系统字体 —— 装进 /home、扛原子升级
# ---------------------------------------------------------------------------
#  为什么不用 AUR 的 ttf-harmonyos-sans:
#    · 它装到 /usr/share/fonts → **rootfs**, SteamOS 原子升级必被冲掉
#    · 取源是华为 CDN 的签名链接(路径里带时间戳+哈希), 随时可能过期
#    → 本脚本: 自己下 zip / 或从本地 zip 取, 装到 ~/.local/share/fonts(扛升级),
#      并允许用户随时用 HARMONY_ZIP 指定本地包, 不依赖那条会过期的链接。
#
#  字体包的两个坑(steamos-nix 分支已踩过并验证):
#    · 目录名带空格:  "HarmonyOS Sans/HarmonyOS_Sans_SC/..."
#    · 混着苹果垃圾:  __MACOSX/、._ 开头的 AppleDouble、.DS_Store
#    · SC(简体) 与 TC(繁体) 混在一起, 默认只要 SC
#
#  字体配置落点用 ~/.config/fontconfig/conf.d/ —— **不碰**用户已有的 fonts.conf,
#  且只给 sans-serif / serif 写 prefer; monospace 不动:
#    鸿蒙是比例字体, 拿它顶替等宽会让终端/代码字体错乱(steamos-nix 的既定结论)。
#
#  用法:
#    bash install-harmony-sans-home.sh                 # 安装/修复(幂等)
#    bash install-harmony-sans-home.sh --check         # 只读自检
#    bash install-harmony-sans-home.sh --force         # 强制重装
#    bash install-harmony-sans-home.sh --plasma        # 连 Plasma 界面字体一起改
#    HARMONY_ZIP=/path/HarmonyOS_Sans.zip bash install-harmony-sans-home.sh
#    HARMONY_VARIANT=TC bash install-harmony-sans-home.sh      # 要繁体
#    HARMONY_VARIANT=ALL bash install-harmony-sans-home.sh     # 简繁都要
#    HARMONY_URL=https://...  bash install-harmony-sans-home.sh # 自定义取源
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_I=$'\033[36m'; C_OK=$'\033[32m'; C_W=$'\033[33m'; C_E=$'\033[31m'; C_D=$'\033[2m'
info() { printf '%s[*]%s %s\n' "$C_I" "$C_R" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_OK" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_W" "$C_R" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_E" "$C_R" "$*" >&2; }
sub()  { printf '    %s\n' "$*"; }
step() { printf '\n%s════════ %s ════════%s\n' "$C_D" "$1" "$C_R"; }

# 家族名与变体(与 steamos-nix 的 fontconfig 发射器保持一致)
HARMONY_FAMILY="${HARMONY_FAMILY:-HarmonyOS Sans SC}"
HARMONY_VARIANT="${HARMONY_VARIANT:-SC}"          # SC | TC | ALL
# 取源: 官方 CDN 的签名链接会过期, 因此优先本地/缓存; 过期时脚本会给出取源指引
HARMONY_URL="${HARMONY_URL:-}"
FORCE=0; DO_PLASMA=0

# ── 运行身份 / 家目录 ──────────────────────────────────────────────────
if [ "$(id -u)" -eq 0 ]; then
    REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
else
    REAL_USER="$(id -un)"
fi
[ -n "${REAL_USER:-}" ] || REAL_USER="deck"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[ -n "${REAL_HOME:-}" ] || REAL_HOME="/home/$REAL_USER"

FONT_SUBDIR="harmonyos-sans-$(printf '%s' "$HARMONY_VARIANT" | tr 'A-Z' 'a-z')"
FONT_DIR="$REAL_HOME/.local/share/fonts/$FONT_SUBDIR"
FC_DIR="$REAL_HOME/.config/fontconfig/conf.d"
FC_FILE="$FC_DIR/10-harmony-sans.conf"
CACHE_DIR="$REAL_HOME/.cache/harmony-sans"
MARKER="$FONT_DIR/.source"

# ===========================================================================
#  --check
# ===========================================================================
do_check() {
    local fail=0 n
    echo "════════ 鸿蒙字体(/home 自持形态) 自检 ════════"
    echo "用户: $REAL_USER   家目录: $REAL_HOME"

    n="$(ls -1 "$FONT_DIR"/*.ttf 2>/dev/null | wc -l)"
    if [ "$n" -gt 0 ]; then
        ok "字体已装: $FONT_DIR ($n 个 ttf, $(du -sh "$FONT_DIR" 2>/dev/null | cut -f1))"
    else
        err "字体缺失: $FONT_DIR"; sub "→ 跑: bash $(basename "$0")"; fail=1
    fi

    if [ -f "$FC_FILE" ]; then
        ok "fontconfig 就绪: $FC_FILE"
        sub "(落点是 conf.d/, 不会覆盖你已有的 fonts.conf)"
    else
        err "fontconfig 未配置"; fail=1
    fi

    if command -v fc-match >/dev/null 2>&1; then
        sub "fc-match sans-serif : $(fc-match sans-serif 2>/dev/null)"
        sub "fc-match serif      : $(fc-match serif 2>/dev/null)"
        sub "fc-match monospace  : $(fc-match monospace 2>/dev/null)  ← 应仍是等宽字体"
        fc-match sans-serif 2>/dev/null | grep -qi "harmony" \
            && ok "sans-serif 已指向鸿蒙" || { warn "sans-serif 还没生效(可能需重登或 fc-cache)"; fail=1; }
    else
        sub "(本机没有 fc-match, 跳过生效验证)"
    fi

    command -v fc-list >/dev/null 2>&1 && fc-list | grep -qi harmony \
        && ok "字库里能查到 Harmony 家族" || warn "fc-list 查不到 Harmony(字体缓存未刷新?)"

    echo
    [ "$fail" -eq 0 ] && { echo "════ 结论: 已生效 ════"; return 0; }
    echo "════ 结论: 有缺件 ════"; return 1
}

# ===========================================================================
#  安装
# ===========================================================================
do_install() {
    local zip="" stage src_dir prev

    echo "════════ 把鸿蒙字体装成系统字体(装进 /home) ════════"
    mkdir -p "$CACHE_DIR" "$FONT_DIR" "$FC_DIR" || return 1

    # ── 0. 已装好就跳过(重跑本脚本最常见的原因只是想确认, 不必再解一遍包) ──
    if [ "$FORCE" -eq 0 ] && [ -f "$FC_FILE" ] && \
       [ "$(ls -1 "$FONT_DIR"/*.ttf 2>/dev/null | wc -l)" -gt 0 ]; then
        ok "已装好($(ls -1 "$FONT_DIR"/*.ttf 2>/dev/null | wc -l) 个 ttf) → 跳过(要重装加 --force)"
        info "当前家族: $HARMONY_FAMILY   目录: $FONT_DIR"
        return 0
    fi

    # ── 1. 取 zip ──
    if [ -n "${HARMONY_ZIP:-}" ]; then
        zip="$HARMONY_ZIP"
        [ -f "$zip" ] || { err "HARMONY_ZIP 指向的文件不存在: $zip"; return 1; }
        info "使用本地字体包: $zip"
    else
        if [ -s "$CACHE_DIR/HarmonyOS_Sans.zip" ]; then
            zip="$CACHE_DIR/HarmonyOS_Sans.zip"
            info "用缓存的字体包($(du -h "$zip" | cut -f1))"
        elif [ -n "$HARMONY_URL" ]; then
            sub "下载(自定义地址)..."
            curl -fL --http1.1 --retry 2 --max-time 900 -o "$CACHE_DIR/HarmonyOS_Sans.zip" "$HARMONY_URL" \
                || { err "下载失败"; return 1; }
            zip="$CACHE_DIR/HarmonyOS_Sans.zip"
            ok "下载完成: $(du -h "$zip" | cut -f1)"
        else
            # 默认不内置一条会过期的签名链接 —— 给出明确指引, 让用户一次性拿到本地包
            err "没有字体包, 且未指定取源地址。"
            sub "华为官方的 zip 直链是带时间戳签名的, 会过期 —— 写死在脚本里只会日后失效。"
            sub "两条路:"
            sub "  ① 自己下好 zip 后指定:"
            sub "     HARMONY_ZIP=/路径/HarmonyOS_Sans.zip bash $(basename "$0")"
            sub "  ② 或从 AUR 取当前链接(它会把 zip 下到 /usr/share/fonts, 但你可以"
            sub "     直接从 PKGBUILD 里拿到 URL 再喂给本脚本):"
            sub "     HARMONY_URL='https://...zip' bash $(basename "$0")"
            sub "  取源页: https://developer.huawei.com/consumer/cn/design/resource/"
            return 1
        fi
    fi

    # ── 2. 解包(bsdtar 能直接吃 zip) ──
    stage="$CACHE_DIR/.stage.$$"
    rm -rf "${stage:?}"; mkdir -p "$stage" || return 1
    sub "解包 zip..."
    if ! bsdtar -xf "$zip" -C "$stage" 2>/dev/null; then
        err "解包失败(不是 zip? 或包损坏)"; rm -rf "${stage:?}"; return 1
    fi
    ok "解包完成"

    # ── 3. 挑字体 ──
    #  ⚠ 实测过包内结构(2026.06.12), 别想当然:
    #     HarmonyOS_Sans.ttf        → 家族 "HarmonyOS Sans"    (拉丁, 0.3MB, 含 Italic/Condensed)
    #     HarmonyOS_Sans_SC.ttf     → 家族 "HarmonyOS Sans SC" (简体, 19.7MB) ← 系统字体靠它显示中文
    #     HarmonyOS_Sans_TC.ttf     → 家族 "HarmonyOS Sans TC" (繁体, 9.5MB)
    #     另有一半条目是 __MACOSX/._* 苹果垃圾(实测 16 个 ttf 里 8 个是垃圾)
    #  → 所以 SC 变体 = "拉丁全家 + SC", 而不是"只挑名字带 SC 的"
    #     (只挑 SC 会把拉丁和斜体全丢掉, 中文能显示但拉丁排版会退化)
    local exclude=''
    case "$HARMONY_VARIANT" in
        SC)  exclude='*TC*' ;;
        TC)  exclude='*SC*' ;;
        ALL) exclude='' ;;
        *)   warn "未知变体 '$HARMONY_VARIANT', 按 SC 处理"; exclude='*TC*' ;;
    esac
    local -a found=()
    while IFS= read -r f; do
        [ -n "$f" ] && found+=("$f")
    done < <(find "$stage" -type f -name '*.ttf' \
                  ! -path '*__MACOSX*' ! -name '._*' ! -name '.DS_Store' \
                  ${exclude:+! -name "$exclude"} 2>/dev/null)
    if [ "${#found[@]}" -eq 0 ]; then
        err "包里没找到匹配的 ttf(变体=$HARMONY_VARIANT)"
        sub "包内 ttf 一览:"; find "$stage" -type f -name '*.ttf' 2>/dev/null | head -8 | sed 's/^/      /'
        rm -rf "${stage:?}"; return 1
    fi
    ok "挑出 ${#found[@]} 个字体文件(变体 $HARMONY_VARIANT, 已排除 __MACOSX/._/.DS_Store)"

    # ── 4. 安装到 ~/.local/share/fonts ──
    prev="$(ls -1 "$FONT_DIR"/*.ttf 2>/dev/null | wc -l)"
    local i=0
    for src_dir in "${found[@]}"; do
        cp -f "$src_dir" "$FONT_DIR/" 2>/dev/null && i=$((i + 1))
    done
    chmod 644 "$FONT_DIR"/*.ttf 2>/dev/null || true
    printf '%s\n' "${HARMONY_ZIP:-$HARMONY_URL}" >"$MARKER" 2>/dev/null || true
    ok "已安装 $i 个到 $FONT_DIR (原有 $prev 个)"
    rm -rf "${stage:?}"

    # ── 5. 校验家族名(有 fc-scan 才验) ──
    if command -v fc-scan >/dev/null 2>&1; then
        local fam
        fam="$(fc-scan --format '%{family[0]}\n' "$FONT_DIR"/*.ttf 2>/dev/null | sort -u | tr '\n' ' ')"
        sub "识别到的家族: $fam"
        printf '%s' "$fam" | grep -qi "harmony" && ok "家族名含 Harmony ✔" || warn "家族名里没看到 Harmony(可能变了名, 检查一下)"
    fi

    # ── 6. fontconfig: 落到 conf.d/, 不碰用户已有的 fonts.conf ──
    cat >"$FC_FILE" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- 由 install-harmony-sans-home.sh 生成; 放在 conf.d/ 下, 不改动你的 fonts.conf -->
<fontconfig>
  <!-- 字体目录在 /home, 原子升级不会被冲 -->
  <dir>$FONT_DIR</dir>
  <!-- 只给比例字体写 prefer: 鸿蒙是比例字体, 顶替 monospace 会让终端/代码字体错乱 -->
  <!-- prefer 的顺序有意义: 拉丁在前, 中文在后(缺字时由后面的兜底) -->
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>HarmonyOS Sans</family>
      <family>$HARMONY_FAMILY</family>
    </prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer>
      <family>HarmonyOS Sans</family>
      <family>$HARMONY_FAMILY</family>
    </prefer>
  </alias>
</fontconfig>
EOF
    chmod 644 "$FC_FILE"
    ok "fontconfig 已写入 $FC_FILE"

    # ── 7. 可选: Plasma 界面字体 ──
    if [ "$DO_PLASMA" -eq 1 ]; then
        local kw=""
        for kw in kwriteconfig6 kwriteconfig5; do command -v "$kw" >/dev/null 2>&1 && break; kw=""; done
        if [ -z "$kw" ]; then
            warn "没找到 kwriteconfig6/5, 跳过 Plasma 界面字体(只能在系统设置里手工改)"
        else
            # 只在 Plasma 自己没锁定的情况下改; 改完需重新登录生效
            [ "$(id -u)" -eq 0 ] && runuser -u "$REAL_USER" -- "$kw" --file kdeglobals --group General --key font "$HARMONY_FAMILY,11,-1,5,50,0,0,0,0,0" \
                                 || "$kw" --file kdeglobals --group General --key font "$HARMONY_FAMILY,11,-1,5,50,0,0,0,0,0"
            ok "Plasma 通用字体已设为 $HARMONY_FAMILY(需注销重登; 如未生效去系统设置确认)"
        fi
    fi

    # ── 8. 刷新缓存 ──
    if command -v fc-cache >/dev/null 2>&1; then
        sub "刷新字体缓存..."
        if [ "$(id -u)" -eq 0 ]; then
            runuser -u "$REAL_USER" -- fc-cache -f >/dev/null 2>&1 || fc-cache -f >/dev/null 2>&1
        else
            fc-cache -f >/dev/null 2>&1
        fi
        ok "字体缓存已刷新"
    fi

    [ "$(id -u)" -eq 0 ] && chown -R "$REAL_USER":"$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")" \
        "$FONT_DIR" "$FC_FILE" "$CACHE_DIR" 2>/dev/null

    echo
    echo "════════ 完成 ════════"
    echo "  字体目录: $FONT_DIR   (在 /home → 原子升级幸存)"
    echo "  配置    : $FC_FILE    (conf.d/, 未动 fonts.conf)"
    echo "  家族    : $HARMONY_FAMILY"
    echo
    echo "  · 没生效的话: 注销重登一次(字体缓存/Plasma 需要重启会话)。"
    echo "  · 想要 Plasma 界面也换: 重跑时加 --plasma, 或在系统设置 → 字体里选。"
    echo "  · monospace(终端/代码)刻意没动 —— 详见脚本头部说明。"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) FORCE=1 ;;
            --plasma) DO_PLASMA=1 ;;
            -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ; return 0 ;;
            --check) do_check; return $? ;;
            "") break ;;
            *) err "未知参数: $1 (可用: --check / --force / --plasma / --help)"; return 2 ;;
        esac
        shift
    done
    do_install
}
main "$@"
