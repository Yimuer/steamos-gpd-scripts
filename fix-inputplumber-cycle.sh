#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 修复: inputplumber 因 systemd ordering cycle 无法开机启动
#
# 症状: 游戏模式下内置手柄仍是 "Microsoft X-Box 360 pad",
#       L4/R4 背键 + Home + KB 全部无映射。
#       桌面模式手动 systemctl start inputplumber 却一切正常。
#
# 根因: gpd-win5-backkeys.service 同时写了
#         After=multi-user.target
#         Before=inputplumber.service
#         WantedBy=multi-user.target
#       三者构成 multi-user.target → inputplumber → backkeys → multi-user.target
#       的死循环, systemd 报 "Unable to break cycle" 后直接丢弃 inputplumber
#       的启动任务 → 游戏模式下 inputplumber 从未运行。
#
# 用法: sudo bash fix-inputplumber-cycle.sh
# ---------------------------------------------------------------------------
set -uo pipefail

C_0=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_D=$'\033[2m'
info(){ printf "${C_G}[✓]${C_0} %s\n" "$*"; }
warn(){ printf "${C_Y}[!]${C_0} %s\n" "$*"; }
err() { printf "${C_R}[✗]${C_0} %s\n" "$*"; }
step(){ printf "\n${C_D}════════ %s ════════${C_0}\n" "$*"; }
ask() { printf "${C_Y}>>>${C_0} %s\n" "$*"; }

UNIT="/etc/systemd/system/gpd-win5-backkeys.service"
IPSVC="inputplumber.service"

[ "$(id -u)" -eq 0 ] || { err "需要 root, 请用 sudo 运行"; exit 1; }

# --------------------------------------------------------------------------
step "[1] 检查是否真的存在 ordering cycle"
# --------------------------------------------------------------------------
if journalctl -u "$IPSVC" -b --no-pager 2>/dev/null | grep -q "ordering cycle"; then
    err "已确认: 本次启动存在 ordering cycle, inputplumber 被 systemd 丢弃"
    journalctl -u "$IPSVC" -b --no-pager 2>/dev/null \
        | grep -iE "ordering cycle|Unable to break" | sort -u | sed 's/^/    /'
else
    warn "本次启动日志里没找到 ordering cycle(可能已被修过, 或日志已轮转)"
fi

# --------------------------------------------------------------------------
step "[2] 修正 unit 依赖(去掉成环的 After=multi-user.target)"
# --------------------------------------------------------------------------
if [ ! -f "$UNIT" ]; then
    err "$UNIT 不存在, 请先跑 steamos-setup.sh 第 4 步"; exit 1
fi

# 保留原有 ExecStart / Restart 等, 便于不同版本兼容
EXEC="$(awk -F= '/^ExecStart=/{sub(/^ExecStart=/,"");print;exit}' "$UNIT")"
# 兜底: 提取失败时用动态 home(不再写死 /home/deck), 与主脚本第4步的安装路径一致
[ -n "$EXEC" ] || {
    RH="$(getent passwd "${SUDO_USER:-deck}" 2>/dev/null | cut -d: -f6)"
    [ -n "$RH" ] || RH="/home/${SUDO_USER:-deck}"
    EXEC="/usr/bin/python3 $RH/.local/opt/gpd-win5-backkeys/gpd-win5-backkeys.py"
}

if grep -qE '^\s*After=.*multi-user\.target' "$UNIT"; then
    TS="$(date +%Y%m%d-%H%M%S)"
    cp -a "$UNIT" "${UNIT}.bak.$TS"
    info "已备份 → ${UNIT}.bak.$TS"
else
    warn "unit 里没有 After=multi-user.target, 无需改依赖(仍会重写以保持一致)"
    TS="$(date +%Y%m%d-%H%M%S)"; cp -a "$UNIT" "${UNIT}.bak.$TS"
fi

cat > "$UNIT" <<EOF
[Unit]
Description=GPD Win 5 back buttons (L4/R4) to uinput translator
# 切勿写 After=multi-user.target: 它与 Before=inputplumber.service 以及
# WantedBy=multi-user.target 构成 ordering cycle(multi-user.target →
# inputplumber → backkeys → multi-user.target), systemd 会报
# "Unable to break cycle" 并丢弃 inputplumber 的启动任务 → 游戏模式无输入管理,
# 手柄退回原始 Xbox 360, 背键/Home/KB 全部失效。
# After=systemd-modules-load.service 只保证 uinput 模块就绪,
# 处于 sysinit 阶段, 不会成环。
After=systemd-modules-load.service
# 守护进程放在 /home 下, 必须等 /home 挂载完(否则 ExecStart 找不到文件,
# 只能靠 Restart 反复重试)。/home 属 local-fs 阶段, 早于 multi-user, 不成环。
RequiresMountsFor=/home
Before=inputplumber.service

[Service]
Type=simple
ExecStart=$EXEC
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
info "unit 已重写, daemon-reload 完成"

