#!/usr/bin/env bash
# ===========================================================================
#  fix-ibus-simplified.sh —— 修复 IBus 输出繁体 + 锁定简体
# ---------------------------------------------------------------------------
#  适用场景: "怎么又变成繁体了"、"输入法打出繁体"。
#
#  根因(2026-09-09 实测确认):
#    ibus-libpinyin 的 gschema 里有个 `trad-switch` 键(简/繁切换快捷键),
#    **默认值是 <Control><Shift>f** —— 打字时极易误触, 一按就切成繁体,
#    而且会记住状态, 于是"又"变繁体。
#
#  本脚本做三件事:
#    1) 切到 ibus-libpinyin(智能拼音) —— 比老引擎 ibus-pinyin 更稳, 默认就是简体,
#       且它有规范的 gschema, 我们才能真正锁住设置(老引擎 ibus-pinyin 没有 gschema)
#    2) 强制简体: init-chinese=true + init-simplified-chinese=true
#    3) **解绑 trad-switch 快捷键** → 彻底杜绝再次误触变繁体(这才是根治)
#
#  用法: bash fix-ibus-simplified.sh        (以 deck 用户身份跑, 不要 sudo!)
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'; C_B=$'\033[1m'
info() { echo "${C_G}[✓]${C_R} $*"; }
warn() { echo "${C_Y}[!]${C_R} $*"; }
err()  { echo "${C_RD}[✗]${C_R} $*"; }

if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
    err "请以普通用户(deck)身份运行, 不要用 sudo。dconf 是用户级配置。"
    exit 1
fi

LP_PATH="/com/github/libpinyin/ibus-libpinyin/libpinyin"

echo "${C_B}=== IBus 简体修复 ===${C_R}"
echo

# ---- 0) 前置检查 ----
if ! command -v dconf >/dev/null 2>&1; then
    err "找不到 dconf"; exit 1
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    warn "没有 D-Bus 会话, dconf 写入可能失败。请在桌面会话的 Konsole 里运行。"
fi

# ---- 1) 确认 libpinyin 可用 ----
if ! pacman -Qq ibus-libpinyin >/dev/null 2>&1; then
    warn "ibus-libpinyin 未安装。请先装: sudo pacman -S ibus-libpinyin"
    err "没有智能拼音引擎, 无法继续(老引擎 ibus-pinyin 没有 gschema, 锁不住设置)"
    exit 1
fi
info "ibus-libpinyin 已安装"

# ---- 2) 记录改动前状态 ----
echo
echo "改动前:"
echo "  preload-engines  = $(dconf read /desktop/ibus/general/preload-engines 2>/dev/null)"
echo "  init-simplified  = $(dconf read $LP_PATH/init-simplified-chinese 2>/dev/null)"
echo "  trad-switch(热键)= $(dconf read $LP_PATH/trad-switch 2>/dev/null)"

# ---- 3) 切到 libpinyin ----
echo
info "① 切换引擎到 libpinyin(智能拼音)..."
dconf write /desktop/ibus/general/preload-engines "['xkb:us::eng', 'libpinyin']" \
    && info "   preload-engines 已设为 [英文, 智能拼音]" || warn "   写入失败"
dconf write /desktop/ibus/general/engines-order "['libpinyin']" \
    && info "   engines-order 已设为 [libpinyin]" || true

# ---- 4) 锁简体 ----
info "② 锁定简体输出..."
dconf write "$LP_PATH/init-chinese" true \
    && info "   init-chinese = true (启动时进中文模式)" || warn "   写入失败"
dconf write "$LP_PATH/init-simplified-chinese" true \
    && info "   init-simplified-chinese = true (简体)" || warn "   写入失败"

# ---- 5) 根除复发: 解绑简繁热键 ----
info "③ 解绑简/繁切换热键(根除误触)..."
dconf write "$LP_PATH/trad-switch" "''" \
    && info "   trad-switch 已清空 → Ctrl+Shift+F 不再切换繁体" || warn "   写入失败"

# ---- 6) 重启 IBus ----
echo
info "④ 重启 IBus 使配置生效..."
ibus restart 2>/dev/null && info "   ibus 已重启" \
    || { warn "   ibus restart 无效, 尝试重启守护进程..."; ibus exit 2>/dev/null; sleep 1; }

# ---- 7) 复验 ----
echo
echo "${C_B}改动后:${C_R}"
echo "  preload-engines  = $(dconf read /desktop/ibus/general/preload-engines 2>/dev/null)"
echo "  init-simplified  = $(dconf read $LP_PATH/init-simplified-chinese 2>/dev/null)"
echo "  trad-switch(热键)= $(dconf read $LP_PATH/trad-switch 2>/dev/null)"
echo
info "完成。注销重登(或重启)后生效最稳妥。"
echo
echo "提示: Super+Space 切中英文。若 WorkBuddy 仍打不出中文, 试 XWayland 兼容模式:"
echo "      IBUS_XWAYLAND=1 sudo bash steamos-setup.sh 2   (会补 GTK_IM_MODULE=ibus)"
