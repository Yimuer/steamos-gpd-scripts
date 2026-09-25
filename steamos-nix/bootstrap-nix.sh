#!/usr/bin/env bash
# =============================================================================
#  bootstrap-nix.sh — 一次性:在 SteamOS(GPD Win5)上安装 Nix,并确保 store
#  落在"系统升级不删除"的持久目录里。装完即可反复跑 install.sh / verify.sh。
# -----------------------------------------------------------------------------
#  为什么需要"确保持久":SteamOS 大版本升级用 A/B 原子更新整块替换 rootfs,
#  /etc /usr /opt 全被覆盖,只有 /home(以及 /nix 若挂在 home 分区 / overlay upper)
#  幸存。Determinate/NixOS 官方安装器默认把 store 放根分区的 /nix;在标准
#  SteamOS 上根分区是只读镜像 + overlay,/nix 实际写进 overlay 上层(home 分区),
#  因此**天然幸存**——但这取决于本机分区布局,不能盲信。本脚本会**探测**并在
#  探测到 /nix 可能不持久时给出显式处置建议(改 home 分区 bind 或 XDG store)。
#
#  幂等:已装 nix 就直接进入探测/收尾,不重复安装。
#  离线友好:安装阶段需要联网下载 nix;探测/收尾不需要。
#
#  用法:
#    bash bootstrap-nix.sh              # 安装(或复用)单用户 nix + 探测持久性
#    bash bootstrap-nix.sh --check-only # 只探测当前 /nix 是否持久,不改系统
#    NIX_PERSIST=home bash bootstrap-nix.sh  # 强制把 store 规划到 ~/nix-store
# =============================================================================
set -euo pipefail

C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_DIM='\033[2m'; C_R='\033[0m'
info(){ printf "${C_OK}[✓]${C_R} %s\n" "$*"; }
warn(){ printf "${C_WARN}[!]${C_R} %s\n" "$*"; }
err(){ printf "${C_ERR}[✗]${C_R} %s\n" "$*" >&2; }
sub(){ printf "${C_DIM}   • %s${C_R}\n" "$*"; }

REAL_USER="$(id -un)"
REAL_HOME="$HOME"
STATE_DIR="$REAL_HOME/.steamos-nix"
CHECK_ONLY=0
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=1

# ── 探测:给定路径落在哪个文件系统/块设备 ──────────────────────────────────
# 返回 "SOURCE:FSTYPE" 便于比对 /home 与 /nix 是否同一持久设备。
fs_of() {
  findmnt -T "$1" -no SOURCE,FSTYPE 2>/dev/null | head -1 || true
}

# ── 探测 /nix 持久性并给出结论 ────────────────────────────────────────────
probe_persistence() {
  local home_fs nix_fs root_fs
  home_fs="$(fs_of "$REAL_HOME")"
  root_fs="$(fs_of /)"
  nix_fs="$(fs_of /nix 2>/dev/null || true)"

  sub "/home fs : $home_fs"
  sub "/      fs : $root_fs"
  sub "/nix    fs : ${nix_fs:-<不存在>}"

  # 关键判断:A/B 原子更新替换的是 rootfs(erofs/ext4 只读镜像, 挂载点 /)。
  # 若 /nix 与 / 同一只读块设备且非 overlay/btrfs-home → 升级必丢, 需迁移。
  local nix_dev="${nix_fs%%:*}" home_dev="${home_fs%%:*}"
  [ -z "$nix_dev" ] && { warn "/nix 尚未就绪(可能刚装/未挂载)"; return 2; }

  # overlay 或指向 home 同一 btrfs/ext 分区 → 持久(随 /home 幸存)
  case "$nix_fs" in
    overlay*) info "/nix 在 overlay 上层(=home 分区): 原子升级后幸存。"; return 0 ;;
  esac
  if [ -n "$home_dev" ] && [ "$nix_dev" = "$home_dev" ]; then
    info "/nix 与 /home 同块设备: 原子升级后幸存。"; return 0
  fi
  # 若 /nix 与易失根分区同设备 → 风险
  if [ "$nix_dev" = "${root_fs%%:*}" ]; then
    warn "/nix 与根分区($root_fs)同设备 —— 大版本原子升级可能整块替换 → /nix 有丢失风险!"
    sub "处置A(推荐, 无需重装 nix): 给 /nix 加 home 分区 bind 挂载 + systemd 挂载单元"
    sub "  (steamos-nix 提供 steamos-nix-nixmount.service, 见 README『/nix 持久化』)"
    sub "处置B: 卸载 nix, 以 XDG/重定位模式重装到 $REAL_HOME/nix-store(需 nix 2.x 特殊构建)"
    return 1
  fi
  info "/nix 与易失根分区不同设备: 视为持久。"; return 0
}

