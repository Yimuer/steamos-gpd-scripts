#!/usr/bin/env bash
# ===========================================================================
#  install-app-home.sh —— 统一的「便携包 → /home 自持」安装引擎
# ---------------------------------------------------------------------------
#  合并了原来 3 个各 440+ 行的独立脚本（firefox / dsh / wps），它们的骨架完全一样：
#    取一个成品包 → 解包校验 → 准原子替换到 /home 或 /opt → 生成入口/桌面项/图标
#  这里把这套骨架实现一次，每个应用只写"取源 / 解包 / 入口内容 / 桌面项字段 / 额外步骤"
#  这几段 profile。**仍然只有一个文件，自包含性不丢**（不依赖任何 lib/）。
#
#  ⚠️ workbuddy 不在这里 —— 它不下载任何产物，而是"让 AUR 装好的 /opt/WorkBuddy
#     在 /home 下自持"，与"下载便携包"是两个物种。硬塞进来只会得到一堆
#     `if app == workbuddy` 特例分支，反而不如让它单独一个脚本。
#
#  用法:
#    bash install-app-home.sh <app> [选项]
#    bash install-app-home.sh --list                 # 列出支持的 app
#    bash install-app-home.sh firefox-nightly        # 安装/修复(幂等)
#    bash install-app-home.sh wps-office --check     # 只读自检
#    bash install-app-home.sh dsh-desktop --force    # 强制重装(仍用缓存)
#    bash install-app-home.sh firefox-nightly --remove-system   # 卸系统 firefox 回收 290M
#    bash install-app-home.sh firefox-nightly --lang en-US      # 换英文原版
#    bash install-app-home.sh dsh-desktop --version v0.17.1     # API 不可达时钉版本
#
#  支持的 app:
#    firefox-nightly   Firefox Nightly(官方 tar.xz)      → ~/.local/opt/firefox-nightly
#    dsh-desktop       DeepSeek Harness 桌面版(官方 AppImage) → ~/.local/opt/deepseek-harness-desktop
#    wps-office        WPS Office 中文版(官方签名 deb)     → /opt/kingsoft + ~/.local
#
#  通用环境变量: MIRROR(镜像前缀) FORCE=1(等同 --force) REFETCH=1(强制重新下载)
#  各 app 专属环境变量见下方 profile 注释。
#
#  【为什么都往 /home 装】SteamOS 大版本升级会整块替换 rootfs(/etc /usr 全冲)，
#  而 /home 与 /opt 幸存(/opt 是 bind-mount 到 home 分区的)。
#  所以：能搬 /home 的搬 /home；必须落 /opt 的（WPS 的官方 Relocations）也天然幸存。
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_I=$'\033[36m'; C_OK=$'\033[32m'; C_W=$'\033[33m'; C_E=$'\033[31m'; C_D=$'\033[2m'
info() { printf '%s[*]%s %s\n' "$C_I" "$C_R" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_OK" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_W" "$C_R" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_E" "$C_R" "$*" >&2; }
sub()  { printf '    %s\n' "$*"; }
step() { printf '\n%s════════ %s ════════%s\n' "$C_D" "$1" "$C_R"; }
die()  { err "$*"; exit 1; }

# ── 运行身份(经 sudo 时定位真用户的家目录) ─────────────────────────────
if [ "$(id -u)" -eq 0 ]; then
    REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
else
    REAL_USER="$(id -un)"
fi
[ -n "${REAL_USER:-}" ] || REAL_USER="deck"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[ -n "${REAL_HOME:-}" ] || REAL_HOME="/home/$REAL_USER"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"

LOCAL="$REAL_HOME/.local"
BIN_DIR="$LOCAL/bin"
APPS_DIR="$LOCAL/share/applications"
ICON_DIR="$LOCAL/share/icons/hicolor"
MIME_DIR="$LOCAL/share/mime"

MIRROR="${MIRROR:-}"
FORCE="${FORCE:-0}"

run_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif command -v sudo >/dev/null 2>&1; then sudo "$@"
    else die "需要 root 但本机没有 sudo"; fi
}

list_apps() { printf '  %s\n' firefox-nightly dsh-desktop wps-office; }

# ===========================================================================
#  公共框架
# ===========================================================================

# fetch <缓存文件名> <URL...> —— 固定缓存目录(不用 mktemp: 随机名让 -C - 续传永久失效)
# ⚠️ 本函数用 stdout 返回"路径", 所以所有提示必须走 stderr ——
#    否则 ARCHIVE="$(fetch ...)" 会把日志一起吞进去, 后面 bsdtar 就找不到文件(踩过)
fetch() {
    local name="$1"; shift
    local dir="$CACHE_DIR" f="$CACHE_DIR/$name" u
    mkdir -p "$dir" || return 1
    if [ -s "$f" ] && [ "${REFETCH:-0}" -eq 0 ]; then
        ok "缓存可用($(du -h "$f" | cut -f1))，跳过下载" >&2
        printf '%s\n' "$f"; return 0
    fi
    for u in "$@"; do
        [ -n "$u" ] || continue
        sub "源: $(printf '%s' "$u" | cut -c1-96)" >&2
        if curl -fL --http1.1 --retry 3 --retry-delay 2 -C - \
                --connect-timeout 20 --max-time 3600 -o "$f" "$u" 2>/dev/null; then
            ok "下载完成: $(du -h "$f" | cut -f1)" >&2
            printf '%s\n' "$f"; return 0
        fi
        warn "  该源失败，换下一个" >&2; rm -f "$f"
    done
    err "所有源都失败"; return 1
}

