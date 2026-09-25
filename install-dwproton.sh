#!/usr/bin/env bash
# ===========================================================================
#  install-dwproton.sh —— 安装 DW-Proton(带 ACE 反作弊补丁的 Proton 分支)
# ---------------------------------------------------------------------------
#  ⚠️⚠️ 2026-09-09 22:43 实机结论: 本机【不需要】DW-Proton, 别装完就切!
#    终末地和鸣潮在 **GE-Proton11-6** 下均已正常进入游戏。
#    装 dwproton 只作为后备选项(万一将来 GE 的 ACE 支持退化)。
#    详见 SCRIPT-MAINTENANCE.md 的 [6h] 定案章节。
#
#    之前的判断反复过三次:
#      [6c]   社区说鹰角系必须 dwproton        → 换过去
#      [6c-3] 解析 ntoskrnl 导出表 → GE 更好    → 换回来
#      [6g]   又被社区帖子说服                  → 又换过去
#      [6h]   实机验证: GE-Proton11-6 就是对的  → 定案
#    教训: 社区结论只是线索, ntoskrnl 导出表 + 实机才是硬证据。
#
#  背景(供后备场景参考):
#    《明日方舟:终末地》自带 **AntiCheatExpert(ACE)** 反作弊。
#    ACE 在部分 Proton 下会让游戏闪退
#    (典型日志: wine: Call from ... to unimplemented function
#     ntoskrnl.exe.PsGetProcessExitStatus, aborting)。
#    DW-Proton 是 Dawn Winery 维护的分支, 内建 ACE 等反作弊补丁:
#      · dwproton-11.0-7 : "Hotfix release fixing launch issues with AK: Endfield"
#      · dwproton-11.0-9 : 新增 AK:Endfield 专用 protonfix(缓解加载时大量写盘)
#    但本机 GE-Proton11-6 的 ntoskrnl 导出表完整度反而最好(见 [6c-3] 对照表)。
#
#  用法:
#    bash install-dwproton.sh                    # 装最新版
#    bash install-dwproton.sh dwproton-11.0-10   # 装指定版本
#
#  装完后(重要):
#    0. 首选 dwproton-10.0-26(见下方 DEFAULT_VER 处的说明); 若用它仍黑屏,
#       再换 11.0-12 对照 —— 两者都装上, 切一次只要十几秒。
#    1. 完全退出 Steam 再重开(否则扫描不到新兼容层)
#    2. Steam 里右键终末地 → 属性 → 兼容性 → 勾选"强制使用" → 选 dwproton
#    3. 若启动后加载异常慢/卡住, 在启动选项加:
#         UMU_ID=umu-endfield %command%
#       (dwproton 官方说明: protonfix 自动匹配失败时需手动指定 UMU_ID)
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'; C_B=$'\033[1m'
info() { echo "${C_G}[✓]${C_R} $*"; }
warn() { echo "${C_Y}[!]${C_R} $*"; }
err()  { echo "${C_RD}[✗]${C_R} $*"; exit 1; }

HOST="${DWPROTON_HOST:-https://dawn.wine}"
OWNER="dawn-winery"; REPO="dwproton"
TOOLS_DIR="${STEAM_COMPAT_DIR:-$HOME/.local/share/Steam/compatibilitytools.d}"
# ⚠ 版本选择的坑(2026-09-09 查 dwproton issue #3 得知, 与"越新越好"相反):
#   上游维护者 ChoeHa-U 原话 —— "endfield will never work if dw version is
#   above 10.0-26", 并建议 "use dw-proton 10.0-26"。若从高版本降到低版本,
#   需先删掉 prefix 目录下的 _proton 文件夹再降级。
#   → 首选 10.0-26; 11.0-12 作为次选/对照。
DEFAULT_VER="dwproton-10.0-26"

# ---- 版本号: 参数 > API > 默认 ----
if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
    TAG="$1"
else
    info "查询最新版本..."
    TAG=""
    API="$HOST/api/v1/repos/$OWNER/$REPO/releases/latest"
    RAW="$(curl -fsS --connect-timeout 10 --max-time 25 "$API" 2>/dev/null || true)"
    if [ -n "$RAW" ]; then
        if command -v jq >/dev/null 2>&1; then
            TAG="$(printf '%s' "$RAW" | jq -r .tag_name 2>/dev/null)"
        else
            TAG="$(printf '%s' "$RAW" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
        fi
    fi
    [ -z "$TAG" ] || [ "$TAG" = "null" ] && { warn "API 取不到版本号, 用默认 $DEFAULT_VER"; TAG="$DEFAULT_VER"; }
fi

case "$TAG" in dwproton-*) ;; *) TAG="dwproton-$TAG";; esac

