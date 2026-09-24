#!/bin/sh
# =============================================================================
#  b-harness.sh — 在纯 Linux 环境里跑 steamos-nix-activate 的健壮性场景。
#  不碰任何真实 /etc: 一切都在 /tmp/sbx 下的假 store + 假 rootfs 里。
#
#  机型自适应: 按 machine.nix(或 STEAMOS_NIX_MACHINE)决定假 store 里放几个落点 ——
#    gpd-win5 → 6 个(背键 unit + udev + inputplumber×2 + ntp + sudoers)
#    其它     → 2 个(ntp + sudoers)
#
#  用法: sh .selftest/b-harness.sh                    # 按 machine.nix
#        STEAMOS_NIX_MACHINE=gpd-win5 sh .selftest/b-harness.sh
# =============================================================================
REPO=/tmp/steamos-nix
SBX=/tmp/sbx
rm -rf "$SBX"
mkdir -p "$SBX"
NP=0; NF=0
pass(){ NP=$((NP+1)); echo "[PASS] $*"; }
fail(){ NF=$((NF+1)); echo "[FAIL] $*"; }
note(){ echo "[NOTE] $*"; }
hdr(){ echo; echo "── $* ──────────"; }

MACHINE=${STEAMOS_NIX_MACHINE:-$(sed -n 's/.*machine[ ]*=[ ]*"\([a-z0-9-]*\)".*/\1/p' "$REPO/machine.nix" | head -1)}
[ -n "$MACHINE" ] || MACHINE=desktop
if [ "$MACHINE" = gpd-win5 ]; then EXPECTED=6; else EXPECTED=2; fi
echo "机型: $MACHINE   预期 /etc 落点: $EXPECTED"

# ── 造一份"假 /nix/store/…-steamos-etc" ──────────────────────────────────
mkgen() {   # mkgen <gen-dir> <tag>
  S="$1/etc"; mkdir -p "$S/systemd/timesyncd.conf.d" "$S/sudoers.d"
  sed -e 's#@NTP_SERVERS@#ntp.aliyun.com ntp.tencent.com#g' \
      "$REPO/config/ntp/ntp.conf.in" > "$S/systemd/timesyncd.conf.d/ntp.conf"
  [ -n "$2" ] && echo "$2" >> "$S/systemd/timesyncd.conf.d/ntp.conf"
  sed -e 's#@USER@#deck#g' \
      -e 's#@ACTIVATE@#/home/deck/.steamos-nix/bin/steamos-nix-activate#g' \
      "$REPO/config/sudoers.d/steamos-nix.in" > "$S/sudoers.d/steamos-nix"
  if [ "$MACHINE" = gpd-win5 ]; then
    mkdir -p "$S/systemd/system" "$S/udev/rules.d" \
             "$S/inputplumber/devices.d" "$S/inputplumber/capability_maps.d"
    sed -e 's#@PYTHON@#/nix/store/xxxxxxxxxxx-python3/bin/python3#g' \
        -e 's#@DAEMON@#/nix/store/yyyyyyyyyyy-daemon/gpd-win5-backkeys.py#g' \
        "$REPO/config/systemd/gpd-win5-backkeys.service.in" > "$S/systemd/system/gpd-win5-backkeys.service"
    cp "$REPO/config/udev/rules.d/70-gpd-backkeys.rules"      "$S/udev/rules.d/"
    cp "$REPO/config/inputplumber/devices.d/20-gpd_win5.yaml"  "$S/inputplumber/devices.d/"
    cp "$REPO/config/inputplumber/capability_maps.d/20-gpd_win5.yaml" "$S/inputplumber/capability_maps.d/"
  fi
}

STORE1="$SBX/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-steamos-etc"
STORE2="$SBX/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-steamos-etc"
mkgen "$STORE1" ""
mkgen "$STORE2" "GEN2MARK"

STATE="$SBX/state"; mkdir -p "$STATE"
ln -sfn "$STORE1" "$STATE/etc-current"
ROOTFS="$SBX/rootfs"; mkdir -p "$ROOTFS"
ACT="$REPO/.selftest/activate-test.sh"
LINK_EXPECT=$((EXPECTED - 1))     # sudoers 是副本, 其余是链接

count_files() { find "$ROOTFS/etc" -type f -o -type l 2>/dev/null | wc -l; }
count_links() { find "$ROOTFS/etc" -type l 2>/dev/null | wc -l; }

