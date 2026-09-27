#!/usr/bin/env bash
# ===========================================================================
#  fix-missing-dev-files.sh —— 补齐 SteamOS 镜像裁掉的开发文件
#                              (头文件 / cmake 配置 / pkgconfig)
# ---------------------------------------------------------------------------
#  根因(2026-09-25 实测, 关键且反直觉):
#    SteamOS 的 /usr 是**运行时镜像**, Valve 在打包时把「开发用」文件摘掉了,
#    但 **pacman 数据库仍然完整记录着它们** → `pacman -Q <pkg>` 说"已装",
#    任何要编译的步骤(CMake find_package / pkg-config / #include)都当场报缺:
#
#      · CMake : Could not find a package configuration file provided by "Qt6"
#      · C     : fatal error: string.h / zlib.h: 没有那个文件或目录
#
#    实测规模(升级后、补过 qt6 的机器上): 全系统 22619 个头文件 + 3986 个
#    .cmake/.pc 只在 DB 里有、磁盘上没有。这不是升级事故, 是镜像的常态。
#
#  被裁掉的 / 没被裁掉的(实测确认, 别多补):
#    ✗ 裁掉: usr/include/**  usr/lib/cmake/**  usr/lib/pkgconfig/*.pc
#            usr/share/locale/**  usr/share/doc/**      ← 后两类是体积大头
#    ✓ 保留: usr/lib/*.so 开发符号链接(libKF6*.so / libz.so 都在)、运行时库、
#            usr/share/ECM(extra-cmake-modules 完好)、usr/lib/qt6/mkspecs
#
#  两种修法:
#    [默认] 只从 .pkg.tar.zst 里抽出上面那三类**开发文件**写回 /usr
#           → 只补缺的、不碰运行时库、不带回 locale/doc 的体积(省 ~90% 空间)
#           → 不动 pacman 事务, 不换版本, 风险≈0
#           实测: kde/qt6 集合 160 包/9322 个文件补齐, rootfs 只少 13 MiB
#    [--full] `pacman -U --overwrite='*'` 整包强制重装(等价于手工做法)
#           → 连 locale/doc 一起回来, 下载/占用大得多, 仅在默认模式漏了什么时用
#
#  版本安全闸: 只接受**与已装版本一致**(去 pkgrel 后)的包。SteamOS 的
#    *-3.9 固定仓库与本机版本对齐; 若解析到滚动 Arch 仓库的更新版本, 脚本会
#    拒绝安装并报出来 —— 那种"部分升级"会拆掉 KDE/KWin 的 ABI。
#    个别包连固定仓库都往前跑了(实测 libwireplumber: 本机 0.5.15 / 仓库 0.5.17,
#    装它会破坏 wireplumber 的依赖) → 这种脚本会明确跳过, 只能等系统整体升级。
#
#  用法:
#    bash fix-missing-dev-files.sh                  # 只读体检: 列出缺开发文件的包
#    sudo bash fix-missing-dev-files.sh --apply     # 修复(--set kde, 默认)
#    sudo bash fix-missing-dev-files.sh --apply --set all   # 全系统扫修(慢, 下载多)
#    sudo bash fix-missing-dev-files.sh --apply --pkgs kio,kwin,qt6-svg
#    sudo bash fix-missing-dev-files.sh --apply --full      # 整包强制重装(带 locale/doc)
#    加 --dry-run 预演; --force 忽略 rootfs 空间告警; --allow-bump 放行版本不一致
#
#  退出码: 0 = 无缺失/修复后无缺失; 1 = 仍有缺失或出错
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'; C_B=$'\033[1m'; C_D=$'\033[2m'
info() { echo "${C_G}[✓]${C_R} $*"; }
warn() { echo "${C_Y}[!]${C_R} $*"; }
err()  { echo "${C_RD}[✗]${C_R} $*" >&2; }
sub()  { echo "    $*"; }

# ── 被镜像裁掉的三类开发文件(只补这些) ─────────────────────────────────
#    注意 `^/?`: pacman -Ql 打出的路径带前导 `/`, 而包内成员清单不带 —— 一个正则
#    同时适配两者, 免得两处匹配规则各写一份、日后漂移。
#    usr/lib/qt6/mkspecs 与 usr/share/ECM 实测完好, 一并列入只为自愈兜底
DEV_RE='^/?usr/(include|lib/cmake|lib/pkgconfig|lib/qt6/mkspecs)(/|$)|^/?usr/share/ECM(/|$)'

# ── 参数 ───────────────────────────────────────────────────────────────
MODE=check; SET=kde; EXTRA_PKGS=""; DRY=0; FORCE=0; FULL=0; ALLOW_BUMP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check)      MODE=check ;;
        --apply)      MODE=apply ;;
        --set)        SET="${2:?--set 需要值}"; shift ;;
        --pkgs)       EXTRA_PKGS="${2:?--pkgs 需要值}"; SET=pkgs; shift ;;
        --dry-run)    DRY=1 ;;
        --force)      FORCE=1 ;;
        --full)       FULL=1 ;;
        --allow-bump) ALLOW_BUMP=1 ;;
        -h|--help)    awk 'NR>1 && /^set -uo pipefail/{exit} NR>1{print}' "$0"; exit 0 ;;
        *) err "未知参数: $1（--help 看用法）"; exit 2 ;;
    esac
    shift
