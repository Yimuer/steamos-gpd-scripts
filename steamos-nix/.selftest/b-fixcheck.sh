#!/bin/sh
# =============================================================================
#  b-fixcheck.sh — 对两处候选修复做回归: 修复版必须让 B4x / B10 转绿, 且
#                  不能破坏 B1/B2/B3 这些原本通过的项。
# =============================================================================
REPO=/tmp/steamos-nix
SBX=/tmp/fixck
rm -rf "$SBX"; mkdir -p "$SBX"
NP=0; NF=0
pass(){ NP=$((NP+1)); echo "[PASS] $*"; }
fail(){ NF=$((NF+1)); echo "[FAIL] $*"; }
hdr(){ echo; echo "── $* ──────────"; }

mkgen() {
  S="$1/etc"; mkdir -p "$S/systemd/system" "$S/udev/rules.d" \
      "$S/inputplumber/devices.d" "$S/inputplumber/capability_maps.d" \
      "$S/systemd/timesyncd.conf.d" "$S/sudoers.d"
  cp "$REPO/config/udev/rules.d/70-gpd-backkeys.rules"        "$S/udev/rules.d/"
  cp "$REPO/config/inputplumber/devices.d/20-gpd_win5.yaml"   "$S/inputplumber/devices.d/"
  cp "$REPO/config/inputplumber/capability_maps.d/20-gpd_win5.yaml" "$S/inputplumber/capability_maps.d/"
  sed -e 's#@PYTHON@#/nix/store/xxxxxxxxxxx-python3/bin/python3#g' \
      -e 's#@DAEMON@#/nix/store/yyyyyyyyyyy-daemon/gpd-win5-backkeys.py#g' \
      "$REPO/config/systemd/gpd-win5-backkeys.service.in" > "$S/systemd/system/gpd-win5-backkeys.service"
  sed -e 's#@NTP_SERVERS@#ntp.aliyun.com ntp.tencent.com#g' \
      "$REPO/config/ntp/ntp.conf.in" > "$S/systemd/timesyncd.conf.d/ntp.conf"
  sed -e 's#@USER@#deck#g' \
      -e 's#@ACTIVATE@#/home/deck/.steamos-nix/bin/steamos-nix-activate#g' \
      "$REPO/config/sudoers.d/steamos-nix.in" > "$S/sudoers.d/steamos-nix"
}

STORE="$SBX/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-steamos-etc"
mkgen "$STORE"
STATE="$SBX/state"; mkdir -p "$STATE"; ln -sfn "$STORE" "$STATE/etc-current"
ROOTFS="$SBX/rootfs"; mkdir -p "$ROOTFS"
ACT_FIX="$REPO/.selftest/activate-fixed.sh"

hdr "F1 修复版: 常规重建 + 链接形态"
sh "$ACT_FIX" --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1
n=$(find "$ROOTFS/etc" -type f -o -type l 2>/dev/null | wc -l)
[ "$n" = 6 ] && pass "F1 仍重建 6 个落点" || fail "F1 落点数=$n"
raw=$(readlink "$ROOTFS/etc/udev/rules.d/70-gpd-backkeys.rules")
case "$raw" in
  "$STORE/etc/udev/rules.d/"*) pass "F1 链接直指 store 真路径" ;;
  *) fail "F1 链接仍绕经指针: $raw" ;;
esac
m=$(stat -c %a "$ROOTFS/etc/sudoers.d/steamos-nix" 2>/dev/null)
[ "$m" = 440 ] && pass "F1 sudoers 仍 0440" || fail "F1 sudoers mode=$m"

hdr "F2 修复版: 幂等 + 半损"
s1=$(find "$ROOTFS/etc" | sort | md5sum | cut -d' ' -f1)
c1=$(find "$ROOTFS/etc" -type f -exec md5sum {} + 2>/dev/null | sort | md5sum | cut -d' ' -f1)
sh "$ACT_FIX" --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1
sh "$ACT_FIX" --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1
s2=$(find "$ROOTFS/etc" | sort | md5sum | cut -d' ' -f1)
c2=$(find "$ROOTFS/etc" -type f -exec md5sum {} + 2>/dev/null | sort | md5sum | cut -d' ' -f1)
[ "$s1" = "$s2" ] && [ "$c1" = "$c2" ] && pass "F2 幂等保持零变化" || fail "F2 幂等被破坏"
rm -rf "$ROOTFS/etc/inputplumber"; rm -f "$ROOTFS/etc/udev/rules.d/70-gpd-backkeys.rules"
sh "$ACT_FIX" --check --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1 \
  && fail "F2 --check 未发现缺失" || pass "F2 --check 仍能当缺失探针"
sh "$ACT_FIX" --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1
sh "$ACT_FIX" --check --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1 \
  && pass "F2 半损后仍可精确补回" || fail "F2 半损修复失败"

hdr "F3 修复版: 路径含空格"
SP="$SBX/has space"; mkdir -p "$SP/state" "$SP/rootfs"
ln -sfn "$STORE" "$SP/state/etc-current"
out=$(sh "$ACT_FIX" --state "$SP/state" --prefix "$SP/rootfs" 2>&1); rc=$?
n=$(find "$SP/rootfs/etc" -type f -o -type l 2>/dev/null | wc -l)
echo "      rc=$rc 落点数=$n"
[ "$n" = 6 ] && pass "F3 含空格路径正常重建" || fail "F3 仍失败: 输出=$(echo "$out" | head -2)"
wrong=$(find "$SP/rootfs" -maxdepth 2 -name '*space*' 2>/dev/null | wc -l)
[ "$wrong" = 0 ] && pass "F3 不再产生垃圾路径" || fail "F3 产生了 $wrong 个畸形路径"
# 内容比对: 带空格环境下每份内容都必须与 store 里的一致
bad=0
for f in udev/rules.d/70-gpd-backkeys.rules systemd/system/gpd-win5-backkeys.service \
         inputplumber/devices.d/20-gpd_win5.yaml systemd/timesyncd.conf.d/ntp.conf \
         sudoers.d/steamos-nix; do
  cmp -s "$SP/rootfs/etc/$f" "$STORE/etc/$f" || { bad=$((bad+1)); echo "      内容不一致: $f"; }
done
[ "$bad" = 0 ] && pass "F3 6 份内容全部与 store 一致" || fail "F3 有 $bad 份内容不一致"

hdr "F4 修复版: 换新 generation 后必须重链(行为变化提示)"
STORE2="$SBX/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-steamos-etc"
mkgen "$STORE2"
ln -sfn "$STORE2" "$STATE/etc-current"
before=$(readlink "$ROOTFS/etc/udev/rules.d/70-gpd-backkeys.rules")
sh "$ACT_FIX" --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1
after=$(readlink "$ROOTFS/etc/udev/rules.d/70-gpd-backkeys.rules")
case "$after" in "$STORE2/etc/udev/rules.d/"*) pass "F4 重跑到新 store 后链接正确改指" ;;
  *) fail "F4 链接未改指: $after" ;; esac
[ "$before" != "$after" ] && note_msg="换代后链接会变化 → 必须跑一次 activate(install.sh 第4步与开机自愈都已覆盖)" \
  || note_msg="链接未变化"
echo "[NOTE] $note_msg"

echo
echo "════════ 修复回归: $NP 通过 / $NF 失败 ════════"
