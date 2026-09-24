#!/usr/bin/env bash
# ===========================================================================
#  install-firefox-nightly-home.sh
#  让 SteamOS 上的 Firefox Nightly 既「原生无沙箱」又「扛原子升级」
# ---------------------------------------------------------------------------
#  【要解决的问题】
#  不论用 pacman 装 firefox 还是 AUR 的 firefox-nightly，落点都在 /usr（rootfs）。
#  SteamOS 的 A/B 原子升级会把 rootfs 整块换成新镜像 → 每次升级后浏览器都没了，
#  还得重装一遍。而 Mozilla 官方只发 tar.xz（原生包，无 flatpak/bwrap 沙箱）。
#
#  【本脚本的对策】
#  用官方 tar.xz 解到 /home，与 pacman、/usr 解耦：
#     ~/.local/opt/firefox-nightly/      程序本体(官方原样解压)
#     ~/.local/bin/firefox-nightly       入口(必要时自动切原生 Wayland)
#     ~/.local/share/applications/firefox-nightly.desktop
#     ~/.local/share/icons/firefox-nightly.png
#  → 原子升级后直接可用，零操作。
#
#  【三个附带好处】
#   1. 装进用户可写目录后，Nightly **自带的更新器能真正自更新**（装在 /usr 时
#      更新器是被禁用的：没权限写自己）。所以日常连本脚本都不用跑。
#   2. 不占 rootfs。反过来还能回收：系统那个 /usr/lib/firefox 约 290M，
#      确认 Nightly 好用后跑 `--remove-system` 把它删掉（见 free-rootfs.sh 的④）。
#   3. 无沙箱。flatpak 版浏览器在 bubblewrap 里，访问 ~/下载、~/.ssh、
#      连本地服务都受限；原生包没有这些限制。
#
#  【用法】
#    bash install-firefox-nightly-home.sh                    # 安装/更新(默认简体中文)
#    bash install-firefox-nightly-home.sh --lang en-US       # 装英文原版
#    bash install-firefox-nightly-home.sh --force            # 版本没变也强制重装
#    bash install-firefox-nightly-home.sh --check            # 只读自检(升级后跑这个)
#    bash install-firefox-nightly-home.sh --remove-system    # 卸掉 pacman 的 firefox 回收 rootfs
#    FFN_MIRROR=https://你的镜像 bash install-firefox-nightly-home.sh   # 自备下载源
#
#  【关于 profile】
#  Nightly 与稳定版共用 `~/.mozilla/firefox` 这个家目录（都在 /home，升级不丢），
#  但默认 profile 名不同（`*.default-nightly` vs `*.default-release`）。两个都留着
#  一般互不干扰；若出现奇怪的设置丢失，先确认启动的是哪个版本。
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_I=$'\033[36m'; C_OK=$'\033[32m'; C_W=$'\033[33m'; C_E=$'\033[31m'
info() { printf '%s[*]%s %s\n' "$C_I" "$C_R" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_OK" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_W" "$C_R" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_E" "$C_R" "$*" >&2; }
sub()  { printf '    %s\n' "$*"; }

# ── 运行身份 / 家目录(以 sudo 跑也要能定位真用户) ───────────────────────
if [ "$(id -u)" -eq 0 ]; then
    REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
else
    REAL_USER="$(id -un)"
fi
[ -n "${REAL_USER:-}" ] || REAL_USER="deck"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[ -n "${REAL_HOME:-}" ] || REAL_HOME="/home/$REAL_USER"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"

FF_HOME="$REAL_HOME/.local/opt/firefox-nightly"    # 我们的安装根
FF_APP="$FF_HOME/firefox"                          # 官方包内的顶层 firefox/
FF_BIN_REAL="$FF_APP/firefox"
FF_PREV="$FF_HOME.prev"
WB_LOCAL="$REAL_HOME/.local"
FF_ENTRY="$WB_LOCAL/bin/firefox-nightly"
FF_DESKTOP="$WB_LOCAL/share/applications/firefox-nightly.desktop"
FF_ICON="$WB_LOCAL/share/icons/firefox-nightly.png"
CACHE_DIR="$REAL_HOME/.cache/firefox-nightly"
ASKPASS="/tmp/ffn-askpass.sh"

run_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
    if [ -t 0 ]; then sudo "$@"; return $?; fi
    if ! command -v kdialog >/dev/null 2>&1; then
        err "需要 root，但当前没有终端可输密码、也找不到 kdialog。请在 Konsole 里手动跑。"
        return 1
    fi
    cat >"$ASKPASS" <<'EOF'
#!/usr/bin/env bash
exec kdialog --title "Firefox Nightly" --password "需要管理员权限，请输入登录密码："
EOF
    chmod 700 "$ASKPASS"
    SUDO_ASKPASS="$ASKPASS" sudo -A "$@"
    local rc=$?
    rm -f "$ASKPASS"
    return $rc
}