TARBALL="${TAG}-x86_64.tar.xz"
SUMFILE="${TAG}-x86_64.sha512sum"
URL="$HOST/$OWNER/$REPO/releases/download/$TAG/$TARBALL"
SUM_URL="$HOST/$OWNER/$REPO/releases/download/$TAG/$SUMFILE"

echo "${C_B}=== DW-Proton 安装器 ===${C_R}"
info "版本: $TAG"
info "源:   $URL"
info "目标: $TOOLS_DIR"
echo

[ -d "${TOOLS_DIR%/*}" ] || err "Steam 目录不存在: ${TOOLS_DIR%/*}  (可设 STEAM_COMPAT_DIR=...)"
mkdir -p "$TOOLS_DIR"

# ⚠ 下载缓存目录必须用"固定路径", 不能 mktemp:
#   dawn.wine 走 HTTP/2 时大包常在 70~80% 处被 stream reset
#   (2026-09-09 实测 268MB 包在 76% 失败, curl: (92) HTTP/2 stream 1 reset)。
#   临时目录每次换名 → `-C -` 续传等于失效 → 每次都从 0 重来。
#   固定目录 + --http1.1 + 重试循环 才能续得上。
DL="${DWPROTON_DL_DIR:-$HOME/Downloads/dwproton-dl}"
mkdir -p "$DL" || err "无法创建下载目录: $DL"
TMP="$DL"

# ---- 下载 ----
info "下载主包(约 285MB, 支持断点续传)..."
OK=0
for i in 1 2 3 4 5 6; do
    SZ="$(stat -c%s "$TMP/$TARBALL" 2>/dev/null || echo 0)"
    [ "$i" -gt 1 ] && warn "第 $i 次尝试(已有 $SZ 字节, 续传)..."
    if curl -fL --http1.1 --connect-timeout 20 --retry 3 --retry-all-errors \
            -C - -o "$TMP/$TARBALL" "$URL"; then OK=1; break; fi
    sleep 3
done
[ "$OK" = 1 ] || err "下载失败(已重试 6 次)。可手动从 $HOST/$OWNER/$REPO/releases 下载后放到 $TMP 再重跑"

# ---- 校验(有就校验, 没有就跳过) ----
if curl -fsSL --connect-timeout 10 --retry 2 -o "$TMP/$SUMFILE" "$SUM_URL" 2>/dev/null \
   && [ -s "$TMP/$SUMFILE" ]; then
    info "校验 SHA512..."
    ( cd "$TMP" && sha512sum -c "$SUMFILE" ) || err "SHA512 校验不通过! 请勿使用该文件"
    info "校验通过"
else
    warn "未取到校验文件, 跳过完整性检查"
fi

# ---- 解压 ----
info "解压到 $TOOLS_DIR ..."
tar -xf "$TMP/$TARBALL" -C "$TOOLS_DIR" || err "解压失败"
info "解压完成"

# ---- 修正 compatibilitytool.vdf 里的工具名 ----
# 上游包里 tool 名可能是 "dwproton-dwproton", Steam 会显示异常, 统一改成 "dwproton"
for d in "$TOOLS_DIR"/dwproton-*; do
    [ -d "$d" ] || continue
    VDF="$d/compatibilitytool.vdf"
    if [ -f "$VDF" ] && grep -q 'dwproton-dwproton' "$VDF" 2>/dev/null; then
        sed -i 's/dwproton-dwproton/dwproton/g' "$VDF" && info "已修正 $VDF 里的工具名"
    fi
    echo "  已安装: $d"
done

echo
info "安装完成。接下来请手动完成:"
echo "  1) 完全退出 Steam(托盘图标 → 退出), 再重新打开"
echo "  2) 库里右键《终末地》→ 属性 → 兼容性 → 勾选强制使用 → 选 dwproton"
echo "  3) 若加载异常缓慢, 启动选项加: UMU_ID=umu-endfield %command%"
echo
echo "  说明: 终末地自带 ACE 反作弊, GE-Proton/官方 Proton 必崩, 只能用 DW-Proton。"
