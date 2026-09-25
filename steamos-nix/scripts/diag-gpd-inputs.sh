#!/usr/bin/env bash
# GPD Win5 输入链路诊断 v2: 背键(L4/R4) + Home/KB 键
#
# 用法:
#   sudo bash diag-gpd-inputs.sh          # 跑全部
#   sudo bash diag-gpd-inputs.sh ip       # 只测 inputplumber(会临时拉起服务)
#   sudo bash diag-gpd-inputs.sh keys     # 只抓 Home/KB 按键码(独占设备, 不会切桌面)
#
# 只读 + 提示按键; 除临时启停 inputplumber 外不改任何系统配置。
set -uo pipefail

C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
h()   { printf "\n${C_B}══════ %s ══════${C_0}\n" "$*"; }
ok()  { printf "  ${C_G}[✓]${C_0} %s\n" "$*"; }
bad() { printf "  ${C_R}[✗]${C_0} %s\n" "$*"; }
warn(){ printf "  ${C_Y}[!]${C_0} %s\n" "$*"; }
ask() { printf "\n${C_Y}>>> %s${C_0}\n" "$*"; }
MODE="${1:-all}"
command -v python3 >/dev/null || { echo "需要 python3"; exit 1; }
command -v busctl  >/dev/null || warn "无 busctl, inputplumber 检测会受限"

# ─────────────────────────────────────────────
[ "$MODE" = "all" ] && {
h "[0] 服务状态"
systemctl is-active --quiet gpd-win5-backkeys 2>/dev/null \
    && ok "gpd-win5-backkeys: 运行中" \
    || bad "gpd-win5-backkeys: 未运行 (sudo systemctl start gpd-win5-backkeys)"
systemctl is-enabled gpd-win5-backkeys 2>/dev/null | grep -q enabled \
    && ok "开机自启: 已启用" || warn "开机自启: 未启用"

h "[1] uinput 虚拟键盘的 udev 属性(inputplumber 虚拟设备门禁)"
python3 - <<'PY'
import glob, os, subprocess
tgt = None
for d in sorted(glob.glob("/sys/class/input/event*")):
    try:
        if open(d + "/device/name").read().strip() == "GPD Win 5 Back Buttons":
            tgt = d; break
    except OSError: pass
if not tgt:
    print("  [✗] 未找到 'GPD Win 5 Back Buttons' —— 守护进程没起来"); raise SystemExit
print("  设备: %s" % tgt)
out = subprocess.run(["udevadm","info","--query=property","--path",
                      tgt.replace("/sys","")], capture_output=True, text=True).stdout
props = dict(l.split("=",1) for l in out.splitlines() if "=" in l)
bus = props.get("ID_BUS","(未设置)")
if bus == "bluetooth":
    print("  [✓] ID_BUS = bluetooth → inputplumber 会放行")
else:
    print("  [✗] ID_BUS = %s → 会被当虚拟设备丢弃" % bus)
    print("     修: sudo udevadm control --reload-rules && sudo udevadm trigger")
PY

h "[2] evdev 层: 背键是否真的发出 F14 / F15"
ask "8 秒内依次按: 背键 L4 → 背键 R4"
python3 - <<'PY'
import glob, os, struct, select, time, fcntl
p = None
for d in sorted(glob.glob("/sys/class/input/event*")):
    try:
        if open(d+"/device/name").read().strip() == "GPD Win 5 Back Buttons":
            p = "/dev/input/" + os.path.basename(d); break
    except OSError: pass
if not p: print("  [✗] 找不到背键设备"); raise SystemExit
fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)
FMT, SZ = "llHHi", struct.calcsize("llHHi")
N = {184: "KEY_F14 (L4)", 185: "KEY_F15 (R4)"}
t0, codes = time.time(), set()
while time.time() - t0 < 8:
    r, _, _ = select.select([fd], [], [], 0.3)
    if not r: continue
    for chunk in iter(lambda: os.read(fd, SZ*64), b""):
        for o in range(0, len(chunk)-SZ+1, SZ):
            _, _, t, c, v = struct.unpack(FMT, chunk[o:o+SZ])
            if t == 1 and v in (0,1):
                codes.add(c); print("    %-16s %s" % (N.get(c,"KEY_%d"%c), "按下" if v else "松开"))
        break
os.close(fd)
print("  [✓] uinput 层正常" if {184,185} & codes else "  [✗] 没有 F14/F15, 断点在守护进程之前")
PY
}

