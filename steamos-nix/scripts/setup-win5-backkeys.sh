#!/usr/bin/env bash
# ============================================================================
#  GPD Win 5 背键（L4/R4）修复脚本
#
#  原理:
#    背键藏在厂商 HID 设备 2F24:0137（内核不解析），本脚本安装一个用户态
#    守护进程读取该设备的原始报告，通过 uinput 注入 F14/F15，
#    再由 InputPlumber 的 gpd4 映射翻译为 Steam Deck 控制器背键拨片。
#
#  动作:
#    1. 安装守护进程 /usr/local/bin/gpd-win5-backkeys + systemd 服务
#    2. 生成 /etc/inputplumber/devices.d/20-gpd_win5.yaml
#       （基于系统自带 50-gpd_win5.yaml，追加虚拟键盘为源设备，数字小优先级高）
#    3. 启动服务并重启 InputPlumber
#
#  用法:
#    sudo bash setup-win5-backkeys.sh              安装
#    bash setup-win5-backkeys.sh --status          查看状态
#    sudo bash setup-win5-backkeys.sh --uninstall  卸载
#    sudo bash setup-win5-backkeys.sh --monitor    调试监听（不注入）
# ============================================================================

set -euo pipefail

# 守护进程源文件: 优先取本脚本同目录下的 gpd-win5-backkeys.py。
# 若本目录没有(旧版脚本曾依赖 /home/deck/下载/workbuddy 下的文件, 现已自包含),
# 回退到已安装位置。实际上本脚本现已不再需要外部 .py —— 见下方内嵌源码。
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON_SRC="$SRC_DIR/gpd-win5-backkeys.py"
DAEMON_DST="/usr/local/bin/gpd-win5-backkeys"
UNIT_PATH="/etc/systemd/system/gpd-win5-backkeys.service"
IP_CFG="/etc/inputplumber/devices.d/20-gpd_win5.yaml"
UDEV_RULE="/etc/udev/rules.d/70-gpd-backkeys.rules"
IP_DEFAULT="/usr/share/inputplumber/devices/50-gpd_win5.yaml"
SERVICE="gpd-win5-backkeys"

DO_UNINSTALL=0
DO_STATUS=0
DO_MONITOR=0
while [ $# -gt 0 ]; do
	case "$1" in
	--uninstall) DO_UNINSTALL=1 ;;
	--status) DO_STATUS=1 ;;
	--monitor) DO_MONITOR=1 ;;
	-h | --help) sed -n '2,21p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
	*) echo "未知参数: $1" >&2; exit 1 ;;
	esac
	shift
done

# --status 无需 root，其余模式自动提权重跑
if [ "$(id -u)" -ne 0 ] && [ "$DO_STATUS" -eq 0 ]; then
	exec sudo "$0" "$@"
fi

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_R=$'\033[0m'
info() { printf "${C_OK}[✓]${C_R} %s\n" "$*"; }
warn() { printf "${C_WARN}[!]${C_R} %s\n" "$*"; }
err()  { printf "${C_ERR}[✗]${C_R} %s\n" "$*" >&2; }
step() { printf "\n${C_DIM}── %s ──${C_R}\n" "$*"; }