# ══ B1 空 rootfs → 一条命令全量重建 ═══════════════════════════════════════
hdr "B1 模拟原子升级后: /etc 干净 → 一次激活全量重建"
out=$(sh "$ACT" --state "$STATE" --prefix "$ROOTFS" 2>&1); rc=$?
echo "      activate: $out (rc=$rc)"
n=$(count_files)
[ "$n" = "$EXPECTED" ] && pass "B1 重建出 $EXPECTED 个落点" || fail "B1 落点数=$n (期望 $EXPECTED)"
[ "$(count_links)" = "$LINK_EXPECT" ] && pass "B1 其中 $LINK_EXPECT 个是符号链接" \
  || fail "B1 链接数=$(count_links) (期望 $LINK_EXPECT)"
m=$(stat -c %a "$ROOTFS/etc/sudoers.d/steamos-nix" 2>/dev/null)
[ "$m" = "440" ] && pass "B1 sudoers 以 0440 落盘" || fail "B1 sudoers mode=$m (期望 440)"
[ -f "$ROOTFS/etc/sudoers.d/steamos-nix" ] && [ ! -L "$ROOTFS/etc/sudoers.d/steamos-nix" ] \
  && pass "B1 sudoers 是副本而非符号链接" || fail "B1 sudoers 不是普通文件副本"
if [ "$MACHINE" = gpd-win5 ]; then
  grep -q '@PYTHON@\|@DAEMON@\|@NTP_SERVERS@\|@USER@\|@ACTIVATE@' \
       "$ROOTFS/etc/systemd/system/gpd-win5-backkeys.service" \
       "$ROOTFS/etc/systemd/timesyncd.conf.d/ntp.conf" \
       "$ROOTFS/etc/sudoers.d/steamos-nix" \
    && fail "B1 仍有未替换占位符" || pass "B1 模板占位符全部替换"
  [ -e "$ROOTFS/etc/inputplumber/devices.d/20-gpd_win5.yaml" ] \
    && pass "B1 Win5: inputplumber 覆盖已就位" || fail "B1 Win5: inputplumber 覆盖缺失"
else
  [ -e "$ROOTFS/etc/systemd/system" ] && fail "B1 机型裁剪失效: desktop 却出现了 unit 目录" \
    || pass "B1 机型裁剪: 没有 Win5 专属 unit"
  [ -e "$ROOTFS/etc/inputplumber" ] && fail "B1 机型裁剪失效: 出现 inputplumber 目录" \
    || pass "B1 机型裁剪: 没有 inputplumber 目录"
fi

# ══ B2 幂等 ══════════════════════════════════════════════════════════════
hdr "B2 重复执行(幂等)"
s1=$(find "$ROOTFS/etc" | sort | md5sum | cut -d' ' -f1)
c1=$(find "$ROOTFS/etc" -type f -exec md5sum {} + 2>/dev/null | sort | md5sum | cut -d' ' -f1)
sh "$ACT" --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1
sh "$ACT" --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1
s2=$(find "$ROOTFS/etc" | sort | md5sum | cut -d' ' -f1)
c2=$(find "$ROOTFS/etc" -type f -exec md5sum {} + 2>/dev/null | sort | md5sum | cut -d' ' -f1)
[ "$s1" = "$s2" ] && pass "B2 文件集合零变化" || fail "B2 文件集合发生变化"
[ "$c1" = "$c2" ] && pass "B2 文件内容零变化" || fail "B2 文件内容发生变化"
sh "$ACT" --check --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1 \
  && pass "B2 --check rc=0" || fail "B2 --check 报告缺失"

# ══ B3 半损 ══════════════════════════════════════════════════════════════
hdr "B3 半损: 冲掉 ntp drop-in 与 sudoers(两种机型都有的通用落点)"
rm -f "$ROOTFS/etc/systemd/timesyncd.conf.d/ntp.conf"
rm -f "$ROOTFS/etc/sudoers.d/steamos-nix"
out=$(sh "$ACT" --check --state "$STATE" --prefix "$ROOTFS" 2>&1); rc=$?
[ "$rc" != 0 ] && pass "B3 --check 探测到缺失 (rc=$rc)" || fail "B3 --check 未发现缺失"
echo "      缺失清单: $(echo "$out" | tr '\n' ' ')"
sh "$ACT" --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1
[ -e "$ROOTFS/etc/systemd/timesyncd.conf.d/ntp.conf" ] && pass "B3 ntp 补回" || fail "B3 ntp 未补回"
[ -e "$ROOTFS/etc/sudoers.d/steamos-nix" ] && pass "B3 sudoers 补回" || fail "B3 sudoers 未补回"
sh "$ACT" --check --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1 \
  && pass "B3 修复后 --check rc=0" || fail "B3 修复后仍报缺失"