done

command -v pacman >/dev/null 2>&1 || { err "本脚本只适用于 pacman 系(SteamOS)"; exit 1; }
command -v bsdtar >/dev/null 2>&1 || { err "缺 bsdtar(libarchive) —— 默认模式要用它抽取开发文件"; exit 1; }

# ── 目标包集合 ─────────────────────────────────────────────────────────
#  kde(默认): pacman 软件组 kf6 + plasma + qt6 里的已装包 + 下面两组常见构建依赖
#  all     : 全部已装包(约 1250 个, 扫描约 20 秒)
#  ① 通用 C/C++ 库与 X11/Wayland 基础
BASE_PKGS="extra-cmake-modules zlib glib2 pcre2 libffi expat dbus icu freetype2
fontconfig harfbuzz libpng libjpeg-turbo libxml2 libxslt openssl brotli libb2
libdrm libglvnd libevdev libinput libei wayland wayland-protocols vulkan-headers
libx11 libxcb libxau libxdmcp libxext libxrender libxfixes libxi libxrandr
libxcursor libxinerama libice libsm libxtst libxss libxcomposite libxdamage
libxres libxkbfile libxfont2 libxcvt libxkbcommon libxkbcommon-x11
xcb-util xcb-util-cursor xcb-util-image xcb-util-keysyms xcb-util-renderutil
xcb-util-wm xcb-util-errors taglib gstreamer gst-plugins-base-libs sqlite"
#  ② CMake 自带 Find 模块最常探的库 —— 缺了会在不同项目上"逐个报缺", 一次补掉省来回
#     实测教训: CMake 的 FindX11 第一个查的是 **X11/X.h**, 它来自 xorgproto 而不是 libx11
#     → 只补 libx11 时 find_package(X11) 仍会报 "missing: X11_X11_INCLUDE_PATH"。
#     libepoxy 同理: KWinConfig.cmake → find_dependency(epoxy) → ECM 的 Findepoxy
#     要 epoxy/gl.h, 缺了报 "Could NOT find epoxy (missing: epoxy_INCLUDE_DIRS)"。
BASE_PKGS="$BASE_PKGS
xorgproto xcb-proto xorg-xkbcomp xorg-xwayland
xz zstd bzip2 libarchive lz4 libdeflate libelf libaio liburing
gmp nettle gnutls krb5 libcap libtasn1 libp11-kit libgpg-error libgcrypt
pcre python gettext double-conversion libpsl libssh2 libidn2 libunistring
libepoxy"