# ---------------------------------------------------------------------------
if [ "$DO_STATUS" -eq 1 ]; then
	step "GPD Win 5 背键方案状态"
	printf "  守护进程   : %s\n" "$(systemctl is-active "$SERVICE" 2>/dev/null)"
	# 注意: 必须让 grep 直接读 name 文件内容，不能 ls | grep（那是搜文件名！）
	grep -qs "GPD Win 5 Back Buttons" /sys/devices/virtual/input/*/name &&
		info "uinput 虚拟键盘存在" || warn "uinput 虚拟键盘不存在（守护进程没跑起来？）"
	if [ -f "$IP_CFG" ]; then
		info "InputPlumber 覆盖配置存在: $IP_CFG"
	else
		warn "InputPlumber 覆盖配置不存在: $IP_CFG"
	fi
	if [ -f "$UDEV_RULE" ]; then
		info "udev 规则存在: $UDEV_RULE"
	else
		warn "udev 规则不存在: $UDEV_RULE"
	fi
	printf "  hidraw 节点: %s\n" \
		"$(python3 -c "
import glob
for p in sorted(glob.glob('/sys/class/hidraw/hidraw*')):
    try:
        for line in open(p + '/device/uevent'):
            if line.startswith('HID_ID=') and '2F24' in line and '0137' in line:
                print(p.replace('/sys/class/hidraw/', '/dev/'))
    except OSError: pass
" 2>/dev/null | head -1)"
	exit 0
fi

# ---------------------------------------------------------------------------
if [ "$DO_UNINSTALL" -eq 1 ]; then
	step "卸载"
	systemctl stop "$SERVICE" 2>/dev/null || true
	systemctl disable "$SERVICE" 2>/dev/null || true
	rm -f "$UNIT_PATH" "$DAEMON_DST" "$IP_CFG" "$UDEV_RULE"
	udevadm control --reload 2>/dev/null || true
	systemctl daemon-reload
	systemctl restart inputplumber 2>/dev/null || true
	info "已卸载（守护进程、服务、InputPlumber 覆盖配置均已移除）"
	exit 0
fi

# ---------------------------------------------------------------------------
if [ "$DO_MONITOR" -eq 1 ]; then
	# 调试监听：临时停 InputPlumber 没必要（hidraw 读取不冲突），直接跑
	exec python3 "$DAEMON_SRC" --monitor
fi

# 守护进程源码改为内嵌(与 steamos-setup.sh 第4步一致), 不依赖外部 .py。
# 若本目录确实存在 gpd-win5-backkeys.py, 优先用它(便于单独维护), 否则落盘内嵌源码。
if [ ! -f "$DAEMON_SRC" ]; then
    cat > "$DAEMON_SRC" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GPD Win 5 背键守护进程: L4/R4 -> uinput F14/F15 (由 setup-win5-backkeys.sh 生成)"""
import glob, os, struct, sys, time
TARGET_VID, TARGET_PID = 0x2F24, 0x0137
REPORT_ID = 0x01
L4_BYTE, R4_BYTE = 9, 10
L4_CODE, R4_CODE = 0x69, 0x6A
KEY_F14, KEY_F15 = 184, 185
EV_SYN, EV_KEY = 0x00, 0x01
BUS_BLUETOOTH = 0x05
UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_SETUP, UI_DEV_CREATE = 0x405C5503, 0x5501
INPUT_EVENT = struct.Struct("llHHi")
UINPUT_NAME = "GPD Win 5 Back Buttons"
DEBUG = os.environ.get("GPD_BACKKEYS_DEBUG") == "1"

def log(m): sys.stdout.write(m + "\n"); sys.stdout.flush()

def find_hidraw():
    for path in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            with open(path + "/device/uevent") as f:
                for line in f:
                    if not line.startswith("HID_ID="): continue
                    p = line.strip().split(":")
                    if len(p) < 3: continue
                    if int(p[1][-4:] or "0", 16) == TARGET_VID and int(p[2], 16) == TARGET_PID:
                        return "/dev/" + os.path.basename(path)
        except OSError: continue
    return None

def create_uinput():
    import fcntl
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY); fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    fcntl.ioctl(fd, UI_SET_KEYBIT, KEY_F14); fcntl.ioctl(fd, UI_SET_KEYBIT, KEY_F15)
    s = struct.pack("HHHH", BUS_BLUETOOTH, TARGET_VID, 0x9001, 1)
    s += UINPUT_NAME.encode().ljust(80, b"\x00") + struct.pack("I", 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, s); fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd

def emit(fd, t, c, v): os.write(fd, INPUT_EVENT.pack(0, 0, t, c, v))
def press(fd, c): emit(fd, EV_KEY, c, 1); emit(fd, EV_SYN, 0, 0)
def release(fd, c): emit(fd, EV_KEY, c, 0); emit(fd, EV_SYN, 0, 0)

def main():
    if "--monitor" in sys.argv:
        prev = None
        while True:
            path = find_hidraw()
            if not path: log("未找到设备,2s重试"); time.sleep(2); continue
            log("监听 %s" % path)
            try: fd = os.open(path, os.O_RDONLY)
            except OSError: time.sleep(2); continue
            try:
                while True:
                    data = os.read(fd, 128)
                    if not data: break
                    if data.hex() != prev:
                        prev = data.hex(); m = []
                        if len(data) > L4_BYTE and data[L4_BYTE] == L4_CODE: m.append("L4↓")
                        if len(data) > R4_BYTE and data[R4_BYTE] == R4_CODE: m.append("R4↓")
                        log("  " + " ".join("%02x" % b for b in data[:16]) + ("  <- " + " ".join(m) if m else ""))
            except OSError: pass
            finally: os.close(fd)
            time.sleep(1)
    if os.geteuid() != 0: print("需root", file=sys.stderr); return 1
    log("GPD Win5 背键守护进程启动")
    ufd = create_uinput()
    log("uinput 键盘 %s (F14=L4 F15=R4)" % UINPUT_NAME)
    l4d = r4d = False; prevr = None
    while True:
        path = find_hidraw()
        if not path: log("未找到设备,2s重试"); time.sleep(2); continue
        log("监听 %s" % path)
        try: fd = os.open(path, os.O_RDONLY)
        except OSError as e: log("打开失败 %s" % e); time.sleep(2); continue
        try:
            while True:
                data = os.read(fd, 128)
                if not data: log("设备EOF,重发现"); break
                if DEBUG and data.hex() != prevr:
                    prevr = data.hex(); log("  report: " + " ".join("%02x" % b for b in data[:24]))
                if len(data) <= max(L4_BYTE, R4_BYTE) or data[0] != REPORT_ID: continue
                l4n, r4n = data[L4_BYTE] == L4_CODE, data[R4_BYTE] == R4_CODE
                if l4n and not l4d: log("L4↓ F14"); press(ufd, KEY_F14)
                elif not l4n and l4d: log("L4↑"); release(ufd, KEY_F14)
                l4d = l4n
                if r4n and not r4d: log("R4↓ F15"); press(ufd, KEY_F15)
                elif not r4n and r4d: log("R4↑"); release(ufd, KEY_F15)
                r4d = r4n
        except OSError as e: log("读取中断 %s" % e)
        finally: os.close(fd)
        time.sleep(1)

if __name__ == "__main__": sys.exit(main())
PYEOF
    chmod 755 "$DAEMON_SRC"
    info "已内嵌守护进程源码到 $DAEMON_SRC"
fi

[ -f "$DAEMON_SRC" ] || { err "守护进程源文件仍不存在: $DAEMON_SRC"; exit 1; }
[ -f "$IP_DEFAULT" ] || { err "找不到 InputPlumber 默认配置: $IP_DEFAULT（InputPlumber 未安装或版本变了）"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "缺少 python3"; exit 1; }

step "安装 udev 规则（虚拟键盘标记为蓝牙设备）"
# InputPlumber 会跳过 /sys/devices/virtual 下的所有虚拟设备（防止把它自己
# 输出的虚拟手柄又抓回来）。此规则给键盘补 ID_BUS=bluetooth 属性，
# 配合守护进程设置的 BUS_BLUETOOTH bustype，让它被当作真实设备接管。
# 注意必须在守护进程重启（创建键盘）之前装好，udev 才能给新键盘打上标记。
cat >"$UDEV_RULE" <<'EOF'
# GPD Win 5 back-buttons virtual keyboard: let InputPlumber manage it.
SUBSYSTEM=="input", ATTRS{name}=="GPD Win 5 Back Buttons", ENV{ID_BUS}="bluetooth"
EOF
udevadm control --reload 2>/dev/null || true
info "udev 规则就绪: $UDEV_RULE"

step "安装守护进程"
install -m 755 "$DAEMON_SRC" "$DAEMON_DST"
cat >"$UNIT_PATH" <<EOF
[Unit]
Description=GPD Win 5 back buttons (L4/R4) to uinput translator
# 切勿写 After=multi-user.target: 与 Before=inputplumber.service + WantedBy=multi-user.target
# 构成 ordering cycle, systemd 会丢弃 inputplumber 启动任务(游戏模式无输入管理)。
# After=systemd-modules-load.service 只保证 uinput 就绪, 在 sysinit 阶段, 不成环。
After=systemd-modules-load.service
Before=inputplumber.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $DAEMON_DST
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"
# 等待 uinput 虚拟键盘就绪 + udev 数据库稳定。
# 若不等就立刻重启 InputPlumber，其初始枚举可能漏掉刚创建的键盘（竞态，已踩坑）
KB_READY=0
for _ in $(seq 10); do
	if grep -qs "GPD Win 5 Back Buttons" /sys/devices/virtual/input/*/name; then
		KB_READY=1
		break
	fi
	sleep 0.5
