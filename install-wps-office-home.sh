#!/usr/bin/env bash
# ===========================================================================
#  install-wps-office-home.sh
#  把 WPS Office(中文版)装到 /opt + /home —— 不占 rootfs、扛原子升级
#  上游 deb: https://wdl1.pcfg.cache.wpscdn.com/wpsdl/wpsoffice/download/linux/
# ---------------------------------------------------------------------------
#  【为什么走官方 deb, 不走 AUR 的 wps-office / wps-office-cn】
#  两个 AUR 包都在 PKGBUILD 里 `sed -i 's|/opt/kingsoft/wps-office|/usr/lib|'`
#  并把 office6 装到 `/usr/lib/office6` —— 那是 **rootfs(5G)**。
#  而这个 deb 自己的 control 明写(11.1.0 与 12.1.2 都一样):
#      Relocations: /opt/kingsoft
#      Installed-Size: 2170380 KB   (12.1.2, ≈2.07 GB!)
#  按官方布局装 → 落在 `/opt`, 而 `/opt` 是 bind-mount 到 /home 分区(918G) 的:
#  既不吃那 5G, 又能在 A/B 原子升级后**整体幸存**。改到 /usr/lib 就必然 ENOSPC。
#
#  【取源: 官方现行通道要带时间戳签名】(2026-09-24 实测)
#    老通道(≤11.x)是无签名静态 URL:
#      https://wdl1.pcfg.cache.wpscdn.com/wpsdl/wpsoffice/download/linux/<末段>/wps-office_<ver>.XA_amd64.deb
#    现行(12.x)改为 Linux2023 通道 + 签名:
#      https://wps-linux-personal.wpscdn.cn/wps/download/ep/Linux2023/<末段>/
#        wps-office_<ver>.AK.preread.sw.Personal_765474_amd64.deb?t=<ts>&k=<md5(key+uri+ts)>
#    key 是客户端常量(官方下载页 JS 里就有), 非机密; 用 date + md5sum 复算即可。
#    实测: 签名 URL 200 / 545MB; 老通道对 12.x 返回 403 → 故两者按序尝试。
#
#  【本 deb 的权威事实】(用 range 请求只取头部, 解 ar + control.tar.gz 得到的;
#   control.tar.* 排在 data.tar.* 前面, 所以前 3MB 就够, 不用下整包)
#    Version(11.1.0) : 11.1.0.11723.XA          Installed-Size: 1630564 KB ≈1.55GB
#    Version(12.1.2) : 12.1.2.28080.AK.preread.sw   Installed-Size: 2170380 KB ≈2.07GB
#    Relocations     : /opt/kingsoft            (两个版本一致)
#    Depends         : libc6, libfreetype6, libcups2, libglib2.0-0, libglu1-mesa,
#                      libsm6, libxrender1, libfontconfig1, libxext6, libxcb1, libbz2-1.0
#                      (12.x 已不含 libstdc++6) → Arch 名见 WPS_DEPS_ARCH
#    preinst         : killall wps wpp et wpsoffice wpspdf wpscloudsvr … 再 kill -9
#    postinst        : 更新 mime / desktop 数据库 + 注册 hicolor 图标
#
#  【产物】—— 只有 /opt 那部分需要 root, 且 /opt 本来就是 rw 的独立挂载,
#           所以**不需要 steamos-readonly disable**, 也不往 /usr 写任何东西。
#    /opt/kingsoft/wps-office/…                本体(官方原样 → 天然幸存)
#    ~/.local/opt/wps-office/bin/{wps,wpp,et,wpspdf}   官方包装脚本的副本
#      (能这么搬是因为: AUR 那份只改了一个绝对路径串就能跑 → 说明这些包装脚本
#       用的是绝对路径而非 $0 相对推导)
#    ~/.local/bin/{wps,wpp,et,wpspdf}          入口(AUR 之外的薄壳, 可注 WPS_X11)
#    ~/.local/share/applications/wps-office-*.desktop  (Exec/TryExec 改绝对路径)
#    ~/.local/share/icons/hicolor/…            图标(升级会把 rootfs 里的冲掉)
#    ~/.local/share/mime/packages/*.xml        自定义 mime 类型(wps/et/wpp 文档)
#    ~/.cache/wps-office/*.deb                 下载缓存(带续传)
#
#  【用法】
#    bash install-wps-office-home.sh                       # 安装/修复(幂等)
#    bash install-wps-office-home.sh --check               # 只读自检(升级后跑这个)
#    bash install-wps-office-home.sh --force               # 有缓存也重装一遍
#    WPS_VER=11.1.0.11723 bash install-wps-office-home.sh  # 指定版本
#    WPS_DEB=/path/wps-office_xxx.deb bash install-wps-office-home.sh  # 用本地 deb
#    WPS_X11=1 wps                                          # 启动时强制走 XWayland
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_I=$'\033[36m'; C_OK=$'\033[32m'; C_W=$'\033[33m'; C_E=$'\033[31m'
info() { printf '%s[*]%s %s\n' "$C_I" "$C_R" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_OK" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_W" "$C_R" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_E" "$C_R" "$*" >&2; }
sub()  { printf '    %s\n' "$*"; }

WPS_VER="${WPS_VER:-12.1.2.28080}"
WPS_CHANNEL="${WPS_CHANNEL:-Linux2023}"     # 官方现行通道(中文版 12.x)
# 官方 12.x 的取源带**时间戳签名**(见 AUR wps-office-cn 的 _get_source_url):
#     url = https://wps-linux-personal.wpscdn.cn/wps/download/ep/<通道>/<ver末段>/
#           wps-office_<ver>.AK.preread.sw.Personal_765474_amd64.deb?t=<ts>&k=<md5(key+uri+ts)>
# 这个 key 是客户端常量(写在官方下载页 JS 里), 非机密; 用 date + md5sum 即可复算。
WPS_SIGN_KEY="${WPS_SIGN_KEY:-7f8faaaa468174dc1c9cd62e5f218a5b}"
# 老通道(11.1.0 及以前)是无签名的静态 URL, 留作兜底(实测仍可下)
WPS_LEGACY_BASE="${WPS_LEGACY_BASE:-https://wdl1.pcfg.cache.wpscdn.com/wpsdl/wpsoffice/download/linux}"
# deb 的 Depends 对应的 Arch 包名(少装漏装都会表现为"点了没反应")
WPS_DEPS_ARCH=(glibc gcc-libs freetype2 libcups glib2 glu libsm libxrender fontconfig libxext libxcb bzip2)
WPS_BINS=(wps wpp et wpspdf)

# 官方现行(带签名)的 deb 下载地址
wps_url_signed() {
    local uri t k
    uri="/wps/download/ep/${WPS_CHANNEL}/${WPS_VER##*.}/wps-office_${WPS_VER}.AK.preread.sw.Personal_765474_amd64.deb"
    t="$(date '+%s')"
    k="$(printf '%s' "${WPS_SIGN_KEY}${uri}${t}" | md5sum | cut -d' ' -f1)"
    printf 'https://wps-linux-personal.wpscdn.cn%s?t=%s&k=%s\n' "$uri" "$t" "$k"
}
# 老通道(无签名, 只对 ≤11.x 的 XA 包有效)
wps_url_legacy() {
    printf '%s/%s/wps-office_%s.XA_amd64.deb\n' "$WPS_LEGACY_BASE" "${WPS_VER##*.}" "$WPS_VER"
}

# ── 运行身份 / 家目录 ──────────────────────────────────────────────────
if [ "$(id -u)" -eq 0 ]; then
    REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
else
    REAL_USER="$(id -un)"
fi
[ -n "${REAL_USER:-}" ] || REAL_USER="deck"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[ -n "${REAL_HOME:-}" ] || REAL_HOME="/home/$REAL_USER"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"

OPT_DIR="/opt/kingsoft/wps-office"                 # 官方 Relocations 目标
LOCAL="$REAL_HOME/.local"
WBIN="$LOCAL/opt/wps-office/bin"                   # 官方包装脚本的 /home 副本
ENTRYDIR="$LOCAL/bin"
APPDIR="$LOCAL/share/applications"
ICONDIR="$LOCAL/share/icons/hicolor"
MIMEDIR="$LOCAL/share/mime"
CACHE_DIR="$REAL_HOME/.cache/wps-office"
ASKPASS="/tmp/wps-askpass.sh"
DEB_NAME="wps-office_${WPS_VER}_amd64.deb"   # 缓存用稳定名(与实际 URL 的文件名解耦)

run_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
    if [ -t 0 ]; then sudo "$@"; return $?; fi
    if ! command -v kdialog >/dev/null 2>&1; then
        err "需要 root, 但当前没有终端可输密码、也找不到 kdialog。请在 Konsole 里跑。"
        return 1
    fi
    cat >"$ASKPASS" <<'EOF'
#!/usr/bin/env bash
exec kdialog --title "安装 WPS Office" --password "需要管理员权限，请输入登录密码："
EOF
    chmod 700 "$ASKPASS"
    SUDO_ASKPASS="$ASKPASS" sudo -A "$@"
    local rc=$?
    rm -f "$ASKPASS"
    return $rc
}