# 准原子替换: <stage 里的相对路径> → <目标目录>
# 旧树先挪成 .prev(同分区 mv, 秒级)，新的进来且校验通过后再删 .prev；中途失败回滚。
atomic_install() {
    local src="$1" dest="$2" prev="$2.prev" as_root="${3:-0}"
    [ -e "$src" ] || { err "暂存里没有 $src"; return 1; }
    if [ "$as_root" -eq 1 ]; then
        run_root mkdir -p "$(dirname "$dest")" || return 1
        [ -e "$dest" ] && { run_root rm -rf "$prev" 2>/dev/null || true; run_root mv "$dest" "$prev" || return 1; }
        if ! run_root cp -a "$src" "$dest"; then
            err "复制失败(空间不足?) —— 回滚"; run_root rm -rf "$dest" 2>/dev/null || true
            [ -e "$prev" ] && run_root mv "$prev" "$dest" 2>/dev/null
            return 1
        fi
        run_root rm -rf "$prev" 2>/dev/null || true
    else
        mkdir -p "$(dirname "$dest")" || return 1
        [ -e "$dest" ] && { rm -rf "${prev:?}" 2>/dev/null || true; mv "$dest" "$prev" || return 1; }
        if ! cp -a "$src" "$dest"; then
            err "复制失败(空间不足?) —— 回滚"; rm -rf "${dest:?}" 2>/dev/null || true
            [ -e "$prev" ] && mv "$prev" "$dest" 2>/dev/null
            return 1
        fi
        rm -rf "${prev:?}" 2>/dev/null || true
    fi
    ok "已就位: $dest"
}

# find_icon <根目录> [优先匹配的 glob...] —— 找到就打印路径
find_icon() {
    local root="$1"; shift
    local pat cand=""
    for pat in "$@"; do
        # shellcheck disable=SC2086
        cand="$(ls -1 $root/$pat 2>/dev/null | sort -V | tail -n1 || true)"
        [ -n "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    done
    # -exec du -b {} + 而不是 find|xargs: 路径可能含空格/换行, xargs 会拆错
    cand="$(find "$root" -maxdepth 6 -type f -iname '*.png' \
            -exec du -b {} + 2>/dev/null | sort -rn | head -n1 | cut -f2 || true)"
    [ -n "$cand" ] && printf '%s\n' "$cand"
}

# copy_icon <图标源> <目标名> —— 搬到 hicolor, 并刷新缓存
copy_icon() {
    local src="$1" name="$2"
    [ -n "$src" ] && [ -f "$src" ] || { warn "没找到图标(png)，桌面项将不带图标"; return 1; }
    mkdir -p "$ICON_DIR/256x256/apps" || return 1
    cp -f "$src" "$ICON_DIR/256x256/apps/$name.png" || return 1
    ok "图标已搬到 /home: $ICON_DIR/256x256/apps/$name.png"
}

# write_desktop <文件名> <Name> <Comment> <Exec> <图标路径或空> <Categories> [MimeType] [WMClass]
write_desktop() {
    local fname="$1" name="$2" comment="$3" exec="$4" icon="$5" cats="$6" mimes="${7:-}" wm="${8:-}"
    mkdir -p "$APPS_DIR" || return 1
    # Categories/MimeType 必须以 ';' 结尾, 否则桌面文件不合法
    case "$cats" in *';') ;; *) cats="$cats;" ;; esac
    if [ -n "$mimes" ]; then case "$mimes" in *';') ;; *) mimes="$mimes;" ;; esac; fi
    {
        printf '[Desktop Entry]\n'
        printf 'Type=Application\n'
        printf 'Name=%s\n' "$name"
        [ -n "$comment" ] && printf 'Comment=%s\n' "$comment"
        printf 'Exec=%s %%u\n' "$exec"
        [ -n "$icon" ] && [ -f "$icon" ] && printf 'Icon=%s\n' "$icon"
        printf 'Terminal=false\n'
        printf 'Categories=%s\n' "$cats"
        [ -n "$mimes" ] && printf 'MimeType=%s\n' "$mimes"
        [ -n "$wm" ] && printf 'StartupWMClass=%s\n' "$wm"
        printf 'StartupNotify=true\n'
    } >"$APPS_DIR/$fname"
    chmod 644 "$APPS_DIR/$fname"
    ok "桌面项就绪: $APPS_DIR/$fname"
}

refresh_caches() {
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 \
        && gtk-update-icon-cache -f -t "$LOCAL/share/icons/hicolor" >/dev/null 2>&1 || true
    command -v update-mime-database >/dev/null 2>&1 && [ -d "$MIME_DIR" ] \
        && update-mime-database "$MIME_DIR" >/dev/null 2>&1 || true
}

