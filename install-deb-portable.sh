#!/usr/bin/env bash
# ===========================================================================
#  install-deb-portable.sh —— 任意 deb 包的「/home 便携化」安装器
# ---------------------------------------------------------------------------
#  【解决什么】SteamOS 的大版本升级会整块替换 rootfs(/usr /etc 全被冲)。而 Linux
#  官方软件大多数只发 .deb —— 直接 `pacman`/`dpkg` 装进 /usr, 升级后就"凭空消失"。
#  本脚本把 deb **拆包搬进 /home**, 于是升级后照常能用(与 WPS / Clash Verge 同套路)。
#
#  【怎么用】
#    bash install-deb-portable.sh                     # 可视化: 选文件/URL → 一路对话框
#    bash install-deb-portable.sh <URL 或本地 .deb>    # 命令行(非交互需给 --name/--bin)
#    bash install-deb-portable.sh --check             # 列出已便携化安装的应用 + 缺库体检
#    bash install-deb-portable.sh --remove <名字>      # 卸载(只删 /home 下那套)
#
#  常用开关:
#    --name <名字>      安装名(默认取 deb 包名, 决定 /home 下的目录与菜单名)
#    --bin <相对路径>   主程序相对路径(如 usr/bin/foo); 不给就自动挑/让你选
#    --prefix <目录>    安装根(默认 ~/.local/opt/<名字>)
#    --no-deps          不尝试补依赖(只报告)
#    --force            覆盖同名已安装的应用
#
#  【三条设计要点(踩过才知道)】
#   1. **必须保留包内的相对结构**(一般是 usr/)。Electron/Tauri 的资源是按可执行文件
#      的相对位置找的, 打散成 bin/ + lib/ 会起不来。所以整棵树搬, 不做重组。
#   2. **入口 wrapper 先自检依赖**。deb 常依赖 /usr 里的库(如 Tauri 需要 webkit2gtk),
#      那部分升级会被冲 —— 缺库时 wrapper 直接打印可复制的装回命令, 绝不"点了没反应"。
#   3. **落点全在 /home**: 本体 ~/.local/opt/<名字>, 入口 ~/.local/bin/<名字>,
#      桌面项/图标 ~/.local/share/{applications,icons}。rootfs 一个字节都不占。
#
#  【可视化】有 DISPLAY + kdialog 时用对话框(选文件/选主程序/确认装依赖);
#   没有就回退终端交互(带 -t 超时守卫, 非交互环境不会永久挂起)。
#
#  合规: 本脚本只负责安装软件; 软件用途请遵守所在地法律法规与所在网络的管理规定。
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_I=$'\033[36m'; C_OK=$'\033[32m'; C_W=$'\033[33m'; C_E=$'\033[31m'
info() { printf '%s[*]%s %s\n' "$C_I" "$C_R" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_OK" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_W" "$C_R" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_E" "$C_R" "$*" >&2; }
sub()  { printf '    %s\n' "$*"; }
die()  { err "$*"; exit 1; }

# ── 运行身份 / 家目录(sudo 下 $HOME 是 /root, 必须解析真实用户) ──────────
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
OPTROOT="$LOCAL/opt"
BIN_DIR="$LOCAL/bin"
APPS_DIR="$LOCAL/share/applications"
ICON_DIR="$LOCAL/share/icons/hicolor"

# ── 可视化: kdialog 优先, 没有就终端 ────────────────────────────────────
have_gui() { [ -n "${DISPLAY:-}" ] && command -v kdialog >/dev/null 2>&1; }
gui_input() {  # $1 标题 $2 提示 $3 默认值 → 打印用户输入
    if have_gui; then kdialog --title "$1" --inputbox "$2" "$3" 2>/dev/null; return; fi
    printf '%s [%s]: ' "$2" "$3" >&2
    local v=""; [ -t 0 ] && read -r -t 300 v || v=""
    printf '%s\n' "${v:-$3}"
}
gui_yesno() {  # $1 标题 $2 提示 → 退出码 0=是
    if have_gui; then kdialog --title "$1" --yesno "$2" 2>/dev/null; return $?; fi
    printf '%s [y/N]: ' "$2" >&2
    [ -t 0 ] || return 1
    local v=""; read -r -t 300 v || true
    case "$v" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
gui_pick_file() {
    if have_gui; then kdialog --getopenfilename "$REAL_HOME" '*.deb *.DEB|Debian 软件包 (*.deb)' 2>/dev/null; return; fi
    printf '请输入本地 deb 的完整路径: ' >&2
    local v=""; [ -t 0 ] && read -r -t 300 v || v=""
    printf '%s\n' "$v"
}
gui_pick_one() {  # $1 标题 $2 提示, 其余: "tag|描述" → 打印选中 tag
    local title="$1" text="$2"; shift 2
    if have_gui; then
        local args=() first=1 it
        for it in "$@"; do
            args+=("${it%%|*}" "${it#*|}")
            if [ "$first" -eq 1 ]; then args+=("on"); first=0; else args+=("off"); fi
        done
        kdialog --title "$title" --radiolist "$text" "${args[@]}" 2>/dev/null
        return
    fi
    printf '%s\n' "$text" >&2
    local i=1 it
    for it in "$@"; do printf '  %d) %s\n' "$i" "${it#*|}" >&2; i=$((i + 1)); done
    printf '选择编号: ' >&2
    local n=""; [ -t 0 ] && read -r -t 300 n || n=""
    i=1
    for it in "$@"; do [ "$n" = "$i" ] && { printf '%s\n' "${it%%|*}"; return; }; i=$((i + 1)); done
    printf '%s\n' "${1%%|*}"
}
gui_msg() { if have_gui; then kdialog --title "$1" --msgbox "$2" 2>/dev/null; else printf '%s\n%s\n' "$1" "$2"; fi; }

# ── 参数 ────────────────────────────────────────────────────────────────
SRC=""; NAME=""; BIN_REL=""; PREFIX=""; NO_DEPS=0; FORCE=0; DO_CHECK=0; REMOVE=""
MIRROR="${MIRROR:-}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)   DO_CHECK=1; shift ;;
        --remove)  REMOVE="${2:?--remove 需要名字}"; shift 2 ;;
        --name)    NAME="${2:?--name 需要值}"; shift 2 ;;
        --bin)     BIN_REL="${2:?--bin 需要值}"; shift 2 ;;
        --prefix)  PREFIX="${2:?--prefix 需要值}"; shift 2 ;;
        --no-deps) NO_DEPS=1; shift ;;
        --force|-f) FORCE=1; shift ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        die "未知参数: $1 (用 --help 看用法)" ;;
        *)         [ -z "$SRC" ] || die "多余的源: $1"; SRC="$1"; shift ;;
    esac
