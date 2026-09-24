#!/usr/bin/env bash
# ===========================================================================
#  install-dsh-desktop-home.sh
#  把 DeepSeek Harness 桌面版(Tauri)装进 /home —— 不占 rootfs、无沙箱、扛原子升级
#  上游: https://github.com/dsh-tauri/deepseek-harness-desktop
# ---------------------------------------------------------------------------
#  【为什么用 AppImage 而不是 .deb】(2026-09-24 实测 deb 的 control 字段得到)
#  官方 Linux 只发两种: amd64.AppImage(90M) 与 amd64.deb(14M)。但那个 deb 的
#  Depends 是: libappindicator3-1, libwebkit2gtk-4.1-0, libgtk-3-0 ——
#  SteamOS 上这几个都没装, 装进 /usr 要吃掉几百 MB rootfs, 而且原子升级后
#  整块被冲掉, 得重装一遍。AppImage 自带 WebKitGTK 等运行时, 落在 /home 就
#  永久幸存 —— 这才是能同时满足"不沙箱"和"扛升级"的那一种。
#
#  【产物布局】
#     ~/.local/opt/deepseek-harness-desktop/
#       Deepseek.Harness.Desktop.AppImage   AppImage 原文件(FUSE 可用时直接跑,
#                                            这样应用内自更新能替换它)
#       app/                                解压树(FUSE 不可用时的回退, 无需 libfuse2)
#     ~/.local/bin/deepseek-harness-desktop 入口(自动在两种模式间选择)
#     ~/.local/share/applications/deepseek-harness-desktop.desktop
#     ~/.local/share/icons/deepseek-harness-desktop.png
#     ~/.cache/dsh-desktop/                 下载缓存(带续传)
#
#  【⚠️ 内核版本关系 —— 装完必须看一眼】
#  桌面版自己声明了推荐的内核版本(包内 resources/version-recommend.json,
#  当前 v0.17.0 要求 dsh >= 0.1.5-rc.3)。而本仓库 step[7] 把 CLI 固定在
#  0.1.2-rc.1(为兼容既有插件), **低于桌面版要求**。
#  而桌面版"如已安装 dsh 则优先使用安装版本" → 可能拿旧核心去跑。
#  本脚本会把这个差异打出来; 要改 CLI 版本请动 steamos-setup.sh 顶部的 DSH_VER。
#
#  【⚠️ 首次运行】
#  会联网下载 Node 运行时 + Harness 内核(几百 MB), 放进 /home, 之后本地运行。
#  它还会注册自己的 `dsh` 命令 shim —— 可能覆盖 ~/.local/bin/dsh。
#  本脚本会在安装前把现有的 dsh 备份成 ~/.local/bin/dsh.predshbak。
#
#  【用法】
#    bash install-dsh-desktop-home.sh                 # 安装/更新到最新版
#    bash install-dsh-desktop-home.sh --check         # 只读自检
#    bash install-dsh-desktop-home.sh --version v0.17.0   # 指定版本(API 不可达时用)
#    bash install-dsh-desktop-home.sh --force         # 已是最新也重装
#    MIRROR=https://ghfast.top bash install-dsh-desktop-home.sh   # 指定下载镜像
#    DSH_DESKTOP_MODE=appimage|extract bash 本脚本     # 强制启动方式(见入口注释)
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_I=$'\033[36m'; C_OK=$'\033[32m'; C_W=$'\033[33m'; C_E=$'\033[31m'
info() { printf '%s[*]%s %s\n' "$C_I" "$C_R" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_OK" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_W" "$C_R" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_E" "$C_R" "$*" >&2; }
sub()  { printf '    %s\n' "$*"; }

REPO="dsh-tauri/deepseek-harness-desktop"
# 兜底版本: 仅在 GitHub API 不可达且未给 --version 时使用(不是"最新版"的真相源)
FALLBACK_VER="0.17.0"
MIN_DSH_FALLBACK="0.1.5-rc.3"      # 读不到包内 version-recommend.json 时的兜底

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

APP_ROOT="$REAL_HOME/.local/opt/deepseek-harness-desktop"
APP_IMG="$APP_ROOT/Deepseek.Harness.Desktop.AppImage"
APP_DIR="$APP_ROOT/app"
APP_PREV="$APP_ROOT.prev"
APP_EXE="$APP_DIR/AppRun"
ENTRY="$REAL_HOME/.local/bin/deepseek-harness-desktop"
DESKTOP="$REAL_HOME/.local/share/applications/deepseek-harness-desktop.desktop"
ICON="$REAL_HOME/.local/share/icons/deepseek-harness-desktop.png"
CACHE_DIR="$REAL_HOME/.cache/dsh-desktop"
CLI_DSH="$REAL_HOME/.local/bin/dsh"

# ── 网络助手 ───────────────────────────────────────────────────────────
url_reachable() {
    curl -fsIL --connect-timeout 8 --max-time 15 "$1" >/dev/null 2>&1
}
# GitHub 直连在境内常失败 → 镜像优先(与本包 install-decky-* 同惯例)
mirrors_of() {
    local url="$1"
    [ -n "${MIRROR:-}" ] && printf '%s\n' "${MIRROR%/}/$url"
    printf '%s\n' "https://ghfast.top/$url" "https://gh-proxy.com/$url" "https://ghproxy.net/$url" "$url"
}
fetch_release_json() {
    local api out
    # ⚠ 只用真正支持 api.github.com 的镜像: 实测(2026-09-24) ghfast.top 与
    #   ghproxy.net 对 api.github.com 一律 403(它们只代理下载路径), 列进去白等超时。
    for api in "https://api.github.com" "https://gh-proxy.com/https://api.github.com"; do
        out="$(curl -fsSL --connect-timeout 10 --max-time 40 \
               "$api/repos/${REPO}/releases/latest" 2>/dev/null)" || continue
        if [ -n "$out" ] && printf '%s' "$out" | grep -q '"tag_name"'; then
            printf '%s' "$out"; return 0
        fi
    done
    return 1
}
# JSON → "tag<TAB>下载地址<TAB>字节数"(取 amd64.AppImage 资产)
pick_asset() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -c '
import json,sys
d=json.load(sys.stdin)
tag=d.get("tag_name","")
for a in d.get("assets",[]):
    n=a.get("name","")
    if n.endswith("_amd64.AppImage"):
        print("%s\t%s\t%s" % (tag, a["browser_download_url"], a.get("size",0))); break
' <<<"$1" 2>/dev/null
}
asset_url_for() { printf 'https://github.com/%s/releases/download/v%s/Deepseek.Harness.Desktop_%s_amd64.AppImage\n' "$REPO" "$1" "$1"; }

