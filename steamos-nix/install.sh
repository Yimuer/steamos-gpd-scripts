#!/usr/bin/env bash
# =============================================================================
#  install.sh — 把 steamos-nix flake 的产物安装/更新到持久 nix 环境。
#  全新安装、日常更新、大版本升级后修复, 都是这一条命令(幂等)。
# -----------------------------------------------------------------------------
#  做五件事:
#    0) 门禁: 拒绝 root 运行(否则 STATE 会漂到 /root, 与 sudoers 的 deck 路径不符)
#    1) 探测机型 → machine.nix(决定 nix 构建哪些部件: Win5 三件套还是桌面套件)
#    2) nix build 所有包(内容进 /nix/store → 持久)
#    3) nix profile 安装 steamos-tools / workbuddy(仅转发器) / steamos-nix-activate
#       (+ 桌面机型的 WPS / 微信 / LocalSend / 中文字体)
#    4) 更新 ~/.steamos-nix/ 里的稳定指针(etc-current, bin/steamos-nix-activate)
#       —— 自愈单元与 sudoers 都引用这些稳定路径; 并为 steamos-etc 建立 GC root
#    5) 桌面入口 + 字体落地 + sudo steamos-nix-activate
#
#  用法:
#    bash install.sh                   # 按探测到的机型安装
#    bash install.sh --machine desktop # 直接指定机型(gpd-win5|steam-deck|desktop)
#    bash install.sh --with-dsh        # 追加安装 dsh(需先按 README 填好 npm hash)
#    bash install.sh --without-apps    # 不装 WPS/微信/LocalSend/字体
#    bash install.sh --no-activate     # 只构建安装, 不碰 /etc
# =============================================================================
# fontconfig 片段渲染器。抽成函数是为了两件事:
#   ① 主流程与"只打印不落盘"的内部模式共用同一份逻辑, 不会写歪
#   ② .selftest 可以在没有 nix 的 Linux 沙盒里直接验证产出(见 VERIFY-REPORT §B12)
# 用法: emit_fontconfig <fonts-dir> <cjk-family|空串>
#
# NOTE: 这段**故意放在 set -euo pipefail 之前** —— 沙盒里只有 busybox ash,
# 它不支持 `set -o pipefail`, 放后面会让 --emit-fontconfig 在任何非 bash 下直接退出。
emit_fontconfig() {
  _fdir="$1"; _fam="$2"
  echo '<?xml version="1.0"?>'
  echo '<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">'
  echo '<fontconfig>'
  echo "  <dir>$_fdir</dir>"
  if [ -n "$_fam" ]; then
    # 只给 sans-serif / serif 写 prefer; monospace 是等宽语义,
    # 拿比例字体的鸿蒙去顶替会让终端/代码字体错乱, 所以不动。
    for gen in sans-serif serif; do
      echo '  <alias>'
      echo "    <family>$gen</family>"
      echo '    <prefer>'
      echo "      <family>$_fam</family>"
      echo '    </prefer>'
      echo '  </alias>'
    done
  fi
  echo '</fontconfig>'
}
# 内部模式(不写任何东西, 只往 stdout 打印): bash install.sh --emit-fontconfig <dir> <cjkFont>
if [ "${1:-}" = "--emit-fontconfig" ]; then
  case "${2:-}" in
    harmony-sans) emit_fontconfig "${3:-$HOME/.nix-profile/share/fonts}" "HarmonyOS Sans SC" ;;
    noto)         emit_fontconfig "${3:-$HOME/.nix-profile/share/fonts}" "Noto Sans CJK SC" ;;
    *)            emit_fontconfig "${3:-$HOME/.nix-profile/share/fonts}" "" ;;
  esac
  exit 0
fi

set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_DIM='\033[2m'; C_R='\033[0m'
info(){ printf "${C_OK}[✓]${C_R} %s\n" "$*"; }
warn(){ printf "${C_WARN}[!]${C_R} %s\n" "$*"; }
err(){ printf "${C_ERR}[✗]${C_R} %s\n" "$*" >&2; }
step(){ printf "\n${C_DIM}════════ %s ════════${C_R}\n" "$*"; }

# ── 0/5 门禁 ─────────────────────────────────────────────────────────────
if [ "$(id -u)" = 0 ]; then
  err "请用普通用户(steamos 的 deck)执行 install.sh。"
  err "  root 会把 STATE 装到 /root/.steamos-nix, 而 sudoers/heal unit 放行的是"
  err "  cfg.activatePath(默认 /home/deck/.steamos-nix/bin/steamos-nix-activate),"
  err "  两条路径对不上 → 开机自愈会永久静默失效。需要 sudo 的只有最后一步激活。"
  exit 1
fi

