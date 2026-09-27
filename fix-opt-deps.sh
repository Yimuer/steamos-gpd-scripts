#!/usr/bin/env bash
# ===========================================================================
#  fix-opt-deps.sh —— 升级后自动补回"便携化应用"缺失的系统依赖
# ---------------------------------------------------------------------------
#  【为什么要有它】
#  用 install-deb-portable.sh 装的应用本体在 /home(扛升级), 但它们的**系统依赖**
#  (典型: Tauri 的 webkit2gtk-4.1)装在 /usr —— 原子升级会整块换掉 rootfs, 于是
#  "应用还在、库没了"。本脚本负责升级后把这些依赖补回来, 让自愈链能无人值守完成。
#
#  【为什么不是直接 sudoers 放行 pacman】
#  放行 pacman = 任何能以 deck 执行代码的东西都能免密装任意包 —— 提权面太大。
#  所以只放行**本脚本**: 它是 **/opt 下的 root 属主快照**(用户改不动),
#  且**包名写死在脚本里**(外加一个同样是 root 属主的配置文件), 不接受命令行传包名。
#  于是提权面 = "重装这几个固定包", 与已有的两条免密规则(主脚本/开发文件补齐器)同款。
#
#  【用法】(root 跑; 由自愈链用 sudo -n 调用)
#    bash fix-opt-deps.sh            # 补回缺失的依赖
#    bash fix-opt-deps.sh --check    # 只读: 报告缺什么, 不改任何东西
#
#  【安全约束(改这个文件时绝不能破)】
#   1. 包名**只能**来自: ①脚本内 OPT_DEPS 数组 ②root 属主的 /opt/steamos-backup/opt-deps.conf。
#      **绝不能**读用户可写目录里的清单(那样用户就能免密装任意包 = 提权)。
#   2. 除 --check 外的参数一律忽略, 绝不把 argv 当包名。
#   3. 只在"确实装过便携化应用"时才动手(看 ~/.local/opt/*/.deb-portable 清单)。
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_I=$'\033[36m'; C_OK=$'\033[32m'; C_W=$'\033[33m'; C_E=$'\033[31m'
info() { printf '%s[*]%s %s\n' "$C_I" "$C_R" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_OK" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_W" "$C_R" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_E" "$C_R" "$*" >&2; }
sub()  { printf '    %s\n' "$*"; }

# ── 运行身份 / 家目录 ───────────────────────────────────────────────────
if [ "$(id -u)" -eq 0 ]; then
    REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
else
    REAL_USER="$(id -un)"
fi
[ -n "${REAL_USER:-}" ] || REAL_USER="deck"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[ -n "${REAL_HOME:-}" ] || REAL_HOME="/home/$REAL_USER"

# ── 允许补回的包(写死; 外加 root 属主的可选配置) ─────────────────────────
#   改这里要同步 check.sh 的注释理由: 这份清单是"提权面", 不是普通配置。
OPT_DEPS=(webkit2gtk-4.1 libayatana-appindicator)
CONF="/opt/steamos-backup/opt-deps.conf"

load_conf() {
    # 只读 root 属主的配置文件; 用户可写的配置一律不认(否则等于把提权面交出去)
    [ -f "$CONF" ] || return 0
    local own
    own="$(stat -c '%U' "$CONF" 2>/dev/null)"
    [ "$own" = "root" ] || { warn "忽略非 root 属主的依赖配置: $CONF(属主 $own)"; return 0; }
    local line
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        # 只接受纯包名字符, 挡掉 `"$(...)"` 之类的注入
        case "$line" in *[!A-Za-z0-9._+-]*) warn "配置里有非法包名, 跳过: $line"; continue ;; esac
        OPT_DEPS+=("$line")
    done < "$CONF"
}

# ── 有没有装过"便携化应用"(没装就不必补, 免得白装几百 MB) ──────────────
has_portable_app() {
    local d f m
    # ① install-deb-portable.sh 装的: 有 .deb-portable 清单
    for d in "$REAL_HOME"/.local/opt/*; do
        [ -f "$d/.deb-portable" ] && return 0
    done
    # ② install-app-home.sh 装的(如 clash-verge): 没有清单, 但**正缺库**也算
    #    (实测漏过一次: 只认清单会让这类应用升级后没人管)
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        m="$(ldd "$f" 2>/dev/null | grep -c 'not found')"
        [ "${m:-0}" -gt 0 ] && return 0
    done < <(find "$REAL_HOME/.local/opt" -maxdepth 4 -type f -executable 2>/dev/null | head -40)
    return 1
}

DO_CHECK=0
for a in "$@"; do
    case "$a" in
        --check) DO_CHECK=1 ;;
        *) warn "忽略参数: $a (本脚本不接受包名 —— 那是提权口子)" ;;
    esac
done

load_conf

if ! has_portable_app; then
    info "没有装过便携化应用(~/.local/opt/*/.deb-portable) → 无需补依赖"
    exit 0
fi

# ── 哪些真的缺 ──────────────────────────────────────────────────────────
MISSING=()
for p in "${OPT_DEPS[@]}"; do
    pacman -Qq "$p" >/dev/null 2>&1 || MISSING+=("$p")
done

if [ "${#MISSING[@]}" -eq 0 ]; then
    ok "依赖齐全: ${OPT_DEPS[*]}"
    exit 0
fi

warn "缺失(多半是原子升级冲掉的): ${MISSING[*]}"
sub "这些包在 /usr —— 每次大版本升级后都需要补回一次"

if [ "$DO_CHECK" -eq 1 ]; then
    sub "--check: 只读, 不做任何修改"
    exit 1
fi

# ── 动手前先看锁(补齐器/别的 pacman 在跑时不抢) ─────────────────────────
PACDB=""
for _c in /usr/lib/holo/pacmandb /var/lib/pacman; do
    [ -d "$_c" ] && { PACDB="$_c"; break; }
done
[ -n "$PACDB" ] || PACDB=/var/lib/pacman
if [ -e "$PACDB/db.lck" ]; then
    err "pacman 正被占用($PACDB/db.lck) —— 本次不动, 交给自愈定时器重试"
    exit 1
fi

# ── 安装(只装缺失的那几个; 仓库顺序以快照源优先, 见主脚本环境准备) ──────
info "补回依赖: ${MISSING[*]}"
if ! pacman -Sy --noconfirm >/dev/null 2>&1; then
    err "pacman -Sy 失败(多半是网络/源) —— 交给自愈定时器重试"
    exit 1
fi
# shellcheck disable=SC2086
if pacman -S --noconfirm --needed "${MISSING[@]}" 2>&1 | tail -3; then
    # 装完再复核一次: 没真装上就返回非 0, 让自愈链下次重试(不写"假成功")
    STILL=0
    for p in "${MISSING[@]}"; do pacman -Qq "$p" >/dev/null 2>&1 || STILL=1; done
    if [ "$STILL" -eq 0 ]; then
        ok "依赖已补回: ${MISSING[*]}"
        exit 0
    fi
fi
err "补依赖未成功 —— 交给自愈定时器重试"
exit 1