collect_targets() {
    local p
    case "$SET" in
        pkgs)
            for p in ${EXTRA_PKGS//,/ }; do
                [ -n "$p" ] || continue
                if pacman -Q "$p" >/dev/null 2>&1; then printf '%s\n' "$p"
                else warn "跳过: $p 未安装" >&2; fi
            done
            return 0
            ;;
        kde)
            { pacman -Sg kf6 plasma qt6 2>/dev/null | awk '{print $2}'
              printf '%s\n' $BASE_PKGS
            } | sort -u
            ;;
        all)  pacman -Qq ;;
        *)    err "--set 只支持 kde|all（或用 --pkgs）"; exit 2 ;;
    esac | while IFS= read -r p; do pacman -Q "$p" >/dev/null 2>&1 && printf '%s\n' "$p"; done
}

mapfile -t TARGETS < <(collect_targets)
[ "${#TARGETS[@]}" -gt 0 ] || { err "目标集为空"; exit 1; }

# ── 扫描: 每个包缺多少个开发文件 ───────────────────────────────────────
# 输出三列:  包名  缺失数  样例路径
scan_all() {
    local pkg f n ex
    for pkg in "${TARGETS[@]}"; do
        n=0; ex=""
        while IFS= read -r f; do
            if [ ! -e "$f" ]; then
                n=$((n + 1))
                [ -z "$ex" ] && ex="$f"
            fi
        done < <(pacman -Ql "$pkg" 2>/dev/null | awk '{print $2}' | grep -E "$DEV_RE")
        [ "$n" -gt 0 ] && printf '%s %s %s\n' "$pkg" "$n" "$ex"
    done
    return 0
}

echo "${C_B}SteamOS 开发文件体检${C_R}  (集合: $SET, 已装包数: ${#TARGETS[@]})"
echo "${C_D}判据: pacman DB 里有、磁盘上没有的 /usr/include、/usr/lib/cmake、/usr/lib/pkgconfig${C_R}"
echo
SCAN_OUT="$(scan_all)"

if [ -z "$SCAN_OUT" ]; then
    info "没有缺失 —— 这套集合的开发文件是齐的。"
    exit 0
fi

TOTAL_FILES=0; TOTAL_PKGS=0
while IFS=' ' read -r pkg n ex; do
    [ -n "${pkg:-}" ] || continue
    TOTAL_PKGS=$((TOTAL_PKGS + 1)); TOTAL_FILES=$((TOTAL_FILES + n))
    printf '  %-26s 缺 %-6s 例: %s\n' "$pkg" "$n" "$ex"
done <<< "$SCAN_OUT"
echo
warn "共 $TOTAL_PKGS 个包、$TOTAL_FILES 个开发文件缺失。"

if [ "$MODE" = check ]; then
    echo
    sub "修:   ${C_B}sudo bash $(basename "$0") --apply${C_R}     (默认只补 kde/qt6 集合, 实测 ~160 个包)"
    sub "全套: ${C_B}sudo bash $(basename "$0") --apply --set all${C_R} (全系统扫修: 更慢、下载更多)"
    sub "只补某个东西要用的: ${C_B}sudo bash $(basename "$0") --apply --pkgs kio,kwin,qt6-svg${C_R}"
    sub "预演(不需要 root):  ${C_B}bash $(basename "$0") --apply --dry-run${C_R}"
    exit 1
fi

# ===========================================================================
#  修复
# ===========================================================================
if [ "$(id -u)" -ne 0 ] && [ "$DRY" -eq 0 ]; then
    err "--apply 需要 root（要写 /usr）。请用:  sudo bash $0 --apply ..."
    sub "想看会做什么而不动手: bash $0 --apply --dry-run (只读, 不需要 root)"
    exit 1
fi