WITH_DSH=0
WITH_APPS=""
MACHINE_ARG=""
NO_ACTIVATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --with-dsh)     WITH_DSH=1 ;;
    --with-apps)    WITH_APPS=1 ;;
    --without-apps) WITH_APPS=0 ;;
    --machine)      shift; MACHINE_ARG="${1:-}" ;;
    --no-activate)  NO_ACTIVATE=1 ;;
    *) warn "忽略未知参数: $1" ;;
  esac
  shift
done

command -v nix >/dev/null 2>&1 || { err "未找到 nix, 先跑: bash bootstrap-nix.sh"; exit 1; }
[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ] && { set +u; . "$HOME/.nix-profile/etc/profile.d/nix.sh"; set -u; }
command -v nix >/dev/null 2>&1 || { err "nix 未就绪"; exit 1; }

STATE="$HOME/.steamos-nix"

step "1/5 机型探测"
if [ -n "$MACHINE_ARG" ]; then
  case "$MACHINE_ARG" in
    gpd-win5|steam-deck|desktop) : ;;
    *) err "--machine 只接受 gpd-win5 | steam-deck | desktop"; exit 1 ;;
  esac
  STEAMOS_NIX_MACHINE="$MACHINE_ARG" bash scripts/steamos-nix-detect.sh
  info "已按 --machine 写入 machine.nix"
elif [ -f scripts/steamos-nix-detect.sh ]; then
  MACHINE=$(bash scripts/steamos-nix-detect.sh --quiet)
  bash scripts/steamos-nix-detect.sh
else
  warn "找不到 scripts/steamos-nix-detect.sh, 沿用 machine.nix 现有值"
fi
MACHINE=$(grep -oE '"[a-z0-9-]+"' machine.nix 2>/dev/null | head -1 | tr -d '"')
info "机型: $MACHINE"
case "$MACHINE" in
  gpd-win5)   info "含 GPD Win5 背键三件套" ;;
  steam-deck) info "通用掌机集(无 Win5 专属配置)" ;;
  desktop)    info "台式机集: 不含任何手持机专属配置, 含桌面生产力套件" ;;
  *)          err "machine.nix 里的机型非法: $MACHINE"; exit 1 ;;
esac
[ -n "$WITH_APPS" ] || { [ "$MACHINE" = desktop ] && WITH_APPS=1 || WITH_APPS=0; }