wps_running() {
    pgrep -x wps >/dev/null 2>&1 || pgrep -x wpp >/dev/null 2>&1 || \
    pgrep -x et  >/dev/null 2>&1 || pgrep -x wpsoffice >/dev/null 2>&1
}
missing_deps() {
    local p out=()
    for p in "${WPS_DEPS_ARCH[@]}"; do
        pacman -Qq "$p" >/dev/null 2>&1 || out+=("$p")
    done
    printf '%s\n' "${out[@]:-}"
}

# ===========================================================================
#  --check
# ===========================================================================
do_check() {
    local fail=0 miss
    echo "════════ WPS Office (/opt + /home 自持形态) 自检 ════════"
    echo "用户: $REAL_USER   家目录: $REAL_HOME"

    if [ -d "$OPT_DIR/office6" ]; then
        ok "本体在位: $OPT_DIR  ($(du -sh /opt/kingsoft 2>/dev/null | cut -f1))"
    elif [ -d "$OPT_DIR" ]; then
        warn "目录在但没有 office6 —— 装不完整"
        fail=1
    else
        err "本体缺失: $OPT_DIR"
        sub "→ 跑: bash install-wps-office-home.sh"
        fail=1
    fi

    local src; src="$(findmnt -no SOURCE --target /opt 2>/dev/null || true)"
    local root; root="$(findmnt -no SOURCE --target / 2>/dev/null || true)"
    if [ -n "$src" ] && [ "$src" != "$root" ]; then
        ok "/opt 独立挂载($src) → 1.55GB 不占 rootfs 且扛原子升级"
    elif [ -n "$src" ]; then
        warn "/opt 与 / 同分区 —— 1.55GB 会吃 rootfs 且升级被冲"
        fail=1
    fi

    local b n=0
    for b in "${WPS_BINS[@]}"; do [ -x "$ENTRYDIR/$b" ] && n=$((n+1)); done
    [ "$n" -eq "${#WPS_BINS[@]}" ] && ok "入口齐备(${WPS_BINS[*]})" || { warn "入口缺 $(( ${#WPS_BINS[@]} - n )) 个"; fail=1; }
    for b in "${WPS_BINS[@]}"; do
        [ -e "$WBIN/$b" ] || { warn "官方包装脚本副本缺: $WBIN/$b"; fail=1; }
    done

    [ -d "$APPDIR" ] && compgen -G "$APPDIR/wps-office*.desktop" >/dev/null \
        && ok "桌面项就绪" || { warn "桌面项缺失"; fail=1; }
    compgen -G "$ICONDIR/*/apps/wps-office*.png" >/dev/null 2>&1 \
        || compgen -G "$ICONDIR/*/mimetypes/wps-office*.png" >/dev/null 2>&1 \
        && ok "图标就绪" || warn "图标缺失(菜单里会没图标)"

    miss="$(missing_deps)"
    if [ -n "$miss" ]; then
        warn "缺运行库(在 rootfs, 升级会被冲): $(printf '%s ' $miss)"
        sub "补: sudo bash $(basename "$0")   (会自动 --needed 补上)"
        fail=1
    else
        ok "运行库齐备"
    fi

    if fc-list :lang=zh 2>/dev/null | head -1 | grep -q .; then
        ok "系统有中文字体(WPS 中文界面不会豆腐块)"
    else
        warn "系统没检出中文字体 —— WPS 界面可能豆腐块"
        sub "补: sudo pacman -S --needed noto-fonts-cjk"
    fi

    wps_running && info "WPS 正在运行" || info "当前未运行"
    if [ -f "$CACHE_DIR/$DEB_NAME" ]; then
        info "缓存 deb: $(du -h "$CACHE_DIR/$DEB_NAME" | cut -f1)  ($CACHE_DIR)"
    fi

    echo
    if [ "$fail" -eq 0 ]; then
        echo "════ 结论: 可用，且原子升级后本体应自动幸存 ════"
        return 0
    fi
    echo "════ 结论: 有缺件，按上面提示补齐 ════"
    return 1
}

