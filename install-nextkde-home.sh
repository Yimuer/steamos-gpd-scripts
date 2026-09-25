#!/usr/bin/env bash
# ===========================================================================
#  install-nextkde-home.sh —— NextKde (KOS Desktop Shell) 装进 /home
# ---------------------------------------------------------------------------
#  NextKde 是什么: 一个基于 QuickShell 的 **KDE Plasma 桌面外壳**（顶栏 / Dock /
#  启动器 / 全局搜索 / 通知中心）。它替换的是 plasmashell 的界面层, KDE/KWin/
#  NetworkManager 等系统组件仍然保留。上游: https://github.com/SuceV587/NextKde
#
#  【本脚本的定位: 包装上游官方安装器, 不重写构建逻辑】
#  上游自带 `./tools/kosctl doctor|build|install|start|uninstall`, 会自己装依赖、
#  编译、处理 KWin 插件与 plasmashellrc。重写一遍没有任何好处 —— 这里只做三件
#  上游不做、而本项目在乎的事:
#    ① 前置检查(Plasma6 Wayland / KWin≥6.4 / quickshell), 缺什么先说清楚再动手
#    ② 源码与构建都放在 ~/.local/opt(=/home, 扛原子升级), 并记录构建时的 KWin 版本
#    ③ 把"会动系统哪些地方"讲明白, 并提供 --check 在升级后判定要不要重编
#
#  ⚠️ 三件必须先知道的事(上游行为, 不是本脚本加的):
#   · 会往 **rootfs** 装编译依赖(qt6/kf6/kwin 开发包/go/cmake/ninja…几百 MB):
#     原子升级会冲掉它们。升级后重跑本脚本即可自动补齐并重编(见 --check)。
#   · `kosctl install` 会把 `plasmashellrc` 的 `[Shell] ShellPackage` 指向 KOS,
#     即**切换桌面外壳**; 切换会让 plasmashell 另建 appletsrc → **壁纸会重置**
#     (上游会自动迁移旧的 appletsrc)。
#   · KWin 特效插件是**编译期**产物, 与 KWin 版本耦合: KWin 升级后可能需要重编,
#     严重时特效报错 —— 所以本脚本记录构建时的 KWin 版本供 --check 比对。
#
#  用法:
#    bash install-nextkde-home.sh              # 安装/修复(幂等; clone/更新 → doctor → install)
#    bash install-nextkde-home.sh --check      # 只读自检(含"KWin 是否已升级"判定)
#    bash install-nextkde-home.sh --doctor     # 只跑上游 doctor, 不动任何东西
#    bash install-nextkde-home.sh --apps       # 连可选应用(日历/待办/天气/音乐)一起装
#    bash install-nextkde-home.sh --no-plugins # 不装 KWin 插件/装饰(纯外壳, 依赖更少)
#    bash install-nextkde-home.sh --uninstall  # 调上游 uninstall 卸载
#    bash install-nextkde-home.sh --yes        # 跳过确认(非交互环境用)
#
#  环境变量: NEXTKDE_REPO(默认官方仓库) NEXTKDE_DIR(默认 ~/.local/opt/NextKde)
#            MIRROR(镜像前缀) KOS_BUILD_KWIN_PLUGINS=OFF 同 --no-plugins
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_I=$'\033[36m'; C_OK=$'\033[32m'; C_W=$'\033[33m'; C_E=$'\033[31m'; C_D=$'\033[2m'
info() { printf '%s[*]%s %s\n' "$C_I" "$C_R" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_OK" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_W" "$C_R" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_E" "$C_R" "$*" >&2; }
sub()  { printf '    %s\n' "$*"; }
step() { printf '\n%s════════ %s ════════%s\n' "$C_D" "$1" "$C_R"; }

# ── 运行身份 ───────────────────────────────────────────────────────────
if [ "$(id -u)" -eq 0 ]; then
    REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
else
    REAL_USER="$(id -un)"
fi
[ -n "${REAL_USER:-}" ] || REAL_USER="deck"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[ -n "${REAL_HOME:-}" ] || REAL_HOME="/home/$REAL_USER"

NEXTKDE_REPO="${NEXTKDE_REPO:-https://github.com/SuceV587/NextKde}"
NEXTKDE_DIR="${NEXTKDE_DIR:-$REAL_HOME/.local/opt/NextKde}"
KOSCTL="$NEXTKDE_DIR/tools/kosctl"
KWIN_STAMP="$NEXTKDE_DIR/.kwin-version-at-build"
NEEDED_PKGS=(git quickshell cmake ninja gcc go qt6-base qt6-declarative \
             kwindowsystem kiconthemes kglobalaccel extra-cmake-modules kwin \
             kconfig ki18n kguiaddons kcmutils kcoreaddons kdecoration gettext \
             libxcb vulkan-headers)

run_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif command -v sudo >/dev/null 2>&1; then sudo "$@"
    else err "需要 root 但本机没有 sudo"; return 1; fi
}
have() { command -v "$1" >/dev/null 2>&1; }