# 生成入口 wrapper: 内容由各 app 提供(argv: 目标路径)
write_entry() {
    local dest="$1"; shift
    mkdir -p "$(dirname "$dest")" || return 1
    "$@" >"$dest" || { err "生成入口失败: $dest"; return 1; }
    chmod 755 "$dest"
    bash -n "$dest" || { err "入口语法有误: $dest"; rm -f "$dest"; return 1; }
    ok "入口就绪: $dest"
}

# ===========================================================================
#  App profile 分派
# ===========================================================================
app_setup() {
    case "$APP" in
        firefox-nightly)
            TITLE="Firefox Nightly"
            NEEDS_ROOT=0
            VENDOR_DIR="$LOCAL/opt/firefox-nightly"
            CACHE_DIR="$REAL_HOME/.cache/firefox-nightly"
            STAGE_REL="firefox"; DEST_DIR="$VENDOR_DIR/firefox"
            ;;
        dsh-desktop)
            TITLE="DeepSeek Harness 桌面版"
            NEEDS_ROOT=0
            VENDOR_DIR="$LOCAL/opt/deepseek-harness-desktop"
            CACHE_DIR="$REAL_HOME/.cache/dsh-desktop"
            STAGE_REL="squashfs-root"; DEST_DIR="$VENDOR_DIR/app"
            DSH_IMG="$VENDOR_DIR/Deepseek.Harness.Desktop.AppImage"
            ;;
        wps-office)
            TITLE="WPS Office 中文版"
            NEEDS_ROOT=1
            VENDOR_DIR="/opt/kingsoft"
            CACHE_DIR="$REAL_HOME/.cache/wps-office"
            STAGE_REL="opt/kingsoft/wps-office"; DEST_DIR="/opt/kingsoft/wps-office"
            ;;
        *) die "未知 app: $APP (可用: $(list_apps | tr -d ' ' | tr '\n' ' '))" ;;
    esac
}

# 取源: 打印 "版本|URL1|URL2..."(按优先级)
app_urls() {
    case "$APP" in
        firefox-nightly) ffn_urls ;;
        dsh-desktop)     dsh_urls ;;
        wps-office)      wps_urls ;;
    esac
}

# 解包到 $STAGE 并校验; 需要的话打印"额外要保留的文件"(如 dsh 的 AppImage 本体)
app_extract() {
    case "$APP" in
        firefox-nightly) ffn_extract ;;
        dsh-desktop)     dsh_extract ;;
        wps-office)      wps_extract ;;
    esac
}

# 生成入口: 单入口的 app 走 write_entry(自动 chmod + bash -n);
# WPS 要生成 4 个(wps/wpp/et/wpspdf) 且有薄壳逻辑, 自己写。
app_entry() {
    case "$APP" in
        firefox-nightly) write_entry "$FFN_ENTRY" ffn_entry_body ;;
        dsh-desktop)     write_entry "$DSH_ENTRY" dsh_entry_body ;;
        wps-office)      wps_entries ;;
    esac
}

# 卸系统版(firefox 专属): 装好 Nightly 后再回收 rootfs 那 290M
app_remove_system() {
    case "$APP" in
        firefox-nightly) ffn_remove_system ;;
        *) err "$APP 不支持 --remove-system"; return 2 ;;
    esac
}

ffn_remove_system() {
    [ -x "$DEST_DIR/firefox" ] \
        || { err "Nightly 还没装好 —— 先跑安装，确认能用再删系统版，否则就没浏览器了"; return 1; }
    local found=() p ans size=""
    for p in firefox firefox-nightly firefox-developer-edition firefox-beta-bin; do
        pacman -Qq "$p" >/dev/null 2>&1 && found+=("$p")
    done
    if [ "${#found[@]}" -eq 0 ]; then
        info "系统里没有 pacman 版 firefox*，无需处理"; return 0
    fi
    size="$(du -sh /usr/lib/firefox 2>/dev/null | cut -f1)"
    warn "将卸载: ${found[*]}   (rootfs 回收约 ${size:-290M})"
    sub "pacman -Rns 会连带删掉无主依赖，请先看清输出"
    if [ -t 0 ]; then
        echo -n "确认继续？输入 yes: "
        read -r ans
        [ "$ans" = "yes" ] || { info "已取消"; return 1; }
    else
        warn "非交互环境，已取消(请在 Konsole 里跑)"; return 1
    fi
    if run_root pacman -Rns --noconfirm "${found[@]}"; then
        ok "已卸载 ${found[*]}，rootfs 回收约 ${size:-290M}"
    else
        err "卸载失败"; return 1
    fi
}

# 桌面项 + 图标
app_desktop() {
    case "$APP" in
        firefox-nightly) ffn_desktop ;;
        dsh-desktop)     dsh_desktop ;;
        wps-office)      wps_desktop ;;
    esac
}