# 语义化比较: ver_ge A B  → A >= B ?
ver_num() { printf '%s\n' "$1" | sed -E 's/^v//; s/^([0-9]+(\.[0-9]+)*).*/\1/'; }
ver_pre() { case "$1" in *-*) printf '%s\n' "${1#*-}" ;; *) printf '' ;; esac; }
ver_ge() {
    local na nb pa pb i max x y
    local -a A B
    na="$(ver_num "$1")"; nb="$(ver_num "$2")"
    pa="$(ver_pre "$1")"; pb="$(ver_pre "$2")"
    IFS=. read -r -a A <<<"$na"; IFS=. read -r -a B <<<"$nb"
    max=${#A[@]}; [ "${#B[@]}" -gt "$max" ] && max=${#B[@]}
    for ((i=0;i<max;i++)); do
        x="${A[i]:-0}"; y="${B[i]:-0}"
        case "$x" in ''|*[!0-9]*) x=0 ;; esac
        case "$y" in ''|*[!0-9]*) y=0 ;; esac
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    [ -z "$pa" ] && return 0          # A 是正式版
    [ -n "$pb" ] && return 0          # 两边都是预发布 → 保守放过
    return 1                          # A 是预发布, B 是正式版 → 不够
}

installed_ver() { [ -f "$APP_ROOT/.version" ] && cat "$APP_ROOT/.version" 2>/dev/null; }
req_dsh_ver() {
    local f
    f="$(find "$APP_DIR" -maxdepth 6 -name 'version-recommend.json' 2>/dev/null | head -n1)"
    if [ -n "$f" ] && command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("dsh",""))' "$f" 2>/dev/null \
            || printf '%s\n' "$MIN_DSH_FALLBACK"
    else
        printf '%s\n' "$MIN_DSH_FALLBACK"
    fi
}
cli_dsh_ver() {
    local out
    out="$(timeout 15 "$CLI_DSH" --version 2>/dev/null || timeout 15 dsh --version 2>/dev/null || true)"
    printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' | head -n1
}
can_fuse() {
    [ -e /dev/fuse ] || return 1
    command -v ldconfig >/dev/null 2>&1 || return 1
    ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2'
}