# ══ B4 换代 / 回滚 ═══════════════════════════════════════════════════════
hdr "B4 store 换代 与 回滚锚点"
sh "$ACT" --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1
ln -sfn "$STORE2" "$STATE/etc-current"
sh "$ACT" --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1
readlink -f "$ROOTFS/etc/systemd/timesyncd.conf.d/ntp.conf" | grep -q "$STORE2" \
  && pass "B4 换代后解析到新 generation" || fail "B4 换代后仍指向旧 generation"
grep -q 'GEN2MARK' "$ROOTFS/etc/systemd/timesyncd.conf.d/ntp.conf" \
  && pass "B4 换代后内容已更新" || fail "B4 内容未更新"
ln -sfn "$STORE1" "$STATE/etc-current"
sh "$ACT" --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1
readlink -f "$ROOTFS/etc/systemd/timesyncd.conf.d/ntp.conf" | grep -q "$STORE1" \
  && pass "B4 回滚后解析回旧 generation" || fail "B4 回滚失败"
sh "$ACT" --check --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1 \
  && pass "B4 回滚后 --check rc=0" || fail "B4 回滚后 --check 失败"

# ══ B4x 链接 target 形态(早期启动能否读到的关键) ════════════════════════
hdr "B4x 链接 target 形态"
raw=$(readlink "$ROOTFS/etc/systemd/timesyncd.conf.d/ntp.conf")
res=$(readlink -f "$ROOTFS/etc/systemd/timesyncd.conf.d/ntp.conf")
echo "      raw     : $raw"
echo "      resolved: $res"
case "$raw" in
  "$SBX/nix/store/"*) pass "B4x 链接直指 /nix/store 真路径" ;;
  *) fail "B4x 链接绕经 $raw —— /home 挂载前 systemd/udev 读不到" ;;
esac

# ══ B5 免密链一致性 ══════════════════════════════════════════════════════
hdr "B5 免密链一致性"
want="/home/deck/.steamos-nix/bin/steamos-nix-activate"
grep -qF "$want" "$ROOTFS/etc/sudoers.d/steamos-nix" \
  && pass "B5 sudoers 放行稳定路径" || fail "B5 sudoers 路径不符"
grep -qF '%h/.steamos-nix/bin/steamos-nix-activate' "$REPO/config/systemd/user/steamos-nix-heal.service" \
  && pass "B5 自愈 unit 调用同一稳定路径" || fail "B5 自愈 unit 路径不符"
grep -qE '^deck ALL=\(ALL\) NOPASSWD: /home/deck/\.steamos-nix/bin/steamos-nix-activate$' \
     "$ROOTFS/etc/sudoers.d/steamos-nix" \
  && pass "B5 sudoers 为单命令宽参数形式" || fail "B5 sudoers 规则形式异常"

# ══ B6 链接持久性 ════════════════════════════════════════════════════════
hdr "B6 链接持久性"
bad=0
for l in $(find "$ROOTFS/etc" -type l); do
  t=$(readlink -f "$l")
  case "$t" in "$SBX/nix/store/"*) : ;; *) bad=$((bad+1)); echo "      越界: $l -> $t";; esac
done
[ "$bad" = 0 ] && pass "B6 全部链接落点在 store 内" || fail "B6 有 $bad 个链接越界"

# ══ B7 store 被 GC ══════════════════════════════════════════════════════
hdr "B7 边界: etc-current 指向的 store 被回收"
cp -a "$STATE/etc-current/." "$SBX/quick-bak" 2>/dev/null
rm -rf "$STORE1"
out=$(sh "$ACT" --state "$STATE" --prefix "$ROOTFS" 2>&1); rc=$?
echo "      rc=$rc 输出: $(echo "$out" | tr '\n' ' ')"
[ "$rc" != 0 ] && pass "B7 悬空后激活器报错退出" || fail "B7 悬空后仍返回成功"
echo "$out" | grep -qi "install.sh" && pass "B7 错误信息指向修复动作" || note "B7 错误信息未提示 install.sh"
[ "$(count_files)" = "$EXPECTED" ] && pass "B7 未破坏既有落点" || fail "B7 既有落点被破坏 ($(count_files))"
mkdir -p "$STORE1"; cp -a "$SBX/quick-bak/." "$STORE1/" 2>/dev/null