# 额外步骤(依赖/mime/清理)
app_extra() {
    case "$APP" in
        firefox-nightly) ffn_extra ;;
        dsh-desktop)     dsh_extra ;;
        wps-office)      wps_extra ;;
    esac
}

# ===========================================================================
#  firefox-nightly
#  env: FFN_LANG(默认 zh-CN) FFN_MIRROR(自定义下载前缀)
# ===========================================================================
FFN_LANG="${FFN_LANG:-zh-CN}"
FFN_ENTRY="$BIN_DIR/firefox-nightly"

ffn_urls() {
    local base="https://download.mozilla.org/?product=firefox-nightly-latest-l10n-ssl&os=linux64&lang=$FFN_LANG"
    local arch="https://archive.mozilla.org/pub/firefox/nightly/latest-mozilla-central-l10n/firefox-${FFN_LANG}.linux-x86_64.tar.xz"
    printf 'nightly|%s\n' "$base"
    # ⚠️ 别写成 `[ -n ... ] && printf` 收尾: 条件为假时函数会返回 1,
    #    调用方 `meta="$(app_urls)" || return 1` 会静默失败(踩过)。
    if [ -n "${FFN_MIRROR:-}" ]; then
        printf 'nightly|%s/%s\n' "${FFN_MIRROR%/}" "$arch"
    fi
}

ffn_extract() {
    bsdtar -xf "$ARCHIVE" -C "$STAGE" 2>/dev/null || tar -xf "$ARCHIVE" -C "$STAGE" 2>/dev/null \
        || return 1
    [ -x "$STAGE/firefox/firefox" ] || { err "包里没有可执行的 firefox/firefox"; return 1; }
    ok "解包校验通过($(du -sh "$STAGE/firefox" 2>/dev/null | cut -f1))"
}

ffn_entry_body() {
    printf '#!/usr/bin/env bash\n'
    printf '# 由 install-app-home.sh(firefox-nightly) 生成 —— /home 自持入口\n'
    printf '# 装在用户可写目录里, Nightly 自带更新器可以真正自更新。\n'
    printf '[ -n "${WAYLAND_DISPLAY:-}" ] && export MOZ_ENABLE_WAYLAND=1\n'
    printf 'exec "%s/firefox" "$@"\n' "$DEST_DIR"
}

ffn_desktop() {
    local ic=""
    ic="$(find_icon "$DEST_DIR" 'browser/chrome/icons/default/default*.png')"
    copy_icon "$ic" firefox-nightly
    write_desktop "firefox-nightly.desktop" "$TITLE" \
        "Nightly 通道浏览器(官方原版解压, 不占 rootfs、无沙箱)" \
        "$FFN_ENTRY" "$ICON_DIR/256x256/apps/firefox-nightly.png" \
        "Network;WebBrowser" \
        "text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https" \
        "Nightly"
}

ffn_extra() { :; }

# ===========================================================================
#  dsh-desktop
#  env: DSH_DESKTOP_MODE=auto|appimage|extract  PIN_VER(钉版本)
# ===========================================================================
DSH_REPO="dsh-tauri/deepseek-harness-desktop"
DSH_FALLBACK_VER="0.17.1"
DSH_ENTRY="$BIN_DIR/deepseek-harness-desktop"

dsh_tag() {
    local api t=""
    for api in "https://api.github.com" "https://gh-proxy.com/https://api.github.com"; do
        # ⚠ ghfast/ghproxy.net 不代理 api.github.com(403), 别加进来白等
        t="$(curl -sL --connect-timeout 8 --max-time 25 "$api/repos/$DSH_REPO/releases/latest" 2>/dev/null \
             | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        [ -n "$t" ] && break
    done
    printf '%s\n' "${t:-v$DSH_FALLBACK_VER}"
}

dsh_urls() {
    local ver="${PIN_VER:-$(dsh_tag)}"; ver="${ver#v}"
    local asset="Deepseek.Harness.Desktop_${ver}_amd64.AppImage"
    local gh="https://github.com/$DSH_REPO/releases/download/v$ver/$asset"
    local m
    printf '%s|%s\n' "$ver" "$gh"
    for m in "$MIRROR" "https://gh-proxy.com" "https://ghfast.top" "https://ghproxy.net"; do
        [ -n "$m" ] || continue          # 未设 MIRROR 时跳过空项
        printf '%s|%s/%s\n' "$ver" "${m%/}" "$gh"
    done
}

dsh_extract() {
    chmod +x "$ARCHIVE" 2>/dev/null || true
    ( cd "$STAGE" && "$ARCHIVE" --appimage-extract >/dev/null 2>&1 ) \
        || { err "AppImage 解压失败(--appimage-extract)"; return 1; }
    [ -d "$STAGE/squashfs-root" ] || { err "解压后没有 squashfs-root —— 包结构异常"; return 1; }
    [ -e "$STAGE/squashfs-root/AppRun" ] || { err "squashfs-root 里没有 AppRun"; return 1; }
    chmod +x "$STAGE/squashfs-root/AppRun" 2>/dev/null || true
    ok "解包校验通过"
}

