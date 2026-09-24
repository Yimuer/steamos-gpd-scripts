#!/usr/bin/env bash
# =============================================================================
#  SteamOS 系统升级自愈钩子 (self-heal-after-upgrade.sh)  v2
# -----------------------------------------------------------------------------
#  触发: systemd user 服务每次开机调用(steamos-self-heal.service, 部署见步骤[12])
#
#  职责:
#    1) 版本变更检测: 对比 /etc/os-release 的 VERSION_ID 与上次记录
#       (记录存 /home, 能扛原子更新)。版本变化 = 经历了一次 A/B 原子更新,
#       rootfs 被整块替换。
#    2) 落地物清点: 逐项检查本项目写入 /etc 的系统级修改是否幸存,
#       生成"被冲掉清单" → 报告落盘 + 桌面通知。
#    3) 自动恢复: sudoers 幸存时直接跑主脚本 --after-upgrade
#       (主脚本落地复核: 完好的自动跳过, 只补被冲掉的, 含 pacman 包);
#       sudoers 也被冲掉时, 通知用户一条手动命令(需输一次密码)。
#
#  诚实说明: sudoers 在 /etc, 升级必被冲 → 大版本升级后的首次自动恢复
#  多半需要用户手动跑一次命令; 之后的局部损坏(无版本变化)可全自动修复。
#
#  本脚本 + main.conf + 版本戳都在 /home, 自身能扛系统升级。
#  主脚本路径固化在 main.conf(部署时由 steamos-setup.sh 步骤[12]写入)。
# =============================================================================

SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
STAMP="$SH_DIR/last-osversion"
REPORT="$SH_DIR/last-report.txt"
CONF="$SH_DIR/main.conf"

# ── 主脚本定位: 优先用部署时固化的 main.conf, 再兜底探测常见位置 ──
MAIN=""
# shellcheck disable=SC1090  # main.conf 由部署时生成, 路径运行期才确定
[ -f "$CONF" ] && . "$CONF" 2>/dev/null
{ [ -z "${MAIN:-}" ] || [ ! -f "$MAIN" ]; } && MAIN="$SH_DIR/steamos-setup.sh"
[ -f "$MAIN" ] || MAIN="$HOME/Downloads/steamos-reinstall-backup/steamos-setup.sh"
if [ ! -f "$MAIN" ]; then
    echo "[自愈] 找不到 steamos-setup.sh(main.conf: $CONF), 无法自动恢复"
    echo "[自愈] 请把备份包放回原位或修改 $CONF 里的 MAIN 路径"
    exit 1
fi

# ── 1. 版本变更检测 ──
VER_NOW="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -1 | tr -d '"')"
VER_PREV="$(cat "$STAMP" 2>/dev/null)"
VERSION_CHANGED=0
if [ -n "$VER_NOW" ]; then
    if [ -z "$VER_PREV" ]; then
        printf '%s\n' "$VER_NOW" > "$STAMP"      # 首次部署: 只登记, 不触发
    elif [ "$VER_NOW" != "$VER_PREV" ]; then
        VERSION_CHANGED=1
    fi
fi

# ── 2. 落地物清点(每项: "描述|路径|判断方式|修复步骤编号") ──
declare -a CHECKS=(
    "背键守护单元|/etc/systemd/system/gpd-win5-backkeys.service|file|4"
    "背键 udev 规则|/etc/udev/rules.d/70-gpd-backkeys.rules|file|4"
    "inputplumber 覆盖配置|/etc/inputplumber/devices.d/20-gpd_win5.yaml|file|4"
    "inputplumber 能力表|/etc/inputplumber/capability_maps.d/20-gpd_win5.yaml|file|4"
    "Decky Loader 系统单元|/etc/systemd/system/plugin_loader.service|file|5"
    "境内 NTP|/etc/systemd/timesyncd.conf.d/ntp.conf|file|10"
    "WorkBuddy Wayland IME|/usr/bin/workbuddy|ime|3"
)
MISSING=(); NEED_REPAIR=()
for entry in "${CHECKS[@]}"; do
    IFS='|' read -r desc path how step <<< "$entry"
    missing=0
    case "$how" in
        file) [ -e "$path" ] || missing=1 ;;
        ime)  { [ -f "$path" ] && grep -q -- "--enable-wayland-ime" "$path" 2>/dev/null; } || missing=1 ;;
    esac
    if [ "$missing" -eq 1 ]; then
        MISSING+=("$desc → $path")
        NEED_REPAIR+=("$step")
    fi