step "2/5 构建包(内容 → /nix/store)"
mkdir -p "$STATE"
# NOTE: --out-link 会创建 indirect GC root。别再对 steamos-etc 用 --no-link ——
# 那样 /nix/store 里这一代会被 nix-collect-garbage 回收, etc-current 变悬空,
# 开机自愈从此只能联网重装。
rm -f "$STATE/etc-gcroot"
ETC=$(nix build   --print-out-paths --out-link "$STATE/etc-gcroot" .#steamos-etc)
TOOLS=$(nix build --no-link --print-out-paths .#steamos-tools)
ACT=$(nix build   --no-link --print-out-paths .#steamos-nix-activate)
WB=$(nix build    --no-link --print-out-paths .#workbuddy)
info "steamos-etc          → $ETC   (GC root: $STATE/etc-gcroot)"
info "steamos-tools        → $TOOLS"
info "steamos-nix-activate → $ACT"
info "workbuddy(转发器)     → $WB"
if [ "$WITH_DSH" = 1 ]; then
  DSH=$(nix build --no-link --print-out-paths .#dsh) || \
    { err "dsh 构建失败 → 大概率是 flake.nix 里 npm hash 还是占位(见 README 两遍法)"; exit 1; }
  info "dsh                  → $DSH"
fi
if [ "$WITH_APPS" = 1 ]; then
  APPS=$(nix build --no-link --print-out-paths .#steamos-apps 2>/dev/null) || APPS=""
  [ -n "$APPS" ] && info "steamos-apps(WPS/微信/LocalSend) → $APPS" \
                 || warn "steamos-apps 构建失败(nixpkgs 缺 wpsoffice/wechat/localsend?) → 跳过桌面套件"

  # 字体单独构建、失败只降级: HarmonyOS Sans 走的是外部 FOD(fetchzip 华为 zip),
  # hash 一旦与上游不一致就会失败。把它和 WPS/微信/LocalSend 解耦,
  # 避免"字体 hash 不对 → 整个桌面套件装不上"。
  FONTLOG=$(mktemp 2>/dev/null || echo /tmp/.steamos-nix-fonts.$$.log)
  if nix build --no-link --print-out-paths .#steamos-cjk-fonts >/dev/null 2>"$FONTLOG"; then
    info "steamos-cjk-fonts 构建通过 → $(nix build --no-link --print-out-paths .#steamos-cjk-fonts 2>/dev/null | tail -1)"
  else
    warn "steamos-cjk-fonts 构建失败 → 不影响 WPS/微信/LocalSend, 但中文会显示豆腐块"
    if grep -qi 'hash mismatch' "$FONTLOG" 2>/dev/null; then
      warn "  看起来是 HarmonyOS Sans 的 FOD hash 不匹配(上游 zip 变了)。修法:"
      warn "  在 steamos-nix 目录跑: nix build .#steamos-cjk-fonts"
      warn "  把报错里 'got:' 后面的整串 sha256-... 填回 flake.nix 的 cfg.harmonySansHash,"
      warn "  再跑一次 bash install.sh。想先绕开就改 cfg.cjkFont = \"noto\"(用 Noto CJK 兜底)。"
    else
      warn "  详情: $FONTLOG"
    fi
  fi
  rm -f "$FONTLOG" 2>/dev/null || true
fi

step "3/5 安装进 nix profile(/home 内, 持久)"
prof() {  # 幂等: 已在 profile 里 → upgrade(换新 store 路径); 否则 install
  local attr="$1" name="$PWD#$1"
  if nix profile list 2>/dev/null | grep -qF "$name"; then
    nix profile upgrade "$name" && info "profile upgrade: $attr"
  else
    nix profile install "$name" && info "profile install: $attr"
  fi
}
prof steamos-tools
prof workbuddy
prof steamos-nix-activate
[ "$WITH_DSH" = 1 ] && prof dsh
if [ "$WITH_APPS" = 1 ] && [ -n "${APPS:-}" ]; then
  for a in wps-office wechat localsend steamos-cjk-fonts; do
    # 专有软件在某些 nixpkgs commit 上会缺失/改名 → 缺就跳过, 不拖垮整条安装
    if ! nix eval ".#packages.x86_64-linux.$a" >/dev/null 2>&1; then
      warn "本机 nixpkgs 没有 $a, 跳过"
    elif prof "$a"; then
      :
    else
      warn "$a 安装失败, 继续其它项"
    fi
  done
fi
command -v steamos-nix-activate >/dev/null 2>&1 || {
  err "~/.nix-profile/bin 不在当前 PATH? 重新登录或: source ~/.nix-profile/etc/profile.d/nix.sh"
  exit 1
}

step "4/5 更新持久稳定指针 ~/.steamos-nix"
mkdir -p "$STATE/bin"
if [ -L "$STATE/etc-current" ]; then
  old=$(readlink "$STATE/etc-current")
  ln -sfn "$old" "$STATE/etc-previous"   # 回滚锚点
fi
ln -sfn "$ETC" "$STATE/etc-current"
ln -sfn "$ACT/bin/steamos-nix-activate" "$STATE/bin/steamos-nix-activate"
ln -sfn "$PWD/README-migration.md" "$STATE/README-migration.md" 2>/dev/null || \
  cp -f README-migration.md "$STATE/README-migration.md" 2>/dev/null || true
: > "$STATE/machine"
echo "machine=$MACHINE" > "$STATE/machine"
info "etc-current → $ETC"
info "bin/steamos-nix-activate → $ACT"

# 用户级自愈服务(单元文件本体在 /home, 天然抗升级)
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"
if [ -f "$UNIT_DIR/steamos-nix-heal.service" ] && \
   ! cmp -s config/systemd/user/steamos-nix-heal.service "$UNIT_DIR/steamos-nix-heal.service"; then
  cp config/systemd/user/steamos-nix-heal.service "$UNIT_DIR/steamos-nix-heal.service"
  info "更新自愈 user 单元"
else
  cp config/systemd/user/steamos-nix-heal.service "$UNIT_DIR/steamos-nix-heal.service"
fi
systemctl --user daemon-reload
systemctl --user enable steamos-nix-heal.service >/dev/null 2>&1 || true

# ── 桌面入口 + 中文字体(都在 /home, 升级幸存) ─────────────────────────────
if [ "$WITH_APPS" = 1 ]; then
  APPDIR="$HOME/.local/share/applications"
  mkdir -p "$APPDIR"
  n=0
  for d in "$HOME/.nix-profile/share/applications"/*.desktop; do
    [ -e "$d" ] || continue
    b=$(basename "$d")
    ln -sfn "$d" "$APPDIR/$b" && n=$((n+1))
  done
  [ "$n" -gt 0 ] && info "桌面入口 $n 个 → $APPDIR" || warn "没有找到任何 .desktop(nix profile 里没有 GUI 包?)"

  # 字体接入: 不复制字体, 而是往 fontconfig 写一条 <dir> 指向 store 路径
  # (不复制、不断链, 换代时整条重写即可)。
  # 额外写 <prefer>: 只给 <dir> 的话 fontconfig 只是"多了个候选",
  # 中文仍可能被别的字体抢走; 显式 prefer 才能确保 sans/serif 优先命中鸿蒙。
  # 族名必须与 ttf 的 name 表一致(实测 "HarmonyOS Sans SC")。
  CJK_FONT=$(grep -oE 'cjkFont[ ]*=[ ]*"[a-z-]+"' flake.nix 2>/dev/null | head -1 \
             | grep -oE '"[a-z-]+"' | tr -d '"' || true)
  case "$CJK_FONT" in
    harmony-sans) CJK_FAMILY="HarmonyOS Sans SC" ;;
    noto)         CJK_FAMILY="Noto Sans CJK SC" ;;
    *)            CJK_FAMILY="" ;;
  esac
  FONTSDIR="$HOME/.nix-profile/share/fonts"
  if [ -d "$FONTSDIR" ]; then
    FCCONF="$HOME/.config/fontconfig/conf.d"
    mkdir -p "$FCCONF"
    emit_fontconfig "$(readlink -f "$FONTSDIR")" "$CJK_FAMILY" \
      > "$FCCONF/10-steamos-nix-fonts.conf"
    info "fontconfig 已指向: $(readlink -f "$FONTSDIR")"
    [ -n "$CJK_FAMILY" ] && info "中文字体首选族: $CJK_FAMILY(cfg.cjkFont=$CJK_FONT)"
    command -v fc-cache >/dev/null 2>&1 && fc-cache -f >/dev/null 2>&1 && info "字体缓存已刷新"
  else
    warn "~/.nix-profile/share/fonts 不存在 → WPS/微信可能显示豆腐块"
    warn "  先确认 .#steamos-cjk-fonts 已装进 profile(见上一步的输出)"
  fi
  info "LocalSend 需要防火墙放行 53317/tcp + 53317/udp(组播发现 + 传输), 见 README §3"
fi

# ── 输入法: 统一 IBus + 小鹤双拼(桌面 + gamescope 两个会话共用) ──────────
# 为什么是 IBus: SteamOS 自带; 且 Steam 游戏模式只认 IBus D-Bus 通道,
# 用 fcitx5 得额外装 AUR 桥接包。详见 README §3.5。
if [ -f scripts/setup-ibus-xiaohe.sh ]; then
  step "4.5 输入法: IBus + 小鹤双拼"
  sh scripts/setup-ibus-xiaohe.sh || warn "输入法配置有失败项(常见是缺 ibus-rime / rime-double-pinyin)"
  echo
  sh scripts/setup-ibus-xiaohe.sh --check || \
    warn "输入法体检未全绿 —— 补齐依赖后重跑: sh scripts/setup-ibus-xiaohe.sh"
else
  warn "找不到 scripts/setup-ibus-xiaohe.sh, 跳过输入法配置"
fi

if [ "$NO_ACTIVATE" = 1 ]; then
  info "--no-activate: 跳过 /etc 重链(仅当你想自己跑 sudo ~/.steamos-nix/bin/steamos-nix-activate)"
  exit 0
fi

step "5/5 激活: 把 nix 里的 /etc 落点链回去(需要 sudo)"
sudo "$STATE/bin/steamos-nix-activate" --state "$STATE"
# ── WorkBuddy: 只装一个"转发器", 本体必须留在系统里 ──────────────────────
# 转发器优先 exec /usr/bin/workbuddy(AUR 原生), 所以系统里有原生 wrapper 是**好事**;
# 只有它缺了, 转发器才会退到"系统 electron → nix electron"去启动 /opt 的 payload。
if [ -x /usr/bin/workbuddy ] && [ ! -L /usr/bin/workbuddy ]; then
  info "WorkBuddy: 检测到系统原生 /usr/bin/workbuddy → nix 转发器会直接调用它(功能完整)"
else
  warn "WorkBuddy: /usr/bin/workbuddy 不存在(被原子升级冲掉了?)"
  warn "  当前会退到 electron 直接启动 /opt/workbuddy —— 能用, 但自更新/插件/输入法可能受限。"
  warn "  建议: yay -S workbuddy  装回系统原生版, 之后 nix 转发器会优先用它。"
fi

info "完成。之后每次大版本升级: 开机自愈会自动重链; 手动兜底一条:"
info "  sudo ~/.steamos-nix/bin/steamos-nix-activate"
[ "$WITH_APPS" = 1 ] && info "应用菜单里应有: WPS / 微信 / LocalSend(命令: wps | wechat | localsend_app)"
[ "$WITH_APPS" = 1 ] && [ -n "${CJK_FAMILY:-}" ] && info "中文字体: $CJK_FAMILY —— 若 WPS 仍是豆腐块: fc-match \"$CJK_FAMILY\""
