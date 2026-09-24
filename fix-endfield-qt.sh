#!/usr/bin/env bash
# ===========================================================================
#  fix-endfield-qt.sh —— 修复《明日方舟：终末地》游戏目录缺失 Qt5 运行时资源
# ---------------------------------------------------------------------------
#  根因(2026-09-09 实测, 两轮):
#    游戏目录 ~/Downloads/Hypergryph Launcher/games/Arknights Endfield/
#    自带全套 Qt5 DLL(Qt5Core/Qt5Gui/Qt5WebEngineCore 114MB...), 但**只带 DLL,
#    不带 Qt 运行时资源目录**。而启动器目录 <版本>/ 是齐全的。缺什么:
#
#    [第1轮] plugins/  (platforms/qwindows.dll 等)
#           → 症状: "no Qt platform plugin could be initialized" 弹窗
#
#    [第2轮] resources/      ← Qt WebEngine 的 Chromium 数据: icudtl.dat(10MB)
#            translations/      + qtwebengine_resources*.pak
#            res/               (res/config/app.data, res/web/*.js)
#           → 症状: 能进游戏、加载条走完, 然后闪退。debug.log 刷
#             "Couldn't mmap icu data file"; PlatformProcess.exe 反复启停;
#             u8sdk_pc.log "ParseConfig fail" + "appCode is null";
#             Player.log 末尾 "FormatException: Input string was not in a
#             correct format." → Crash
#           因为游戏的内嵌网页(登录/公告)跑在 Qt WebEngine 上, 缺 ICU 数据
#           就起不来, 全局配置传不过来, 拿不到区服号 → 解析空串 → 崩。
#
#  版本兼容性: 两边同为 Qt 5.15.8(Qt5WebEngineCore.dll 仅差 136 字节, 是构建
#              时间戳差异), 资源文件可直接复用。
#
#  特性: 幂等(已齐全则跳过)、自动找最新启动器版本目录、自动覆盖所有带
#        Qt5Core.dll 的子目录、--dry-run 预演。游戏更新后重跑即可。
#
#  用法: bash fix-endfield-qt.sh [--dry-run]
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'; C_B=$'\033[1m'
info() { echo "${C_G}[✓]${C_R} $*"; }
warn() { echo "${C_Y}[!]${C_R} $*"; }
err()  { echo "${C_RD}[✗]${C_R} $*"; }

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

HOME_GUESS="${HOME:-}"
[ -z "$HOME_GUESS" ] && HOME_GUESS="/home/$(id -un 2>/dev/null || echo deck)"
BASE="${HYPERGRYPH_DIR:-$HOME_GUESS/Downloads/Hypergryph Launcher}"
[ -d "$BASE" ] || BASE="/home/deck/Downloads/Hypergryph Launcher"
if [ ! -d "$BASE" ]; then
    err "找不到启动器目录: $BASE"; exit 1
fi
echo "${C_B}启动器根目录:${C_R} $BASE"

# ── 定位启动器版本目录(取版本号最大的, 里面有 plugins/platforms/qwindows.dll)
SRC=""
for d in "$BASE"/*/; do
    [ -f "$d/plugins/platforms/qwindows.dll" ] || continue
    v="$(basename "$d")"
    if [ -z "$SRC" ] || [ "$(printf '%s\n%s\n' "$SRC" "$v" | sort -V | tail -1)" = "$v" ]; then
        SRC="$(basename "$d")"
    fi
done
[ -n "$SRC" ] || { err "启动器目录里没找到 plugins/platforms/qwindows.dll"; exit 1; }
info "资源来源: $SRC/"

# ── 需要补齐的资源项。格式:  "源目录名|目标目录名|校验文件(相对)"
#    校验文件存在即认为已齐全(幂等判据)
ITEMS=(
    "plugins|plugins|platforms/qwindows.dll"
    "resources|resources|icudtl.dat"
    "translations|translations|qt_en.qm"
    "res|res|config/app.data"
)

# 只处理启动器里真实存在的项(不同版本启动器可能没有 res/ )
AVAIL=()
for it in "${ITEMS[@]}"; do
    s="${it%%|*}"; rest="${it#*|}"; d="${rest%%|*}"; chk="${rest#*|}"
    if [ -e "$BASE/$SRC/$s/$chk" ]; then
        AVAIL+=("$it")
    else
        warn "启动器 $SRC/ 里没有 $s/($chk), 跳过该项"
    fi
done
[ ${#AVAIL[@]} -gt 0 ] || { err "启动器目录里没有任何可用资源"; exit 1; }

# ── 找出所有需要补资源的目标目录: 含 Qt5Core.dll 的目录
# 注意: 不依赖 /dev/fd(受限环境里可能没有), 用临时文件做进程替换
TARGETS=()
_TMP="$(mktemp 2>/dev/null || echo /tmp/.fixendfield.$$)"
find "$BASE/games" -name 'Qt5Core.dll' -printf '%h\n' 2>/dev/null | sort -u > "$_TMP"
while IFS= read -r _d; do
    [ -n "$_d" ] && TARGETS+=("$_d")
done < "$_TMP"
rm -f "$_TMP"

if [ ${#TARGETS[@]} -eq 0 ]; then
    warn "游戏目录里没找到 Qt5Core.dll —— 游戏可能尚未安装完成"; exit 0
fi

echo "${C_B}需要检查的目录:${C_R} ${#TARGETS[@]} 个"
echo

FIXED=0
for t in "${TARGETS[@]}"; do
    echo "${C_B}── ${t#$BASE/}${C_R}"
    for it in "${AVAIL[@]}"; do
        s="${it%%|*}"; rest="${it#*|}"; d="${rest%%|*}"; chk="${rest#*|}"
        if [ -e "$t/$d/$chk" ]; then
            echo "   ${C_G}✓${C_R} $d 已具备"
            continue
        fi
        echo "   ${C_Y}✗ $d 缺失${C_R} (缺 $chk)"
        if [ "$DRY" -eq 1 ]; then
            echo "      (dry-run) 将复制 $SRC/$s/ → $d/"
            FIXED=$((FIXED+1)); continue
        fi
        mkdir -p "$t/$d" || { err "无法创建 $t/$d"; continue; }
        if cp -a "$BASE/$SRC/$s/." "$t/$d/" 2>/dev/null && [ -e "$t/$d/$chk" ]; then
            echo "   ${C_G}✓${C_R} $d 已补齐"
            FIXED=$((FIXED+1))
        else
            err "复制失败: $SRC/$s/ → ${t#$BASE/}/$d/"
        fi
    done
    echo
done

if [ "$DRY" -eq 1 ]; then
    warn "dry-run 模式, 未做任何修改。需补齐 ${FIXED} 项。"
else
    [ "$FIXED" -gt 0 ] && info "已补齐 ${FIXED} 项。现在可以重新启动游戏。" \
                       || info "无需修复, 所有资源齐全。"
fi
echo
echo "验证: 游戏目录应同时具备 resources/icudtl.dat 与 plugins/platforms/qwindows.dll"
echo "若仍闪退, 查这些日志(游戏自己写的, 比 Proton 日志准得多):"
echo "  <prefix>/drive_c/users/steamuser/AppData/LocalLow/Hypergryph/Endfield/sdklogs/u8sdk_pc.log"
echo "  <prefix>/.../AppData/LocalLow/Hypergryph/Endfield/Player.log"
echo "  <游戏目录>/debug.log"