dsh_entry_body() {
    printf '#!/usr/bin/env bash\n'
    printf '# 由 install-app-home.sh(dsh-desktop) 生成 —— /home 自持入口\n'
    printf '# 优先直接跑 AppImage(应用内自更新能替换自己); 没有 FUSE2 就退回解压树。\n'
    printf '# 强制方式: DSH_DESKTOP_MODE=appimage|extract\n'
    printf 'APP_IMG="%s"\n' "$DSH_IMG"
    printf 'APP_DIR="%s"\n' "$DEST_DIR"
    printf 'case "${DSH_DESKTOP_MODE:-auto}" in\n'
    printf '  appimage) exec "$APP_IMG" "$@" ;;\n'
    printf '  extract)  exec "$APP_DIR/AppRun" "$@" ;;\n'
    printf 'esac\n'
    printf 'if [ -e /dev/fuse ] && command -v ldconfig >/dev/null 2>&1 \\\n'
    printf '   && ldconfig -p 2>/dev/null | grep -q "libfuse\\.so\\.2"; then\n'
    printf '  exec "$APP_IMG" "$@"\n'
    printf 'fi\n'
    printf 'exec "$APP_DIR/AppRun" "$@"\n'
}

dsh_desktop() {
    # 桌面项字段照搬包内 .desktop(别自己编)
    local bdesk="" name="$TITLE" comment="Desktop application for DeepSeek Harness"
    local wmclass="deepseek-harness-desktop" cats="Development" mimes="x-scheme-handler/dsh" t
    bdesk="$(find "$DEST_DIR" -maxdepth 4 -name '*.desktop' 2>/dev/null | head -n1)"
    if [ -n "$bdesk" ]; then
        t="$(sed -n 's/^Name=//p' "$bdesk" | head -n1)";           [ -n "$t" ] && name="$t"
        t="$(sed -n 's/^Comment=//p' "$bdesk" | head -n1)";        [ -n "$t" ] && comment="$t"
        t="$(sed -n 's/^StartupWMClass=//p' "$bdesk" | head -n1)"; [ -n "$t" ] && wmclass="$t"
        t="$(sed -n 's/^Categories=//p' "$bdesk" | head -n1)";     [ -n "$t" ] && cats="$t"
        t="$(sed -n 's/^MimeType=//p' "$bdesk" | head -n1)";       [ -n "$t" ] && mimes="$t"
        info "已从包内 .desktop 继承字段(WMClass=$wmclass)"
    else
        warn "包内没找到 .desktop, 用内置默认字段"
    fi
    local ic=""
    ic="$(find_icon "$DEST_DIR" 'usr/share/icons/hicolor/512x512/apps/*.png' 'usr/share/icons/hicolor/*/apps/*.png' '.DirIcon')"
    copy_icon "$ic" deepseek-harness-desktop
    write_desktop "deepseek-harness-desktop.desktop" "$name" \
        "$comment (官方 AppImage 解到 /home, 不占 rootfs)" \
        "$DSH_ENTRY" "$ICON_DIR/256x256/apps/deepseek-harness-desktop.png" \
        "$cats" "$mimes" "$wmclass"
}

dsh_extra() {
    # 保留 AppImage 本体: 入口优先直接跑它(应用内自更新可替换自身)
    mkdir -p "$VENDOR_DIR" || return 0
    mv -f "$ARCHIVE" "$DSH_IMG" 2>/dev/null || cp -f "$ARCHIVE" "$DSH_IMG" 2>/dev/null || true
    # 包内若声明所需 dsh CLI 版本, 顺带提示
    local rec="$DEST_DIR/resources/version-recommend.json" need=""
    [ -f "$rec" ] && need="$(sed -n 's/.*"dsh"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$rec" | head -1)"
    if [ -n "$need" ]; then
        local have=""
        command -v dsh >/dev/null 2>&1 && have="$(dsh --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -1)"
        if [ -n "$have" ] && [ "$have" != "$need" ]; then
            warn "包内建议 dsh CLI $need, 本机是 $have —— 插件兼容性以包内建议为准"
        else
            sub "包内建议的 dsh CLI 版本: $need"
        fi
    fi
}

# ===========================================================================
#  wps-office
#  env: WPS_VER(默认 12.1.2.28080) WPS_DEB(本地 deb) WPS_CHANNEL
# ===========================================================================
WPS_VER="${WPS_VER:-12.1.2.28080}"
WPS_CHANNEL="${WPS_CHANNEL:-Linux2023}"
WPS_SIGN_KEY="${WPS_SIGN_KEY:-7f8faaaa468174dc1c9cd62e5f218a5b}"
WPS_LEGACY_BASE="${WPS_LEGACY_BASE:-https://wdl1.pcfg.cache.wpscdn.com/wpsdl/wpsoffice/download/linux}"
WPS_DEPS_ARCH=(glibc gcc-libs freetype2 libcups glib2 glu libsm libxrender fontconfig libxext libxcb bzip2)
WPS_BINS=(wps wpp et wpspdf)
WPS_WBIN="$LOCAL/opt/wps-office/bin"
WPS_DEB_NAME="wps-office_${WPS_VER}_amd64.deb"