kwin_version() {
    # 依次试: kwin_wayland --version → pacman → plasmashell; 取不到就留空(不阻断)
    local v=""
    if have kwin_wayland; then
        v="$(kwin_wayland --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    fi
    [ -n "$v" ] || v="$(pacman -Q kwin 2>/dev/null | awk '{print $2}' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    [ -n "$v" ] || v="$(plasmashell --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    printf '%s\n' "$v"
}

# ── 前置检查 ───────────────────────────────────────────────────────────
preflight() {
    local bad=0 v
    info "前置检查(上游要求: Plasma 6 Wayland 会话 + KWin ≥ 6.4 + Quickshell 0.3.x)"

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        ok "会话类型: wayland"
    else
        warn "当前不是 Wayland 会话(XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-空})"
        sub "NextKde 需要 Plasma 6 Wayland 会话; 装好后请用 Wayland 会话登录"
    fi
    case "${XDG_CURRENT_DESKTOP:-}" in
        *KDE*) ok "桌面: $XDG_CURRENT_DESKTOP" ;;
        "")    sub "(读不到 XDG_CURRENT_DESKTOP, 跳过桌面判定)" ;;
        *)     warn "当前桌面是 $XDG_CURRENT_DESKTOP —— 本外壳是给 KDE Plasma 用的" ;;
    esac

    v="$(kwin_version)"
    if [ -n "$v" ]; then
        case "$v" in
            6.4*|6.[5-9]*|[7-9].*) ok "KWin 版本: $v (≥6.4 ✔)" ;;
            *) warn "KWin 版本 $v 低于 6.4 —— 上游要求 ≥6.4, 可能不工作"; bad=1 ;;
        esac
    else
        sub "(读不到 KWin 版本, 跳过判定)"
    fi

    if have qs || pacman -Qq quickshell >/dev/null 2>&1; then
        ok "Quickshell 已装"
    else
        warn "Quickshell 未装(上游依赖, Arch 官方 extra 里有: sudo pacman -S quickshell)"
        bad=1
    fi

    if have git; then ok "git 已装"; else warn "缺 git(要 clone 源码)"; bad=1; fi
    return "$bad"
}

# ── 列出缺的编译依赖 ───────────────────────────────────────────────────
missing_pkgs() {
    local p
    have pacman || return 0
    for p in "${NEEDED_PKGS[@]}"; do
        pacman -Qq "$p" >/dev/null 2>&1 || printf '%s\n' "$p"
    done
}