# pacman 不能被别的进程占着(Discover/pamac/Steam 可能在跑)
if [ -e /var/lib/pacman/db.lck ]; then
    err "/var/lib/pacman/db.lck 存在 —— 有别的 pacman 在跑, 等它结束再来。"
    exit 1
fi

# rootfs 空间守卫: 默认模式只写开发文件(小), --full 会带回 locale/doc(大)
avail_kb="$(df -Pk / | awk 'NR==2{print $4}')"
[ -n "$avail_kb" ] || avail_kb=0
sub "rootfs 可用: $((avail_kb / 1024)) MiB"
if [ "$avail_kb" -lt 204800 ] && [ "$FORCE" -eq 0 ]; then
    err "rootfs 可用不足 200 MiB —— 先跑 free-rootfs.sh --apply, 或用 --force 硬上。"
    exit 1
fi
[ "$FULL" -eq 1 ] && warn "--full 模式会连 locale/doc 一起装回来, 占用明显更大。"

CACHE="${FIXDEV_CACHE:-/var/cache/pacman/pkg}"   # FIXDEV_CACHE 只用于自测(指定替身缓存目录)
[ -d "$CACHE" ] || { err "找不到 pacman 缓存目录 $CACHE"; exit 1; }

# 解除只读(幂等; 重启自动回到只读; dry-run 不动)
if [ "$DRY" -eq 0 ] && command -v steamos-readonly >/dev/null 2>&1; then
    if steamos-readonly status 2>/dev/null | grep -qiE "enabled|只读|read-only"; then
        sub "解除 SteamOS 只读根 (steamos-readonly disable; 重启后自动恢复)…"
        steamos-readonly disable >/dev/null 2>&1 || warn "steamos-readonly disable 未成功, 继续尝试"
    fi
fi

OK_PKGS=0; FAIL_PKGS=0; SKIP_PKGS=0; REFUSED=0
FAILED_LIST=""
AVAIL_BEFORE="$avail_kb"
LFILE="/tmp/.fix-missing-dev-files.list.$$"
trap 'rm -f "$LFILE"' EXIT