wps_urls() {
    local uri t k
    uri="/wps/download/ep/${WPS_CHANNEL}/${WPS_VER##*.}/wps-office_${WPS_VER}.AK.preread.sw.Personal_765474_amd64.deb"
    t="$(date '+%s')"
    k="$(printf '%s' "${WPS_SIGN_KEY}${uri}${t}" | md5sum | cut -d' ' -f1)"
    printf '%s|https://wps-linux-personal.wpscdn.cn%s?t=%s&k=%s\n' "$WPS_VER" "$uri" "$t" "$k"
    printf '%s|%s/%s/wps-office_%s.XA_amd64.deb\n' "$WPS_VER" "$WPS_LEGACY_BASE" "${WPS_VER##*.}" "$WPS_VER"
}

wps_extract() {
    if ! bsdtar -tf "$ARCHIVE" 2>/dev/null | grep -q '^data\.tar'; then
        err "deb 里没有 data.tar.* —— 不是标准 deb"; return 1
    fi
    bsdtar -xf "$ARCHIVE" -C "$STAGE" 2>/dev/null || { err "解包 deb(ar)失败"; return 1; }
    local dtx; dtx="$(ls -1 "$STAGE"/data.tar* 2>/dev/null | head -1)"
    [ -n "$dtx" ] || { err "没找到 data.tar.*"; return 1; }
    bsdtar -xf "$dtx" -C "$STAGE" 2>/dev/null || { err "解包 data.tar 失败"; return 1; }
    [ -d "$STAGE/opt/kingsoft/wps-office/office6" ] \
        || { err "包结构异常: 找不到 opt/kingsoft/wps-office/office6"; return 1; }
    ok "解包校验通过"
}

wps_running() {
    pgrep -x wps >/dev/null 2>&1 || pgrep -x wpp >/dev/null 2>&1 \
        || pgrep -x et >/dev/null 2>&1 || pgrep -x wpscloudsvr >/dev/null 2>&1
}

wps_entries() {
    # 官方包装脚本在包内 usr/bin/, 另存一份到 /home; 入口做成薄壳:
    # 有 /usr/bin 的官方件就优先用它, 没有(升级后被冲)就用 /home 副本。
    local b n=0
    mkdir -p "$WPS_WBIN" "$BIN_DIR" || return 1
    for b in "${WPS_BINS[@]}"; do
        if [ -f "$STAGE/usr/bin/$b" ]; then
            cp -f "$STAGE/usr/bin/$b" "$WPS_WBIN/$b"; chmod 755 "$WPS_WBIN/$b" 2>/dev/null
            {
                printf '#!/usr/bin/env bash\n'
                printf '# 由 install-app-home.sh(wps-office) 生成\n'
                printf '# WPS 是 Qt 应用: 缩放/输入法跟随异常时用 WPS_X11=1 走 XWayland\n'
                printf '[ "${WPS_X11:-0}" = "1" ] && export QT_QPA_PLATFORM=xcb\n'
                printf 'if [ -x /usr/bin/%s ]; then exec /usr/bin/%s "$@"; fi\n' "$b" "$b"
                printf 'exec "%s/%s" "$@"\n' "$WPS_WBIN" "$b"
            } >"$BIN_DIR/$b"
            chmod 755 "$BIN_DIR/$b"
            bash -n "$BIN_DIR/$b" 2>/dev/null && n=$((n+1)) || warn "入口语法有误: $b"
        else
            warn "包里没有 usr/bin/$b(官方版式变了?)"
        fi
    done
    [ "$n" -gt 0 ] && ok "入口就绪: $BIN_DIR/{${WPS_BINS[*]}} ($n 个)" || warn "入口一个都没生成"
}