done
udevadm settle 2>/dev/null || true
if [ "$KB_READY" -eq 1 ]; then
	info "守护进程已安装并启动，虚拟键盘就绪（开机自启）"
else
	warn "守护进程已启动，但虚拟键盘迟迟未出现（继续安装，稍后验证）"
fi

step "生成 InputPlumber 覆盖配置"
# 基于系统自带 50-gpd_win5.yaml 生成 20-gpd_win5.yaml，追加虚拟键盘源设备。
# 数字越小优先级越高，InputPlumber 会用 20- 代替 50-，两者只生效其一。
mkdir -p "$(dirname "$IP_CFG")"
python3 - "$IP_DEFAULT" "$IP_CFG" <<'PYEOF'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

extra = (
    "  - group: keyboard\n"
    "    evdev:\n"
    '      name: "GPD Win 5 Back Buttons"\n'
    "      handler: event*\n"
)

lines = text.splitlines(keepends=True)
out, inserted = [], False
for line in lines:
    if not inserted and line.startswith("options:"):
        out.append("# === 以下为追加的源设备：背键守护进程注入的虚拟键盘 ===\n")
        out.append(extra)
        out.append("\n")
        inserted = True
    out.append(line)
if not inserted:
    sys.exit("未找到插入点（options:），InputPlumber 配置格式可能已变化")

