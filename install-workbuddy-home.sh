#!/usr/bin/env bash
# ===========================================================================
#  install-workbuddy-home.sh
#  让 SteamOS 上的 WorkBuddy 既「原生无沙箱」又「扛原子升级」
# ---------------------------------------------------------------------------
#  【要解决的问题】
#  官方 Linux 只发 .deb，AUR 的 workbuddy 包在本地解包后装到 /opt/WorkBuddy，
#  入口是 /usr/bin/workbuddy，运行时用系统 electron。而 SteamOS 的 A/B 原子
#  升级会整块替换 rootfs，于是升级后：
#     · 幸存的：/opt/WorkBuddy 本体
#       —— SteamOS 把 /opt bind-mount 到 /home 分区
#          (/home/.steamos/offload/opt)，物理上根本不在 rootfs 里。
#          /usr/local 同理也是 offload 的。
#     · 被冲掉的：/usr/bin/workbuddy(入口) + /usr 里的系统 electron(运行时)
#                 + pacman 数据库记录(导致 pacman -Qq workbuddy 判为"没装")
#  结果：主体还在，但没有运行时、没有入口 —— 看起来就像"被整个冲掉了"。
#
#  【本脚本的对策】
#  把"会被冲掉"的那部分整体搬进 /home，从此与 /usr、pacman 解耦：
#     ~/.local/opt/wb-electron/                     自带 electron 运行时
#     ~/.local/bin/workbuddy                        入口 wrapper(含 Wayland IME 参数)
#     ~/.local/share/applications/workbuddy.desktop 桌面入口
#     ~/.local/share/icons/workbuddy.png            图标(一起搬，否则升级后图标也没)
#  → 原子升级后 WorkBuddy 直接可用，零操作、不需要 pacman。
#
#  【三条不要】
#   1. 不要把 /opt/WorkBuddy 挪进 /home —— AUR 包在 build() 里把 app 内的
#      process.resourcesPath 硬替换成了字面量 '/opt/WorkBuddy'，挪走必崩；
#      而 /opt 本来就在 /home 分区上，本来就不会被冲。只搬"被冲的那部分"。
#   2. 不要用 Discover/Flatpak 版 —— flatpak 的 bubblewrap 沙箱会挡掉 /etc、
#      systemd 等，正是"无法直接操作系统"的来源。本脚本假设走 AUR 原生版。
#      若机器上存在 flatpak 版，本脚本会提示卸载，避免两个入口混用。
#   3. 不要把入口写回 /usr/bin —— 写回去就等于把命脉重新交给会被冲的 rootfs。
#
#  【用法】
#    bash install-workbuddy-home.sh                # 安装/修复(幂等)
#    bash install-workbuddy-home.sh --check        # 只读自检(升级后先跑这个)
#    bash install-workbuddy-home.sh --sandbox-off  # 关掉 WorkBuddy 的命令沙箱
#    WB_IME=wayland3|x11 bash install-workbuddy-home.sh   # 切输入法参数(同主脚本)
#
#  【前置】
#    /opt/WorkBuddy 已存在。若不在，先跑 `sudo bash steamos-setup.sh 3` 把主体
#    装回来，再回来跑本脚本。
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_I=$'\033[36m'; C_OK=$'\033[32m'; C_W=$'\033[33m'; C_E=$'\033[31m'
info() { printf '%s[*]%s %s\n' "$C_I" "$C_R" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_OK" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_W" "$C_R" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_E" "$C_R" "$*" >&2; }
sub()  { printf '    %s\n' "$*"; }

# ── 运行身份 / 家目录(以 sudo 或普通用户跑都要能定位真用户) ──────────────
if [ "$(id -u)" -eq 0 ]; then
    REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
else
    REAL_USER="$(id -un)"
fi
[ -n "${REAL_USER:-}" ] || REAL_USER="deck"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[ -n "${REAL_HOME:-}" ] || REAL_HOME="/home/$REAL_USER"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"

APP_DIR="/opt/WorkBuddy"
APP_ENTRY="$APP_DIR/app.asar.unpacked"
WB_LOCAL="$REAL_HOME/.local"
WB_ELECTRON="$WB_LOCAL/opt/wb-electron"
WB_BIN="$WB_LOCAL/bin/workbuddy"
WB_DESKTOP="$WB_LOCAL/share/applications/workbuddy.desktop"
WB_ICON="$WB_LOCAL/share/icons/workbuddy.png"
WB_SETTINGS="$REAL_HOME/.workbuddy/settings.json"
ASKPASS="/tmp/wb-home-askpass.sh"

# ── 提权助手: 有终端就直接 sudo; 无终端(桌面图标启动)弹 kdialog 密码框 ──
run_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
    if [ -t 0 ]; then sudo "$@"; return $?; fi
    if ! command -v kdialog >/dev/null 2>&1; then
        err "需要 root，但当前没有终端可输密码、也找不到 kdialog。请在 Konsole 里手动跑本脚本。"
        return 1
    fi
    cat >"$ASKPASS" <<'EOF'
#!/usr/bin/env bash
exec kdialog --title "WorkBuddy 迁入 /home" --password "需要管理员权限，请输入登录密码："
EOF
    chmod 700 "$ASKPASS"
    SUDO_ASKPASS="$ASKPASS" sudo -A "$@"
    local rc=$?
    rm -f "$ASKPASS"
    return $rc
}

