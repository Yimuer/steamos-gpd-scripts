#!/usr/bin/env bash
# ===========================================================================
#  游戏模式(大屏幕 / gamescope)中文输入 —— 走 IBus 原生通道
# ---------------------------------------------------------------------------
#  ⚠ 变更说明(2026-09-16)
#    旧版是给 fcitx5 装 AUR 桥接包 fcitx5-steam-ibus-frontend, 让 fcitx5 冒充
#    IBus 供 Steam 使用。Steam 客户端在游戏模式下**只认 IBus D-Bus 协议**
#    (会话 target 里的 ibus-gamescope.service 就是这个通道), 所以那层桥接是
#    纯补丁 —— 上游一改就断, 而且和桌面模式的 fcitx5 抢 DBus 名。
#
#    输入法统一到 IBus(SteamOS 自带)之后, 这个通道由**真正的 ibus-daemon**
#    提供, 桥接层整个不需要了。少一层就少一处坏点。
#
#  现在本脚本只做三件事:
#    1) 确认 ibus-daemon 常驻(桌面模式与 gamescope 共用同一个守护进程)
#    2) 确认 unit 挂上了 gamescope-session.target
#    3) 给出排查命令
#
#  真正写配置的是: sh scripts/setup-ibus-xiaohe.sh
#
#  用法: bash setup-steam-game-mode-ime.sh
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'; C_B=$'\033[1m'
info() { echo "${C_G}[✓]${C_R} $*"; }
warn() { echo "${C_Y}[!]${C_R} $*"; }
err()  { echo "${C_RD}[✗]${C_R} $*" >&2; }

UNIT="$HOME/.config/systemd/user/ibus-daemon.service"
SETUP="$(dirname "$0")/setup-ibus-xiaohe.sh"

echo "${C_B}=== 游戏模式(gamescope)中文输入 · IBus 原生通道 ===${C_R}"
echo

# ── 1/3 前置: IBus 配置是否已经做过 ─────────────────────────────────────
if [ ! -f "$UNIT" ]; then
    warn "没有 $UNIT —— 先把输入法配好再来"
    if [ -f "$SETUP" ]; then
        echo "  现在跑: sh $SETUP"
        sh "$SETUP"
    else
        err "找不到 $SETUP"
        exit 1
    fi
fi

# ── 2/3 确认 unit 与 target ─────────────────────────────────────────────
echo
echo "== 1/3 检查 ibus-daemon unit =="
if [ -f "$UNIT" ]; then
    info "unit 存在: $UNIT"
    if grep -q 'gamescope-session.target' "$UNIT"; then
        info "已挂上 gamescope-session.target"
    else
        warn "unit 里没有 gamescope-session.target → 重跑 setup-ibus-xiaohe.sh 刷新"
    fi
    if grep -q 'gamescope-environment' "$UNIT"; then
        info "会读取 gamescope 的 DISPLAY(EnvironmentFile)"
    else
        warn "unit 没读 gamescope-environment, 游戏模式下可能拿不到 DISPLAY"
    fi
fi

echo
echo "== 2/3 检查运行状态 =="
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if systemctl --user is-enabled ibus-daemon.service >/dev/null 2>&1; then
        info "ibus-daemon.service 已 enable"
    else
        warn "未 enable, 正在启用…"
        systemctl --user enable ibus-daemon.service >/dev/null 2>&1 \
            && info "已 enable" || warn "enable 失败"
    fi
    if systemctl --user is-active ibus-daemon.service >/dev/null 2>&1; then
        info "ibus-daemon 正在运行"
    else
        warn "没在跑(桌面模式下可能还没进会话), 尝试拉起…"
        systemctl --user restart ibus-daemon.service >/dev/null 2>&1 \
            && info "已拉起" || warn "拉起失败"
    fi
    systemctl --user is-active fcitx5-steam-ibus.service >/dev/null 2>&1 && {
        warn "检测到旧的 fcitx5-steam-ibus.service 还在跑 —— 它会和 ibus-daemon 抢 DBus 名"
        warn "  停掉: systemctl --user disable --now fcitx5-steam-ibus.service"
    }
else
    warn "没有 systemctl(沙盒环境属正常)"
fi

# ── 3/3 排查指引 ────────────────────────────────────────────────────────
echo
echo "== 3/3 完成 =="
cat <<EOF

使用:
  1) 切到游戏模式(或重启后直接进)
  2) STEAM + X 呼出虚拟键盘
  3) 键盘左下角切换输入法 → 选中文(小鹤双拼 / rime)

排查(游戏模式里开终端或 SSH):
  systemctl --user status ibus-daemon.service
  journalctl --user -u ibus-daemon -b --no-pager | tail -30
  sh $(dirname "$0")/setup-ibus-xiaohe.sh --check

说明: 桌面模式与游戏模式共用同一个 ibus-daemon 与同一份 Rime 配置,
      小鹤双拼两边一致, 不需要分别配置。
EOF