# ══ B8 悬空链接 ═════════════════════════════════════════════════════════
hdr "B8 边界: 已存在但悬空的符号链接"
ln -sfn "$SBX/nonexistent-target" "$ROOTFS/etc/systemd/timesyncd.conf.d/ntp.conf"
sh "$ACT" --check --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1 \
  && fail "B8 悬空链接未被 --check 发现" || pass "B8 --check 识别悬空链接"
sh "$ACT" --state "$STATE" --prefix "$ROOTFS" >/dev/null 2>&1
[ -e "$ROOTFS/etc/systemd/timesyncd.conf.d/ntp.conf" ] \
  && pass "B8 apply 自动修复悬空链接" || fail "B8 悬空链接未修复"

# ══ B9 无写权限 ═════════════════════════════════════════════════════════
hdr "B9 边界: 目标不可写"
RO2="$SBX/readonly"; mkdir -p "$RO2"
sh "$ACT" --state "$STATE" --prefix "$RO2" >/dev/null 2>&1
rm -f "$RO2/etc/sudoers.d/steamos-nix"
chmod -R a+rX "$RO2"; chmod a+rx "$SBX" "$STATE" "$STORE1"
out=$(su nobody -s /bin/sh -c "sh '$ACT' --state '$STATE' --prefix '$RO2'" 2>&1); rc=$?
echo "      nobody 身份 rc=$rc"
[ "$rc" != 0 ] && pass "B9 无写权限 → 非零退出(自愈单元可识别失败)" \
                || fail "B9 无写权限却返回成功"

# ══ B10 路径含空格 ══════════════════════════════════════════════════════
hdr "B10 边界: 路径含空格"
SPS="$SBX/has space"; mkdir -p "$SPS/state" "$SPS/rootfs"
ln -sfn "$STORE1" "$SPS/state/etc-current"
out=$(sh "$ACT" --state "$SPS/state" --prefix "$SPS/rootfs" 2>&1); rc=$?
n=$(find "$SPS/rootfs/etc" -type f -o -type l 2>/dev/null | wc -l)
echo "      rc=$rc 落点数=$n"
[ "$n" = "$EXPECTED" ] && pass "B10 含空格路径下正常重建" \
  || fail "B10 重建失败(落点=$n) 输出: $(echo "$out" | head -2)"
wrong=$(find "$SPS/rootfs" -maxdepth 2 -name '*space*' 2>/dev/null | wc -l)
[ "$wrong" = 0 ] && pass "B10 未产生畸形路径" || fail "B10 产生了 $wrong 个畸形路径"

# ══ B11 字体 installPhase(从 lib.nix 提取的真实代码) ═══════════════════
# 华为 zip 里 "HarmonyOS Sans" 目录名**带空格**, 且混着 __MACOSX / ._ 开头的
# AppleDouble 文件 / .DS_Store。这段验证: 只捞 ttf、路径带空格不出错、
# 上游结构变了会报错而不是静默装个空包。
hdr "B11 harmonyos-sans installPhase(带空格目录 + AppleDouble 干扰)"
FTEST="$REPO/.selftest/font-install-test.sh"
FSRC="$SBX/font src"                      # 故意带空格
FOUT="$SBX/fontout"
rm -rf "$FSRC" "$FOUT"
mkdir -p "$FSRC/HarmonyOS Sans/HarmonyOS_Sans_SC" \
         "$FSRC/HarmonyOS Sans/HarmonyOS_Sans_TC" \
         "$FSRC/__MACOSX/HarmonyOS Sans/HarmonyOS_Sans_SC" \
         "$FOUT"
for w in Thin Light Regular Medium Bold Black; do
  : > "$FSRC/HarmonyOS Sans/HarmonyOS_Sans_SC/HarmonyOS_Sans_SC_$w.ttf"