# 内核版本关系体检(装/查都要看)
check_core() {
    local need have
    need="$(req_dsh_ver)"
    have="$(cli_dsh_ver)"
    if [ -n "$have" ]; then
        if [ -n "$need" ] && ! ver_ge "$have" "$need"; then
            warn "CLI 的 dsh 是 $have, 但桌面版推荐 >= $need —— 桌面版会优先用这个旧核心"
            sub "两条路: ①把 steamos-setup.sh 顶部的 DSH_VER 升上去(--after-upgrade 重跑[7])"
            sub "        ②先不动 CLI, 看桌面版能否只用它自带下载的核心"
        else
            ok "CLI dsh $have 满足桌面版要求(>= ${need:-?})"
        fi
    else
        info "未发现 CLI 版 dsh → 桌面版会用它自己下载的核心(首次运行需联网)"
    fi
}

# ===========================================================================
#  --check
# ===========================================================================
do_check() {
    local fail=0 v src srv
    echo "════════ DeepSeek Harness 桌面版 /home 自持形态 自检 ════════"
    echo "用户: $REAL_USER   家目录: $REAL_HOME"

    if [ -x "$APP_EXE" ] || [ -x "$APP_IMG" ]; then
        v="$(installed_ver)"
        ok "已安装: ${v:-未知版本}  ($(du -sh "$APP_ROOT" 2>/dev/null | cut -f1))"
        [ -d "$APP_DIR" ] && sub "解压树: $APP_DIR"
        [ -x "$APP_IMG" ] && sub "AppImage: $APP_IMG"
    else
        err "未安装: $APP_ROOT"
        sub "→ 跑: bash install-dsh-desktop-home.sh"
        fail=1
    fi

    [ -x "$ENTRY" ] && ok "入口: $ENTRY" || { err "入口缺失: $ENTRY"; fail=1; }
    [ -f "$DESKTOP" ] && ok "桌面项就绪" || { warn "桌面项缺失"; fail=1; }
    [ -f "$ICON" ] && ok "图标就绪" || warn "图标缺失(菜单里会没图标)"

    src="$(findmnt -no SOURCE --target "$REAL_HOME" 2>/dev/null || true)"
    srv="$(findmnt -no SOURCE --target "$APP_ROOT" 2>/dev/null || true)"
    if [ -n "$srv" ] && [ "$src" = "$srv" ]; then
        ok "落在 home 分区($srv) → 原子升级幸存"
    elif [ -n "$srv" ]; then
        warn "不在 /home 同一分区($srv vs ${src:-?}) —— 可能被原子升级冲掉"
        fail=1
    else
        info "（读不到挂载信息，跳过分区判定）"
    fi

    if can_fuse; then
        info "FUSE2 可用 → 入口会优先直接跑 AppImage(应用内自更新可替换它)"
    else
        info "FUSE2 不可用 → 入口会跑解压树(无需 libfuse2, 但应用内自更新可能失效)"
        sub "补 FUSE: sudo pacman -S fuse2   (会占 rootfs 且升级后被冲, 非必需)"
    fi

    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':3080 '; then
        warn "3080 端口已被占用 —— 桌面版/ dsh web 默认就用 3080, 同时开会冲突"
    fi

    check_core

    if command -v pacman >/dev/null 2>&1 && pacman -Qq deepseek-harness-desktop >/dev/null 2>&1; then
        warn "另有 pacman 版装着(在 rootfs, 升级会冲掉, 且入口重名) —— 建议 pacman -Rns 掉"
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
#  安装 / 更新
# ===========================================================================
do_install() {
    local tag ver url base archive stage src_url ok_dl=0 m expect=0 have=0
    local -a cands=()

    echo "════════ 把 DeepSeek Harness 桌面版装进 /home ════════"

    # ── 1. 解析版本 ────────────────────────────────────────────────
    if [ -n "${PIN_VER:-}" ]; then
        ver="${PIN_VER#v}"
        url="$(asset_url_for "$ver")"
        info "使用指定版本: v$ver"
    else
        sub "查询最新版本(GitHub API, 直连失败自动走镜像)..."
        local j
        if j="$(fetch_release_json)"; then
            local pair
            pair="$(pick_asset "$j" || true)"
            if [ -n "$pair" ]; then
                tag="$(printf '%s' "$pair" | cut -f1)"
                url="$(printf '%s' "$pair" | cut -f2)"
                expect="$(printf '%s' "$pair" | cut -f3)"
                ver="${tag#v}"
                info "最新版本: $tag  (${expect:-?} 字节)"
            fi
        fi
        if [ -z "${url:-}" ]; then
            warn "GitHub API 不可达(境内常见) → 退回内置兜底版本 v$FALLBACK_VER"
            sub "要装别的版本: bash $(basename "$0") --version v0.18.0"
            ver="$FALLBACK_VER"
            url="$(asset_url_for "$ver")"
        fi
    fi
    base="$(basename "$url")"
    local cur; cur="$(installed_ver)"
    [ -n "$cur" ] && info "本地版本: $cur"

    # ── 2. 已经是最新就不折腾 ──────────────────────────────────────
    if [ "${FORCE:-0}" -ne 1 ] && [ -n "$cur" ] && [ "$cur" = "$ver" ] \
       && { [ -x "$APP_EXE" ] || [ -x "$APP_IMG" ]; }; then
        ok "已是最新(v$ver)，跳过重装(想强制重来加 --force)"
    else
        # ── 3. 下载(固定缓存目录 + 续传 + 镜像择优) ─────────────────
        #  完整性判据用"文件大小 == API 报的 size"，不要只看文件存在 ——
        #  中断留下的残包也存在，光看存在会跳过下载然后在解压时才发现坏包。
        mkdir -p "$CACHE_DIR" || return 1
        archive="$CACHE_DIR/$base"
        [ -s "$archive" ] && have="$(stat -c%s "$archive" 2>/dev/null || echo 0)"
        if [ "${expect:-0}" -gt 0 ] && [ "$have" = "$expect" ]; then
            ok "缓存包完整，跳过下载: $(du -h "$archive" | cut -f1)"
        else
            if [ "${have:-0}" -gt 0 ]; then
                sub "发现残包 $(numfmt --to=iec "$have" 2>/dev/null || echo "${have}B")，继续续传..."
            fi
            sub "下载 → $archive  (约 90MB; 中断了重跑会接着下)"
            while IFS= read -r m; do cands+=("$m"); done < <(mirrors_of "$url")
            for src_url in "${cands[@]}"; do
                sub "源: $(printf '%s' "$src_url" | cut -c1-78)"
                if curl -L --http1.1 --retry 2 --retry-delay 2 -C - \
                        --connect-timeout 15 --max-time 1800 \
                        -o "$archive" "$src_url" 2>/dev/null; then
                    ok_dl=1; break
                fi
                warn "该源失败，留着残包换下一个(支持续传)"
            done
            if [ "$ok_dl" -ne 1 ]; then
                err "所有源都失败。可自备镜像或手动下载后放到缓存目录:"
                sub "MIRROR=https://你的镜像 bash $(basename "$0")"
                sub "缓存目录: $CACHE_DIR"
                sub "需要的文件名: $base"
                return 1
            fi
            have="$(stat -c%s "$archive" 2>/dev/null || echo 0)"
            if [ "${expect:-0}" -gt 0 ] && [ "$have" != "$expect" ]; then
                warn "大小对不上(实 $have / 期望 $expect) —— 可能被镜像截断，以解压结果为准"
            fi
            ok "下载完成: $(du -h "$archive" | cut -f1)"
        fi

        chmod +x "$archive" 2>/dev/null || true

        # ── 4. 解压(AppImage 自带 --appimage-extract, 不需要 FUSE) ──
        stage="$CACHE_DIR/.stage.$$"
        rm -rf "$stage"; mkdir -p "$stage" || return 1
        sub "解压 AppImage(--appimage-extract, 不需要 libfuse2)..."
        if ! ( cd "$stage" && "$archive" --appimage-extract >/dev/null 2>&1 ); then
            err "解压失败 —— 下载不完整或不是标准 AppImage。"
            sub "可先删掉缓存重下: rm -f $archive"
            rm -rf "$stage"; return 1
        fi
        if [ ! -d "$stage/squashfs-root" ]; then
            err "解压后没有 squashfs-root —— 包结构异常"
            sub "顶层内容: $(ls -1 "$stage" 2>/dev/null | head -5 | tr '\n' ' ')"
            rm -rf "$stage"; return 1
        fi
        if [ ! -e "$stage/squashfs-root/AppRun" ]; then
            err "解压树里没有 AppRun —— 无法启动"
            rm -rf "$stage"; return 1
        fi
        chmod +x "$stage/squashfs-root/AppRun" 2>/dev/null || true
        ok "解压校验通过"

        # ── 5. 原子替换(留 .prev 供回滚) ────────────────────────────
        mkdir -p "$APP_ROOT" || { rm -rf "$stage"; return 1; }
        if [ -d "$APP_DIR" ]; then
            rm -rf "$APP_PREV"
            mv "$APP_DIR" "$APP_PREV" || { err "备份旧版本失败"; rm -rf "$stage"; return 1; }
        fi
        if ! mv "$stage/squashfs-root" "$APP_DIR"; then
            err "放入新版本失败，回滚"
            [ -d "$APP_PREV" ] && mv "$APP_PREV" "$APP_DIR"
            rm -rf "$stage"; return 1
        fi
        rm -rf "$stage"
        if [ ! -e "$APP_DIR/AppRun" ]; then
            err "新版本校验失败，回滚"
            rm -rf "$APP_DIR"
            [ -d "$APP_PREV" ] && mv "$APP_PREV" "$APP_DIR"
            return 1
        fi
        # 保住 AppImage 原文件: FUSE 可用时直接跑它, 应用内自更新才能替换自己
        mv -f "$archive" "$APP_IMG" 2>/dev/null || cp -f "$archive" "$APP_IMG" 2>/dev/null || true
        [ -x "$APP_IMG" ] || warn "AppImage 原文件未就位(不影响解压树模式启动)"
        printf '%s\n' "$ver" >"$APP_ROOT/.version"
        ok "程序就位: $APP_DIR  (v$ver)"
        [ -d "$APP_PREV" ] && sub "上一版本留档: $APP_PREV (确认新版好用后可删)"
    fi

    # ── 6. 备份 CLI dsh(桌面版首次运行可能注册自己的 shim 覆盖它) ──
    if [ -e "$CLI_DSH" ] && [ ! -e "$CLI_DSH.predshbak" ]; then
        cp -a "$CLI_DSH" "$CLI_DSH.predshbak" 2>/dev/null \
            && info "已备份 CLI dsh → $CLI_DSH.predshbak (被桌面版覆盖时可还原)"
    fi

    # ── 7. 入口(自动选择 FUSE / 解压树) ───────────────────────────
    mkdir -p "$(dirname "$ENTRY")" || return 1
    {
        printf '#!/usr/bin/env bash\n'
        printf '# 由 install-dsh-desktop-home.sh 生成 —— /home 自持入口\n'
        printf '# 优先直接跑 AppImage(应用内自更新能替换自己); 没有 FUSE2 就退回解压树。\n'
        printf '# 强制方式: DSH_DESKTOP_MODE=appimage|extract\n'
        printf 'APP_IMG="%s"\n' "$APP_IMG"
        printf 'APP_DIR="%s"\n' "$APP_DIR"
        printf 'case "${DSH_DESKTOP_MODE:-auto}" in\n'
        printf '  appimage) exec "$APP_IMG" "$@" ;;\n'
        printf '  extract)  exec "$APP_DIR/AppRun" "$@" ;;\n'
        printf 'esac\n'
        printf 'if [ -e /dev/fuse ] && command -v ldconfig >/dev/null 2>&1 \\\n'
        printf '   && ldconfig -p 2>/dev/null | grep -q "libfuse\\.so\\.2"; then\n'
        printf '  exec "$APP_IMG" "$@"\n'
        printf 'fi\n'
        printf 'exec "$APP_DIR/AppRun" "$@"\n'
    } >"$ENTRY"
    chmod 755 "$ENTRY"
    if bash -n "$ENTRY"; then
        ok "入口就绪: $ENTRY"
    else
        err "入口语法有误"; rm -f "$ENTRY"; return 1
    fi

    # ── 8. 桌面项 + 图标(照搬包内 .desktop 的关键字段, 别自己编) ──
    local bdesk="" name="Deepseek Harness Desktop" comment="Desktop application for DeepSeek Harness"
    local wmclass="deepseek-harness-desktop" cats="Development;" mimes="x-scheme-handler/dsh"
    bdesk="$(find "$APP_DIR" -maxdepth 4 -name '*.desktop' 2>/dev/null | head -n1)"
    if [ -n "$bdesk" ]; then
        local t
        t="$(sed -n 's/^Name=//p' "$bdesk" | head -n1)";            [ -n "$t" ] && name="$t"
        t="$(sed -n 's/^Comment=//p' "$bdesk" | head -n1)";         [ -n "$t" ] && comment="$t"
        t="$(sed -n 's/^StartupWMClass=//p' "$bdesk" | head -n1)";  [ -n "$t" ] && wmclass="$t"
        t="$(sed -n 's/^Categories=//p' "$bdesk" | head -n1)";      [ -n "$t" ] && cats="$t"
        t="$(sed -n 's/^MimeType=//p' "$bdesk" | head -n1)";        [ -n "$t" ] && mimes="$t"
        info "已从包内 .desktop 继承字段(WMClass=$wmclass)"
    else
        warn "包内没找到 .desktop, 用内置默认字段"
    fi

    mkdir -p "$(dirname "$ICON")" || return 1
    local icand=""
    icand="$(ls -1 "$APP_DIR"/usr/share/icons/hicolor/512x512/apps/*.png 2>/dev/null | head -n1 || true)"
    [ -z "$icand" ] && icand="$(ls -1 "$APP_DIR"/usr/share/icons/hicolor/*/apps/*.png 2>/dev/null | sort -V | tail -n1 || true)"
    [ -z "$icand" ] && [ -e "$APP_DIR/.DirIcon" ] && icand="$APP_DIR/.DirIcon"
    [ -z "$icand" ] && icand="$(find "$APP_DIR" -maxdepth 6 -type f -name '*.png' 2>/dev/null | head -n1 || true)"
    if [ -n "$icand" ] && [ -f "$icand" ]; then
        cp -f "$icand" "$ICON" && ok "图标已搬到 /home: $ICON (源自 ${icand#$APP_DIR/})"
    else
        warn "没找到图标(png)，桌面项将不带图标"
    fi

    mkdir -p "$(dirname "$DESKTOP")" || return 1
    # Categories/MimeType 必须以 ';' 结尾, 否则桌面文件不合法
    case "$cats" in *';') ;; *) cats="$cats;" ;; esac
    [ -n "$mimes" ] && case "$mimes" in *';') ;; *) mimes="$mimes;" ;; esac
    {
        printf '[Desktop Entry]\n'
        printf 'Type=Application\n'
        printf 'Name=%s\n' "$name"
        printf 'Comment=%s (官方 AppImage 解到 /home, 不占 rootfs)\n' "$comment"
        printf 'Exec=%s %%u\n' "$ENTRY"
        [ -f "$ICON" ] && printf 'Icon=%s\n' "$ICON"
        printf 'Terminal=false\n'
        printf 'Categories=%s\n' "$cats"
        [ -n "$mimes" ] && printf 'MimeType=%s\n' "$mimes"
        printf 'StartupWMClass=%s\n' "$wmclass"
        printf 'StartupNotify=true\n'
    } >"$DESKTOP"
    chmod 644 "$DESKTOP"
    ok "桌面项就绪: $DESKTOP"
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$(dirname "$DESKTOP")" >/dev/null 2>&1 || true

    # ── 9. 归属 ────────────────────────────────────────────────────
    [ "$(id -u)" -eq 0 ] && chown -R "$REAL_USER:$REAL_GROUP" \
        "$APP_ROOT" "$ENTRY" "$DESKTOP" "$ICON" "$CACHE_DIR" 2>/dev/null

    # ── 10. 收尾 ───────────────────────────────────────────────────
    echo
    check_core
    echo
    echo "════════ 完成 ════════"
    echo "  版本: v$(installed_ver)"
    echo "  入口: $ENTRY"
    echo "  程序: $APP_DIR"
    echo
    echo "  · 首次启动会联网下载 Node 运行时 + Harness 内核(几百 MB, 落在 /home)。"
    echo "  · 原子升级后直接能用; 想确认就跑 --check。"
    echo "  · 启动即黑屏/无窗口时依次试(运维侧解法, 上游 README 同款):"
    echo "      1) WEBKIT_DISABLE_COMPOSITING_MODE=1 WEBKIT_DISABLE_DMABUF_RENDERER=1 GDK_BACKEND=x11 $ENTRY"
    echo "      2) LD_PRELOAD=/usr/lib/libwayland-client.so.0 $ENTRY"
    echo "      3) DSH_DESKTOP_MODE=extract $ENTRY   (强制走解压树)"
    echo "  · 应用内自更新只在入口走 AppImage 模式时能替换自己; 解压树模式请重跑本脚本。"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) shift; PIN_VER="${1:-}" ;;
            --version=*) PIN_VER="${1#--version=}" ;;
            --force) FORCE=1 ;;
            -h|--help) sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
            --check) do_check; return $? ;;
            "") break ;;
            *) err "未知参数: $1 (可用: --check / --version vX.Y.Z / --force / --help)"; return 2 ;;
        esac
        shift
    done
    do_install
}
main "$@"