# ─────────────────────────────────────────────
[ "$MODE" = "all" ] || [ "$MODE" = "ip" ] && {
h "[3] inputplumber 复合设备(桌面模式需临时拉起服务)"
export DBUS_SYSTEM_BUS_ADDRESS="${DBUS_SYSTEM_BUS_ADDRESS:-unix:path=/run/dbus/system_bus_socket}"
STARTED=0
if ! pgrep -x inputplumber >/dev/null 2>&1; then
    warn "inputplumber 未运行(桌面模式默认不起)"
    echo "     为完成检测需临时拉起。它只会接管内置手柄/内置键鼠/背键,"
    echo "     你的外接 USB 键鼠不受影响; 测完会自动关掉。"
    read -r -t 30 -p "     现在启动? [y/N] " A
    if [ "${A:-N}" = "y" ] || [ "${A:-N}" = "Y" ]; then
        systemctl start inputplumber && sleep 4 && STARTED=1
    else
        warn "跳过。请回到【游戏模式】后再单独跑: sudo bash $0 ip"
    fi
fi

if pgrep -x inputplumber >/dev/null 2>&1; then
    ok "inputplumber 已运行"
    # 背键设备是否被 inputplumber 接管(被接管会被 udev 隐藏 + 建 by-hidden 链接)
    python3 - <<'PY'
import glob, os, subprocess
tgt = None
for d in sorted(glob.glob("/sys/class/input/event*")):
    try:
        if open(d+"/device/name").read().strip() == "GPD Win 5 Back Buttons":
            tgt = os.path.basename(d); break
    except OSError: pass
if not tgt: print("  [✗] 背键设备不见了"); raise SystemExit
dev = "/dev/input/" + tgt
mode = oct(os.stat(dev).st_mode)[-4:]
hid  = os.path.exists("/dev/inputplumber/by-hidden/" + tgt)
print("  %s 权限=%s  by-hidden链接=%s" % (dev, mode, hid))
if mode == "0000" or hid:
    print("  [✓] inputplumber 已接管背键键盘")
else:
    print("  [✗] inputplumber 没接管背键键盘(虚拟设备被过滤 或 配置没匹配上)")
PY
    echo
    busctl tree org.shadowblip.InputPlumber 2>/dev/null \
        | grep -oE "CompositeDevice[0-9]+" | sort -u | sed 's/^/  发现: /'
    for i in 0 1 2 3 4; do
        P="/org/shadowblip/InputPlumber/CompositeDevice$i"
        busctl introspect org.shadowblip.InputPlumber "$P" >/dev/null 2>&1 || continue
        echo; echo "  ── $P ──"
        busctl call org.shadowblip.InputPlumber "$P" \
            org.shadowblip.Input.CompositeDevice GetName 2>&1 | sed 's/^/  名称: /'
        SRC=$(busctl call org.shadowblip.InputPlumber "$P" \
            org.shadowblip.Input.CompositeDevice GetSourceDevicePaths 2>&1)
        echo "$SRC" | grep -qi "back buttons" \
            && ok "背键键盘【已】纳入源设备" || warn "背键键盘【未】纳入源设备"
        echo "$SRC" | grep -oE '"[^"]+"' | tr -d '"' | sed 's/^/      src: /' | head -12
        CAP=$(busctl call org.shadowblip.InputPlumber "$P" \
            org.shadowblip.Input.CompositeDevice GetTargetCapabilities 2>&1)
        PD=$(echo "$CAP" | grep -oiE '(Left|Right)Paddle[0-9]' | sort -u | tr '\n' ' ')
        [ -n "$PD" ] && ok "目标支持背键: $PD" || bad "目标【不支持】Paddle"
        echo "$CAP" | grep -oiE 'Gamepad:Button:[A-Za-z0-9]+' | sort -u \
            | paste -sd' ' - | sed 's/^/      caps: /'
    done
fi
if [ "$STARTED" -eq 1 ]; then
    read -r -t 20 -p "     检测完毕, 停掉 inputplumber? [Y/n] " B
    [ "${B:-Y}" = "n" ] || { systemctl stop inputplumber; ok "已停止(恢复桌面模式默认状态)"; }
fi
}

# ─────────────────────────────────────────────
[ "$MODE" = "all" ] || [ "$MODE" = "keys" ] && {
h "[4] Home / KB 键原始按键码(独占抓取, 不会再切走桌面)"
ask "12 秒内依次按: 左下 Home → 右下 KB (已独占设备, KDE 收不到)"
python3 - <<'PY'
import glob, os, struct, select, time, fcntl
EVIOCGRAB = 0x40044590
names = {}
for d in sorted(glob.glob("/sys/class/input/event*")):
    try: names["/dev/input/"+os.path.basename(d)] = open(d+"/device/name").read().strip()
    except OSError: pass
cands = {p: n for p, n in names.items()
         if "Keyboard for Windows" in n or "Mouse for Windows" in n
         or "Vendor for Windows" in n or n == "AT Translated Set 2 keyboard"}
fds = {}
for p in cands:
    try:
        fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK); fcntl.ioctl(fd, EVIOCGRAB, 1); fds[p] = fd
    except OSError as e: pass
if not fds: print("  [!] 没有可监听设备"); raise SystemExit
print("  独占监听:", ", ".join("%s(%s)" % (cands[p], os.path.basename(p)) for p in fds))
FMT, SZ = "llHHi", struct.calcsize("llHHi")
t0, seen = time.time(), {}
while time.time() - t0 < 12:
    r, _, _ = select.select(list(fds.values()), [], [], 0.3)
    for fd in r:
        p = [k for k, v in fds.items() if v == fd][0]
        try: chunk = os.read(fd, SZ*64)
        except BlockingIOError: continue
        pressed = set()
        for o in range(0, len(chunk)-SZ+1, SZ):
            _, _, t, c, v = struct.unpack(FMT, chunk[o:o+SZ])
            if t == 1 and v == 1: pressed.add(c)
        if pressed:
            seen.setdefault(cands[p], set()).update(pressed)
            print("    %-26s codes=%s" % (cands[p][:26], sorted(pressed)))
for fd in fds.values():
    try: fcntl.ioctl(fd, EVIOCGRAB, 0)
    except OSError: pass
    os.close(fd)
print()
for n, cs in seen.items(): print("  %s → 按键码 %s" % (n, sorted(cs)))
print("  对照: Meta=125 LeftCtrl=29 D=32 O=24 Tab=15 Delete=111")
print("  期望: Home=[125,32]  KB=[125,29,24]")
PY
}

echo
h "诊断结束"
echo "  把上面全部输出贴回即可定位。"