installed_version() {
    [ -f "$FF_APP/application.ini" ] || return 1
    grep -m1 '^Version=' "$FF_APP/application.ini" 2>/dev/null | cut -d= -f2-
}

# 解析官方包的最新真实地址(l10n=简体中文, 非 l10n=英文原版)
resolve_url() {
    local lang="$1" product final
    if [ "$lang" = "en-US" ]; then
        product="firefox-nightly-latest-ssl"
    else
        product="firefox-nightly-latest-l10n-ssl"
    fi
    final="$(curl -sIL -o /dev/null -w '%{url_effective}' --max-time 25 \
             "https://download.mozilla.org/?product=${product}&os=linux64&lang=${lang}" 2>/dev/null)"
    case "$final" in
        *.tar.xz|*.tar.bz2) printf '%s\n' "$final"; return 0 ;;
        *) return 1 ;;
    esac
}

# 从包名里抠版本号: firefox-158.0a1.zh-CN.linux-x86_64.tar.xz → 158.0a1
ver_from_name() {
    printf '%s\n' "$(basename "$1")" | sed -nE 's/^firefox-([0-9]+\.[0-9]+[ab][0-9]+)\..*$/\1/p'
}

# ===========================================================================
#  --check
# ===========================================================================
do_check() {
    local fail=0 v latest cur base p src_home src_ff
    echo "════════ Firefox Nightly /home 自持形态 自检 ════════"
    echo "用户: $REAL_USER   家目录: $REAL_HOME"

    if [ -x "$FF_BIN_REAL" ]; then
        v="$(installed_version || echo '?')"
        ok "已安装: version $v  ($(du -sh "$FF_HOME" 2>/dev/null | cut -f1))"
        sub "路径: $FF_BIN_REAL"
        [ -f "$FF_HOME/.ffn-lang" ] && sub "语言: $(cat "$FF_HOME/.ffn-lang" 2>/dev/null)"
    else
        err "未安装(或目录不完整): $FF_BIN_REAL"
        sub "→ 跑: bash install-firefox-nightly-home.sh"
        fail=1
    fi

    [ -x "$FF_ENTRY" ]    && ok "入口: $FF_ENTRY"                || { err "入口缺失: $FF_ENTRY"; fail=1; }
    [ -f "$FF_DESKTOP" ]  && ok "桌面项就绪"                       || { warn "桌面项缺失"; fail=1; }
    [ -f "$FF_ICON" ]     && ok "图标就绪"                         || warn "图标缺失(菜单里会没图标)"

    # 挂载归属: 必须确认程序和家目录在同一个挂载点上, 否则就是落在会被冲的地方。
    # (findmnt 不可用时不要凭空判过 —— 空值相等会造成假阳性)
    src_home="$(findmnt -no SOURCE --target "$REAL_HOME" 2>/dev/null || true)"
    src_ff="$(findmnt -no SOURCE --target "$FF_HOME" 2>/dev/null || true)"
    if [ -n "$src_ff" ] && [ "$src_home" = "$src_ff" ]; then
        ok "落在 home 分区($src_ff) → 原子升级幸存"
    elif [ -n "$src_ff" ]; then
        warn "不在 /home 同一分区($src_ff vs ${src_home:-?}) —— 可能被原子升级冲掉"
        fail=1
    else
        info "（读不到挂载信息，跳过分区判定）"
    fi

    if pgrep -f "$FF_APP/firefox" >/dev/null 2>&1; then
        warn "Nightly 正在运行 —— 更新前必须完全退出(含后台进程)"
    else
        info "当前未运行"
    fi

    if pacman -Qq firefox >/dev/null 2>&1; then
        info "系统里还有 pacman 版 firefox ($(du -sh /usr/lib/firefox 2>/dev/null | cut -f1))，占 rootfs"
        sub "确认 Nightly 好用后可回收: bash install-firefox-nightly-home.sh --remove-system"
    else
        info "无 pacman 版 firefox（rootfs 已省下约 290M）"
    fi
    for p in firefox-nightly firefox-developer-edition firefox-beta-bin; do
        pacman -Qq "$p" >/dev/null 2>&1 \
            && warn "另有 pacman 包 $p 装着(同样在 rootfs，升级会冲掉) —— 可用 --remove-system 一并清理"
    done

    if [ -d "$CACHE_DIR" ]; then
        info "下载缓存: $(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)  ($CACHE_DIR)"
    fi

    # 联网探最新版(只读 HEAD, 失败不扣分)
    cur="$(installed_version || true)"
    if base="$(resolve_url "${FFN_LANG:-zh-CN}" 2>/dev/null)"; then
        latest="$(ver_from_name "$base")"
        if [ -n "$latest" ] && [ -n "$cur" ] && [ "$latest" != "$cur" ]; then
            info "官方最新: $latest （本地 $cur）→ 有新版本，跑一次安装即更新"
        elif [ -n "$latest" ]; then
            ok "已是最新: $latest"
        fi
    else
        info "（联网探测最新版失败，跳过；不影响本地判断）"
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
#  --remove-system : 回收 rootfs(卸掉 pacman 版 firefox)
# ===========================================================================
do_remove_system() {
    local found=() p ans size
    for p in firefox firefox-nightly firefox-developer-edition firefox-beta-bin; do
        pacman -Qq "$p" >/dev/null 2>&1 && found+=("$p")
    done
    if [ "${#found[@]}" -eq 0 ]; then
        info "系统里没有 pacman 版 firefox*，无需处理"
        return 0
    fi
    if [ ! -x "$FF_BIN_REAL" ]; then
        err "Nightly 还没装好 —— 先跑安装，确认能用再删系统版，否则就没浏览器了"
        return 1
    fi
    local size
    size="$(du -sh /usr/lib/firefox 2>/dev/null | cut -f1)"
    warn "将卸载: ${found[*]}   (rootfs 回收约 ${size:-290M})"
    sub "pacman -Rns 会连带删掉无主依赖，请先看清输出"
    echo -n "确认继续？输入 yes: "
    if [ -t 0 ]; then
        read -r ans
        [ "$ans" = "yes" ] || { info "已取消"; return 1; }
    else
        warn "非交互环境，已取消(请在 Konsole 里跑)"
        return 1
    fi
    if run_root pacman -Rns --noconfirm "${found[@]}"; then
        ok "已卸载 ${found[*]}，rootfs 回收约 ${size:-290M}"
    else
        err "卸载失败"
        return 1
    fi
}

# ===========================================================================
#  安装 / 更新
# ===========================================================================
do_install() {
    local lang="${FFN_LANG:-zh-CN}"
    local canon base archive stage cur latest

    case "$lang" in
        *[!A-Za-z0-9-]*|'') err "非法的 --lang 值: $lang"; return 1 ;;
    esac

    echo "════════ 把 Firefox Nightly 装进 /home (语言: $lang) ════════"

    # ── 1. 运行中拒绝替换(否则会写坏正在用的程序文件) ──────────────
    if pgrep -f "$FF_APP/firefox" >/dev/null 2>&1; then
        err "Nightly 正在运行，先完全退出(菜单→退出; 或 pkill -f firefox-nightly)再跑本脚本"
        return 1
    fi

    # ── 2. 解析最新版本 ────────────────────────────────────────────
    sub "查询官方最新版本..."
    if ! canon="$(resolve_url "$lang")"; then
        err "拿不到下载地址(网络不通或 Mozilla 改版)。"
        sub "手工确认: https://download.mozilla.org/?product=firefox-nightly-latest-l10n-ssl&os=linux64&lang=$lang"
        return 1
    fi
    base="$(basename "$canon")"
    latest="$(ver_from_name "$canon")"
    cur="$(installed_version || true)"
    info "最新: ${latest:-?}   $base"
    [ -n "$cur" ] && info "本地: $cur"

    # 版本和语言都没变就不折腾(重装要解压约 95MB); --force 可强制重来。
    # 注意语言也要比: 同版本号的 en-US / zh-CN 是两个不同的包。
    local installed_lang="" skip_x=0
    [ -f "$FF_HOME/.ffn-lang" ] && installed_lang="$(cat "$FF_HOME/.ffn-lang" 2>/dev/null || true)"
    if [ "${FFN_FORCE:-0}" -ne 1 ] && [ -n "$latest" ] && [ "$latest" = "$cur" ] \
       && [ "$installed_lang" = "$lang" ] && [ -f "$FF_BIN_REAL" ]; then
        ok "已是最新($cur, $lang)，跳过重装(想强制重来加 --force)"
        skip_x=1
    fi

    # ── 3. 下载(固定缓存目录 + 续传; 多源择优) ─────────────────────
    #  官方 download.mozilla.org 会 302 到 download-installer.cdn.mozilla.net，
    #  实测同一个文件从 archive.mozilla.org 取快一两个数量级(路径完全相同)，
    #  所以默认优先 archive，失败再退回官方解析出的地址。
    #  想用别处镜像:  FFN_MIRROR=https://your.mirror  bash 本脚本
    mkdir -p "$CACHE_DIR" || return 1
    archive="$CACHE_DIR/$base"
    if [ -s "$archive" ] && tar -tJf "$archive" >/dev/null 2>&1; then
        ok "已有完整包，跳过下载: $(du -h "$archive" | cut -f1)"
    else
        local path_only cand ok_dl=0
        path_only="$(printf '%s\n' "$canon" | sed -E 's#^https?://[^/]+##')"
        local -a cands=()
        [ -n "${FFN_MIRROR:-}" ] && cands+=("${FFN_MIRROR%/}$path_only")
        cands+=("https://archive.mozilla.org$path_only")
        cands+=("$canon")
        sub "下载 → $archive   (约 100MB; 中断了重跑本脚本会接着下)"
        for cand in "${cands[@]}"; do
            sub "源: $(printf '%s' "$cand" | cut -c1-78)"
            if curl -L --http1.1 --retry 2 --retry-delay 2 -C - \
                    --connect-timeout 15 --max-time 1800 \
                    -o "$archive" "$cand" 2>/dev/null \
               && tar -tJf "$archive" >/dev/null 2>&1; then
                ok_dl=1; break
            fi
            warn "该源失败，清掉残包换下一个"
            rm -f "$archive"
        done
        if [ "$ok_dl" -ne 1 ]; then
            err "所有下载源都失败。可自备镜像:"
            sub "FFN_MIRROR=https://你的镜像 bash $(basename "$0")"
            return 1
        fi
        ok "下载完成: $(du -h "$archive" | cut -f1)"
    fi

    if [ "$skip_x" -ne 1 ]; then
        # ── 4. 解压到暂存目录并校验 ────────────────────────────────
        stage="$CACHE_DIR/.stage.$$"
        rm -rf "$stage"; mkdir -p "$stage" || return 1
        sub "解压校验..."
        if ! tar -xJf "$archive" -C "$stage" 2>/dev/null; then
            # 老版本包可能是 bz2
            if ! tar -xjf "$archive" -C "$stage" 2>/dev/null; then
                err "解压失败"; rm -rf "$stage"; return 1
            fi
        fi
        if [ ! -x "$stage/firefox/firefox" ]; then
            err "包内结构异常: 找不到可执行的 firefox/firefox"
            sub "包内顶层: $(ls -1 "$stage" 2>/dev/null | head -5 | tr '\n' ' ')"
            rm -rf "$stage"; return 1
        fi
        ok "解压校验通过"

        # ── 5. 原子替换(留一份 .prev 供回滚) ───────────────────────
        mkdir -p "$FF_HOME" || { rm -rf "$stage"; return 1; }
        if [ -d "$FF_APP" ]; then
            rm -rf "$FF_PREV"
            mv "$FF_APP" "$FF_PREV" || { err "备份旧版本失败"; rm -rf "$stage"; return 1; }
        fi
        if ! mv "$stage/firefox" "$FF_APP"; then
            err "放入新版本失败，回滚"
            [ -d "$FF_PREV" ] && mv "$FF_PREV" "$FF_APP"
            rm -rf "$stage"; return 1
        fi
        rm -rf "$stage"
        if [ ! -x "$FF_BIN_REAL" ]; then
            err "新版本校验失败，回滚到旧版本"
            rm -rf "$FF_APP"
            [ -d "$FF_PREV" ] && mv "$FF_PREV" "$FF_APP"
            return 1
        fi
        printf '%s\n' "$lang" >"$FF_HOME/.ffn-lang"
        ok "程序就位: $FF_APP  (version $(installed_version || echo '?'), $lang)"
        if [ -d "$FF_PREV" ]; then
            sub "上一版本留档: $FF_PREV (确认新版好用后可删)"
        fi
    fi

    # ── 6. 入口 wrapper(自动切原生 Wayland) ────────────────────────
    mkdir -p "$(dirname "$FF_ENTRY")" || return 1
    {
        printf '#!/usr/bin/env bash\n'
        printf '# 由 install-firefox-nightly-home.sh 生成 —— /home 自持入口\n'
        printf '# 装在用户可写目录里, Nightly 自带更新器可以真正自更新。\n'
        printf '[ -n "${WAYLAND_DISPLAY:-}" ] && export MOZ_ENABLE_WAYLAND=1\n'
        printf 'exec "%s" "$@"\n' "$FF_BIN_REAL"
    } >"$FF_ENTRY"
    chmod 755 "$FF_ENTRY"
    if bash -n "$FF_ENTRY"; then
        ok "入口就绪: $FF_ENTRY"
    else
        err "入口语法有误"; rm -f "$FF_ENTRY"; return 1
    fi

    # ── 7. 图标 + 桌面项 ───────────────────────────────────────────
    mkdir -p "$(dirname "$FF_ICON")" || return 1
    local cand=""
    cand="$(ls -1 "$FF_APP"/browser/chrome/icons/default/default*.png 2>/dev/null \
            | sort -V | tail -n1 || true)"
    if [ -z "$cand" ]; then
        # -exec du -b {} + 而不是 find|xargs: 图标路径可能含空格/换行, xargs 会拆错
        cand="$(find "$FF_APP" -maxdepth 5 -type f -iname '*.png' \
                -exec du -b {} + 2>/dev/null | sort -rn | head -n1 | cut -f2 || true)"
    fi
    if [ -n "$cand" ] && [ -f "$cand" ]; then
        cp -f "$cand" "$FF_ICON" && ok "图标已搬到 /home: $FF_ICON"
    else
        warn "包里没找到图标(png)，桌面项将不带图标"
    fi

    mkdir -p "$(dirname "$FF_DESKTOP")" || return 1
    {
        printf '[Desktop Entry]\n'
        printf 'Type=Application\n'
        printf 'Name=Firefox Nightly\n'
        printf 'GenericName=Web Browser\n'
        printf 'Comment=Nightly 通道浏览器(官方原版解压, 不占 rootfs、无沙箱)\n'
        printf 'Exec=%s %%u\n' "$FF_ENTRY"
        [ -f "$FF_ICON" ] && printf 'Icon=%s\n' "$FF_ICON"
        printf 'Terminal=false\n'
        printf 'Categories=Network;WebBrowser;\n'
        printf 'MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;\n'
        printf 'StartupNotify=true\n'
        printf 'StartupWMClass=Nightly\n'
    } >"$FF_DESKTOP"
    chmod 644 "$FF_DESKTOP"
    ok "桌面项就绪: $FF_DESKTOP"
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$(dirname "$FF_DESKTOP")" >/dev/null 2>&1 || true
    fi

    # ── 8. 归属(root 跑时产生的文件交还给用户) ────────────────────
    [ "$(id -u)" -eq 0 ] && chown -R "$REAL_USER:$REAL_GROUP" \
        "$FF_HOME" "$FF_ENTRY" "$FF_DESKTOP" "$FF_ICON" "$CACHE_DIR" 2>/dev/null

    # ── 9. 收尾 ────────────────────────────────────────────────────
    echo
    echo "════════ 完成 ════════"
    echo "  版本: $(installed_version || echo '?')"
    echo "  入口: $FF_ENTRY"
    echo "  程序: $FF_APP"
    echo "  缓存: $archive"
    echo
    echo "  · 日常不用管: Nightly 自带更新器会自更新(目录在 /home, 有写权限)。"
    echo "  · 原子升级后: 直接能用; 想确认就跑 --check。"
    echo "  · 想把 Nightly 设为默认浏览器:"
    echo "      xdg-settings set default-web-browser firefox-nightly.desktop"
    echo "  · 回收 rootfs 那 290M: bash $(basename "$0") --remove-system"
    echo "  · 首次务必彻底退出所有 Firefox 窗口再重开。"
}

main() {
    # 参数解析: --lang 取值
    while [ $# -gt 0 ]; do
        case "$1" in
            --lang) shift; FFN_LANG="${1:-zh-CN}" ;;
            --lang=*) FFN_LANG="${1#--lang=}" ;;
            --force) FFN_FORCE=1 ;;
            -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
            --check) do_check; return $? ;;
            --remove-system) do_remove_system; return $? ;;
            "") break ;;
            *) err "未知参数: $1 (可用: --lang zh-CN|en-US / --check / --remove-system / --help)"; return 2 ;;
        esac
        shift
    done
    do_install
}
main "$@"