open(dst, "w").write("".join(out))
print("已生成 %s" % dst)
PYEOF
info "覆盖配置就绪（20- 优先于 50-，系统自带配置保持原样未被修改）"

step "重启 InputPlumber 使配置生效"
systemctl restart inputplumber
sleep 3

# ---------------------------------------------------------------------------
step "验证"
sleep 1
if systemctl is-active --quiet "$SERVICE"; then
	info "守护进程运行中"
else
	err "守护进程未运行: journalctl -u $SERVICE -n 30"
fi
grep -qs "GPD Win 5 Back Buttons" /sys/devices/virtual/input/*/name &&
	info "uinput 虚拟键盘已创建" || warn "uinput 虚拟键盘未创建，查看日志"
SRC_N=$(busctl --system get-property org.shadowblip.InputPlumber \
	/org/shadowblip/InputPlumber/CompositeDevice0 \
	org.shadowblip.Input.CompositeDevice SourceDevicePaths 2>/dev/null |
	grep -o "/dev/input/event" | wc -l)
if [ "${SRC_N:-0}" -ge 5 ]; then
	info "InputPlumber 已接管虚拟键盘（合成设备现有 $SRC_N 个 evdev 源）"
elif [ -n "${SRC_N:-}" ] && [ "$SRC_N" -ge 1 ]; then
	warn "InputPlumber 仅 $SRC_N 个 evdev 源，虚拟键盘未被接管 —— 手动执行: sudo systemctl restart inputplumber"
else
	warn "无法查询 InputPlumber 合成设备状态（可能还在启动）"
fi
if [ -f /usr/share/inputplumber/capability_maps/gpd_type4.yaml ]; then
	info "gpd4 映射在位: F14→LeftPaddle1, F15→RightPaddle1"
fi

cat <<EOF

${C_OK}==================== 安装完成 ====================${C_R}

  现在按 L4 / R4 测试。推荐测试路径：
    1. 游戏手柄测试器或 Steam 里查看控制器输入
    2. Steam 设置 → 控制器 → Steam Deck 控制器 → 应能看到背键拨片

  调试命令:
    查看状态     bash $0 --status
    原始监听     sudo bash $0 --monitor
    守护进程日志 journalctl -u $SERVICE -f
    发现新字节   GPD_BACKKEYS_DEBUG=1 sudo /usr/local/bin/gpd-win5-backkeys

  卸载:
    sudo bash $0 --uninstall

  注意:
    InputPlumber 升级后若 50-gpd_win5.yaml 格式变化，重跑本脚本即可
    重新生成覆盖配置。

EOF