done
: > "$FSRC/HarmonyOS Sans/HarmonyOS_Sans_SC/.DS_Store"
: > "$FSRC/HarmonyOS Sans/HarmonyOS_Sans_SC/._HarmonyOS_Sans_SC_Regular.ttf"
: > "$FSRC/__MACOSX/HarmonyOS Sans/HarmonyOS_Sans_SC/._HarmonyOS_Sans_SC_Regular.ttf"
: > "$FSRC/HarmonyOS Sans/HarmonyOS_Sans_TC/HarmonyOS_Sans_TC_Regular.ttf"   # 诱饵: 不该被捞
src="$FSRC" out="$FOUT" sh "$FTEST"; rc=$?
[ "$rc" = 0 ] && pass "B11 带空格的源目录执行成功" || fail "B11 rc=$rc"
n=$(ls -A "$FOUT/share/fonts/truetype/harmonyos-sans-sc" 2>/dev/null | wc -l)
[ "$n" = 6 ] && pass "B11 恰好捞出 6 个字重" || fail "B11 捞出 $n 个(期望 6)"
junk=$(find "$FOUT" -name '.DS_Store' -o -name '._*' | wc -l)
[ "$junk" = 0 ] && pass "B11 未带入 .DS_Store / AppleDouble" || fail "B11 带入了 $junk 个干扰文件"
find "$FOUT" -name '*TC*' | grep -q . && fail "B11 诱饵 HarmonyOS_Sans_TC 被误捞" \
  || pass "B11 只捞 SC, 未误捞 TC 诱饵"
m=$(stat -c %a "$FOUT/share/fonts/truetype/harmonyos-sans-sc/HarmonyOS_Sans_SC_Regular.ttf" 2>/dev/null)
[ "$m" = "644" ] && pass "B11 落盘权限 0644" || fail "B11 权限=$m (期望 644)"
# 负例: 上游结构变了(没有 SC 目录)→ 必须报错退出, 不能装个空包
rm -rf "$FOUT" "$FSRC/HarmonyOS Sans/HarmonyOS_Sans_SC"
mkdir -p "$FOUT"
src="$FSRC" out="$FOUT" sh "$FTEST" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && pass "B11 上游结构变化 → 报错退出(不静默装空包)" \
                || fail "B11 上游结构变化却返回成功"

# ══ B12 fontconfig 片段(install.sh --emit-fontconfig) ═══════════════════
hdr "B12 fontconfig 渲染"
FCDIR="$SBX/fc"; mkdir -p "$FCDIR"
STOREFONT=/nix/store/aaaa-harmonyos-sans-sc/share/fonts
sh "$REPO/install.sh" --emit-fontconfig harmony-sans "$STOREFONT" \
  > "$FCDIR/10-steamos-nix-fonts.conf"
grep -q "<dir>$STOREFONT</dir>" "$FCDIR/10-steamos-nix-fonts.conf" \
  && pass "B12 <dir> 指向 store 真路径" || fail "B12 <dir> 内容不对: $(cat "$FCDIR/10-steamos-nix-fonts.conf")"
grep -q '<family>HarmonyOS Sans SC</family>' "$FCDIR/10-steamos-nix-fonts.conf" \
  && pass "B12 prefer 族名 = HarmonyOS Sans SC(与 ttf name 表一致)" \
  || fail "B12 族名不对"
[ "$(grep -c '<fontconfig>' "$FCDIR/10-steamos-nix-fonts.conf")" = 1 ] \
  && [ "$(grep -c '</fontconfig>' "$FCDIR/10-steamos-nix-fonts.conf")" = 1 ] \
  && pass "B12 根标签配对且唯一" || fail "B12 根标签不配对"
na=$(grep -c '<alias>' "$FCDIR/10-steamos-nix-fonts.conf")
nb=$(grep -c '</alias>' "$FCDIR/10-steamos-nix-fonts.conf")
[ "$na" = 2 ] && [ "$nb" = 2 ] && pass "B12 恰好 2 组 alias(sans-serif + serif)" \
  || fail "B12 alias 数: 开=$na 闭=$nb (期望 2/2)"
grep -q 'monospace' "$FCDIR/10-steamos-nix-fonts.conf" \
  && fail "B12 不该污染 monospace(等宽语义)" || pass "B12 未污染 monospace"
sh "$REPO/install.sh" --emit-fontconfig noto /x > "$FCDIR/noto.conf"
grep -q 'Noto Sans CJK SC' "$FCDIR/noto.conf" && pass "B12 cjkFont=noto → Noto 兜底族名" \
  || fail "B12 noto 兜底族名不对: $(cat "$FCDIR/noto.conf")"
sh "$REPO/install.sh" --emit-fontconfig none /x > "$FCDIR/none.conf"
[ "$(grep -c '<alias>' "$FCDIR/none.conf")" = 0 ] && pass "B12 cjkFont=none → 不写 alias" \
  || fail "B12 cjkFont=none 仍写了 alias"