# --------------------------------------------------------------------------
step "[3] 校验依赖图不再成环"
# --------------------------------------------------------------------------
CYCLE="$(systemd-analyze verify "$UNIT" 2>&1 | grep -i 'cycle' || true)"
if [ -n "$CYCLE" ]; then
    err "systemd-analyze 仍报告 cycle:"; echo "$CYCLE" | sed 's/^/    /'
else
    info "systemd-analyze: 未发现 ordering cycle"
fi

# --------------------------------------------------------------------------
step "[4] 确保 inputplumber 开机能起来"
# --------------------------------------------------------------------------
RUN_WANTS="/run/systemd/system/multi-user.target.wants/$IPSVC"
ETC_WANTS="/etc/systemd/system/multi-user.target.wants/$IPSVC"
if [ -e "$ETC_WANTS" ]; then
    info "inputplumber 已永久启用(/etc)"
elif [ -e "$RUN_WANTS" ]; then
    info "inputplumber 由 udev 规则运行时启用(/run), 正常"
else
    warn "两处 wants 链接都不存在, 开机可能不启动 → 永久启用"
    systemctl enable "$IPSVC" 2>&1 | sed 's/^/    /'
fi

# --------------------------------------------------------------------------
step "[5] 立即重启服务并验证"
# --------------------------------------------------------------------------
systemctl restart gpd-win5-backkeys 2>&1 | sed 's/^/    /'
sleep 2
systemctl restart "$IPSVC" 2>&1 | sed 's/^/    /'
sleep 5

if systemctl is-active --quiet "$IPSVC"; then
    info "inputplumber: 已运行 (PID $(pgrep -f '^/usr/bin/inputplumber' | head -1))"
else
    err "inputplumber 仍未运行, 日志:"
    journalctl -u "$IPSVC" -n 25 --no-pager 2>/dev/null | sed 's/^/    /'
fi

if systemctl is-active --quiet gpd-win5-backkeys; then
    info "gpd-win5-backkeys: 运行中"
else
    err "gpd-win5-backkeys 未运行"
fi

# --------------------------------------------------------------------------
step "[6] 复合设备 / 目标设备核查"
# --------------------------------------------------------------------------
CDP="/org/shadowblip/InputPlumber/CompositeDevice0"
if busctl --no-pager introspect org.shadowblip.InputPlumber "$CDP" \
     org.shadowblip.Input.CompositeDevice >/dev/null 2>&1; then
    NAME="$(busctl get-property org.shadowblip.InputPlumber "$CDP" \
        org.shadowblip.Input.CompositeDevice Name 2>&1 | tr -d '\n')"
    echo "    名称: $NAME"

    CAPS="$(busctl call org.shadowblip.InputPlumber "$CDP" \
        org.shadowblip.Input.CompositeDevice GetTargetCapabilities 2>&1)"
    if echo "$CAPS" | grep -qi "LeftPaddle\|RightPaddle"; then
        info "目标能力含 Paddle(背键可用)"
    else
        warn "目标能力里没找到 Paddle, 原始返回:"
        echo "$CAPS" | head -c 500 | sed 's/^/    /'
    fi
    if echo "$CAPS" | grep -qi "Guide"; then
        info "目标能力含 Guide(Steam 键可用)"
    fi
    if echo "$CAPS" | grep -qi "QuickAccess"; then
        info "目标能力含 QuickAccess(右侧边栏可用)"
    fi
else
    warn "CompositeDevice0 不存在(inputplumber 刚起来, 再等几秒或查看日志)"
fi

echo
echo "    源设备列表:"
busctl get-property org.shadowblip.InputPlumber "$CDP" \
    org.shadowblip.Input.CompositeDevice SourceDevicePaths 2>&1 \
    | tr ' ' '\n' | grep -i "event" | sed 's/^/      /'

# gamepad 目标身份
for i in 0 1 2; do
    P="/org/shadowblip/InputPlumber/devices/target/gamepad$i"
    T="$(busctl get-property org.shadowblip.InputPlumber "$P" \
        org.shadowblip.Input.TargetGamepad Name 2>/dev/null | tr -d '\n')"
    [ -n "$T" ] && echo "    gamepad$i = $T"
done

# --------------------------------------------------------------------------
step "[7] 接下来"
# --------------------------------------------------------------------------
cat <<'EOT'
  1) 重启: sudo reboot
  2) 进游戏模式 → 设置 → 控制器, 确认选中的是内置手柄
     (注意别选到你外接的 Steam Controller 接收器)
  3) 按 L4 / R4 / Home / KB 验证:
       背键  → L4 / R4
       Home  → Steam 大菜单
       KB    → 右侧边栏 QAM
  4) 若还有问题, 回到桌面模式执行(可看到游戏模式期间的日志):
       journalctl -u inputplumber -b --no-pager | grep -iE "deck|target|cycle|error"
EOT
