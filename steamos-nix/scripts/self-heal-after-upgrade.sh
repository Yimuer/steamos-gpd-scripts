#!/usr/bin/env bash
# =============================================================================
#  SteamOS 系统升级后自愈脚本 (self-heal-after-upgrade.sh)
# -----------------------------------------------------------------------------
#  背景: SteamOS 用原子更新(A/B 分区), 每次大版本升级(如 3.8→3.9)会整块替换
#  rootfs 镜像, 把 steamos-setup.sh 写进 /etc /usr /opt 的系统级修改全部冲掉。
#  只有 /home 里的东西(守护脚本/游戏/Decky/进度文件)能幸存。
#
#  本脚本解决: 开机自动检测哪些系统级修改被冲掉, 缺了就调用 steamos-setup.sh
#  对应步骤(带 FORCE=1)重建。零重复逻辑 —— 完全复用主脚本的幂等安装。
#
#  设计要点:
#    - 本脚本 + 配套 systemd user 服务都放 /home, 本身能扛系统升级。
#    - 重建需要 root → 走 sudo 免密(仅放行下面 NEEDED_CMDS 这几条, 最小权限)。
#    - 无缺失时静默退出(exit 0), 不刷日志。
#
#  部署: 由 steamos-setup.sh 步骤[12] 一键安装。也可手动:
#    sudo bash steamos-setup.sh 12
# =============================================================================

# 主脚本路径(本脚本与 steamos-setup.sh 同目录)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
MAIN="$SCRIPT_DIR/steamos-setup.sh"

# ── 4 个系统级落点(升级会被冲掉) + 对应修复步骤 ──
# 数组顺序即检查顺序。每个元素: "落点描述|文件/命令|判断方式|修复步骤编号"
declare -a CHECKS=(
    # 1) 背键 systemd 单元
    "背键守护单元|/etc/systemd/system/gpd-win5-backkeys.service|file|4"
    # 2) udev 规则(背键虚拟键盘 ID_BUS 门禁)
    "背键 udev 规则|/etc/udev/rules.d/70-gpd-backkeys.rules|file|4"
    # 3) inputplumber 覆盖配置(deck 目标 + 背键虚拟键盘)
    "inputplumber 覆盖配置|/etc/inputplumber/devices.d/20-gpd_win5.yaml|file|4"
    # 4) inputplumber 自定义能力表(KB→QuickAccess)
    "inputplumber 能力表|/etc/inputplumber/capability_maps.d/20-gpd_win5.yaml|file|4"
    # 5) NTP drop-in(境内服务器, 加速开机)
    "境内 NTP|/etc/systemd/timesyncd.conf.d/ntp.conf|file|10"
    # 6) WorkBuddy wrapper 的 Wayland IME 参数
    "WorkBuddy Wayland IME|/usr/bin/workbuddy|ime|3"
)

NEED_REPAIR=()
for entry in "${CHECKS[@]}"; do
    IFS='|' read -r desc path how step <<< "$entry"
    missing=0
    case "$how" in
        file)
            [ -e "$path" ] || missing=1
            ;;
        ime)
            # wrapper 存在且含 --enable-wayland-ime 才算完好
            [ -f "$path" ] && grep -q -- "--enable-wayland-ime" "$path" 2>/dev/null || missing=1
            ;;
    esac
    if [ "$missing" -eq 1 ]; then
        NEED_REPAIR+=("$step")
        echo "[自愈] 检测到缺失: $desc ($path) → 需要重跑步骤 $step"
    fi
done

if [ "${#NEED_REPAIR[@]}" -eq 0 ]; then
    # 全部完好, 静默退出
    exit 0
fi

# ── 去重 + 排序, 得到需要重跑的步骤 ──
mapfile -t STEPS < <(printf '%s\n' "${NEED_REPAIR[@]}" | sort -u)
echo "[自愈] 需要重跑步骤: ${STEPS[*]}"

if [ ! -f "$MAIN" ]; then
    echo "[自愈] 找不到 $MAIN, 无法自愈。请重新解压备份包。"
    exit 1
fi

# 逐个步骤调用主脚本重建(FORCE=1 强制重跑, 因为进度文件可能还标着"已完成")
rc=0
for s in "${STEPS[@]}"; do
    echo "[自愈] 重建步骤 $s ..."
    if sudo -n bash "$MAIN" "$s" >/dev/null 2>&1; then
        echo "[自愈] 步骤 $s 完成"
    else
        # 无免密 sudo 时静默降级: 不报错刷屏, 下次开机再试(用户可手动跑)
        echo "[自愈] 步骤 $s 未执行(需 sudo 免密, 见 steamos-setup.sh 12)"
        rc=1
    fi
done

exit $rc