# ══ B13 WorkBuddy 转发器: 系统原生优先, 且不在沙盒里 ════════════════════
# WorkBuddy 必须跑在系统环境里 —— 自更新 / dsh·MCP 插件 / native .node / fcitx5 输入法 /
# xdg-portal 都依赖可写的系统路径。这个用例钉死"优先 exec 系统 wrapper"这个不变量,
# 防止哪天有人图省事改回"nix electron 直启 app.asar"。
hdr "B13 workbuddy 转发器(系统原生优先 / 禁用 chromium sandbox)"
WBTEST="$REPO/.selftest/workbuddy-test.sh"
WB="$SBX/wb"; rm -rf "$WB"
mkdir -p "$WB/sys/bin" "$WB/sys/lib" "$WB/app/resources" "$WB/nix"
: > "$WB/app/resources/app.asar"
WBTRACE="$WB/trace"

mk_fake() {   # mk_fake <path> <tag>
  cat > "$1" <<EOF
#!/bin/sh
echo "$2 \$*" >> "$WBTRACE"
echo "EDSB=\$ELECTRON_DISABLE_SANDBOX" >> "$WBTRACE"
echo "LLP=\$LD_LIBRARY_PATH" >> "$WBTRACE"
EOF
  chmod +x "$1"
}
mk_fake "$WB/sys/bin/workbuddy"  SYSTEM_NATIVE
mk_fake "$WB/sys/bin/electron"   SYS_ELECTRON
mk_fake "$WB/nix/electron"       NIX_ELECTRON

export WB_APPDIR="$WB/app" WB_NIX_ELECTRON="$WB/nix/electron" \
       WB_FLAGS="--test-flag" WB_RUNTIMEPATH="/nonexistent-nix-runtime"
export STEAMOS_NIX_SYSROOT="$WB/sys"

# 场景 1: 系统有原生 wrapper → 必须 exec 它, 一个 electron 都不许碰
: > "$WBTRACE"
sh "$WBTEST" --foo >/dev/null 2>&1
grep -q '^SYSTEM_NATIVE' "$WBTRACE" && pass "B13 有系统原生 wrapper → exec 它(不进 nix)" \
  || fail "B13 未调用系统 wrapper: $(cat "$WBTRACE")"
grep -q 'ELECTRON' "$WBTRACE" && fail "B13 系统 wrapper 可用却仍启动了 electron" \
  || pass "B13 系统 wrapper 可用时不启动任何 electron"
grep -q -- '--foo' "$WBTRACE" && pass "B13 参数透传给系统 wrapper" || fail "B13 参数未透传"

# 场景 2: 强制 nix 模式 → 跳过系统 wrapper, 用系统 electron, 且必须关 sandbox
: > "$WBTRACE"
STEAMOS_NIX_WORKBUDDY=nix sh "$WBTEST" >/dev/null 2>&1
grep -q '^SYSTEM_NATIVE' "$WBTRACE" && fail "B13 mode=nix 却仍走了系统 wrapper" \
  || pass "B13 STEAMOS_NIX_WORKBUDDY=nix 会跳过系统 wrapper"
grep -q '^SYS_ELECTRON' "$WBTRACE" && pass "B13 优先用**系统** electron(非 nix 的)" \
  || fail "B13 未使用系统 electron: $(cat "$WBTRACE")"
grep -q -- '--no-sandbox' "$WBTRACE" && grep -q -- '--disable-setuid-sandbox' "$WBTRACE" \
  && pass "B13 传了 --no-sandbox --disable-setuid-sandbox" || fail "B13 未禁用 chromium sandbox"
grep -q 'EDSB=1' "$WBTRACE" && pass "B13 ELECTRON_DISABLE_SANDBOX=1 已导出" \
  || fail "B13 ELECTRON_DISABLE_SANDBOX 未设置"
grep -q 'LLP=.*wb/sys/lib' "$WBTRACE" && pass "B13 追加了系统库路径(给 native .node 用)" \
  || fail "B13 未追加系统库路径: $(grep LLP "$WBTRACE")"
grep -q -- '--test-flag' "$WBTRACE" && pass "B13 IME/Wayland flags 仍在" || fail "B13 flags 丢失"

# 场景 3: 系统 electron 也没有 → 才轮到 nix electron 兜底
rm -f "$WB/sys/bin/electron"
: > "$WBTRACE"
STEAMOS_NIX_WORKBUDDY=nix sh "$WBTEST" >/dev/null 2>&1
grep -q '^NIX_ELECTRON' "$WBTRACE" && pass "B13 系统 electron 缺失 → nix electron 兜底" \
  || fail "B13 兜底未生效: $(cat "$WBTRACE")"