done

NOTHING_MISSING=0
[ "${#MISSING[@]}" -eq 0 ] && NOTHING_MISSING=1
if [ "$NOTHING_MISSING" -eq 1 ] && [ "$VERSION_CHANGED" -eq 0 ]; then
    exit 0    # 完好且无版本变化: 静默退出, 不刷日志
fi

# ── 3. 生成报告 ──
{
    echo "══ SteamOS 升级自愈报告  $(date '+%F %T') ══"
    if [ "$VERSION_CHANGED" -eq 1 ]; then
        echo "版本变化: ${VER_PREV:-未知} → $VER_NOW (原子更新已发生)"
    fi
    if [ "$NOTHING_MISSING" -eq 0 ]; then
        echo "本次检测到被冲掉的内容:"
        printf '  ✗ %s\n' "${MISSING[@]}"
        echo "(pacman 包等其余系统级内容由主脚本 --after-upgrade 的落地复核接管)"
    else
        echo "系统级落点完好; pacman 包等由主脚本落地复核接管"
    fi
} | tee "$REPORT"

notify() {
    command -v notify-send >/dev/null 2>&1 \
        && notify-send -u critical -a "SteamOS 自愈" "$1" "$2" 2>/dev/null
    return 0
}

rc=0
if [ "$VERSION_CHANGED" -eq 1 ]; then
    # ── 4a. 版本变了 → 全量自动恢复(--after-upgrade: 只补被冲掉的) ──
    echo "[自愈] 检测到版本变更 → 尝试全量自动恢复(需免密 sudo)..."
    # shellcheck disable=SC2024  # 重定向发生在用户侧, 报告文件属主是 deck, 正合需求
    if sudo -n bash "$MAIN" --after-upgrade >>"$REPORT" 2>&1; then
        echo "[自愈] 全量恢复完成, 详情见 $REPORT"
        notify "SteamOS 升级自愈" "系统已更新到 $VER_NOW, 配置已自动恢复。详情: $REPORT"
    else
        echo "[自愈] 自动恢复未执行成功(多半是 sudoers 也被升级冲掉了)。"
        echo "[自愈] 请手动跑一次(需输密码):"
        echo "        sudo bash $MAIN --after-upgrade"
        notify "SteamOS 升级自愈" "检测到升级到 $VER_NOW, 有配置被冲掉。请手动执行: sudo bash $MAIN --after-upgrade"
        rc=1
    fi
    printf '%s\n' "$VER_NOW" > "$STAMP"
else
    # ── 4b. 无版本变化但有缺失(局部损坏) → 逐点重建 ──
    mapfile -t STEPS < <(printf '%s\n' "${NEED_REPAIR[@]}" | sort -u)
    echo "[自愈] 检测到局部缺失, 需要重跑步骤: ${STEPS[*]}"
    for s in "${STEPS[@]}"; do
        echo "[自愈] 重建步骤 $s ..."
        # shellcheck disable=SC2024  # 同上
        if sudo -n bash "$MAIN" "$s" >>"$REPORT" 2>&1; then
            echo "[自愈] 步骤 $s 完成"
        else
            echo "[自愈] 步骤 $s 未执行(需免密 sudo, 见 steamos-setup.sh 12)"
            rc=1
        fi
    done
fi
exit $rc
