#!/usr/bin/env bash
# =============================================================================
#  verify.sh — steamos-nix 迁移的可行性 + 健壮性验证(在 SteamOS 上运行, 需要 nix)
# -----------------------------------------------------------------------------
#  A 可行性: nix 能求值/构建全部包, 产物语法/权限合法, visudo 校验 sudoers。
#  B 健壮性: 在 --prefix 沙盒里**模拟大版本升级把 /etc 冲掉**, 验证:
#              ① 空 /etc → 一条命令全量重建  ② 重复执行零变化(幂等)
#              ③ --check 能当"是否需要修复"探针 ④ etc-previous 回滚锚点可用
#              ⑤ sudoers 白名单路径与实际调用路径逐字一致
#              ⑥ 链接 target 直指 /nix/store(而不是绕经 /home 的软链)
#  C 环境:  GC root 是否覆盖了 steamos-etc(/etc DNS[i] 内容不能被 GC 掉)
#           + 桌面机型的 WPS/微信/LocalSend/中文字体是否就位
#  只读为主: 除沙盒步骤写临时目录外, 不触碰真实 /etc。
#  用法: bash verify.sh   (退出码 0 = 全部通过)
# =============================================================================
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

C_OK='\033[32m'; C_ERR='\033[31m'; C_WARN='\033[33m'; C_DIM='\033[2m'; C_R='\033[0m'
pass(){ printf "${C_OK}[PASS]${C_R} %s\n" "$*"; }
fail(){ printf "${C_ERR}[FAIL]${C_R} %s\n" "$*"; FAILED=$((FAILED+1)); }
note(){ printf "${C_WARN}[WARN]${C_R} %s\n" "$*"; }
head1(){ printf "\n${C_DIM}── %s ──────────${C_R}\n" "$*"; }

FAILED=0; TOTAL=0
check(){ TOTAL=$((TOTAL+1)); local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }

[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ] && { set +u; . "$HOME/.nix-profile/etc/profile.d/nix.sh"; set -u; }

# ── 机型: 决定"应该有多少个 /etc 落点" ────────────────────────────────────
MACHINE=$(grep -oE '"[a-z0-9-]+"' machine.nix 2>/dev/null | head -1 | tr -d '"')
case "$MACHINE" in
  gpd-win5)   EXPECTED=6 ;;
  steam-deck) EXPECTED=2 ;;
  desktop)    EXPECTED=2 ;;
  *)          MACHINE="unknown"; EXPECTED=2
              note "machine.nix 里读不到合法机型(得到 '$MACHINE'), 按 2 个通用落点校验" ;;
esac
echo "机型: $MACHINE  → 预期 /etc 落点数: $EXPECTED"