grep -q 'EDSB=1' "$WBTRACE" && pass "B13 兜底路径同样禁用 sandbox" || fail "B13 兜底路径未禁用 sandbox"

# 场景 4: 连 app payload 都没有 → 报错退出并提示 AUR, 不能静默启动空 electron
rm -rf "$WB/app"
: > "$WBTRACE"
STEAMOS_NIX_WORKBUDDY=nix sh "$WBTEST" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && pass "B13 无 payload → 报错退出(rc=$rc)" || fail "B13 无 payload 却返回成功"
STEAMOS_NIX_WORKBUDDY=nix sh "$WBTEST" 2>&1 >/dev/null | grep -qi 'workbuddy' \
  && pass "B13 错误信息指向安装 WorkBuddy" || note "B13 错误信息未提示安装方式"

# ══ B14 输入法: IBus + 小鹤双拼(端到端跑真实脚本) ═══════════════════════
# setup-ibus-xiaohe.sh 刻意写成 POSIX sh, 所以能在只有 busybox 的沙盒里
# 真跑一遍 —— 不是照抄片段, 是同一个文件。缺失的 ibus/pacman/systemctl 都会
# 走降级分支, 这本身也是健壮性的一部分。
hdr "B14 IBus + 小鹤双拼(setup-ibus-xiaohe.sh 端到端)"
IMESH="$REPO/scripts/setup-ibus-xiaohe.sh"
IH="$SBX/imehome"; rm -rf "$IH"; mkdir -p "$IH"
# 造一个 IBus 的 Wayland desktop 文件, 让 kwinrc 探测分支真的走到
mkdir -p /usr/share/applications
: > /usr/share/applications/org.freedesktop.IBus.Panel.Wayland.Gtk3.desktop
# 造一份已有内容的 kwinrc, 验证 awk 是"替换"而不是"追加一段重复的"
mkdir -p "$IH/.config"
printf '[Wayland]\nFoo=bar\nInputMethod=/old/broken/path\n\n[Other]\nX=1\n' > "$IH/.config/kwinrc"

# 门禁: dconf / systemd --user 都是用户级的, root 直跑必须被拒绝
HOME="$IH" sh "$IMESH" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && pass "B14 root 直跑被拒绝(dconf/systemd --user 是用户级的)" \
                || fail "B14 root 门禁失效"
# 沙盒里只有 root(容器默认), 用 SUDO_USER 模拟"sudo 调用"来跑配置逻辑本身
HOME="$IH" SUDO_USER=sbxtest sh "$IMESH" >/dev/null 2>&1
ok=1
[ -f "$IH/.config/ibus/rime/default.custom.yaml" ] || ok=0
grep -q 'double_pinyin_flypy' "$IH/.config/ibus/rime/default.custom.yaml" 2>/dev/null \
  && pass "B14 Rime 配置写入且小鹤双拼(double_pinyin_flypy)为默认方案" \
  || { fail "B14 Rime 配置不对"; ok=0; }
grep -q 'schema: double_pinyin_flypy' "$IH/.config/ibus/rime/default.custom.yaml" \
  && [ "$(grep -c 'schema:' "$IH/.config/ibus/rime/default.custom.yaml")" -ge 2 ] \
  && pass "B14 schema_list 里还有全拼等备用方案" || note "B14 备用方案不足"
[ -f "$IH/.config/ibus/rime/default.yaml" ] && { fail "B14 default.yaml 应被删掉才会重算部署"; ok=0; } \
  || pass "B14 已删除 default.yaml(触发重新部署)"

# 环境变量: 会话自适应是这个需求的命门 —— Wayland 下强设 GTK/QT 会让候选框不跟随
ENVSH="$IH/.config/plasma-workspace/env/90-steamos-nix-ime.sh"
[ -f "$ENVSH" ] && pass "B14 环境变量片段已就位" || { fail "B14 缺 $ENVSH"; ok=0; }
_wl=$(XDG_SESSION_TYPE=wayland sh -c ". '$ENVSH'; printf '%s|%s|%s' \"\${XMODIFIERS-n}\" \"\${GTK_IM_MODULE-n}\" \"\${QT_IM_MODULE-n}\"")
echo "      wayland: $_wl"
[ "$_wl" = "@im=ibus|n|n" ] && pass "B14 Wayland: 只设 XMODIFIERS, GTK/QT_IM_MODULE 未设" \
  || fail "B14 Wayland 分支不对: $_wl"