# ===========================================================================
#  安装 / 修复
# ===========================================================================
do_install() {
    local deb="" stage own_deb=0 have expect ok_dl=0 src already=0
    local MARKER="$LOCAL/opt/wps-office/.version"

    echo "════════ 把 WPS Office 装到 /opt + /home ════════"
    mkdir -p "$CACHE_DIR" || return 1

    # ── 0. 本体已是这个版本 → 跳过"下载+解包+复制 2GB"这三件重活, 只补 /home 侧。
    #      (重跑本脚本最常见的原因就是升级后 /usr 侧的入口被冲掉, 那种情况根本不用重灌本体)
    if [ "${FORCE:-0}" -ne 1 ] && [ -d "$OPT_DIR/office6" ] \
       && [ "$(cat "$MARKER" 2>/dev/null)" = "$WPS_VER" ]; then
        ok "本体已是 $WPS_VER → 跳过下载/解包/复制(只补 /home 侧)"
        already=1
    fi

    if [ "$already" -eq 0 ]; then
    # ── 1. 取 deb ──
    if [ -n "${WPS_DEB:-}" ]; then
        deb="$WPS_DEB"; own_deb=1
        [ -f "$deb" ] || { err "WPS_DEB 指向的文件不存在: $deb"; return 1; }
        info "使用本地 deb: $deb"
    else
        deb="$CACHE_DIR/$DEB_NAME"
        have=0
        [ -s "$deb" ] && have="$(stat -c%s "$deb" 2>/dev/null || echo 0)"
        if [ "${FORCE:-0}" -eq 0 ] && [ "${have:-0}" -gt 0 ] && bsdtar -tf "$deb" >/dev/null 2>&1; then
            ok "缓存 deb 可用($(du -h "$deb" | cut -f1))，跳过下载"
        else
            [ "${have:-0}" -gt 0 ] && warn "缓存不完整/不可读($have 字节)，重新下载"
            info "下载 WPS $WPS_VER (装后约 2GB; 中断了重跑会接着下)"
            rm -f "$deb"
            for src in "$(wps_url_signed)" "$(wps_url_legacy)"; do
                sub "源: $(printf '%s' "$src" | cut -c1-96)"
                expect="$(curl -sIL --max-time 25 "$src" 2>/dev/null \
                          | grep -i '^content-length' | tail -1 | tr -dc '0-9')"
                if curl -L --http1.1 --retry 3 --retry-delay 2 -C - \
                        --connect-timeout 20 --max-time 5400 \
                        -o "$deb" "$src" 2>/dev/null && bsdtar -tf "$deb" >/dev/null 2>&1; then
                    have="$(stat -c%s "$deb" 2>/dev/null || echo 0)"
                    if [ "${expect:-0}" -gt 0 ] && [ "$have" != "$expect" ]; then
                        warn "  大小对不上(实 $have / 期望 $expect)，换下一个源"
                        rm -f "$deb"; continue
                    fi
                    ok_dl=1; break
                fi
                warn "  该源失败，清残包换下一个"
                rm -f "$deb"
            done
            if [ "$ok_dl" -ne 1 ]; then
                err "官方两个通道都不通。可自行下载 deb 后指定本地文件:"
                sub "WPS_DEB=/路径/任意名.deb bash $(basename "$0")"
                sub "(官方页 https://linux.wps.cn 有下载入口)"
                return 1
            fi
            ok "下载完成: $(du -h "$deb" | cut -f1)"
        fi
    fi

    # ── 2. 完整性 ──
    if ! bsdtar -tf "$deb" >/dev/null 2>&1; then
        err "deb 结构不可读(下载不完整?)"
        [ "$own_deb" -eq 0 ] && rm -f "$deb"
        return 1
    fi
    if ! bsdtar -tf "$deb" 2>/dev/null | grep -q '^data\.tar'; then
        err "deb 里没有 data.tar.* —— 不是标准 deb"
        return 1
    fi
    info "deb 校验通过"

    # ── 3. 解包到暂存区 ──
    stage="$CACHE_DIR/.stage.$$"
    rm -rf "$stage"; mkdir -p "$stage" || return 1
    sub "解包(ar → data.tar.xz)..."
    if ! bsdtar -xf "$deb" -C "$stage" 2>/dev/null; then
        err "解包 deb 失败"; rm -rf "$stage"; return 1
    fi
    local dtx
    dtx="$(ls -1 "$stage"/data.tar* 2>/dev/null | head -1)"
    if [ -z "$dtx" ]; then err "没找到 data.tar.*"; rm -rf "$stage"; return 1; fi
    if ! bsdtar -xf "$dtx" -C "$stage" 2>/dev/null; then
        err "解包 data.tar 失败"; rm -rf "$stage"; return 1
    fi
    if [ ! -d "$stage/opt/kingsoft/wps-office/office6" ]; then
        err "包结构异常: 找不到 opt/kingsoft/wps-office/office6"
        sub "顶层内容: $(ls -1 "$stage" 2>/dev/null | tr '\n' ' ')"
        rm -rf "$stage"; return 1
    fi
    [ -x "$stage/opt/kingsoft/wps-office/office6/wps" ] \
        || warn "office6/wps 不是可执行文件 —— 官方版式变了, 但目录结构对, 继续"
    ok "解包校验通过"

    # ── 4. 运行中的 WPS 必须先退出(官方 preinst 也是 killall) ──
    if wps_running; then
        err "WPS 正在运行 —— 先完全退出(含后台 wpscloudsvr)再跑本脚本"
        sub "或执行: killall wps wpp et wpsoffice wpspdf wpscloudsvr"
        rm -rf "$stage"; return 1
    fi

    # ── 5. 装本体到 /opt(官方 Relocations 目标; /opt 是 rw 独立挂载, 不用解只读) ──
    #  同分区 mv 做"准原子"替换: 旧树先挪成 .prev, 新的进来并校验通过后再删 .prev;
    #  中途失败就把 .prev 挪回去 —— 免得半个新树盖在旧树上面变成混合状态。
    sub "安装本体 → /opt/kingsoft (需 root; 不写 /usr)"
    local OLD="/opt/kingsoft/wps-office" PREVW="/opt/kingsoft/.wps-office.prev"
    if ! run_root mkdir -p /opt/kingsoft; then rm -rf "$stage"; return 1; fi
    if [ -d "$OLD" ]; then
        run_root rm -rf "$PREVW" 2>/dev/null || true
        run_root mv "$OLD" "$PREVW" || { err "旧本体让位失败"; rm -rf "$stage"; return 1; }
    fi
    if ! run_root cp -a "$stage/opt/kingsoft/." /opt/kingsoft/; then
        err "复制到 /opt/kingsoft 失败(空间不足?) —— 回滚旧本体"
        sub "需要约 2.1GB 可用; /opt 在 home 分区上, 正常应有几百 G"
        run_root rm -rf "$OLD" 2>/dev/null || true
        [ -d "$PREVW" ] && run_root mv "$PREVW" "$OLD" 2>/dev/null
        rm -rf "$stage"; return 1
    fi
    if [ ! -d "$OPT_DIR/office6" ]; then
        err "新版校验失败(没有 office6) —— 回滚旧本体"
        run_root rm -rf "$OLD" 2>/dev/null || true
        [ -d "$PREVW" ] && run_root mv "$PREVW" "$OLD" 2>/dev/null
        rm -rf "$stage"; return 1
    fi
    run_root rm -rf "$PREVW" 2>/dev/null || true
    mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
    printf '%s\n' "$WPS_VER" >"$MARKER" 2>/dev/null || true
    ok "本体就位: $OPT_DIR  ($(du -sh /opt/kingsoft 2>/dev/null | cut -f1))"
    fi   # ← 本体已就位时跳过的重活块(下载/解包/复制)

    # ── 6. /home 自持化: 入口 / 桌面项 / 图标 / mime ──
    #  这一段的每一样在 rootfs 里都有一份官方件, 但原子升级会把 rootfs 冲掉,
    #  所以全部在 ~/.local 下另存一份 —— 升级后菜单照样在。
    sub "把入口/桌面项/图标/mime 另存到 /home(升级后靠它们)..."

    mkdir -p "$WBIN" "$ENTRYDIR" "$APPDIR" "$ICONDIR" "$MIMEDIR/packages"
    local b
    for b in "${WPS_BINS[@]}"; do
        if [ -f "$stage/usr/bin/$b" ]; then
            cp -f "$stage/usr/bin/$b" "$WBIN/$b"
            chmod 755 "$WBIN/$b" 2>/dev/null
            # 薄壳: 有 /usr/bin 的官方件就优先用它(当前会话里它一定在),
            #       没有(升级后被冲)就用 /home 副本 —— /home 副本也是官方原样。
            {
                printf '#!/usr/bin/env bash\n'
                printf '# 由 install-wps-office-home.sh 生成\n'
                printf '# WPS 是 Qt 应用: 缩放/输入法跟随异常时用 WPS_X11=1 走 XWayland\n'
                printf '[ "${WPS_X11:-0}" = "1" ] && export QT_QPA_PLATFORM=xcb\n'
                printf 'if [ -x /usr/bin/%s ]; then exec /usr/bin/%s "$@"; fi\n' "$b" "$b"
                printf 'exec "%s/%s" "$@"\n' "$WBIN" "$b"
            } >"$ENTRYDIR/$b"
            chmod 755 "$ENTRYDIR/$b"
        else
            warn "包里没有 usr/bin/$b(官方版式变了?)"
        fi
    done
    local n=0; for b in "${WPS_BINS[@]}"; do [ -x "$ENTRYDIR/$b" ] && n=$((n+1)); done
    [ "$n" -gt 0 ] && ok "入口就绪: $ENTRYDIR/{${WPS_BINS[*]}} ($n 个)" \
                  || warn "入口一个都没生成"

    # 只改"相对路径"的 Exec/TryExec; 已经是绝对路径的别动(否则会拼成 /a//b/c)
    local d
    for d in "$stage"/usr/share/applications/wps-office*.desktop; do
        [ -f "$d" ] || continue
        sed -E "s#^(Exec|TryExec)=([^/][^ ]*)#\1=$ENTRYDIR/\2#" "$d" >"$APPDIR/$(basename "$d")"
        chmod 644 "$APPDIR/$(basename "$d")"
    done
    compgen -G "$APPDIR/wps-office*.desktop" >/dev/null && ok "桌面项就位: $APPDIR" \
        || warn "没找到官方 .desktop(桌面菜单里可能看不到 WPS)"

    # 图标: 整棵 hicolor 合并过去(官方把图标放在 apps/ 与 mimetypes/ 两处)
    [ -d "$stage/usr/share/icons/hicolor" ] && cp -a "$stage/usr/share/icons/hicolor/." "$ICONDIR/" 2>/dev/null
    compgen -G "$ICONDIR/*/apps/wps-office*.png" >/dev/null 2>&1 \
        && ok "图标就位: $ICONDIR" || warn "图标没搬成"

    # 自定义 mime(wps/et/wpp 文档双击关联)
    if compgen -G "$stage/usr/share/mime/packages/*.xml" >/dev/null; then
        cp -f "$stage"/usr/share/mime/packages/*.xml "$MIMEDIR/packages/" 2>/dev/null
        command -v update-mime-database >/dev/null 2>&1 \
            && update-mime-database "$MIMEDIR" >/dev/null 2>&1
        ok "mime 类型已注册(用户级)"
    fi

    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$APPDIR" >/dev/null 2>&1
    command -v gtk-update-icon-cache >/dev/null 2>&1 \
        && gtk-update-icon-cache -q -t -f "$ICONDIR" >/dev/null 2>&1

    rm -rf "$stage"

    # ── 7. 系统运行库 + 字体(在 rootfs; 升级会被冲 → --check 会报) ──
    local miss
    miss="$(missing_deps)"
    if [ -n "$miss" ]; then
        sub "补运行库(deb 的 Depends 里 SteamOS 缺的那几个): ${miss//$'\n'/ }"
        # shellcheck disable=SC2086
        run_root pacman -S --noconfirm --needed --asdeps $miss 2>&1 | tail -3 \
            || warn "有包没装上, 不影响已装部分; 可稍后手工补"
    else
        ok "运行库齐备"
    fi
    if ! fc-list :lang=zh 2>/dev/null | head -1 | grep -q .; then
        warn "系统没中文字体 —— WPS 界面会豆腐块"
        sub "补: sudo pacman -S --needed noto-fonts-cjk"
    fi

    [ "$(id -u)" -eq 0 ] && chown -R "$REAL_USER:$REAL_GROUP" \
        "$LOCAL/opt/wps-office" "$ENTRYDIR" "$APPDIR" "$ICONDIR" "$MIMEDIR" "$CACHE_DIR" 2>/dev/null

    # ── 8. 收尾 ──
    echo
    echo "════════ 完成 ════════"
    echo "  本体: $OPT_DIR  ($(du -sh /opt/kingsoft 2>/dev/null | cut -f1), 在 /opt → 扛原子升级)"
    echo "  入口: $ENTRYDIR/wps | wpp | et | wpspdf"
    echo "  菜单: 应用列表搜 WPS"
    echo
    echo "  · 原子升级后: 程序本体在 /opt、入口与菜单项在 ~/.local, 都应幸存;"
    echo "    系统运行库在 rootfs 会被冲 → 想确认跑 --check(缺了重跑本脚本即可)。"
    echo "  · 首次启动请先退出所有 WPS 窗口; 若显示异常依次试:"
    echo "      WPS_X11=1 wps                       (走 XWayland, 治缩放/输入法跟随)"
    echo "      QT_IM_MODULE=ibus WPS_X11=1 wps     (中文输不进去时)"
    echo "  · 用户配置在 ~/.kingsoft 与 ~/.local/share/Kingsoft → 都在 /home, 升级不丢。"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) FORCE=1 ;;
            -h|--help) sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
            --check) do_check; return $? ;;
            "") break ;;
            *) err "未知参数: $1 (可用: --check / --force / --help)"; return 2 ;;
        esac
        shift
    done
    do_install
}
main "$@"
