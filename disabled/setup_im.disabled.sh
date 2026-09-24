# ===========================================================================
#  [2] setup_im 原始实现 —— 已禁用存档 (2026-09-24)
#  用户要求: 不改动原系统(SteamOS)输入法相关的任何内容。
#  本文件仅留档, 不会被 steamos-setup.sh 的任何路径执行。
#  如需恢复: 把本文件内容覆盖回 steamos-setup.sh 中 setup_im 的位置。
# ===========================================================================
setup_im() {
    step "[2/7] IBus 原生输入法 + 中文引擎"
    prepare "$@"

    local ENVD_DIR="$REAL_HOME/.config/environment.d"
    local AUTOSTART_DIR="$REAL_HOME/.config/autostart"
    local FISH_CONF="$REAL_HOME/.config/fish/conf.d"
    local IBUS_PANEL="/usr/share/applications/org.freedesktop.IBus.Panel.Wayland.Gtk3.desktop"
    local IBUS_ENGINE="${IBUS_ENGINE:-libpinyin}"
    local ENGINE_NAME=""

    mkdir -p "$ENVD_DIR" "$AUTOSTART_DIR" "$FISH_CONF"

    # 从已安装的引擎组件里解析真实 engine name(避免写死)
    pick_zh_engine() {
        local want f
        for want in "$@"; do
            for f in /usr/share/ibus/component/*.xml; do
                grep -q "<name>$want</name>" "$f" 2>/dev/null && { echo "$want"; return 0; }
            done
        done
        echo ""
    }

    # ---- 0) 清理旧 fcitx5 残留(改方案后必须清, 否则两套打架) ----
    sub "清理 fcitx5 残留配置..."
    rm -f "$ENVD_DIR/fcitx5.conf" "$FISH_CONF/fcitx5.fish" 2>/dev/null
    if [ -f /etc/xdg/autostart/org.fcitx.Fcitx5.desktop ] ||
       [ -f /usr/share/applications/org.fcitx.Fcitx5.desktop ]; then
        cat > "$AUTOSTART_DIR/org.fcitx.Fcitx5.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5 (disabled)
Hidden=true
EOF
        info "已屏蔽 fcitx5 自启动"
    fi
    pacman -Qq fcitx5 >/dev/null 2>&1 &&
        warn "检测到已装 fcitx5(本脚本不再安装)。如需清理: sudo pacman -Rns fcitx5 fcitx5-rime" || true

    # ---- 1) 确保 ibus 与中文引擎 ----
    sub "检查 ibus(SteamOS 自带)..."
    pacman -S --noconfirm --needed ibus 2>&1 | tail -2 || warn "ibus 安装异常(通常已自带)"

    case "$IBUS_ENGINE" in
        rime)
            sub "安装 ibus-rime(需 archlinuxcn)..."
            pacman -S --noconfirm --needed ibus-rime 2>&1 | tail -3 \
                || warn "ibus-rime 装不上: 先跑第[1]步配 archlinuxcn, 或改用 IBUS_ENGINE=libpinyin"
            ;;
        pinyin)
            pacman -S --noconfirm --needed ibus-pinyin 2>&1 | tail -2 || warn "ibus-pinyin 安装失败"
            ;;
        *)
            sub "安装 ibus-libpinyin(官方 extra, 支持小鹤双拼)..."
            pacman -S --noconfirm --needed ibus-libpinyin 2>&1 | tail -3 \
                || warn "ibus-libpinyin 装不上(确认 extra 源), 回退 ibus-pinyin"
            pacman -Qq ibus-libpinyin >/dev/null 2>&1 || \
                pacman -S --noconfirm --needed ibus-pinyin 2>&1 | tail -2 || true
            ;;
    esac

    ENGINE_NAME="$(pick_zh_engine libpinyin rime pinyin bopomofo)"
    if [ -n "$ENGINE_NAME" ]; then
        info "中文引擎: $ENGINE_NAME"
    else
        warn "未找到中文引擎组件(装包可能失败)。可手动: ibus-setup → 输入法 → 添加中文"
    fi

    # ---- 2) 环境变量 ----
    # 默认: 只留 XMODIFIERS, 不设 GTK/QT_IM_MODULE, 走 Wayland 原生 text-input 前端。
    # 例外 IBUS_XWAYLAND=1: 给需要跑 XWayland 的应用(如 Electron/Wine/老 Qt)补
    #   GTK_IM_MODULE=ibus, 让它们经 gtk im module + XIM 输入。这是"仅在需要时"
    #   的补充, 不要无条件全局设 —— 全局设会导致 Wayland 下候选框闪烁。
    if [ "${IBUS_XWAYLAND:-0}" -eq 1 ]; then
        sub "写入环境变量(XWayland 兼容模式: 补 GTK_IM_MODULE=ibus)..."
        cat > "$ENVD_DIR/ibus.conf" <<'EOF'
# XWayland 兼容: Electron 若用 WB_IME=x11 走 XWayland, 需 gtk im module
# QT_IM_MODULE 仍未设: Wayland 下 Qt6 走原生 text-input 更稳
GTK_IM_MODULE=ibus
XMODIFIERS=@im=ibus
EOF
        cat > "$FISH_CONF/ibus.fish" <<'EOF'
set -gx GTK_IM_MODULE ibus
set -gx XMODIFIERS @im=ibus
EOF
        warn "IBUS_XWAYLAND=1: 已设 GTK_IM_MODULE=ibus。若 Wayland 应用候选框闪烁, 改回默认(不设)"
    else
        sub "写入环境变量(仅 XMODIFIERS, 走 Wayland 原生前端)..."
        cat > "$ENVD_DIR/ibus.conf" <<'EOF'
# Wayland 原生前端: 不要设 GTK_IM_MODULE / QT_IM_MODULE
# XMODIFIERS 供 XWayland(Steam 客户端等)走 XIM
XMODIFIERS=@im=ibus
EOF
        cat > "$FISH_CONF/ibus.fish" <<'EOF'
# Wayland 原生前端: 不要设 GTK_IM_MODULE / QT_IM_MODULE
set -gx XMODIFIERS @im=ibus
EOF
    fi
    info "已写 $ENVD_DIR/ibus.conf"

    # ---- 3) 屏蔽系统级独立自启动, 让 ibus-ui-gtk3 托管 daemon ----
    if [ -f /etc/xdg/autostart/ibus.desktop ]; then
        sub "屏蔽 /etc/xdg/autostart/ibus.desktop(它独立拉起 daemon 会触发警告)..."
        cat > "$AUTOSTART_DIR/ibus.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=IBus (disabled - started by ibus-ui-gtk3)
Hidden=true
EOF
        info "已屏蔽, 改为由 KWin → ibus-ui-gtk3 拉起"
    fi

    # ---- 4) KWin Wayland 输入法 = IBus Wayland 面板(唯一入口) ----
    local KW=""
    command -v kwriteconfig6 >/dev/null 2>&1 && KW=kwriteconfig6
    [ -z "$KW" ] && command -v kwriteconfig5 >/dev/null 2>&1 && KW=kwriteconfig5
    if [ -f "$IBUS_PANEL" ] && [ -n "$KW" ]; then
        sudo -u "$REAL_USER" "$KW" --file kwinrc --group Wayland --key InputMethod "$IBUS_PANEL" \
            && info "KWin InputMethod=IBus Wayland 面板" \
            || warn "写 kwinrc 失败, 请登录后: 系统设置→键盘→虚拟键盘→选 IBus"
    else
        warn "无 kwriteconfig 或缺少 $IBUS_PANEL, 请手动: 系统设置→键盘→虚拟键盘→IBus"
    fi

    # ---- 5) 预置引擎(需桌面会话的 D-Bus, 失败属正常) ----
    if [ -n "$ENGINE_NAME" ] && command -v dconf >/dev/null 2>&1; then
        sudo -u "$REAL_USER" dconf write /desktop/ibus/general/preload-engines "['$ENGINE_NAME']" \
            2>/dev/null && info "已预置引擎 $ENGINE_NAME" \
            || warn "dconf 需桌面会话; 登录后执行: dconf write /desktop/ibus/general/preload-engines \"['$ENGINE_NAME']\""
    fi

    chown -R "$REAL_USER:$REAL_GROUP" "$ENVD_DIR" "$AUTOSTART_DIR" "$FISH_CONF" 2>/dev/null || true
    info "IBus 原生输入法配置完成"
    cat <<'EOF'
  注销重登(或重启)后生效。验证:
    echo "[$GTK_IM_MODULE][$QT_IM_MODULE]"          两个都应为空
    pgrep -a ibus-ui-gtk3 ; pgrep -a ibus-daemon    后者的 PPID 应是前者
  切输入法: Super+Space(或 ibus-setup 里改); 增删引擎: ibus-setup
  只跑 X11 的老应用(WPS/Anki 等)若不能输入: 单独给它 QT_IM_MODULE=ibus, 不要全局设
  游戏模式要中文: systemctl --user enable --now ibus-gamescope.service
EOF
}


# ===========================================================================
#  rootfs 体检 / 瘦身
#
#  两个已实测确认、且与老结论相反的事实:
#   ① /opt 在 SteamOS 上是 bind mount 到 /home 分区:
#        findmnt /opt → /dev/nvme0n1p8[/.steamos/offload/opt]
#      所以 /opt 下的体积(WorkBuddy 818M)完全不占 rootfs。别再 mv /opt
#      (它是挂载点, 会报"设备或资源忙"), 也别按"818M 占 rootfs"做预检。
#   ② rootfs 5GB 是 btrfs, 常见 "Device unallocated ≈ 0" —— chunk 全部分配完,
#      剩余空间只是 chunk 内部余量; 写满不会提示空间不足, 而是直接 ENOSPC
#      (可能损坏文件系统)。所以必须留缓冲, 不能踩红线装东西。
# ===========================================================================
OPT_OFFLOAD=0