_x11=$(XDG_SESSION_TYPE=x11 sh -c ". '$ENVSH'; printf '%s|%s|%s' \"\${XMODIFIERS-n}\" \"\${GTK_IM_MODULE-n}\" \"\${QT_IM_MODULE-n}\"")
echo "      x11    : $_x11"
[ "$_x11" = "@im=ibus|ibus|ibus" ] && pass "B14 X11/XWayland: 全套 GTK/QT/XMODIFIERS" \
  || fail "B14 X11 分支不对: $_x11"
# Wayland 下即使外部预设了 GTK_IM_MODULE, 也必须清掉 —— 留着就会走 XWayland 的 IM 模块
_wlu=$(GTK_IM_MODULE=preset XDG_SESSION_TYPE=wayland sh -c ". '$ENVSH'; printf '%s|%s' \"\${XMODIFIERS-n}\" \"\${GTK_IM_MODULE-n}\"")
echo "      wayland(预设GTK): $_wlu"
[ "$_wlu" = "@im=ibus|n" ] && pass "B14 Wayland: 会清掉预设的 GTK_IM_MODULE(否则走 XWayland IM)" \
  || fail "B14 Wayland 未清掉预设值: $_wlu"

# kwinrc: 必须是替换旧值 + 保留其它段, 不能追加出重复的 [Wayland]
_kim=$(grep '^InputMethod=' "$IH/.config/kwinrc" | head -1)
echo "      kwinrc : $_kim"
case "$_kim" in
  *IBus*Wayland*) pass "B14 kwinrc InputMethod 指向探测到的 IBus Wayland desktop" ;;
  *) fail "B14 kwinrc InputMethod 不对: $_kim" ;;
esac
[ "$(grep -c '^\[Wayland\]' "$IH/.config/kwinrc")" = 1 ] \
  && pass "B14 没有追加出重复的 [Wayland] 段" || fail "B14 [Wayland] 段重复了"
grep -q '^X=1' "$IH/.config/kwinrc" && grep -q '^Foo=bar' "$IH/.config/kwinrc" \
  && pass "B14 kwinrc 其它段/键未被破坏" || fail "B14 kwinrc 原有内容被破坏"

# systemd unit: 桌面 + gamescope 共用同一个 ibus-daemon
UNIT="$IH/.config/systemd/user/ibus-daemon.service"
[ -f "$UNIT" ] && pass "B14 ibus-daemon user unit 已写入" || { fail "B14 缺 unit"; ok=0; }
grep -q 'gamescope-session.target' "$UNIT" && grep -q 'graphical-session.target' "$UNIT" \
  && pass "B14 unit 同时挂桌面会话与 gamescope 会话" || fail "B14 unit 缺 target"
grep -q 'EnvironmentFile=-%t/gamescope-environment' "$UNIT" \
  && pass "B14 unit 会读 gamescope 的 DISPLAY(且缺失不报错)" || fail "B14 unit 未读 gamescope-environment"
grep -q 'StartLimitBurst' "$UNIT" && pass "B14 unit 有 StartLimitBurst(不无限重试)" \
  || fail "B14 unit 可能无限重试"
grep -q 'ibus-daemon' "$UNIT" && pass "B14 unit 启的是 ibus-daemon(不是 fcitx5 桥接)" \
  || fail "B14 unit 内容异常"

# 幂等: 再跑一遍内容不变
_m1=$(find "$IH/.config" -type f -exec md5sum {} + 2>/dev/null | sort | md5sum)
HOME="$IH" SUDO_USER=sbxtest sh "$IMESH" >/dev/null 2>&1
_m2=$(find "$IH/.config" -type f -exec md5sum {} + 2>/dev/null | sort | md5sum)
[ "$_m1" = "$_m2" ] && pass "B14 重复执行幂等(配置内容零变化)" || fail "B14 重复执行产生变化"

# --check 必须是只读的
CH="$SBX/imehome-check"; rm -rf "$CH"; mkdir -p "$CH"
HOME="$CH" sh "$IMESH" --check >/dev/null 2>&1
[ -d "$CH/.config" ] && fail "B14 --check 竟然写了文件" || pass "B14 --check 是只读的(不写任何文件)"
rm -f /usr/share/applications/org.freedesktop.IBus.Panel.Wayland.Gtk3.desktop

echo
echo "════════ 沙盒动态($MACHINE): $NP 通过 / $NF 失败 ════════"
[ "$NF" = 0 ]