# ── 确认(改桌面外壳是显眼动作, 先说清后果) ─────────────────────────────
confirm() {
    if [ "${ASSUME_YES:-0}" -eq 1 ]; then return 0; fi
    echo
    warn "接下来会做三件会改变系统的事:"
    sub "① 往 **rootfs** 装编译依赖(qt6/kf6/kwin 开发包 + go/cmake/ninja…几百 MB)"
    sub "    → 原子升级会冲掉; 升级后重跑本脚本即可补齐重编"
    sub "② 把 plasmashellrc 的 ShellPackage 指向 KOS(**切换桌面外壳**)"
    sub "    → 切换会让 plasmashell 另建 appletsrc, **壁纸会重置**(上游会自动迁移旧的)"
    sub "③ 编译并安装 KWin 特效插件(编译期产物, 与 KWin 版本耦合; 想跳过用 --no-plugins)"
    echo
    if [ -t 0 ]; then
        echo -n "确认继续？输入 yes: "
        local a; read -r a
        [ "$a" = "yes" ] || { info "已取消"; return 1; }
    else
        err "非交互环境(没有终端) —— 请在有终端的窗口里跑, 或显式加 --yes"
        return 1
    fi
}

# ── 安装 ───────────────────────────────────────────────────────────────
do_install() {
    preflight || warn "前置检查有告警项(不阻断, 上游 kosctl install 也会再查一遍)"

    step "取源码 → $NEXTKDE_DIR (在 /home, 扛原子升级)"
    mkdir -p "$(dirname "$NEXTKDE_DIR")" || return 1
    if [ -d "$NEXTKDE_DIR/.git" ]; then
        sub "已有仓库 → git pull"
        if git -C "$NEXTKDE_DIR" pull --ff-only 2>/dev/null; then
            ok "已更新到 $(git -C "$NEXTKDE_DIR" log -1 --format=%h)"
        else
            warn "git pull 失败(本地有改动? 镜像不通?) —— 继续用现有源码"
            sub "如需强制同步: git -C $NEXTKDE_DIR fetch && git -C $NEXTKDE_DIR reset --hard origin/main"
        fi
    else
        local url="$NEXTKDE_REPO"
        [ -n "${MIRROR:-}" ] && sub "镜像前缀: $MIRROR"
        # 直连 GitHub 在境内常失败 → 依次试镜像
        local u
        for u in "$url" "${MIRROR:+${MIRROR%/}/$url}" "https://gh-proxy.com/$url"; do
            [ -n "$u" ] || continue
            sub "clone: $u"
            if git clone --depth 1 "$u" "$NEXTKDE_DIR" 2>/dev/null; then ok "克隆完成"; break; fi
            rm -rf "${NEXTKDE_DIR:?}"; warn "  该源失败, 换下一个"
        done
        [ -x "$KOSCTL" ] || { err "克隆失败(或仓库结构变了: 没有 tools/kosctl)"; return 1; }
    fi
    [ -x "$KOSCTL" ] || die_help "上游没有 tools/kosctl —— 它的安装方式变了, 请改本脚本"

    local miss; miss="$(missing_pkgs)"
    if [ -n "$miss" ]; then
        warn "缺编译依赖(将装进 rootfs, 升级会被冲): $(printf '%s ' $miss)"
    else
        ok "编译依赖齐备"
    fi

    confirm || return 1

    step "上游 doctor(体检)"
    ( cd "$NEXTKDE_DIR" && ./tools/kosctl doctor ) || warn "doctor 报告了告警项(继续, 让 install 去解决)"

    step "上游 install(装依赖 + 编译 + 安装)"
    sub "上游会在需要时提示安装缺的 Arch 包"
    if ! ( cd "$NEXTKDE_DIR" && ./tools/kosctl install ); then
        err "kosctl install 失败 —— 按上面的输出处理(常见: 缺依赖 / KWin 版本太低 / 网络)"
        return 1
    fi

    # 记录构建时的 KWin 版本: 以后 KWin 升级了就能判定"插件要重编"
    local kv; kv="$(kwin_version)"
    printf '%s\n' "${kv:-unknown}" >"$KWIN_STAMP" 2>/dev/null || true
    ok "已记录构建时的 KWin 版本: ${kv:-未知}"

    echo
    echo "════════ 完成 ════════"
    echo "  源码/构建: $NEXTKDE_DIR   (在 /home → 升级幸存)"
    echo "  · 登录后 KOS 会自动启动; 想立刻切换桌面外壳: ./tools/kosctl start"
    echo "  · **注销重登**一次让外壳生效(壁纸可能重置, 上游会自动迁移旧配置)。"
    echo "  · 原子升级后请跑: bash $(basename "$0") --check"
    echo "    (它会告诉你依赖是否被冲、KWin 是否变了、要不要重编)"
}