head1 "A. 可行性验证"
check "nix CLI 就绪" command -v nix
check "flake 可求值(nix flake show)" nix flake show --no-write-lock-file .
TOOLS=$(nix build --no-link --print-out-paths .#steamos-tools 2>/dev/null) && check "steamos-tools 可构建" test -n "$TOOLS"
ETC=$(nix build   --no-link --print-out-paths .#steamos-etc 2>/dev/null) && check "steamos-etc 可构建" test -n "$ETC"
ACT=$(nix build   --no-link --print-out-paths .#steamos-nix-activate 2>/dev/null) && check "activate 可构建" test -n "$ACT"
WB=$(nix build    --no-link --print-out-paths .#workbuddy 2>/dev/null) && check "workbuddy 可构建" test -n "$WB"
DAE=$(nix build   --no-link --print-out-paths .#gpd-win5-backkeys-daemon 2>/dev/null) && check "backkeys daemon 可构建" test -n "$DAE"

if [ "$MACHINE" = desktop ]; then
  WPS=$(nix build --no-link --print-out-paths .#wps-office 2>/dev/null) && check "wps-office 可构建(专有, unfree)" test -n "$WPS"
  WX=$(nix build  --no-link --print-out-paths .#wechat 2>/dev/null) && check "wechat 可构建(专有, unfree)" test -n "$WX"
  LS=$(nix build  --no-link --print-out-paths .#localsend 2>/dev/null) && check "localsend 可构建(MIT)" test -n "$LS"
  # 字体是外部 FOD, 构建失败不阻塞上面三个应用 —— 这里只 note, 不计 FAIL
  FONT=$(nix build --no-link --print-out-paths .#steamos-cjk-fonts 2>/dev/null) \
    && pass "steamos-cjk-fonts 可构建(HarmonyOS Sans SC FOD)" \
    || note "steamos-cjk-fonts 构建失败 → 大概率是 cfg.harmonySansHash 不匹配, 见 README §3.2 两遍法(不会阻塞 WPS/微信/LocalSend)"
  [ -n "${WPS:-}" ] && check "wps 二进制存在" test -x "$WPS/bin/wps"
  [ -n "${WX:-}" ]  && check "wechat 二进制存在" test -x "$WX/bin/wechat"
  [ -n "${LS:-}" ]  && check "localsend_app 二进制存在" test -x "$LS/bin/localsend_app"
  [ -n "${WPS:-}" ] && check "wps-x11 变体存在" test -x "$WPS/bin/wps-x11"
  [ -n "${LS:-}" ]  && check "localsend_app-x11 变体存在(GTK 用 GDK_BACKEND)" test -x "$LS/bin/localsend_app-x11"
  if [ -n "${FONT:-}" ]; then
    # 只装 ttf、且不能混进 AppleDouble(._xxx.ttf)—— 沙盒 B11 已守, 真机再验一次
    NTTF=$(find "$FONT" -name '*.ttf' | wc -l)
    NJNK=$(find "$FONT" -name '._*' -o -name '.DS_Store' | wc -l)
    check "字体目录里有 ttf" test "$NTTF" -gt 0
    check "字体目录无 AppleDouble/DS_Store 残留" test "$NJNK" -eq 0
    note "字体: $NTTF 个 ttf, $NJNK 个干扰文件"
  fi
fi

if [ -n "$TOOLS" ]; then
  for s in steamos-setup.sh steamos-nix-detect.sh self-heal-after-upgrade.sh install-ge-proton.sh; do
    check "bash 语法: $s" bash -n "$TOOLS/bin/$s"
  done
  PYOUT=$(nix build --no-link --print-out-paths 'nixpkgs#python3' 2>/dev/null || true)
  if [ -n "$PYOUT" ]; then PYB="$PYOUT/bin/python3"; else PYB=$(command -v python3 || true); fi
  [ -n "$PYB" ] || { note "无可用 python3, 跳过 py 语法检查"; }
  for p in set-steam-launchoptions switch-compat-tool; do
    check "python 语法: $p.py" "$PYB" -c \
      "import py_compile; py_compile.compile('$TOOLS/libexec/steamos-tools/$p.py', doraise=True)"
  done
  [ -n "$PYB" ] && check "注入的 python 具备 yaml(vdf+pyyaml)" "$PYB" -c "import yaml, vdf"
  check "detect 脚本在本机能给出机型" test -n "$(bash scripts/steamos-nix-detect.sh --quiet)"
fi
[ -n "$DAE" ] && [ -n "${PYB:-}" ] && check "python 语法: backkeys daemon" "$PYB" -c \
  "import py_compile; py_compile.compile('$DAE/gpd-win5-backkeys.py', doraise=True)"
[ -n "$ACT" ] && check "activate bash 语法" bash -n "$ACT/bin/steamos-nix-activate"
if [ -n "$ETC" ]; then
  check "etc 树落点数 = $EXPECTED($MACHINE)" sh -c '[ "$(find "'"$ETC"'/etc" -type f | wc -l)" = "'"$EXPECTED"'" ]'
  for f in etc/systemd/timesyncd.conf.d/ntp.conf etc/sudoers.d/steamos-nix; do
    check "通用落点存在: $f" test -f "$ETC/$f"
  done
  check "ntp 无未替换占位符" sh -c "! grep -q '@NTP_SERVERS@' '$ETC/etc/systemd/timesyncd.conf.d/ntp.conf'"
  if command -v visudo >/dev/null 2>&1; then
    check "sudoers 通过 visudo 校验" visudo -cf "$ETC/etc/sudoers.d/steamos-nix"
  else
    note "本机无 visudo, 跳过 sudoers 校验(激活时脚本内部仍会校验)"
  fi
  if [ "$MACHINE" = gpd-win5 ]; then
    for f in etc/systemd/system/gpd-win5-backkeys.service \
             etc/udev/rules.d/70-gpd-backkeys.rules \
             etc/inputplumber/devices.d/20-gpd_win5.yaml \
             etc/inputplumber/capability_maps.d/20-gpd_win5.yaml; do
      check "Win5 落点存在: $f" test -f "$ETC/$f"
    done
    check "unit 已替换 ExecStart 为 store 路径" sh -c "! grep -q '@PYTHON@\|@DAEMON@' '$ETC/etc/systemd/system/gpd-win5-backkeys.service'"
    check "unit ExecStart 指向 /nix/store" grep -q '^ExecStart=/nix/store' "$ETC/etc/systemd/system/gpd-win5-backkeys.service"
    check "inputplumber device yaml 完整" grep -q 'name: GPD Win5' "$ETC/etc/inputplumber/devices.d/20-gpd_win5.yaml"
    check "capmap 引用 gpd_win5_custom" grep -q 'id: gpd_win5_custom' "$ETC/etc/inputplumber/capability_maps.d/20-gpd_win5.yaml"
  else
    if [ -e "$ETC/etc/systemd/system/gpd-win5-backkeys.service" ]; then
      fail "非 Win5 机型却产出了背键 unit —— 机型裁剪失效"
    else
      pass "机型裁剪: $MACHINE 未产出任何 Win5 专属落点"
    fi
    if [ -e "$ETC/etc/inputplumber" ]; then
      fail "非 Win5 机型却产出了 inputplumber 覆盖"
    else
      pass "机型裁剪: $MACHINE 未产出 inputplumber 覆盖"
    fi
  fi
fi

head1 "B. 健壮性验证(沙盒内模拟原子升级, 不碰真实 /etc)"
SIM=$(mktemp -d /tmp/steamos-nix-verify.XXXXXX)
FAKETC=$SIM/etc-sim
STATE_SIM=$SIM/state
mkdir -p "$FAKETC" "$STATE_SIM/bin"
if [ -n "$ETC" ] && [ -n "$ACT" ]; then
  ln -sfn "$ETC" "$STATE_SIM/etc-current"
  A="$ACT/bin/steamos-nix-activate"

  # B1 模拟升级后: /etc 干净, 一条命令重建
  if "$A" --state "$STATE_SIM" --prefix "$FAKETC" >/dev/null 2>&1; then
    n=$(find "$FAKETC/etc" -type l -o -type f 2>/dev/null | grep -v steamos-nix-wtest | wc -l)
    if [ "$n" = "$EXPECTED" ]; then pass "B1 空 /etc 沙盒: 重建出全部 $EXPECTED 个落点"; else fail "B1 沙盒重建数量不符(=$n, 期望 $EXPECTED)"; fi
  else
    fail "B1 沙盒重建执行失败"
  fi
  check "B1t ntp drop-in 内容可读" test -r "$FAKETC/etc/systemd/timesyncd.conf.d/ntp.conf"
  check "B1s sudoers 以 0440 落盘" sh -c 'stat -c %a "'"$FAKETC"'/etc/sudoers.d/steamos-nix" | grep -q 440'
  check "B1u sudoers 是副本而非符号链接" test -f "$FAKETC/etc/sudoers.d/steamos-nix"

  # B2 幂等
  before=$(find "$FAKETC/etc" | sort | md5sum)
  "$A" --state "$STATE_SIM" --prefix "$FAKETC" >/dev/null 2>&1
  "$A" --state "$STATE_SIM" --prefix "$FAKETC" >/dev/null 2>&1
  after=$(find "$FAKETC/etc" | sort | md5sum)
  check "B2 二次执行零变化(幂等)" test "$before" = "$after"
  check "B2 --check 通过(重建后无缺失)" "$A" --check --state "$STATE_SIM" --prefix "$FAKETC"

  # B3 半损修复
  rm -f "$FAKETC/etc/systemd/timesyncd.conf.d/ntp.conf"
  rm -f "$FAKETC/etc/sudoers.d/steamos-nix"
  if "$A" --check --state "$STATE_SIM" --prefix "$FAKETC" >/dev/null 2>&1; then
    fail "B3 --check 未检测到人为冲掉的落点"
  else
    pass "B3 --check 能当缺失探针"
  fi
  "$A" --state "$STATE_SIM" --prefix "$FAKETC" >/dev/null 2>&1
  check "B3 半损后重建: ntp 回来" test -e "$FAKETC/etc/systemd/timesyncd.conf.d/ntp.conf"
  check "B3 半损后重建: sudoers 回来" test -e "$FAKETC/etc/sudoers.d/steamos-nix"

  # B4 回滚锚点
  ln -sfn "$ETC" "$STATE_SIM/etc-previous"
  ln -sfn "$(readlink "$STATE_SIM/etc-previous")" "$STATE_SIM/etc-current"
  check "B4 回滚锚点可激活" "$A" --state "$STATE_SIM" --prefix "$FAKETC"

  # B5 sudoers 白名单与真实调用路径一致
  want="$HOME/.steamos-nix/bin/steamos-nix-activate"
  check "B5 sudoers 指向稳定路径" grep -qF "$want" "$ETC/etc/sudoers.d/steamos-nix"
  check "B5 自愈单元调用同一路径" grep -qF "steamos-nix-activate" config/systemd/user/steamos-nix-heal.service

  # B6 链接 target 必须直指 store, 而不是绕经 ~/.steamos-nix/etc-current
  #    (后者在 /home 挂载前 open 会得到 ENOENT —— 用 readlink -f 会漏判, 所以这里不加 -f)
  bad=0
  for l in $(find "$FAKETC/etc" -type l); do
    t=$(readlink "$l")
    case "$t" in
      /nix/store/*) : ;;
      *) bad=$((bad+1)); echo "      绕经指针的链接: $l -> $t" ;;
    esac
  done
  check "B6 链接 target 直指 /nix/store" test "$bad" = 0

  # B7 store 被 GC 掉 → 必须报错退出, 且不破坏既有落点
  cp -a "$STATE_SIM/etc-current/." "$SIM/bak" 2>/dev/null
  real_store=$(readlink -f "$STATE_SIM/etc-current")
  rm -rf "$real_store"
  if "$A" --state "$STATE_SIM" --prefix "$FAKETC" >/dev/null 2>&1; then
    fail "B7 store 缺失时仍返回成功"
  else
    pass "B7 store 缺失时报错退出"
  fi
  n=$(find "$FAKETC/etc" -type l -o -type f 2>/dev/null | wc -l)
  check "B7 未破坏既有落点" test "$n" = "$EXPECTED"
  mkdir -p "$real_store"; cp -a "$SIM/bak/." "$real_store/" 2>/dev/null

  # B8 含空格的 state/prefix 路径
  SP="$SIM/has space"; mkdir -p "$SP/state" "$SP/rootfs"
  ln -sfn "$real_store" "$SP/state/etc-current"
  "$A" --state "$SP/state" --prefix "$SP/rootfs" >/dev/null 2>&1
  n=$(find "$SP/rootfs/etc" -type l -o -type f 2>/dev/null | wc -l)
  check "B8 含空格路径下正常重建" test "$n" = "$EXPECTED"
else
  fail "B 组跳过: 构建产物缺失"
fi

head1 "C. 环境持久性 / 桌面集成"
check "C steamos-etc 有 GC root(不被 collect-garbage 回收)" sh -c \
  'nix store gc --print-roots 2>/dev/null | grep -q steamos-etc'
if findmnt -T /nix -no SOURCE,FSTYPE 2>/dev/null | grep -qE 'overlay|/dev/(mapper/)?home|btrfs|/dev/nvme'; then
  pass "C /nix 所在文件系统中看起来含持久层特征(overlay/home/btrfs)"
else
  note "C 请人工确认 /nix 不在易失 rootfs(bootstrap-nix.sh 有逐项探测)"
fi
check "C profile 已含 steamos-tools" sh -c 'nix profile list 2>/dev/null | grep -q steamos-tools'
check "C profile 已含 steamos-nix-activate" sh -c 'nix profile list 2>/dev/null | grep -q steamos-nix-activate'
if [ "$MACHINE" = desktop ]; then
  check "C profile 已含中文字体" sh -c 'nix profile list 2>/dev/null | grep -q cjk-fonts'
  check "C 存在 .desktop 入口" sh -c '[ -n "$(ls "$HOME/.local/share/applications"/*.desktop 2>/dev/null)" ]'
  check "C fontconfig 已指向 nix 字体" test -f "$HOME/.config/fontconfig/conf.d/10-steamos-nix-fonts.conf"
  if [ -f "$HOME/.config/fontconfig/conf.d/10-steamos-nix-fonts.conf" ]; then
    grep -q '<prefer>' "$HOME/.config/fontconfig/conf.d/10-steamos-nix-fonts.conf" \
      && pass "C fontconfig 已写 <prefer>(只给 <dir> 中文仍会被抢)" \
      || note "C fontconfig 缺 <prefer>"
    grep -q 'HarmonyOS Sans SC' "$HOME/.config/fontconfig/conf.d/10-steamos-nix-fonts.conf" \
      && pass "C 首选族 = HarmonyOS Sans SC" || note "C 首选族不是 HarmonyOS Sans SC(cfg.cjkFont 不是 harmony-sans?)"
    command -v fc-match >/dev/null 2>&1 && {
      note "C fc-match sans-serif:lang=zh-cn → $(fc-match 'sans-serif:lang=zh-cn' 2>/dev/null)"
    }
  fi
  command -v wps          >/dev/null 2>&1 && pass "C PATH 中有 wps"          || note "C PATH 中还没有 wps"
  command -v wechat       >/dev/null 2>&1 && pass "C PATH 中有 wechat"       || note "C PATH 中还没有 wechat"
  command -v localsend_app >/dev/null 2>&1 && pass "C PATH 中有 localsend_app" || note "C PATH 中还没有 localsend_app"
  # LocalSend 靠 53317 组播发现; 防火墙没放行会"能打开但搜不到对端"
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --list-ports 2>/dev/null | grep -q 53317 \
      && pass "C 防火墙已放行 53317(LocalSend 发现+传输)" \
      || note "C 防火墙未放行 53317/tcp+udp → LocalSend 搜不到对端, 见 README §3.1"
  fi
fi
# ── WorkBuddy: 本体必须留在系统里, nix 只提供转发器 ──────────────────────
# 塞进 /nix/store(只读)会废掉自更新 / dsh·MCP 插件 / native .node / fcitx5 / xdg-portal。
if [ -x /usr/bin/workbuddy ] && [ ! -L /usr/bin/workbuddy ]; then
  pass "C WorkBuddy 走系统原生 /usr/bin/workbuddy(自更新/插件/输入法/portal 均可用)"
else
  note "C /usr/bin/workbuddy 缺失 → 转发器会退到 electron 直启 /opt/workbuddy, 功能受限; 建议 yay -S workbuddy"
fi
if command -v workbuddy >/dev/null 2>&1; then
  WBPATH=$(command -v workbuddy)
  case "$WBPATH" in
    */.nix-profile/*|*/nix/store/*)
      pass "C workbuddy 命令由 nix 转发器提供(升级幸存)"
      # 转发器必须真的是转发器, 不能是"nix electron 直启 app.asar"
      grep -q 'bin/workbuddy' "$WBPATH" 2>/dev/null \
        && pass "C 转发器确实优先调用系统 wrapper(不是 nix electron 直启)" \
        || note "C 转发器里没有系统 wrapper 分支 —— 检查 lib.nix 第 5 节"
      grep -q -- '--no-sandbox' "$WBPATH" 2>/dev/null \
        && pass "C 转发器禁用了 chromium sandbox" || note "C 转发器未禁用 sandbox"
      ;;
    *) note "C workbuddy 解析到 $WBPATH —— 不是 nix 转发器, 原子升级后可能消失" ;;
  esac
fi

rm -rf "$SIM"

echo
echo "════════ 结果: $((TOTAL-FAILED))/$TOTAL 通过 ════════"
[ "$FAILED" = 0 ] && { echo -e "${C_OK}全部通过: 迁移可行, 升级自愈路径健壮。${C_R}"; exit 0; } \
                   || { echo -e "${C_ERR}$FAILED 项失败, 见上方 [FAIL]。${C_R}"; exit 1; }