done

# ===========================================================================
#  --check : 只读体检(升级后跑它就知道哪些应用还缺 /usr 里的库)
# ===========================================================================
do_check() {
    local d m name ver bin miss
    echo "════════ 已便携化安装的应用(/home 自持) ════════"
    local found=0
    for d in "$OPTROOT"/*; do
        m="$d/.deb-portable"
        [ -f "$m" ] || continue
        found=1
        name="$(sed -n 's/^NAME=//p' "$m" | head -1)"
        ver="$(sed -n 's/^VERSION=//p' "$m" | head -1)"
        bin="$(sed -n 's/^BIN=//p' "$m" | head -1)"
        printf '  %s' "${name:-$(basename "$d")}"
        [ -n "$ver" ] && printf ' (%s)' "$ver"
        echo
        sub "目录: $d"
        if [ -n "$bin" ] && [ -x "$d/$bin" ]; then
            miss="$(missing_libs "$d/$bin")"
            if [ "$miss" = "UNKNOWN" ]; then
                warn "  无法判定依赖(ldd 无输出) —— 以实际启动为准"
            elif [ -n "$miss" ]; then
                warn "  缺库(升级被冲?): $(printf '%s' "$miss" | tr '\n' ' ')"
            else
                ok "  依赖齐全"
            fi
        else
            warn "  主程序不在: ${bin:-未知}"
        fi
    done
    [ "$found" -eq 1 ] || echo "  (还没有装过任何便携化 deb)"
}

# 列出某个可执行文件**当前**缺失的动态库(不启动程序)。
# ⚠️ 两个坑都踩过:
#   ① ldd 需要**可执行位** —— 解出来的文件若没带 +x, ldd 静默无输出 → 会误判成"依赖齐全"
#      (假绿灯, 与本项目最恨的那类同款)。所以先补 +x。
#   ② ldd 完全没输出(非 ELF / 静态链接 / 工具缺失)时, 要报"无法判定"而不是"齐全"。
missing_libs() {
    local f="$1" m="" out=""
    [ -f "$f" ] || { printf 'UNKNOWN\n'; return 0; }
    [ -x "$f" ] || chmod +x "$f" 2>/dev/null || true
    out="$(ldd "$f" 2>/dev/null)"
    if [ -z "$out" ]; then printf 'UNKNOWN\n'; return 0; fi
    m="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([^ ]*\.so[^ ]*\)[[:space:]]*=> not found.*/\1/p' | sort -u)"
    printf '%s\n' "$m"
}