die_help() { err "$*"; exit 1; }

# ── 自检 ───────────────────────────────────────────────────────────────
do_check() {
    local f=0 kv stamp
    echo "════════ NextKde(KOS) 自检 ════════"
    echo "源码/构建目录: $NEXTKDE_DIR"

    if [ ! -d "$NEXTKDE_DIR" ]; then
        err "没装: 目录不存在"; sub "→ bash $(basename "$0")"; return 1
    fi
    # 外壳的落地物: kosctl install 会把 shell 装到 ~/.local/share/... 并在 plasmashellrc 里指过去
    local shpkg=""
    [ -f "$REAL_HOME/.config/plasmashellrc" ] \
        && shpkg="$(sed -n 's/^ShellPackage=//p' "$REAL_HOME/.config/plasmashellrc" | head -1)"
    if printf '%s' "$shpkg" | grep -qi kos; then
        ok "plasmashellrc 已指向 KOS: $shpkg"
    else
        warn "plasmashellrc 里的 ShellPackage 不是 KOS(当前: ${shpkg:-未设置})"
        sub "→ 若刚装完还没登录, 属正常; 否则重跑安装"
    fi

    local miss; miss="$(missing_pkgs)"
    if [ -n "$miss" ]; then
        err "编译依赖缺失(多半是原子升级冲掉了 rootfs): $(printf '%s ' $miss)"
        sub "→ 重跑 bash $(basename "$0") 即可自动补齐并重编"
        f=1
    else
        ok "编译依赖齐备"
    fi

    kv="$(kwin_version)"; stamp="$(cat "$KWIN_STAMP" 2>/dev/null || echo '')"
    if [ -n "$stamp" ] && [ "$stamp" != "unknown" ] && [ -n "$kv" ]; then
        if [ "$stamp" = "$kv" ]; then
            ok "KWin 版本未变($kv): KWin 插件仍然匹配"
        else
            warn "KWin 已从 $stamp 变成 $kv —— KWin 特效插件是编译期产物, 可能不兼容"
            sub "→ 建议重跑 bash $(basename "$0")(会重新编译插件)"
            sub "  若特效报错或 KWin 不稳, 先临时停用: 系统设置 → 窗口管理 → 特效"
            f=1
        fi
    else
        sub "(没有构建时的 KWin 版本记录, 跳过版本比对)"
    fi

    have qs || pacman -Qq quickshell >/dev/null 2>&1 \
        && ok "Quickshell 在" || { err "Quickshell 不在(升级冲掉了)"; f=1; }

    echo
    if [ "$f" -eq 0 ]; then echo "════ 结论: 就绪 ════"; return 0; fi
    echo "════ 结论: 需要处理 → 见上面的 → 提示 ════"; return 1
}

# ── 直达上游子命令 ─────────────────────────────────────────────────────
passthrough() {
    [ -x "$KOSCTL" ] || { err "没装(找不到 $KOSCTL) —— 先跑 bash $(basename "$0")"; return 1; }
    info "转发给上游: kosctl $*"
    ( cd "$NEXTKDE_DIR" && ./tools/kosctl "$@" )
}

main() {
    MODE=install; ASSUME_YES=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --check) MODE=check ;;
            --doctor) MODE=doctor ;;
            --apps) MODE=apps ;;
            --uninstall) MODE=uninstall ;;
            --yes|-y) ASSUME_YES=1 ;;
            --no-plugins) KOS_BUILD_KWIN_PLUGINS=OFF; export KOS_BUILD_KWIN_PLUGINS ;;
            -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) err "未知参数: $1"; exit 2 ;;
        esac
        shift
    done
    case "$MODE" in
        check)     do_check ;;
        doctor)    passthrough doctor ;;
        apps)      passthrough install apps ;;
        uninstall) passthrough uninstall ;;
        install)   do_install ;;
    esac
}
main "$@"