for pkg in $(printf '%s\n' "$SCAN_OUT" | awk '{print $1}'); do
    echo "${C_B}── $pkg${C_R}"

    inst="$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')"
    [ -n "$inst" ] || { warn "未安装, 跳过"; SKIP_PKGS=$((SKIP_PKGS + 1)); continue; }

    # 目标版本: 取仓库里该包会被安装的版本(pacman.conf 里 *-3.9 固定仓库在前)
    # ⚠️ 用 `%n %v` 按名字精确取, 不要 `head -1`: 若该包会连带升级某个依赖,
    #    pacman 会先打印":: 安装 xxx 破坏依赖 ..."这类信息行, head -1 会把它当版本号。
    pkginfo="$(pacman -Sp --print-format '%n %v' "$pkg" 2>/dev/null)"
    repo="$(printf '%s\n' "$pkginfo" | awk -v p="$pkg" '$1==p{print $2; exit}')"
    if [ -z "$repo" ]; then
        # 固定仓库也会随上游往前走, 个别包会出现"仓库版本会破坏依赖"的情况
        # （实测: libwireplumber 本机 0.5.15-1.2 / 仓库 0.5.17-1.1, wireplumber 锁着旧版）
        if printf '%s' "$pkginfo" | grep -q '破坏依赖\|conflict\|^::'; then
            warn "仓库版本会破坏依赖 → 跳过(这种包只能等系统整体升级, 别硬补):"
            printf '%s\n' "$pkginfo" | grep '^::' | head -2 | sed 's/^/      /'
        else
            warn "不在任何仓库里(可能是 AUR/本地包) → 只能手工处理, 跳过"
        fi
        SKIP_PKGS=$((SKIP_PKGS + 1)); continue
    fi

    base_inst="${inst%%-*}"; base_repo="${repo%%-*}"
    if [ "$base_inst" != "$base_repo" ] && [ "$ALLOW_BUMP" -eq 0 ]; then
        err "版本不一致: 本机 $inst, 仓库 $repo"
        sub "拒绝 —— 只换开发文件也要求版本对齐, 否则头文件与实际库 ABI 会错位。"
        sub "(固定仓库也会随上游往前跑, 个别包出现这种偏差是正常的; 确认无误再加 --allow-bump)"
        REFUSED=$((REFUSED + 1)); FAILED_LIST="$FAILED_LIST $pkg(版本不一致)"
        continue
    fi

    # 缓存文件名不能拼 "-x86_64": 有相当一批包是 arch=**any**(xorgproto/字体/纯数据包…),
    # 它们的文件名是 <pkg>-<ver>-any.pkg.tar.zst。正确做法是从 pacman 解析出的 URL 取 basename,
    # 再按"包名开头"精确挑出目标包(一个目标可能连带打印依赖的 URL)。
    purl="$(pacman -Sp "$pkg" 2>/dev/null | grep -E "/${pkg}-[^/]*\.pkg\.tar\.zst$" | head -1)"
    [ -n "$purl" ] || purl="$(pacman -Sp "$pkg" 2>/dev/null | grep -E '\.pkg\.tar\.zst$' | head -1)"
    if [ -n "$purl" ]; then
        pkgfile="$CACHE/$(basename "$purl")"
    else
        pkgfile="$(ls -1 "$CACHE/$pkg-$repo-"*.pkg.tar.zst 2>/dev/null | head -1)"
    fi
    if [ -z "$pkgfile" ] || [ ! -f "$pkgfile" ]; then
        # 没用 URL 兜底时, 允许"已下过的任意架构"命中缓存
        pkgfile="$(ls -1 "$CACHE/$pkg-$repo-"*.pkg.tar.* 2>/dev/null | head -1)"
    fi
    if [ -z "$pkgfile" ] || [ ! -f "$pkgfile" ]; then
        if [ "$DRY" -eq 1 ]; then
            sub "(dry-run) 需先下载 $(basename "${purl:-$pkg-$repo}"), 再抽开发文件写回 /usr"
            OK_PKGS=$((OK_PKGS + 1)); continue
        fi
        sub "下载 $pkg-$repo…"
        pacman -Sw --noconfirm "$pkg" >/dev/null 2>&1 || true
        # 下完再用同一条规则找(架构可能是 any)
        pkgfile="$(ls -1 "$CACHE/$pkg-$repo-"*.pkg.tar.zst 2>/dev/null | head -1)"
        [ -n "$pkgfile" ] || pkgfile="$(ls -1 "$CACHE/$pkg-$repo-"*.pkg.tar.* 2>/dev/null | head -1)"
    fi
    if [ -z "$pkgfile" ] || [ ! -f "$pkgfile" ]; then
        err "拿不到包文件(期望 $CACHE/$pkg-$repo-<arch>.pkg.tar.*) —— 下载失败或版本号变了, 跳过"
        FAIL_PKGS=$((FAIL_PKGS + 1)); FAILED_LIST="$FAILED_LIST $pkg(无包文件)"
        continue
    fi

    if [ "$DRY" -eq 1 ]; then
        sub "(dry-run) 从 $(basename "$pkgfile") 抽开发文件写回 /usr"; OK_PKGS=$((OK_PKGS + 1)); continue
    fi

    if [ "$FULL" -eq 1 ]; then
        # 整包强制重装(连 locale/doc 一起回来)
        if pacman -U --noconfirm --overwrite='*' "$pkgfile" >/dev/null 2>&1; then
            info "已整包重装 $pkg-$repo"
            OK_PKGS=$((OK_PKGS + 1))
        else
            err "pacman -U 失败: $pkg"; FAIL_PKGS=$((FAIL_PKGS + 1)); FAILED_LIST="$FAILED_LIST $pkg(U失败)"
        fi
        continue
    fi

    # 默认: 只抽开发文件(按成员清单抽, 不碰运行时库、不带 locale/doc)
    if ! bsdtar -tf "$pkgfile" 2>/dev/null | grep -E "$DEV_RE" > "$LFILE"; then
        warn "读包失败: $pkgfile"; FAIL_PKGS=$((FAIL_PKGS + 1)); FAILED_LIST="$FAILED_LIST $pkg(读包失败)"
        continue
    fi
    members="$(wc -l < "$LFILE")"
    if [ "$members" -eq 0 ]; then
        warn "包内没有开发文件(该包本身就是纯运行时的) → 跳过"; SKIP_PKGS=$((SKIP_PKGS + 1)); continue
    fi
    if bsdtar -xf "$pkgfile" -C / -T "$LFILE" 2>/dev/null; then
        info "已补 $members 个开发文件"
        OK_PKGS=$((OK_PKGS + 1))
    else
        err "抽取失败: $pkg"; FAIL_PKGS=$((FAIL_PKGS + 1)); FAILED_LIST="$FAILED_LIST $pkg(解包失败)"
    fi