wps_desktop() {
    # 图标
    local ic=""
    ic="$(find_icon "$STAGE" 'usr/share/icons/hicolor/256x256/mimetypes/wps-office*.png' \
                                   'usr/share/icons/hicolor/*/apps/wps-office*.png')"
    mkdir -p "$ICON_DIR/256x256/apps"
    local n=0 i
    if [ -n "$ic" ]; then
        while IFS= read -r i; do
            [ -n "$i" ] && cp -f "$i" "$ICON_DIR/256x256/apps/" 2>/dev/null && n=$((n+1))
        done < <(find "$STAGE/usr/share/icons/hicolor" -type f -name 'wps-office*.png' 2>/dev/null | head -20)
    fi
    [ "$n" -gt 0 ] && ok "图标已搬到 /home ($n 个)" || warn "没找到 WPS 图标"

    # 桌面项: 照搬官方件, 但把"相对路径"的 Exec/TryExec 改成绝对路径
    #   ⚠ 必须同时改 Exec 和 TryExec —— TryExec 找不到会把整个菜单项隐藏掉
    mkdir -p "$APPS_DIR"; local d src n2=0
    for src in "$STAGE"/usr/share/applications/wps-office-*.desktop; do
        [ -f "$src" ] || continue
        d="$APPS_DIR/$(basename "$src")"
        sed -E "s#^Exec=([a-z]+)( |\$)#Exec=$BIN_DIR/\1\2#; s#^TryExec=([a-z]+)\$#TryExec=$BIN_DIR/\1#" \
            "$src" >"$d" 2>/dev/null && n2=$((n2+1))
    done
    [ "$n2" -gt 0 ] && ok "桌面项就位($n2 个, Exec/TryExec 已改绝对路径)" || warn "没生成桌面项"

    # 自定义 mime(用户级注册, 扛升级)
    if [ -d "$STAGE/usr/share/mime/packages" ]; then
        mkdir -p "$MIME_DIR/packages"
        cp -f "$STAGE"/usr/share/mime/packages/*.xml "$MIME_DIR/packages/" 2>/dev/null \
            && ok "mime 类型已注册(用户级)" || true
    fi
}

wps_extra() {
    # 依赖: deb 的 Depends 对应的 Arch 包, 少装会表现为"点了没反应"
    local miss=() p
    if command -v pacman >/dev/null 2>&1; then
        for p in "${WPS_DEPS_ARCH[@]}"; do pacman -Qq "$p" >/dev/null 2>&1 || miss+=("$p"); done
        if [ "${#miss[@]}" -gt 0 ]; then
            info "缺运行库: ${miss[*]} → 用 pacman 补(在 rootfs, 升级后需重装)"
            run_root pacman -S --noconfirm --needed "${miss[@]}" >/dev/null 2>&1 \
                && ok "运行库已补齐" || warn "补依赖失败, WPS 可能起不来"
        else
            ok "运行库齐备"
        fi
    fi
    command -v fc-list >/dev/null 2>&1 && fc-list 2>/dev/null | grep -qi "cjk\|wenquanyi\|noto sans sc" \
        || warn "没检测到中文字体 —— 菜单可能显示方块(装 noto-fonts-cjk 或用可选组件的鸿蒙字体)"
}

# ===========================================================================
#  do_check / do_install / main
# ===========================================================================
do_check() {
    local f=0
    printf '════════ %s 自检(%s) ════════\n' "$TITLE" "$APP"
    printf '用户: %s   安装根: %s\n' "$REAL_USER" "$DEST_DIR"
    case "$APP" in
        firefox-nightly)
            [ -x "$DEST_DIR/firefox" ] && ok "程序在: $DEST_DIR/firefox" || { err "程序缺失: $DEST_DIR/firefox"; f=1; }
            [ -x "$FFN_ENTRY" ] && ok "入口在: $FFN_ENTRY" || { err "入口缺失"; f=1; }
            [ -f "$DEST_DIR/application.ini" ] && [ -d "$DEST_DIR/updater" ] \
                && ok "自带更新器在(用户可写目录里能真正自更新)" || warn "没看到 updater/ —— 自更新可能不可用"
            ;;
        dsh-desktop)
            [ -x "$DEST_DIR/AppRun" ] && ok "解压树在: $DEST_DIR/AppRun" || { err "解压树缺失"; f=1; }
            [ -f "$DSH_IMG" ] && ok "AppImage 本体在(FUSE 可用时优先跑它)" || warn "AppImage 本体不在, 只能走解压树"
            [ -x "$DSH_ENTRY" ] && ok "入口在: $DSH_ENTRY" || { err "入口缺失"; f=1; }
            ;;
        wps-office)
            [ -d "$DEST_DIR/office6" ] && ok "本体在: $DEST_DIR" || { err "本体缺失"; f=1; }
            local n=0 b; for b in "${WPS_BINS[@]}"; do [ -x "$BIN_DIR/$b" ] && n=$((n+1)); done
            [ "$n" -gt 0 ] && ok "入口在: $BIN_DIR/{${WPS_BINS[*]}} ($n 个)" || { err "入口缺失"; f=1; }
            ;;
    esac
    [ -f "$APPS_DIR/$APP.desktop" ] && ok "桌面项在: $APPS_DIR/$APP.desktop" \
        || { [ -f "$APPS_DIR/firefox-nightly.desktop" ] && [ "$APP" = firefox-nightly ] \
             && ok "桌面项在" || warn "桌面项缺失(不影响命令行使用)"; }
    echo
    if [ "$f" -eq 0 ]; then echo "════ 结论: 就绪 ════"; return 0; fi
    echo "════ 结论: 有缺件 → 重跑 bash $(basename "$0") $APP ════"; return 1
}

do_install() {
    step "安装 $TITLE → $( [ "$NEEDS_ROOT" -eq 1 ] && echo "$DEST_DIR(需 root, 但 /opt 扛升级)" || echo "$VENDOR_DIR(/home 扛升级)")"
    mkdir -p "$CACHE_DIR" "$VENDOR_DIR" "$BIN_DIR" "$APPS_DIR" 2>/dev/null || true

    # ── 1. 取源 ──
    local meta ver urls=() u
    meta="$(app_urls)" || return 1
    ver="$(printf '%s\n' "$meta" | head -1 | cut -d'|' -f1)"
    while IFS= read -r u; do [ -n "$u" ] && urls+=("$(printf '%s' "$u" | cut -d'|' -f2-)") ; done \
        <<<"$(printf '%s\n' "$meta" | sed 's/^[^|]*|//')"
    info "目标版本: $ver"

    # ── 2. 已是同一版本 → 跳过"下载/解包/复制"这三件重活(仍补入口与桌面项) ──
    #   WPS 那 2GB 复制尤其不该白做; 重跑通常只是想补入口/桌面项。
    local installed=""
    [ -f "$VENDOR_DIR/.version" ] && installed="$(cat "$VENDOR_DIR/.version" 2>/dev/null)"
    if [ "$FORCE" -eq 0 ] && [ -n "$installed" ] && [ "$installed" = "$ver" ] && [ -d "$DEST_DIR" ]; then
        ok "已是 $ver → 跳过下载/解包/复制(只补入口/桌面项)"
        app_entry; app_desktop; app_extra; refresh_caches
        echo
        echo "════════ 完成(未重装本体) ════════"
        printf '  版本  : %s\n  安装根: %s\n' "$ver" "$DEST_DIR"
        return 0
    fi

    if [ "$APP" = wps-office ] && [ -n "${WPS_DEB:-}" ]; then
        ARCHIVE="$WPS_DEB"
        [ -f "$ARCHIVE" ] || { err "WPS_DEB 不存在: $ARCHIVE"; return 1; }
        info "使用本地 deb: $ARCHIVE"
    else
        local cname="$WPS_DEB_NAME"
        [ "$APP" = firefox-nightly ] && cname="firefox-nightly-${FFN_LANG}.tar.xz"
        [ "$APP" = dsh-desktop ] && cname="Deepseek.Harness.Desktop_${ver}_amd64.AppImage"
        ARCHIVE="$(fetch "$cname" "${urls[@]}")" || return 1
    fi

    # ── 2. 解包到暂存 ──
    STAGE="$CACHE_DIR/.stage.$$"
    rm -rf "${STAGE:?}"; mkdir -p "$STAGE" || return 1
    sub "解包..."
    if ! app_extract; then rm -rf "${STAGE:?}"; return 1; fi

    # ── 3. WPS: 先确认没在运行(官方 preinst 也是 killall) ──
    if [ "$APP" = wps-office ] && wps_running; then
        err "WPS 正在运行 —— 先完全退出(含后台 wpscloudsvr)再跑"
        sub "或执行: killall wps wpp et wpsoffice wpspdf wpscloudsvr"
        rm -rf "${STAGE:?}"; return 1
    fi

    # ── 4. 准原子替换 ──
    if ! atomic_install "$STAGE/$STAGE_REL" "$DEST_DIR" "$NEEDS_ROOT"; then
        rm -rf "${STAGE:?}"; return 1
    fi
    [ -d "$DEST_DIR" ] || { err "安装后校验失败: $DEST_DIR 不存在"; rm -rf "${STAGE:?}"; return 1; }

    # ── 5. 入口 / 桌面项 / 额外步骤 ──
    app_entry
    app_desktop
    app_extra
    printf '%s\n' "$ver" >"$VENDOR_DIR/.version" 2>/dev/null || true
    [ "$NEEDS_ROOT" -eq 0 ] && chown -R "$REAL_USER:$REAL_GROUP" "$VENDOR_DIR" 2>/dev/null || true

    refresh_caches
    rm -rf "${STAGE:?}"

    echo
    echo "════════ 完成 ════════"
    printf '  版本  : %s\n' "$ver"
    printf '  安装根: %s\n' "$DEST_DIR"
    echo "  · 没生效的话: 注销重登一次(桌面数据库/图标缓存需要刷新会话)。"
    echo "  · 只读复查: bash $(basename "$0") $APP --check"
}

main() {
    [ $# -ge 1 ] || { err "用法: bash $(basename "$0") <app> [--check|--force]"; list_apps; exit 2; }
    case "$1" in
        --list|-l) list_apps; exit 0 ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
    APP="$1"; shift
    MODE=install; SEEN_LANG=0; SEEN_VER=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --check) MODE=check ;;
            --force) FORCE=1 ;;
            --remove-system) MODE=remove-system ;;
            --lang) shift; FFN_LANG="${1:-zh-CN}"; SEEN_LANG=1 ;;
            --version) shift; PIN_VER="${1:-}"; SEEN_VER=1 ;;
            -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) err "未知参数: $1"; exit 2 ;;
        esac
        shift
    done
    app_setup
    # app 专属参数只对对应 app 有意义, 用错就明确报错, 别默默忽略
    [ "$SEEN_LANG" -eq 1 ] && [ "$APP" != firefox-nightly ] && { err "--lang 只适用于 firefox-nightly"; exit 2; }
    [ "$SEEN_VER"  -eq 1 ] && [ "$APP" != dsh-desktop ]     && { err "--version 只适用于 dsh-desktop"; exit 2; }
    case "$MODE" in
        check) do_check ;;
        remove-system) app_remove_system ;;
        install) do_install ;;
    esac
}
main "$@"
