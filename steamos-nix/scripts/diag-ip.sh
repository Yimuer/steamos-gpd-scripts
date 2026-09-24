#!/usr/bin/env bash
# inputplumber 深度探针 v2
#   sudo bash diag-ip.sh
# 会临时拉起 inputplumber(只接管内置手柄/内置键鼠/背键, 外接 USB 键鼠不受影响)。
set -uo pipefail
SVC=org.shadowblip.InputPlumber
IF=org.shadowblip.Input.CompositeDevice
BASE=/org/shadowblip/InputPlumber
export DBUS_SYSTEM_BUS_ADDRESS="${DBUS_SYSTEM_BUS_ADDRESS:-unix:path=/run/dbus/system_bus_socket}"
h() { printf "\n\033[1m══════ %s ══════\033[0m\n" "$*"; }

h "[A] 启动 inputplumber"
STARTED=0
pgrep -x inputplumber >/dev/null 2>&1 || { systemctl start inputplumber && sleep 4 && STARTED=1; }
pgrep -x inputplumber >/dev/null 2>&1 && echo "  已运行" || { echo "  启动失败"; exit 1; }

h "[B] CompositeDevice0 关键信息"
for i in 0 1 2; do
    P="$BASE/CompositeDevice$i"
    busctl introspect $SVC "$P" >/dev/null 2>&1 || continue
    echo "  ── $P ──"
    busctl introspect $SVC "$P" 2>&1 | grep -E "interface|method|property" | sed 's/^/    /'
    echo
    for M in GetName GetSourceDevicePaths GetTargetCapabilities GetTargetDevicePaths; do
        printf "  · %s →\n" "$M"
        busctl call $SVC "$P" $IF "$M" 2>&1 | sed 's/^/      /'
    done
done

h "[C] 背键源设备 event25 的属性"
S="$BASE/devices/source/event25"
busctl introspect $SVC "$S" 2>&1 | grep -E "interface|property" | sed 's/^/  /'
for I in $(busctl introspect $SVC "$S" 2>/dev/null | awk '$2=="interface"{print $1}'); do
    for PROP in Name Id DevicePath; do
        V=$(busctl get-property $SVC "$S" "$I" "$PROP" 2>/dev/null) && echo "  $I.$PROP = $V"
    done
done

h "[D] 目标设备 gamepad1 是什么"
for T in gamepad0 gamepad1 dbus0 keyboard0 mouse0; do
    P="$BASE/devices/target/$T"
    busctl introspect $SVC "$P" >/dev/null 2>&1 || continue
    echo "  ── $T ──"
    for I in $(busctl introspect $SVC "$P" 2>/dev/null | awk '$2=="interface"{print $1}'); do
        for PROP in Name Type DevicePath; do
            V=$(busctl get-property $SVC "$P" "$I" "$PROP" 2>/dev/null) && echo "    $I.$PROP = $V"
        done
    done
done

h "[E] 实测: 强制把目标设成 deck"
echo "  调用 SetTargetDevices([\"deck\"])..."
busctl call $SVC "$BASE/CompositeDevice0" $IF SetTargetDevices as 1 deck 2>&1 | sed 's/^/    /'
sleep 3
echo
echo "  再次列出 /dev/input (找 Valve Steam Deck Controller):"
python3 - <<'PY'
import glob, os
rows=[]
for d in glob.glob("/sys/class/input/event*"):
    try: rows.append((int(os.path.basename(d).replace("event","")),
                      open(d+"/device/name").read().strip()))
    except OSError: pass
for n, name in sorted(rows):
    mark = "  <<<<" if ("Steam Deck" in name or "Puck" in name or "Back Buttons" in name) else ""
    print("    event%-4d %s%s" % (n, name, mark))
PY

h "[F] 结束"
if [ "$STARTED" -eq 1 ]; then
    read -r -t 20 -p "  停掉 inputplumber? [Y/n] " B
    [ "${B:-Y}" = "n" ] || { systemctl stop inputplumber; echo "  已停止"; }
fi