# ── 定位系统 electron 的真实二进制(/usr/bin/electron 只是个包装) ─────────
find_electron_bin() {
    local w="/usr/bin/electron" t d
    if [ -e "$w" ]; then
        t="$(readlink -f "$w" 2>/dev/null || true)"
        case "$t" in
            */electron) [ -x "$t" ] && { printf '%s\n' "$t"; return 0; } ;;
        esac
        t="$(grep -oE '/usr/lib/[^ ]*/electron' "$w" 2>/dev/null | head -n1 || true)"
        [ -n "$t" ] && [ -x "$t" ] && { printf '%s\n' "$t"; return 0; }
    fi
    for d in /usr/lib/electron /usr/lib/electron[0-9]*; do
        [ -x "$d/electron" ] && { printf '%s\n' "$d/electron"; return 0; }
    done
    return 1
}

# ── 定位图标(优先系统安装的 hicolor，其次 app 目录里翻) ─────────────────
find_icon() {
    local p
    p="$(ls -1 /usr/share/icons/hicolor/*/apps/workbuddy.png 2>/dev/null | sort -V | tail -n1 || true)"
    [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    [ -d "$APP_DIR" ] || return 1
    p="$(find "$APP_DIR" -maxdepth 4 -type f \
            \( -iname 'workbuddy.png' -o -iname 'icon.png' \) 2>/dev/null | head -n1 || true)"
    [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    return 1
}

opt_mount()   { findmnt -no SOURCE --target /opt 2>/dev/null || true; }
root_mount()  { findmnt -no SOURCE --target / 2>/dev/null || true; }
usrsrc_mount(){ findmnt -no SOURCE --target /usr/local 2>/dev/null || true; }

# ── 沙箱状态(读 ~/.workbuddy/settings.json) ─────────────────────────────
sandbox_state() {
    [ -f "$WB_SETTINGS" ] || { echo "无配置"; return; }
    command -v python3 >/dev/null 2>&1 || { echo "未知(无 python3)"; return; }
    python3 - "$WB_SETTINGS" <<'PY' 2>/dev/null || echo "解析失败"
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:
    print("解析失败"); raise SystemExit
sb=d.get('sandbox') if isinstance(d,dict) else None
if not isinstance(sb,dict) or 'enabled' not in sb:
    print("未设置(跟随默认)")
elif sb.get('enabled'):
    print("开启 ← 受限!")
else:
    print("已关闭")
PY
}

# ===========================================================================
#  --check : 只读自检(升级后跑这个就知道还能不能直接启动)
# ===========================================================================
do_check() {
    local fail=0 ebin om rm
    echo "════════ WorkBuddy /home 自持形态 自检 ════════"
    echo "用户: $REAL_USER   家目录: $REAL_HOME"

    om="$(opt_mount)"; rm="$(root_mount)"
    if [ -n "$om" ] && [ "$om" != "$rm" ]; then
        ok "/opt 独立挂载: $om"
        sub "→ 主体在 /home 分区上，原子升级不会冲掉它"
    else
        warn "/opt 与 / 同一文件系统($rm) —— 主体会占 rootfs 且升级会一起丢"
        sub "→ SteamOS 正常应 offload 到 /.steamos/offload/opt，请先确认该机制在生效"
        fail=1
    fi

    if [ -d "$APP_ENTRY" ]; then
        ok "主体 $APP_ENTRY 存在 ($(du -sh "$APP_DIR" 2>/dev/null | cut -f1))"
    else
        err "主体缺失: $APP_ENTRY"
        sub "→ 跑: sudo bash steamos-setup.sh 3   (装回主体，再回来跑本脚本)"
        fail=1
    fi

    if [ -x "$WB_ELECTRON/electron" ]; then
        ok "自带运行时 $WB_ELECTRON ($(du -sh "$WB_ELECTRON" 2>/dev/null | cut -f1))"
    else
        err "自带运行时缺失: $WB_ELECTRON/electron"
        sub "→ 跑: bash install-workbuddy-home.sh   (补上)"
        fail=1
    fi

    if [ -x "$WB_BIN" ]; then
        ok "入口 $WB_BIN"
    else
        err "入口缺失: $WB_BIN"
        fail=1
    fi

    if [ -f "$WB_DESKTOP" ] && [ -f "$WB_ICON" ]; then
        ok "桌面入口 + 图标就绪"
    else
        warn "桌面入口或图标不全(菜单里可能看不到/没图标)"
        [ -f "$WB_DESKTOP" ] || fail=1
    fi

    if [ -e /usr/bin/workbuddy ]; then
        info "系统入口 /usr/bin/workbuddy 也在(升级后它会消失，属正常; 本形态不依赖它)"
    else
        info "系统入口 /usr/bin/workbuddy 不在 —— 正常，本形态不依赖它"
    fi

    ebin="$(find_electron_bin || true)"
    if [ -n "$ebin" ]; then
        info "系统 electron: $ebin (仅作下次拷贝的源)"
    else
        info "系统 electron 未安装 —— 无妨，自带运行时已在 /home"
    fi

    info "WorkBuddy 命令沙箱: $(sandbox_state)"
    sub "要放开: bash install-workbuddy-home.sh --sandbox-off"

    if command -v flatpak >/dev/null 2>&1 && flatpak list --user --app 2>/dev/null | grep -qi workbuddy; then
        warn "检测到 flatpak 版 WorkBuddy —— 它被 bubblewrap 关在沙箱里，无法直接操作系统"
        sub "建议卸载后只用原生版: flatpak uninstall --user <app-id>"
    fi

    echo
    if [ "$fail" -eq 0 ]; then
        echo "════ 结论: 可用，且原子升级后应自动幸存 ════"
        return 0
    fi
    echo "════ 结论: 有缺件，按上面提示补齐 ════"
    return 1
}

# ===========================================================================
#  --sandbox-off : 关掉 WorkBuddy 自身的命令沙箱(安全合并, 先备份)
# ===========================================================================
do_sandbox_off() {
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$(dirname "$WB_SETTINGS")"
    [ -f "$WB_SETTINGS" ] || printf '{}\n' >"$WB_SETTINGS"
    cp -a "$WB_SETTINGS" "$WB_SETTINGS.bak.$ts" || { err "备份失败，中止"; return 1; }
    info "已备份 → $WB_SETTINGS.bak.$ts"
    if ! command -v python3 >/dev/null 2>&1; then
        err "需要 python3 才能安全合并 JSON。手动加这段即可:"
        sub '"sandbox": { "enabled": false, "allowUnsandboxedCommands": true }'
        return 1
    fi
    python3 - "$WB_SETTINGS" <<'PY' || { err "写入失败"; return 1; }
import json,sys
p=sys.argv[1]
try:
    d=json.load(open(p,encoding='utf-8'))
except Exception:
    d={}
if not isinstance(d,dict): d={}
sb=d.get('sandbox')
if not isinstance(sb,dict): sb={}
sb['enabled']=False
sb['allowUnsandboxedCommands']=True
sb['autoAllowBashIfSandboxed']=True
d['sandbox']=sb
perm=d.get('permissions')
if not isinstance(perm,dict): perm={}
perm.setdefault('defaultMode','acceptEdits')
d['permissions']=perm
with open(p,'w',encoding='utf-8') as fh:
    json.dump(d,fh,ensure_ascii=False,indent=2); fh.write('\n')
PY
    ok "已写入 sandbox.enabled=false (保留其余设置)"
    sub "现在状态: $(sandbox_state)"
    echo
    warn "必须【彻底退出】WorkBuddy 再重开(托盘右键退出 / pkill -f WorkBuddy)，否则不生效。"
    warn "若设置界面里有「沙箱」开关，以界面为准；界面与文件冲突时界面会被回写。"
}

# ===========================================================================
#  安装 / 修复
# ===========================================================================
do_install() {
    local ebin src_dir icon sc

    echo "════════ 把 WorkBuddy 的入口与运行时迁进 /home ════════"

    # ── 1. 主体在位性 ──────────────────────────────────────────────
    if [ ! -d "$APP_ENTRY" ]; then
        err "找不到 $APP_ENTRY —— 主体不在，本脚本无源可依。"
        warn "先跑: sudo bash steamos-setup.sh 3   (AUR 版重建主体)"
        warn "装完再回来跑: bash $(basename "$0")"
        return 1
    fi
    ok "主体在位: $APP_DIR ($(du -sh "$APP_DIR" 2>/dev/null | cut -f1))"

    # ── 2. offload 提示(仅提示，不阻断) ────────────────────────────
    local om rm
    om="$(opt_mount)"; rm="$(root_mount)"
    if [ -n "$om" ] && [ "$om" != "$rm" ]; then
        info "/opt 已 offload 到 $om → 主体扛得住原子升级"
    else
        warn "/opt 与 / 同分区: 原子升级会连主体一起冲掉，本形态只能省掉『重装运行时/入口』这一步"
    fi
    if [ -n "$(usrsrc_mount)" ] && [ "$(usrsrc_mount)" != "$rm" ]; then
        info "/usr/local 也是 offload 的 → 稍后在那放个软链做 PATH 兜底"
    fi

    # ── 3. 自带 electron 运行时 ────────────────────────────────────
    echo
    if [ -x "$WB_ELECTRON/electron" ]; then
        ok "自带运行时已存在，跳过拷贝: $WB_ELECTRON"
    else
        ebin="$(find_electron_bin || true)"
        if [ -z "$ebin" ]; then
            err "系统没装 electron，也无自带运行时 —— 二者必须有一个。"
            warn "先装一次(装完就跑本脚本，之后不再依赖它):"
            sub "sudo pacman -S --needed electron"
            return 1
        fi
        src_dir="$(dirname "$ebin")"
        info "拷贝 electron 运行时: $src_dir → $WB_ELECTRON"
        sub "(约 300MB, 落在 /home 分区; 一次性, 之后升级不再需要 /usr 的 electron)"
        mkdir -p "$WB_ELECTRON" || return 1
        if ! cp -a "$src_dir/." "$WB_ELECTRON/"; then
            err "拷贝失败"
            return 1
        fi
        # chrome-sandbox 需要 setuid root，否则 Chromium 沙箱层会报错(内核允许
        # 非特权 userns 时用不到它，故失败不致命)
        if [ -f "$WB_ELECTRON/chrome-sandbox" ]; then
            if run_root chown root:root "$WB_ELECTRON/chrome-sandbox" \
               && run_root chmod 4755 "$WB_ELECTRON/chrome-sandbox"; then
                ok "chrome-sandbox 已设 setuid"
            else
                warn "chrome-sandbox setuid 未设成(通常仍可启动: 内核 userns 生效时用它不到)"
            fi
        fi
        [ "$(id -u)" -eq 0 ] && chown -R "$REAL_USER:$REAL_GROUP" "$WB_ELECTRON" 2>/dev/null
        ok "运行时就绪: $WB_ELECTRON"
    fi
    [ -x "$WB_ELECTRON/electron" ] || { err "运行时校验失败"; return 1; }

    # ── 4. 入口 wrapper(含 Wayland IME 参数, 与主脚本 setup_wb 同口径) ──
    echo
    local WB_IME_MODE="${WB_IME:-wayland}"
    local FLAGS="" MARKTXT=""
    case "$WB_IME_MODE" in
        wayland3)
            FLAGS='--enable-features=UseOzonePlatform --ozone-platform=wayland --enable-wayland-ime --wayland-text-input-version=3'
            MARKTXT="text-input-v3"
            warn "WB_IME=wayland3: KWin 下候选框可能错位，非必要勿用"
            ;;
        x11)
            FLAGS=""
            MARKTXT="XWayland(不加 ozone 参数)"
            info "WB_IME=x11: 走 XWayland，靠 GTK_IM_MODULE/XMODIFIERS 接管"
            ;;
        *)
            FLAGS='--enable-features=UseOzonePlatform --ozone-platform=wayland --enable-wayland-ime'
            MARKTXT="text-input-v1(KWin/Electron 官方推荐)"
            ;;
    esac
    mkdir -p "$(dirname "$WB_BIN")" || return 1
    {
        printf '#!/usr/bin/env bash\n'
        printf '# 由 install-workbuddy-home.sh 生成 —— WorkBuddy 的 /home 自持入口\n'
        printf '# 自带 electron 运行时, 不依赖 /usr 的 electron, 原子升级后依然可用。\n'
        printf '# 改输入法参数请重跑: WB_IME=wayland3|x11 bash install-workbuddy-home.sh\n'
        printf 'WB_RUNTIME="${HOME}/.local/opt/wb-electron"\n'
        printf 'APP_DIR="/opt/WorkBuddy/app.asar.unpacked"\n'
        if [ -n "$FLAGS" ]; then
            printf 'exec "$WB_RUNTIME/electron" "$APP_DIR" %s "$@"\n' "$FLAGS"
        else
            printf 'exec "$WB_RUNTIME/electron" "$APP_DIR" "$@"\n'
        fi
    } >"$WB_BIN"
    chmod 755 "$WB_BIN"
    if bash -n "$WB_BIN"; then
        ok "入口就绪: $WB_BIN  (IME=$WB_IME_MODE $MARKTXT)"
    else
        err "生成的入口语法有误，已中止"
        rm -f "$WB_BIN"
        return 1
    fi

    # ── 5. 桌面入口 + 图标(一起搬, 否则升级后菜单里只剩个没图标的空壳) ──
    echo
    sc="$(grep -i '^StartupWMClass=' /usr/share/applications/workbuddy.desktop 2>/dev/null \
          | head -n1 | cut -d= -f2- || true)"
    [ -n "$sc" ] || sc="WorkBuddy"
    mkdir -p "$(dirname "$WB_DESKTOP")" "$(dirname "$WB_ICON")" || return 1
    if icon="$(find_icon)"; then
        cp -f "$icon" "$WB_ICON" && ok "图标已搬到 /home: $WB_ICON (源自 $icon)"
    else
        warn "没找到图标；桌面项将不带图标。可稍后手动放一张 PNG 到 $WB_ICON"
    fi
    {
        printf '[Desktop Entry]\n'
        printf 'Type=Application\n'
        printf 'Name=WorkBuddy\n'
        printf 'Comment=腾讯 AI Agent 办公工作台(原生, 无沙箱)\n'
        printf 'Exec=%s %%U\n' "$WB_BIN"
        [ -f "$WB_ICON" ] && printf 'Icon=%s\n' "$WB_ICON"
        printf 'Terminal=false\n'
        printf 'Categories=Utility;Office;\n'
        printf 'StartupWMClass=%s\n' "$sc"
        printf 'StartupNotify=true\n'
    } >"$WB_DESKTOP"
    chmod 644 "$WB_DESKTOP"
    ok "桌面入口就绪: $WB_DESKTOP"
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$(dirname "$WB_DESKTOP")" >/dev/null 2>&1 || true
    fi

    # ── 6. /usr/local/bin 兜底软链(可选; /usr/local 也 offload, 同样扛升级) ──
    echo
    if [ -n "$(usrsrc_mount)" ] && [ "$(usrsrc_mount)" != "$rm" ]; then
        if run_root ln -sfn "$WB_BIN" /usr/local/bin/workbuddy; then
            ok "/usr/local/bin/workbuddy → $WB_BIN (PATH 里的命令行入口, 同样扛升级)"
        else
            warn "软链创建失败；不影响图形菜单启动"
        fi
    else
        info "跳过 /usr/local 软链(/usr/local 不是独立挂载, 放那也会被冲)"
    fi

    # ── 7. flatpak 版共存提醒 ─────────────────────────────────────
    if command -v flatpak >/dev/null 2>&1 && flatpak list --user --app 2>/dev/null | grep -qi workbuddy; then
        echo
        warn "机器上还有 flatpak 版 WorkBuddy(沙箱内, 碰不到系统)。建议卸载以免混用:"
        flatpak list --user --app 2>/dev/null | grep -i workbuddy | sed 's/^/    /'
    fi

    [ "$(id -u)" -eq 0 ] && chown -R "$REAL_USER:$REAL_GROUP" "$WB_LOCAL/bin" "$WB_LOCAL/share" 2>/dev/null

    # ── 8. 收尾 ───────────────────────────────────────────────────
    echo
    echo "════════ 完成 ════════"
    echo "  入口(图形菜单): $WB_DESKTOP"
    echo "  入口(命令行)  : $WB_BIN"
    echo "  运行时        : $WB_ELECTRON"
    echo "  主体(已幸存)  : $APP_DIR"
    echo
    echo "  · 原子升级后: 直接能用, 零操作。升级后想确认就跑 --check。"
    echo "  · 改输入法参数: WB_IME=wayland3|x11 bash $(basename "$0") 后重启 WorkBuddy"
    echo "  · 关命令沙箱  : bash $(basename "$0") --sandbox-off"
    echo "  · 首次务必彻底退出 WorkBuddy 再重开(托盘→退出)。"
}

# ===========================================================================
main() {
    case "${1:-}" in
        -h|--help)
            sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
            ;;
        --check)       do_check ;;
        --sandbox-off) do_sandbox_off ;;
        "")            do_install ;;
        *) err "未知参数: $1 (可用: --check / --sandbox-off / --help)"; exit 2 ;;
    esac
}
main "$@"