# 尝试把 .so 反查成包名(pacman -F 需要 files 数据库; 没有就返回空)
lib_to_pkgs() {
    local libs="$1" out="" l
    command -v pacman >/dev/null 2>&1 || return 0
    for l in $libs; do
        local hit=""
        hit="$(pacman -F "/usr/lib/$l" 2>/dev/null | sed -n 's#^[^ ]*/##p' | awk '{print $1}' | sort -u | head -2 | tr '\n' ' ')"
        [ -n "$hit" ] && out="$out $hit"
    done
    printf '%s\n' "$out" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# ===========================================================================
#  --remove
# ===========================================================================
do_remove() {
    local d="$OPTROOT/$REMOVE"
    [ -d "$d" ] || die "没装过: $REMOVE (已装的: $(ls -1 "$OPTROOT" 2>/dev/null | tr '\n' ' '))"
    if ! gui_yesno "卸载 $REMOVE" "将删除 $d 及其入口/桌面项/图标(只动 /home, 不动系统)。继续?"; then
        info "已取消"; return 0
    fi
    # ⚠️ 空变量=删根, 逐个加 :? 守卫(项目铁律 §2)
    rm -rf "${d:?}" "${BIN_DIR:?}/$REMOVE" "${APPS_DIR:?}/$REMOVE.desktop" \
           "${ICON_DIR:?}/256x256/apps/$REMOVE.png" 2>/dev/null || true
    ok "已卸载: $REMOVE"
}

# ===========================================================================
#  安装主流程
# ===========================================================================
do_install() {
    # ── 1. 取源 ──
    if [ -z "$SRC" ]; then
        if gui_yesno "deb 便携化安装" "手上有本地 .deb 文件吗?\n(选「否」则改为输入下载链接)"; then
            SRC="$(gui_pick_file)"
        else
            SRC="$(gui_input "deb 便携化安装" "请输入 deb 的下载链接(支持 GitHub 等直链):" "")"
        fi
    fi
    [ -n "$SRC" ] || die "没有源(既没给文件也没给链接)"

    local deb="" tmpdir=""
    tmpdir="$REAL_HOME/.cache/deb-portable"
    mkdir -p "$tmpdir" || die "无法创建缓存目录: $tmpdir"
    case "$SRC" in
        http://*|https://*)
            deb="$tmpdir/$(basename "${SRC%%\?*}")"
            [ -s "$deb" ] || { info "下载: $SRC"; fetch_deb "$SRC" "$deb" || die "下载失败"; }
            ;;
        *)
            [ -f "$SRC" ] || die "文件不存在: $SRC"
            deb="$SRC"
            ;;
    esac
    # deb 的基本校验: ar 包, 且含 data.tar.*
    local member=""
    member="$(bsdtar -tf "$deb" 2>/dev/null | grep -E '^data\.tar\.(gz|zst|xz)$' | head -1)"
    [ -n "$member" ] || die "这不是有效的 deb(找不到 data.tar.*): $deb"
    ok "deb 就绪: $(basename "$deb") ($(du -h "$deb" 2>/dev/null | cut -f1))"

    # ── 2. 解包到暂存区 ──
    local stage="" tree_root=""
    stage="$(mktemp -d "${tmpdir}/stage.XXXXXX")" || die "无法创建暂存目录"
    mkdir -p "$stage/tree" || die "无法创建 $stage/tree"
    case "$member" in
        *.zst) bsdtar -xOf "$deb" "$member" 2>/dev/null | zstd -dcf 2>/dev/null | tar -xf - -C "$stage/tree" ;;
        *.xz)  bsdtar -xOf "$deb" "$member" 2>/dev/null | tar -xJf - -C "$stage/tree" ;;
        *)     bsdtar -xOf "$deb" "$member" 2>/dev/null | tar -xzf - -C "$stage/tree" ;;
    esac
    # 包里的"树根": 多数是 usr/, 少数直接是 opt/ 或其它
    tree_root="tree"
    [ -d "$stage/tree/usr" ] && tree_root="tree/usr"
    ok "解包完成(树根: ${tree_root#tree/})"

    # ── 3. 定名字 ──
    if [ -z "$NAME" ]; then
        local ctl_pkg=""
        ctl_pkg="$(bsdtar -xOf "$deb" 'control.tar.gz' 2>/dev/null | bsdtar -xOf - './control' 2>/dev/null \
                   | sed -n 's/^Package:[[:space:]]*//p' | head -1)"
        NAME="$ctl_pkg"
        [ -n "$NAME" ] || NAME="$(basename "$deb" .deb | tr '[:upper:]' '[:lower:]')"
        NAME="$(printf '%s' "$NAME" | tr ' ' '-' | tr -cd 'A-Za-z0-9._+-')"
        if [ -t 0 ] || have_gui; then
            NAME="$(gui_input "安装名" "给这个应用起个安装名(决定目录与菜单项):" "$NAME")"
        fi
    fi
    NAME="$(printf '%s' "$NAME" | tr ' ' '-' | tr -cd 'A-Za-z0-9._+-')"
    [ -n "$NAME" ] || die "名字为空"

    local dest=""
    dest="${PREFIX:-$OPTROOT/$NAME}"
    if [ -e "$dest" ] && [ "$FORCE" -ne 1 ]; then
        die "已存在: $dest (加 --force 覆盖, 或换 --name/--prefix)"
    fi

    # ── 4. 挑主程序 ──
    local -a ELFS=()
    while IFS= read -r f; do
        [ -n "$f" ] && ELFS+=("$f")
    done < <(find "$stage/$tree_root/bin" -maxdepth 1 -type f -executable 2>/dev/null | sort)

    local bdesk=""
    bdesk="$(find "$stage/$tree_root/share/applications" -maxdepth 1 -name '*.desktop' 2>/dev/null | head -1)"
    if [ -z "$BIN_REL" ] && [ -n "$bdesk" ]; then
        # 优先信包内 .desktop 的 Exec=(相对树根的路径; 可能是裸命令名)
        local ex=""
        ex="$(sed -n 's/^Exec=//p' "$bdesk" | head -1 | sed 's/ .*$//' | tr -d '"')"
        case "$ex" in
            /*) BIN_REL="${ex#/}" ;;
            *)  [ -n "$ex" ] && [ -e "$stage/$tree_root/bin/$ex" ] && BIN_REL="bin/$ex" ;;
        esac
    fi
    if [ -z "$BIN_REL" ]; then
        if [ "${#ELFS[@]}" -eq 1 ]; then
            BIN_REL="${ELFS[0]#$stage/$tree_root/}"
        elif [ "${#ELFS[@]}" -gt 1 ]; then
            local opts=() f
            for f in "${ELFS[@]}"; do opts+=("${f#$stage/$tree_root/}|${f#$stage/$tree_root/}"); done
            BIN_REL="$(gui_pick_one "选主程序" "包里有多个可执行文件, 哪个是主程序?" "${opts[@]}")"
        fi
    fi
    [ -n "$BIN_REL" ] || die "没能确定主程序 —— 请用 --bin 指定(相对树根, 如 --bin bin/foo 或 usr/bin/foo)"
    # 两种写法都接受: 用户直觉写 usr/bin/foo, 而树根本身可能就是 usr/ → 剥掉前缀
    case "$BIN_REL" in
        usr/*) [ "$tree_root" = "tree/usr" ] && BIN_REL="${BIN_REL#usr/}" ;;
    esac
    # 判据看**真能执行的文件**, 不是"目录在"(GE-Proton 假绿灯同款教训)
    [ -f "$stage/$tree_root/$BIN_REL" ] || die "主程序不在包里: $BIN_REL"
    ok "主程序: ${BIN_REL}"

    # ── 5. 依赖体检(先记下来, 装完再决定补不补) ──
    local miss="" pkgs=""
    miss="$(missing_libs "$stage/$tree_root/$BIN_REL")"
    if [ "$miss" = "UNKNOWN" ]; then
        warn "无法用 ldd 判定依赖(文件可能非动态链接或缺少工具) —— 以实际启动为准"
    elif [ -n "$miss" ]; then
        warn "该程序依赖这些库(若落在 /usr, 升级会被冲):"
        printf '%s\n' "$miss" | sed 's/^/      /'
        pkgs="$(lib_to_pkgs "$miss")"
        [ -n "$pkgs" ] && info "pacman -F 反查到的候选包: $pkgs"
    else
        ok "动态库依赖齐全(ldd 无 not found)"
    fi

    # ── 6. 落地: 整棵树搬进 /home(保留相对结构) ──
    info "安装到: $dest  (/home → 原子升级不会被冲)"
    rm -rf "${dest:?}"
    mkdir -p "$dest" || die "无法创建 $dest"
    cp -a "$stage/$tree_root/." "$dest/" || { err "复制失败(空间不足?)"; rm -rf "${dest:?}"; return 1; }
    [ -x "$dest/$BIN_REL" ] || { err "落地后主程序不可执行 —— 回滚"; rm -rf "${dest:?}"; return 1; }
    ok "本体就位: $dest ($(du -sh "$dest" 2>/dev/null | cut -f1))"

    # ── 7. 写清单(供 --check 与升级后体检) ──
    local ver=""
    ver="$(bsdtar -xOf "$deb" 'control.tar.gz' 2>/dev/null | bsdtar -xOf - './control' 2>/dev/null \
           | sed -n 's/^Version:[[:space:]]*//p' | head -1)"
    {
        printf 'NAME=%s\n' "$NAME"
        printf 'VERSION=%s\n' "${ver:-未知}"
        printf 'BIN=%s\n' "$BIN_REL"
        printf 'SRC=%s\n' "$SRC"
        printf 'TIME=%s\n' "$(date '+%F %T')"
        printf 'MISSING_LIBS=%s\n' "$(printf '%s' "$miss" | tr '\n' ' ')"
        [ -n "$pkgs" ] && printf 'LIB_PKGS=%s\n' "$pkgs"
    } > "$dest/.deb-portable" 2>/dev/null || true

    # ── 8. 入口 wrapper(带缺库自检) ──
    local entry="$BIN_DIR/$NAME"
    mkdir -p "$BIN_DIR" || return 1
    {
        printf '#!/usr/bin/env bash\n'
        printf '# 由 install-deb-portable.sh 生成 —— /home 自持入口(升级不会被冲)\n'
        printf 'APP="%s/%s"\n' "$dest" "$BIN_REL"
        printf '[ -x "$APP" ] || { echo "%s 本体不在: $APP —— 重跑 install-deb-portable.sh 装回" >&2; exit 1; }\n' "$NAME"
        if [ -n "$miss" ]; then
            printf '# 依赖自检: 这些库在 /usr, 原子升级会被冲 —— 缺了就给命令, 不哑失败\n'
            local l
            for l in $miss; do
                printf 'ldconfig -p 2>/dev/null | grep -q "%s" || { echo "%s: 缺 %s(升级被冲)。装回: sudo pacman -S --needed <含该库的包>" >&2; exit 1; }\n' \
                    "$l" "$NAME" "$l"
            done
        fi
        printf 'exec "$APP" "$@"\n'
    } > "$entry"
    chmod 755 "$entry"
    bash -n "$entry" || { err "生成的入口有语法错误, 已删除"; rm -f "$entry"; return 1; }
    ok "入口就绪: $entry"

    # ── 9. 桌面项 + 图标 ──
    local disp_name="$NAME" comment="由 install-deb-portable.sh 便携化安装" wm="$NAME" cats="Utility" mimes=""
    if [ -n "$bdesk" ]; then
        local t
        t="$(sed -n 's/^Name=//p' "$bdesk" | head -1)";        [ -n "$t" ] && disp_name="$t"
        t="$(sed -n 's/^Comment=//p' "$bdesk" | head -1)";     [ -n "$t" ] && comment="$t"
        t="$(sed -n 's/^StartupWMClass=//p' "$bdesk" | head -1)"; [ -n "$t" ] && wm="$t"
        t="$(sed -n 's/^Categories=//p' "$bdesk" | head -1)";  [ -n "$t" ] && cats="$t"
        t="$(sed -n 's/^MimeType=//p' "$bdesk" | head -1)";    [ -n "$t" ] && mimes="$t"
        info "桌面项字段照搬包内 .desktop"
    fi
    local ic=""
    ic="$(find "$dest/share/icons" -type f -iname '*.png' 2>/dev/null \
         | grep -E '256x256@2|128x128|256x256' | sort -V | tail -1)"
    [ -z "$ic" ] && ic="$(find "$dest" -maxdepth 4 -type f -iname '*.png' 2>/dev/null | head -1)"
    local icon_path=""
    if [ -n "$ic" ]; then
        mkdir -p "$ICON_DIR/256x256/apps" 2>/dev/null
        cp -f "$ic" "$ICON_DIR/256x256/apps/$NAME.png" 2>/dev/null && icon_path="$ICON_DIR/256x256/apps/$NAME.png" \
            && ok "图标已搬到 /home"
    else
        warn "包内没找到图标 —— 桌面项将不带图标"
    fi
    mkdir -p "$APPS_DIR" || return 1
    case "$cats" in *';') ;; *) cats="$cats;" ;; esac
    {
        printf '[Desktop Entry]\n'
        printf 'Type=Application\n'
        printf 'Name=%s\n' "$disp_name"
        printf 'Comment=%s (便携化安装, 不占 rootfs)\n' "$comment"
        printf 'Exec=%s %%u\n' "$entry"
        [ -n "$icon_path" ] && printf 'Icon=%s\n' "$icon_path"
        printf 'Terminal=false\n'
        printf 'Categories=%s\n' "$cats"
        [ -n "$mimes" ] && printf 'MimeType=%s\n' "$mimes"
        printf 'StartupWMClass=%s\n' "$wm"
        printf 'StartupNotify=true\n'
    } > "$APPS_DIR/$NAME.desktop"
    chmod 644 "$APPS_DIR/$NAME.desktop"
    ok "桌面项就绪: $APPS_DIR/$NAME.desktop"

    # ── 10. 依赖: 能补就补(要 root; 这些库在 /usr, 升级后需再来一次) ──
    if [ "$NO_DEPS" -eq 1 ]; then
        info "--no-deps → 跳过依赖安装"
    elif [ -n "$pkgs" ] && [ "$(id -u)" -eq 0 ]; then
        if gui_yesno "补依赖" "检测到缺失的库, 候选包: $pkgs\n它们在 /usr(升级会被冲, 以后重跑本工具即可补回)。现在装吗?"; then
            # shellcheck disable=SC2086
            pacman -S --noconfirm --needed $pkgs 2>&1 | tail -3
        fi
    elif [ -n "$miss" ] && [ "$(id -u)" -ne 0 ]; then
        warn "非 root: 无法自动补依赖。缺的库:"
        printf '%s\n' "$miss" | sed 's/^/      /'
        [ -n "$pkgs" ] && sub "可试: sudo pacman -S --needed $pkgs"
    fi

    # ── 11. 收尾 ──
    [ "$(id -u)" -eq 0 ] && chown -R "$REAL_USER:$REAL_GROUP" "$dest" "$BIN_DIR/$NAME" \
        "$APPS_DIR/$NAME.desktop" "$ICON_DIR" 2>/dev/null
    rm -rf "${stage:?}" 2>/dev/null
    echo
    echo "════════ 完成 ════════"
    echo "  名字  : $NAME"
    echo "  安装根: $dest   (/home → 原子升级不会被冲)"
    echo "  入口  : $entry"
    echo "  · 菜单里没有就注销重登一次(桌面数据库要刷新)。"
    echo "  · 升级后体检: bash install-deb-portable.sh --check"
    if [ -n "$miss" ]; then
        warn "注意: 该程序依赖 /usr 里的库(上面列过) —— 那部分升级会被冲,"
        warn "      冲掉后入口会明确告诉你缺什么并给出命令, 不会'点了没反应'。"
    fi
}

# 下载(多镜像 + 超时 + 续传)
fetch_deb() {
    local url="$1" out="$2" m
    local urls=("$url")
    for m in "$MIRROR" "https://gh-proxy.com" "https://ghfast.top"; do
        [ -n "$m" ] || continue
        urls+=("${m%/}/$url")
    done
    for m in "${urls[@]}"; do
        sub "源: $(printf '%s' "$m" | cut -c1-90)"
        curl -fL --http1.1 --retry 3 --retry-delay 2 -C - \
             --connect-timeout 20 --max-time 1800 -o "$out" "$m" 2>/dev/null && return 0
    done
    return 1
}

# ===========================================================================
main() {
    if [ "$DO_CHECK" -eq 1 ]; then do_check; return 0; fi
    [ -n "$REMOVE" ] && { do_remove; return 0; }
    do_install
}
main "$@"
