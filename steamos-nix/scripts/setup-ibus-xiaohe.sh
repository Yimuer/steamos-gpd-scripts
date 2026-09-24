#!/bin/sh
# ===========================================================================
#  setup-ibus-xiaohe.sh —— SteamOS 输入法统一到 IBus + 小鹤双拼(XIAOHE / flypy)
# ---------------------------------------------------------------------------
#  为什么是 IBus 而不是 fcitx5:
#    ① SteamOS **自带** ibus。
#    ② Steam 游戏模式(gamescope)只能通过 **IBus D-Bus 协议** 跟输入法通信
#       (会话 target 里的 ibus-gamescope.service 就是这个通道)。用 fcitx5 得额外
#       装 AUR 桥接包 fcitx5-steam-ibus-frontend —— 多一层就多一处坏点。
#       换回 ibus = 走原生通道, 桥接层直接省掉。
#    ③ 两套框架并存会抢 DBus 名与 GTK/QT IM 模块, 是"候选框乱飞/输入发不出"的常见源。
#
#  两个会话都要能用:
#    · KDE 桌面模式(Plasma Wayland)
#        —— KWin 负责拉起输入法, 需要在 ~/.config/kwinrc 指定 [Wayland] InputMethod。
#        —— 并且 **不能**再 export GTK_IM_MODULE / QT_IM_MODULE:
#           Wayland 下强制设会让程序走 XWayland 的 IM 模块, 候选框不跟随、输入发不出。
#           只 export XMODIFIERS=@im=ibus 即可(IBus 官方也是这么建议的)。
#    · 游戏模式(gamescope)
#        —— Steam 走 IBus D-Bus, 只要 ibus-daemon 在用户会话里跑着就行。
#        —— 用 systemd user unit 常驻, 桌面与游戏模式共用同一个守护进程;
#           靠 EnvironmentFile=-%t/gamescope-environment 拿到 gamescope 的 DISPLAY。
#
#  刻意写成 POSIX sh: 这样 .selftest 能在只有 busybox 的沙盒里直接跑它做回归(B14)。
#
#  用法:
#    sh setup-ibus-xiaohe.sh            # 配置(幂等, 可重复跑)
#    sh setup-ibus-xiaohe.sh --check    # 只体检, 不写任何东西
#    sh setup-ibus-xiaohe.sh --install  # 顺带用 pacman 补装 ibus-rime 等依赖
# ===========================================================================
set -u

C_R='\033[0m'; C_G='\033[32m'; C_Y='\033[33m'; C_RD='\033[31m'; C_B='\033[1m'
info() { printf "${C_G}[✓]${C_R} %s\n" "$*"; }
warn() { printf "${C_Y}[!]${C_R} %s\n" "$*"; }
err()  { printf "${C_RD}[✗]${C_R} %s\n" "$*" >&2; }
step() { printf "\n${C_B}── %s ──${C_R}\n" "$*"; }

CHECK_ONLY=0
DO_INSTALL=0
for _a in "$@"; do
  case "$_a" in
    --check)   CHECK_ONLY=1 ;;
    --install) DO_INSTALL=1 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
    *) warn "忽略未知参数: $_a" ;;
  esac
done

# ── 路径(全部在 /home, 升级幸存) ────────────────────────────────────────
RIME_DIR="$HOME/.config/ibus/rime"
ENV_DIR="$HOME/.config/plasma-workspace/env"
ENV_SH="$ENV_DIR/90-steamos-nix-ime.sh"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/ibus-daemon.service"
KWINRC="$HOME/.config/kwinrc"
FISH_DIR="$HOME/.config/fish/conf.d"
FISH_SH="$FISH_DIR/steamos-nix-ime.fish"