done
rm -f "$LFILE"

echo
# 关键文件抽查(这几个是"编译真的能过"的代表性判据)
echo "${C_B}关键文件${C_R}"
for f in /usr/lib/cmake/Qt6/Qt6Config.cmake \
         /usr/lib/cmake/KF6Config/KF6ConfigConfig.cmake \
         /usr/lib/cmake/KWin/KWinConfig.cmake \
         /usr/include/zlib.h /usr/include/X11/Xlib.h /usr/include/kwin/effect/effect.h; do
    [ -e "$f" ] && echo "  ${C_G}✓${C_R} $f" || echo "  ${C_RD}✗${C_R} $f"
done
echo

if [ "$DRY" -eq 1 ]; then
    warn "dry-run 结束: 未做任何修改。去掉 --dry-run、加 sudo 才会真的补。"
    exit 1
fi

# ── 复核 ───────────────────────────────────────────────────────────────
echo "${C_B}复核(重扫同一集合)…${C_R}"
SCAN_OUT2="$(scan_all)"
LEFT_PKGS=0; LEFT_FILES=0
if [ -n "$SCAN_OUT2" ]; then
    while IFS=' ' read -r pkg n ex; do
        [ -n "${pkg:-}" ] || continue
        LEFT_PKGS=$((LEFT_PKGS + 1)); LEFT_FILES=$((LEFT_FILES + n))
        printf '  %-26s 仍缺 %s\n' "$pkg" "$n"
    done <<< "$SCAN_OUT2"
fi

echo
echo "---------------- 结果 ----------------"
sub "已处理: $OK_PKGS 个包    跳过: $SKIP_PKGS    失败: $FAIL_PKGS    拒绝(版本): $REFUSED"
[ -n "$FAILED_LIST" ] && sub "有问题的: $FAILED_LIST"
AVAIL_AFTER="$(df -Pk / | awk 'NR==2{print $4}')"
sub "rootfs 可用: $((AVAIL_AFTER / 1024)) MiB (本次变化 $(( (AVAIL_AFTER - AVAIL_BEFORE) / 1024 )) MiB)"
echo

if [ "$LEFT_FILES" -gt 0 ]; then
    warn "还有 $LEFT_PKGS 个包 / $LEFT_FILES 个文件没补上。"
    sub "常见原因: 该包不在 *-3.9 固定仓库(升级后新装的包) / 版本不一致被拒 / 下载失败。"
    sub "对单个包手工处理: pacman -Sw <pkg> && sudo pacman -U --overwrite='*' /var/cache/pacman/pkg/<pkg>-<ver>-x86_64.pkg.tar.zst"
    exit 1
fi
info "这套集合的开发文件已齐全, 可以继续编译(NextKde / AUR 构建等)。"
exit 0