echo "════════ 1/3 安装/复用 Nix ════════"
if command -v nix >/dev/null 2>&1 && [ -e "$REAL_HOME/.nix-profile" ]; then
  info "检测到已安装 Nix: $(nix --version 2>/dev/null)"
else
  if [ "$CHECK_ONLY" = 1 ]; then err "--check-only 但 nix 未安装"; exit 3; fi
  sub "安装单用户版 Nix(profile 落 ~/.nix-profile → /home, 满足持久前提)"
  # 境内加速: 官方脚本接受"二进制 tarball URL/路径"位置参数, 可指向
  # ghproxy 前缀的 GitHub releases, 例:
  #   NIX_TARBALL_URL=https://ghfast.top/https://github.com/NixOS/nix/releases/download/latest/nix-latest-x86_64-linux.tar.xz \
  #   bash bootstrap-nix.sh
  sh <(curl -fsSL "${NIX_INSTALL_SCRIPT:-https://nixos.org/nix/install}") \
      --no-daemon ${NIX_TARBALL_URL:+"$NIX_TARBALL_URL"} \
  || { err "传统安装器失败。可选: ①挂代理重试 ②手动下载 nix tarball 后跑 sh install --no-daemon <tarball> ③换 determinate 多用户安装(注意其 /nix 位置需按下方持久性探测自行规划)"; exit 4; }
  # 让当前 shell 立即用上 nix
  # shellcheck disable=SC1091
  [ -f "$REAL_HOME/.nix-profile/etc/profile.d/nix.sh" ] && . "$REAL_HOME/.nix-profile/etc/profile.d/nix.sh"
fi

# 幂等补齐 user 级 nix.conf(在 /home, 不碰 /etc): flakes + 国内二进制缓存
mkdir -p "$REAL_HOME/.config/nix"
NIX_CONF="$REAL_HOME/.config/nix/nix.conf"
touch "$NIX_CONF"
conf_set_if_missing() {  # conf_set_if_missing <grep-key> <line>
    grep -qE "^${1}" "$NIX_CONF" 2>/dev/null || { echo "$2" >> "$NIX_CONF"; info "nix.conf += $2"; }
}
conf_set_if_missing 'experimental-features' 'experimental-features = nix-command flakes'
conf_set_if_missing 'accept-flake-config'   'accept-flake-config = true'
# 国内镜像优先(USTC/TUNA 镜像保留上游签名, 无需额外 trusted-public-keys;
# cache.nixos.org 兜底 —— 镜像缺 nar 时 nix 会自动回源)。单换源: export NIX_SUBSTITUTER=...
NIX_SUBSTITUTER="${NIX_SUBSTITUTER:-https://mirrors.ustc.edu.cn/nix-channels/store https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store https://cache.nixos.org/}"
conf_set_if_missing 'substituters' "substituters = $NIX_SUBSTITUTER"
info "nix.conf 就绪: $NIX_CONF"

echo; echo "════════ 2/3 探测 /nix 持久性 ════════"
rc=0; probe_persistence || rc=$?
if [ "$rc" = 1 ]; then
  warn "持久性存疑, 但**不影响**你继续用 nix profile(/home 内)管理脚本与配置。"
  warn "仅当你的 store 真的在易失根分区时, 才需按 README『/nix 持久化』做 bind 挂载。"
fi

echo; echo "════════ 3/3 收尾 ════════"
mkdir -p "$STATE_DIR/bin"
info "持久状态目录: $STATE_DIR (在 /home, 升级幸存)"
cat > "$STATE_DIR/bootstrap.done" <<EOF
nix_version=$(nix --version 2>/dev/null || echo unknown)
user=$REAL_USER
home=$REAL_HOME
state_dir=$STATE_DIR
persist_probe_rc=$rc
done_at=$(date -u +%FT%TZ)
EOF
info "写标记: $STATE_DIR/bootstrap.done"

echo
echo "下一步:"
echo "  bash install.sh            # 把脚本+依赖装进 nix profile 并激活 /etc 链接"
echo "  bash verify.sh            # 可行性 + 健壮性验证(含模拟升级)"
echo "  —— 之后每次大版本升级, 只需(自动的除外):"
echo "  sudo $STATE_DIR/bin/steamos-nix-activate"
