#!/usr/bin/env bash
# =============================================================================
#  steamos-nix-detect.sh — 判定本机机型类别, 决定 steamos-nix 构建哪些部件。
# -----------------------------------------------------------------------------
#  为什么要这一步: steamos-nix 最初是为 GPD Win 5 写的 —— 背键守护进程 / udev 规则 /
#  inputplumber 设备覆盖与能力表这三件套, 对一台 9800X3D + 7900XTX 的台式机来说
#  纯属噪音(而且会导致 step4 在无 Win5 硬件的机器上无谓地失败)。反过来, 台式机通常
#  需要 WPS / 微信这类桌面生产力软件, 手持机则不需要。
#
#  nix 是纯函数式求值: 不能在 flake 里偷偷探测硬件。所以这里在 **nix 之外** 探测,
#  把结论写进 machine.nix(一个普通文件), flake 再 import 它 —— 既可复现, 又自动。
#
#  机型类别:
#    gpd-win5    有 GPD Win5 专用背键硬件 → 装三件套 + 背键守护
#    steam-deck  Valve 掌机 → 不装 Win5 三件套, 但保留掌机相关的省事默认值
#    desktop     台式机/HTPC(外接键鼠+手柄) → 只装跨机型通用的部分
#
#  用法:
#    bash steamos-nix-detect.sh              # 只打印结论 + 判定依据
#    bash steamos-nix-detect.sh --write      # 把结论写入 ../machine.nix
#    bash steamos-nix-detect.sh --quiet      # 只输出机型字符串(给脚本用)
#    bash steamos-nix-detect.sh --detect-only... 同 --quiet
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# 本脚本既可能在 scripts/ 里(源码树), 也可能装在 $out/bin(steamos-tools 里)
for cand in "$SCRIPT_DIR/.." "$SCRIPT_DIR/../../../../steamos-nix" "$PWD"; do
  if [ -f "$cand/flake.nix" ]; then REPO_ROOT="$(cd "$cand" && pwd)"; break; fi
done
REPO_ROOT="${REPO_ROOT:-$PWD}"

MACHINE_FILE="$REPO_ROOT/machine.nix"
QUIET=0
WRITE=0
FORCE=""
[ "${1:-}" = "--write" ]  && WRITE=1
[ "${1:-}" = "--quiet" ]  && QUIET=1
[ "${1:-}" = "--quiet" ] && [ "${2:-}" = "--write" ] && WRITE=1
case "${STEAMOS_NIX_MACHINE:-}" in
  gpd-win5|steam-deck|desktop) FORCE="$STEAMOS_NIX_MACHINE" ;;
esac

dmi() {  # dmi <file> — 读 DMI, 读不到返回空
  cat "/sys/class/dmi/id/$1" 2>/dev/null || echo ""
}
VENDOR="$(dmi sys_vendor)"
PRODUCT="$(dmi product_name)"
BOARD="$(dmi board_name)"
CHASSIS="$(dmi chassis_type)"
CPU="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || echo "")"
GPU="$(lspci 2>/dev/null | grep -E 'VGA|3D|Display' | head -3 | tr '\n' ';' | sed 's/;$//' || echo "lspci 不可用")"
BATTERIES="$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | wc -l)"
HAS_UINPUT="$( [ -e /dev/uinput ] && echo yes || echo no)"

# Win5 背键的 HID 是否真的存在(VID 2F24 / PID 0137)
win5_hid_present() {
  local found=no
  for d in /sys/class/hidraw/hidraw*; do
    [ -e "$d/device/uevent" ] || continue
    if grep -qi 'HID_ID=.*:00002F24:00000137' "$d/device/uevent" 2>/dev/null; then
      found=yes; break
    fi
  done
  echo "$found"
}
WIN5_HID="$(win5_hid_present)"

# ── 判定 ──────────────────────────────────────────────────────────────────
if [ -n "$FORCE" ]; then
  MACHINE="$FORCE"
  REASON="STEAMOS_NIX_MACHINE 环境变量强制指定"
elif echo "$VENDOR$PRODUCT$BOARD" | grep -qi GPD && echo "$VENDOR$PRODUCT$BOARD" | grep -q "G1618-05"; then
  MACHINE="gpd-win5"
  REASON="DMI 匹配 GPD Win 5 (G1618-05)"
elif [ "$WIN5_HID" = yes ]; then
  MACHINE="gpd-win5"
  REASON="探测到 Win5 背键 HID (2F24:0137)"
elif echo "$VENDOR" | grep -qi 'Valve' && echo "$PRODUCT" | grep -qiE 'Jupiter|Galileo'; then
  MACHINE="steam-deck"
  REASON="DMI 匹配 Valve 掌机 ($PRODUCT)"
elif [ "$BATTERIES" -gt 0 ] 2>/dev/null; then
  MACHINE="steam-deck"
  REASON="有电池($BATTERIES 块)+非 Win5 → 按掌机类处理"
else
  MACHINE="desktop"
  REASON="无内置电池 / 非掌机 chassis → 按台式机处理"
fi

if [ "$QUIET" = 1 ]; then
  echo "$MACHINE"
  [ "$WRITE" = 1 ] && { echo "$MACHINE" >/dev/null; }
else
  echo "════════ 机型画像 ════════"
  printf "  %-14s %s\n" "机型类别:" "$MACHINE"
  printf "  %-14s %s\n" "判定依据:" "$REASON"
  echo
  printf "  %-14s %s / %s\n" "厂商/型号:" "${VENDOR:-未知}" "${PRODUCT:-未知}"
  printf "  %-14s %s\n" "主板:" "${BOARD:-未知}"
  printf "  %-14s %s\n" "机箱类型:" "${CHASSIS:-未知}"
  printf "  %-14s %s\n" "CPU:" "${CPU:-未知}"
  printf "  %-14s %s\n" "GPU:" "${GPU:-未知}"
  printf "  %-14s %s 块\n" "电池:" "$BATTERIES"
  printf "  %-14s %s\n" "/dev/uinput:" "$HAS_UINPUT"
  printf "  %-14s %s\n" "Win5 背键 HID:" "$WIN5_HID"
  echo
  case "$MACHINE" in
    gpd-win5)   echo "  → 构建 Win5 全套: 背键守护 + udev 规则 + inputplumber 覆盖/能力表 + NTP + sudoers";;
    steam-deck) echo "  → 构建通用掌机集: NTP + sudoers(不含 Win5 三件套)";;
    desktop)    echo "  → 构建台式机集: NTP + sudoers + 桌面生产力包(WPS/微信/字体), 不含任何手持机专属配置";;
  esac
fi

if [ "$WRITE" = 1 ]; then
  cat > "$MACHINE_FILE" <<EOF
# machine.nix — 本机机型类别, 决定 steamos-nix 构建哪些部件。
#
# 由 scripts/steamos-nix-detect.sh --write 自动生成; 也可以直接手改。
# 可选值:
#   "gpd-win5"    GPD Win 5 —— 含背键守护/udev/inputplumber 三件套
#   "steam-deck"  Valve 掌机 —— 通用掌机集
#   "desktop"     台式机/HTPC —— 外接键鼠+手柄场景
{ machine = "$MACHINE"; }
EOF
  [ "$QUIET" = 1 ] || echo
  [ "$QUIET" = 1 ] || echo "  已写入 $MACHINE_FILE"
fi

exit 0