# ── 环境变量片段: 会话自适应(这段是核心, 别改) ──────────────────────────
emit_ime_env() {
  cat <<'EOF'
# steamos-nix: IBus 输入法环境变量 —— 会话自适应
#
# Wayland 会话下**只**设 XMODIFIERS:
#   KWin 自己拉起输入法(kwinrc 的 [Wayland] InputMethod), 再 export
#   GTK_IM_MODULE / QT_IM_MODULE 会让程序改走 XWayland 的 IM 模块,
#   结果就是候选框不跟随、甚至完全发不出中文。
# X11 / XWayland 会话下才需要全套。
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
  export XMODIFIERS='@im=ibus'
  unset GTK_IM_MODULE
  unset QT_IM_MODULE
else
  export GTK_IM_MODULE=ibus
  export QT_IM_MODULE=ibus
  export XMODIFIERS='@im=ibus'
fi
EOF
}

# ── kwinrc [Wayland] InputMethod: 纯 POSIX 的 ini 改写 ──────────────────
# 有 kwriteconfig6/5 就用它(更懂 KDE 的落盘时机), 没有就直接改 ini。
set_kwin_inputmethod() {
  _im="$1"
  if command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig6 --file kwinrc --group Wayland --key InputMethod "$_im" && return 0
  fi
  if command -v kwriteconfig5 >/dev/null 2>&1; then
    kwriteconfig5 --file kwinrc --group Wayland --key InputMethod "$_im" && return 0
  fi
  [ -f "$KWINRC" ] || : > "$KWINRC"
  awk -v im="$_im" '
    BEGIN { inw=0; done=0 }
    /^\[/ { if (inw && !done) { print "InputMethod=" im; done=1 } inw=0 }
    /^\[Wayland\]/ { inw=1; print; next }
    inw && /^InputMethod=/ { print "InputMethod=" im; done=1; inw=0; next }
    { print }
    END { if (!done) { if (!inw) print "[Wayland]"; print "InputMethod=" im } }
  ' "$KWINRC" > "$KWINRC.tmp" && mv "$KWINRC.tmp" "$KWINRC"
}

# ── systemd user unit: 桌面 + gamescope 共用一个 ibus-daemon ─────────────
emit_ibus_unit() {
  cat <<'EOF'
[Unit]
Description=IBus input method daemon (shared by KDE desktop + gamescope game mode)
Documentation=https://github.com/ibus/ibus
PartOf=graphical-session.target
After=graphical-session.target
# 与 fcitx5 互斥: 两套框架会抢 DBus 名与 IM 模块
Conflicts=fcitx5.service

[Service]
Type=simple
ExecStart=/usr/bin/ibus-daemon --replace --xim
Restart=on-failure
RestartSec=3
# 别无限重试: 失败 5 次 / 10 分钟后进入 start-limit, 交给自愈服务处理
StartLimitBurst=5
StartLimitIntervalSec=600
# gamescope 会把 DISPLAY / WAYLAND_DISPLAY 同步到这个文件;
# 前缀 - 表示文件不存在也不报错(桌面模式下就是不存在)
EnvironmentFile=-%t/gamescope-environment

[Install]
WantedBy=graphical-session.target gamescope-session.target
EOF
}

# ── 小鹤双拼的 Rime 配置 ────────────────────────────────────────────────
emit_rime_default() {
  cat <<'EOF'
# Rime 用户配置 —— 小鹤双拼(double_pinyin_flypy)为默认方案
# 由 steamos-nix 的 setup-ibus-xiaohe.sh 写入; 改完需要「重新部署」才生效。
patch:
  schema_list:
    - schema: double_pinyin_flypy   # 小鹤双拼(默认)
    - schema: luna_pinyin           # 明月拼音(全拼备用)
    - schema: double_pinyin_mspy    # 微软双拼
    - schema: emoji                 # emoji
  menu/page_size: 7
EOF
}

# ═════════════════════════════════════════════════════════════════════════
#  --check: 只体检, 不写任何东西
# ═════════════════════════════════════════════════════════════════════════
if [ "$CHECK_ONLY" = 1 ]; then
  step "IBus + 小鹤双拼 体检(只读)"
  _rc=0
  command -v ibus-daemon >/dev/null 2>&1 \
    && info "ibus-daemon 存在: $(command -v ibus-daemon)" \
    || { err "ibus-daemon 不在 PATH —— SteamOS 应自带 ibus, 试试: sudo pacman -S ibus"; _rc=1; }

  if [ -f /usr/share/rime-data/double_pinyin_flypy.schema.yaml ]; then
    info "小鹤双拼方案文件存在: /usr/share/rime-data/double_pinyin_flypy.schema.yaml"
  else
    warn "缺 double_pinyin_flypy 方案文件 → sudo pacman -S rime-double-pinyin(或 archlinuxcn 同名包)"
    _rc=1
  fi
  if [ -f /usr/lib/ibus/ibus-engine-rime ] || command -v ibus-engine-rime >/dev/null 2>&1; then
    info "ibus-rime 引擎已安装"
  else
    warn "ibus-rime 未安装 → sudo pacman -S ibus-rime librime"
    _rc=1
  fi

  if [ -f "$RIME_DIR/default.custom.yaml" ]; then
    if grep -q 'double_pinyin_flypy' "$RIME_DIR/default.custom.yaml" 2>/dev/null; then
      info "Rime 配置已把小鹤双排列在 schema_list(默认方案)"
    else
      warn "Rime 配置里没有 double_pinyin_flypy"
      _rc=1
    fi
  else
    warn "缺 $RIME_DIR/default.custom.yaml"
    _rc=1
  fi

  [ -f "$ENV_SH" ] && info "环境变量片段已就位: $ENV_SH" || { warn "缺 $ENV_SH"; _rc=1; }
  _ime_frag_found=0
  for _f in "$ENV_DIR"/*steamos-nix-ime*; do [ -f "$_f" ] && _ime_frag_found=1; done
  if [ "$_ime_frag_found" -eq 1 ] || [ -f "$ENV_SH" ]; then
    if grep -q 'unset GTK_IM_MODULE' "$ENV_SH" 2>/dev/null; then
      info "Wayland 下不会强设 GTK/QT_IM_MODULE(避免候选框不跟随)"
    else
      warn "环境变量片段缺少 Wayland 分支"
      _rc=1
    fi
  fi

  if [ -f "$KWINRC" ] && grep -q '^InputMethod=' "$KWINRC" 2>/dev/null; then
    info "kwinrc InputMethod = $(grep '^InputMethod=' "$KWINRC" | head -1 | cut -d= -f2-)"
  else
    warn "kwinrc 没有 [Wayland] InputMethod → Wayland 原生应用会打不出中文"
    _rc=1
  fi

  [ -f "$UNIT" ] && info "ibus-daemon user unit 已就位" || { warn "缺 $UNIT"; _rc=1; }
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user is-enabled ibus-daemon.service >/dev/null 2>&1 \
      && info "ibus-daemon.service 已 enable" || warn "ibus-daemon.service 未 enable"
  fi

  echo
  [ "$_rc" = 0 ] && info "体检通过" || err "体检有失败项, 跑: sh $0"
  exit "$_rc"
fi

# ═════════════════════════════════════════════════════════════════════════
if [ "$(id -u)" = 0 ] && [ -z "${SUDO_USER:-}" ]; then
  err "请以普通用户(deck)身份运行 —— dconf / systemd --user 都是用户级的。"
  exit 1
fi

echo "${C_B}=== IBus + 小鹤双拼 配置 ===${C_R}"
echo "  HOME      : $HOME"
echo "  SESSION   : ${XDG_SESSION_TYPE:-unknown}"

# ── 1/7 与 fcitx5 的冲突检查 ────────────────────────────────────────────
step "1/7 检查 fcitx5 冲突(两套框架不能并存)"
FCITX_HITS=""
[ -f "$HOME/.config/environment.d/fcitx5.conf" ] && FCITX_HITS="$FCITX_HITS environment.d/fcitx5.conf"
[ -f "$HOME/.config/autostart/org.fcitx.Fcitx5.desktop" ] && FCITX_HITS="$FCITX_HITS autostart/Fcitx5.desktop"
[ -d "$HOME/.config/fcitx5" ] && FCITX_HITS="$FCITX_HITS config/fcitx5/"
[ -f "$HOME/.local/bin/fcitx5-steam-ibus-start.sh" ] && FCITX_HITS="$FCITX_HITS fcitx5-steam-ibus-start.sh"
if command -v pgrep >/dev/null 2>&1 && pgrep -x fcitx5 >/dev/null 2>&1; then
  FCITX_HITS="$FCITX_HITS [运行中]"
fi
if [ -n "$FCITX_HITS" ]; then
  warn "检测到 fcitx5 残留:$FCITX_HITS"
  warn "  建议清理(本脚本不擅自删你的东西):"
  warn "    rm -f ~/.config/environment.d/fcitx5.conf ~/.config/autostart/org.fcitx.Fcitx5.desktop"
  warn "    rm -f ~/.local/bin/fcitx5-steam-ibus-start.sh ~/.config/systemd/user/fcitx5-steam-ibus.service"
  warn "    sudo pacman -Rns fcitx5 fcitx5-rime fcitx5-steam-ibus-frontend 2>/dev/null || true"
  warn "  游戏模式不再需要 fcitx5-steam-ibus-frontend —— Steam 原生就走 IBus。"
else
  info "没有 fcitx5 残留"
fi

# ── 2/7 依赖 ────────────────────────────────────────────────────────────
step "2/7 依赖检查"
if command -v ibus-daemon >/dev/null 2>&1 || [ -x /usr/bin/ibus-daemon ]; then
  info "ibus 已安装"
else
  warn "没找到 ibus-daemon"
  [ "$DO_INSTALL" = 1 ] && sudo pacman -S --needed ibus || warn "  装: sudo pacman -S ibus"
fi

if [ -f /usr/lib/ibus/ibus-engine-rime ] || command -v ibus-engine-rime >/dev/null 2>&1; then
  info "ibus-rime 引擎已安装"
else
  warn "ibus-rime 未安装(Rime 引擎)"
  if [ "$DO_INSTALL" = 1 ]; then
    sudo pacman -S --needed ibus-rime librime || warn "  pacman 安装失败, 手动来一次"
  else
    warn "  装: sudo pacman -S ibus-rime librime   (或加 --install 让本脚本帮你装)"
  fi
fi

if [ -f /usr/share/rime-data/double_pinyin_flypy.schema.yaml ]; then
  info "小鹤双拼方案已安装(double_pinyin_flypy)"
else
  warn "缺 rime-double-pinyin(小鹤双拼方案文件)"
  if [ "$DO_INSTALL" = 1 ]; then
    sudo pacman -S --needed rime-double-pinyin || warn "  pacman 安装失败; 若在 SteamOS 上请确认仓库里有该包"
  else
    warn "  装: sudo pacman -S rime-double-pinyin   (或加 --install)"
    warn "  备选: ibus-libpinyin 也内置小鹤双拼, 但配置走 gsettings, 不如 Rime 好版本化。"
  fi
fi

# ── 3/7 Rime 配置 ───────────────────────────────────────────────────────
step "3/7 写入 Rime 配置(小鹤双拼为默认)"
mkdir -p "$RIME_DIR"
emit_rime_default > "$RIME_DIR/default.custom.yaml"
info "已写入 $RIME_DIR/default.custom.yaml"

# ── 4/7 重新部署(删掉 default.yaml 才会重算) ────────────────────────────
step "4/7 触发 Rime 重新部署"
rm -f "$RIME_DIR/default.yaml"
info "已删除 default.yaml(下次启动 ibus 时会按新配置重算)"
if command -v ibus >/dev/null 2>&1; then
  ibus restart >/dev/null 2>&1 && info "ibus 已重启" || warn "ibus restart 无效(可能没在跑, 下一步会拉起)"
else
  warn "没有 ibus 命令, 跳过重启"
fi

# ── 5/7 环境变量(会话自适应) ────────────────────────────────────────────
step "5/7 写入环境变量(KDE 桌面 + 终端)"
mkdir -p "$ENV_DIR"
emit_ime_env > "$ENV_SH"
chmod +x "$ENV_SH" 2>/dev/null || true
info "已写入 $ENV_SH"
if [ -d "$HOME/.config/fish" ] || command -v fish >/dev/null 2>&1; then
  mkdir -p "$FISH_DIR"
  cat > "$FISH_SH" <<'EOF'
# steamos-nix: IBus 输入法环境变量(终端里启动的程序也能用)
if set -q XDG_SESSION_TYPE; and test "$XDG_SESSION_TYPE" = wayland
    set -gx XMODIFIERS '@im=ibus'
    set -e GTK_IM_MODULE
    set -e QT_IM_MODULE
else
    set -gx GTK_IM_MODULE ibus
    set -gx QT_IM_MODULE ibus
    set -gx XMODIFIERS '@im=ibus'
end
EOF
  info "已写入 $FISH_SH"
fi

# ── 6/7 kwinrc: 让 KWin 在 Wayland 下拉起 IBus ──────────────────────────
step "6/7 配置 kwinrc [Wayland] InputMethod"
IM_DESKTOP=""
for _d in /usr/share/applications/*IBus*Wayland*.desktop /usr/share/applications/*ibus*wayland*.desktop; do
  [ -f "$_d" ] && { IM_DESKTOP="$_d"; break; }
done
if [ -n "$IM_DESKTOP" ]; then
  set_kwin_inputmethod "$IM_DESKTOP"
  info "已设为: $IM_DESKTOP"
else
  warn "没找到 IBus 的 Wayland desktop 文件, 跳过(不瞎写路径)"
  warn "  手动: 系统设置 → 键盘 → 虚拟键盘 → 选 「IBus Wayland」"
fi

# ── 7/7 systemd user unit + 拉起 ────────────────────────────────────────
step "7/7 常驻 ibus-daemon(桌面 + gamescope 共用)"
mkdir -p "$UNIT_DIR"
emit_ibus_unit > "$UNIT"
info "已写入 $UNIT"
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user enable ibus-daemon.service >/dev/null 2>&1 \
    && info "已 enable ibus-daemon.service" || warn "enable 失败(沙盒/无 systemd 时正常)"
  if command -v ibus-daemon >/dev/null 2>&1; then
    systemctl --user restart ibus-daemon.service >/dev/null 2>&1 \
      && info "已拉起 ibus-daemon" || ibus-daemon -drx >/dev/null 2>&1 || warn "启动 ibus-daemon 失败"
  fi
else
  warn "没有 systemctl, 跳过(沙盒环境属正常)"
fi
if command -v dconf >/dev/null 2>&1; then
  dconf write /desktop/ibus/general/preload-engines "['xkb:us::eng', 'rime']" 2>/dev/null \
    && info "ibus 引擎列表 = [英文, rime]" || warn "dconf 写入失败(没有 D-Bus 会话时正常)"
else
  warn "没有 dconf, 跳过引擎列表设置"
fi

echo
echo "${C_B}==============================================${C_R}"
echo " 完成。生效方式:"
echo "   1) 注销重登(或重启)—— 环境变量与 kwinrc 都需要新会话"
echo "   2) 首次进入会触发 Rime 部署, 1~2 分钟(编词库)"
echo
echo " 常用:"
echo "   Super + Space      切换中/英"
echo "   Ctrl + \` 或 F4     方案选单(小鹤双拼 / 明月拼音 / emoji)"
echo
echo " 复查: sh $0 --check"
echo "${C_B}==============================================${C_R}"
