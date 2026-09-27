#!/bin/bash
# ⚠️ 严格模式(2026-09-27 补齐): 本项目所有脚本统一 `set -uo pipefail`。
#    此前本文件是少数没设的 —— 未定义变量会静默变空, 在装包/删目录这类地方最危险。
set -uo pipefail
# =============================================================================
#  可选组件安装器 —— 必装之外的增强项(与 steamos-setup.sh 16 步主线解耦)
# -----------------------------------------------------------------------------
#  用法: 终端里 bash 本文件; 或由「重装后先运行我」在必装完成后拉起。
#  必装环境(archlinuxcn源/WorkBuddy/Decky/背键/TDP...)请跑 steamos-setup.sh。
#
#  【扩展点】新增可选项: ①写 install_xxx() ②MENU_ORDER/MENU_NAME/MENU_PKGS
#  各加一行 ③case 分支加一行 —— 三处, 不要散落逻辑。
#  非 pacman 安装的项(如 dsh-desktop 是解包官方便携包)额外在 MENU_CHECK
#  注册一个"是否已装"判据函数名, 否则菜单里的 ✓ 标记永远不亮。
# =============================================================================
cd "$(dirname "$0")" || exit 1

# pacman 需要 root: 沿用主脚本的提权模式(-E 保留用户环境)
#  ⚠️ TTY 守卫必须放在 sudo 之前: 非交互环境(被管道/定时器/批量拉起)下,
#     sudo 会在真终端上停等密码 —— 实测 `echo q | bash 本文件` 也永久挂住,
#     根本走不到后面带超时的 read。stdin 不是终端就直接说明并退出, 别挂。
if [ ! -t 0 ]; then
    echo "这是交互式菜单(要 sudo 提权 + 键盘选择), 请直接在终端里运行: bash $0" >&2
    exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
    # ⚠ 必须先转成绝对路径再提权: 上面 cd "$(dirname "$0")" 之后, $0 仍是调用时的
    #    相对路径(例如用户用 bash ./可选组件安装.sh 调用)。sudo 重跑本脚本时 cwd 已变,
    #    相对 $0 会指错目录 → 找不到脚本(2026-09-25 审查发现)。这里把脚本解析成绝对
    #    路径再 exec, 无论怎么调用都能正确重跑。
    SCRIPT_PATH="$(pwd)/$(basename "$0")"
    exec sudo -E bash "$SCRIPT_PATH" "$@"
fi

# 以 root 跑时要能定位真用户的家目录(下面有装在 /home 的项)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo deck)}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$REAL_HOME" ] || REAL_HOME="/home/$REAL_USER"

# 收尾: 本脚本以 root 跑, 往 /home 写的东西属主会变成 root —— 用户之后自己重跑
#   安装器就会"权限不够"(2026-09-25 实测: 鸿蒙字体脚本被 root 属主的
#   ~/.cache/harmony-sans 卡死, 用户无从下手)。退出前统一还给真用户。
#   与主脚本的 fix_home_owner 是同一套路径清单, 改一处要同步另一处。
fix_home_owner_opt() {
    [ "$(id -u)" -eq 0 ] || return 0
    local _rg _p
    _rg="$(id -gn "$REAL_USER" 2>/dev/null || printf '%s' "$REAL_USER")"
    for _p in \
        "$REAL_HOME/.cache/harmony-sans" "$REAL_HOME/.cache/glow" \
        "$REAL_HOME/.cache/localsend" "$REAL_HOME/.cache/firefox-nightly" \
        "$REAL_HOME/.cache/dsh-desktop" "$REAL_HOME/.cache/decky-store.json" \
        "$REAL_HOME/.local/share/fonts" "$REAL_HOME/.config/fontconfig" \
        "$REAL_HOME/.config/glow" "$REAL_HOME/.local/opt" \
        "$REAL_HOME/.local/bin" "$REAL_HOME/.local/share/applications" ; do
        if [ -e "$_p" ]; then
            chown -R "$REAL_USER:$_rg" "$_p" 2>/dev/null || true
        fi
    done
    return 0
}

# ── 可选项注册表 ──
MENU_ORDER=(wechat dsh-desktop clash-verge deb-portable wps-office harmony-sans nextkde)
declare -A MENU_NAME=(
    [wechat]="微信 (官方原生版沙盒封装 wechat-universal-bwrap, 含中文字体)"
    [dsh-desktop]="DeepSeek Harness 桌面版 (Tauri; 官方 AppImage 解到 /home, 不占 rootfs)"
    [clash-verge]="Clash Verge Rev (网络代理客户端; 官方 deb 拆到 /home 扛升级; ⚠️ WebView 依赖在 /usr, 升级后重跑本项补回)"
    [deb-portable]="任意 deb 包便携化安装 (自己给 URL 或本地 .deb → 装进 /home 扛升级; 可视化引导)"
    [wps-office]="WPS Office 中文版 (官方 deb → /opt; 2GB 不占 rootfs、扛原子升级)"
    [harmony-sans]="鸿蒙字体 HarmonyOS Sans (装进 /home 扛升级; 需自备官方 zip)"
    [nextkde]="NextKde 桌面外壳 (KOS: 顶栏/Dock/启动器/搜索; ⚠️ 需编译, 依赖进 rootfs)"
)
declare -A MENU_PKGS=(
    [wechat]="wechat-universal-bwrap"
    [dsh-desktop]="deepseek-harness-desktop"
    [wps-office]="wps-office"
    [harmony-sans]="harmonyos-sans"
    [nextkde]="nextkde"
)
# 可选: 自定义"是否已装"判据(函数名)。不设则用 pacman 查 MENU_PKGS 的包名。
declare -A MENU_CHECK=(
    [dsh-desktop]="dshdesk_installed"
    [clash-verge]="clashverge_installed"
    [wps-office]="wps_installed"
    [harmony-sans]="harmony_installed"
    [nextkde]="nextkde_installed"
)

pkg_installed() { pacman -Qq "$1" >/dev/null 2>&1; }

# dsh-desktop 同理(解压官方 AppImage 到 /home)
dshdesk_installed() { [ -e "$REAL_HOME/.local/opt/deepseek-harness-desktop/app/AppRun" ]; }
# clash-verge: 官方 deb 拆进 ~/.local/opt/clash-verge(整棵 usr/ 树), 入口在 ~/.local/bin
clashverge_installed() {
    [ -x "$REAL_HOME/.local/opt/clash-verge/usr/bin/clash-verge" ] && \
    [ -f "$REAL_HOME/.local/share/applications/clash-verge.desktop" ]
}
# wps-office 装到 /opt(本体)+~/.local(入口), 都不是 pacman 包
wps_installed() { [ -x "$REAL_HOME/.local/bin/wps" ] && [ -d /opt/kingsoft/wps-office/office6 ]; }
# 鸿蒙字体装到 ~/.local/share/fonts + fontconfig 的 conf.d/
harmony_installed() {
    [ -d "$REAL_HOME/.local/share/fonts/harmonyos-sans-sc" ] && \
    [ -f "$REAL_HOME/.config/fontconfig/conf.d/10-harmony-sans.conf" ]
}
# NextKde: 源码在 ~/.local/opt/NextKde; 生效判据是 plasmashellrc 已指向 KOS
nextkde_installed() {
    [ -x "$REAL_HOME/.local/opt/NextKde/tools/kosctl" ] && \
    grep -qi kos "$REAL_HOME/.config/plasmashellrc" 2>/dev/null
}

# ── 各组件安装函数 ──
install_wechat() {
    # SteamOS 缺 CJK 字体, 不装微信会显示方块
    echo "  · 安装中文字体(noto-fonts-cjk)..."
    pacman -S --noconfirm --needed noto-fonts-cjk 2>&1 | tail -2

    # ① 先在已配置仓库里找。包名随上游调整, 逐个探测。
    local pkg hit=""
    for pkg in wechat-universal-bwrap wechat-beta wechat; do
        if pacman -Si "$pkg" >/dev/null 2>&1; then hit="$pkg"; break; fi
    done
    if [ -n "$hit" ]; then
        echo "  · 从仓库安装 $hit ..."
        pacman -S --noconfirm --needed "$hit" 2>&1 | tail -3
        if pkg_installed "$hit"; then
            echo "  [✓] 微信已安装($hit)。桌面/游戏模式的应用列表里会出现 WeChat"
            return 0
        fi
        echo "  [✗] 安装失败"; return 1
    fi

    # ② 仓库里确实没有(2026-09 实测 archlinuxcn 已无任何微信包) → 退到 AUR。
    echo "  [!] 已配置的仓库里没有微信包 —— 改从 AUR 装(官方 deb 的沙盒封装)"
    echo "      注意: 这条路会装进 /usr(rootfs), 原子升级后会被冲掉且要重装;"
    echo "      若想要「装一次就扛升级」的效果, 可参照 install-app-home.sh wps-office 的"
    echo "      「官方 deb → /opt + 入口/桌面项放 /home」套路自行处理。"
    local a=""
    for a in yay paru; do command -v "$a" >/dev/null 2>&1 && break; a=""; done
    if [ -z "$a" ]; then
        echo "  [✗] 也没有 AUR 助手(yay/paru)。两条路:"
        echo "      ① 先跑 sudo bash steamos-setup.sh 3 (它装 WorkBuddy 时会带上"
        echo "         最小编译集与 AUR 助手), 再回来重试本项"
        echo "      ② 或自行安装 AUR 助手后重试"
        return 1
    fi
    # ── 预检: /opt/wechat-universal 有**无主**文件 → 孤儿现场, 直接带 --overwrite ──
    #   (与主脚本 workbuddy 段同源: /opt 是 offload, 升级后文件幸存、DB 被冲)
    local WOV=()
    if [ -e /opt/wechat-universal ]; then
        local orphan=0 p owner
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            owner="$(pacman -Qo "$p" 2>/dev/null || true)"
            [ -z "$owner" ] && orphan=$((orphan + 1))
        done < <(find /opt/wechat-universal -maxdepth 2 -type f 2>/dev/null | head -15)
        if [ "$orphan" -gt 0 ]; then
            echo "  [!] /opt/wechat-universal 发现 $orphan 个孤儿文件(升级幸存、DB 被冲)"
            echo "      直接带 --overwrite 安装, 不白跑注定失败的轮次"
            WOV=(--overwrite='*')
        fi
    fi
    # 统一日志(RPC 兜底的判定读它; 只喂目录给 mkdir 的位置自己拼文件名)
    local WLOG="$REAL_HOME/.cache/steamos-wechat-install.log"
    mkdir -p "$REAL_HOME/.cache" 2>/dev/null
    : > "$WLOG"
    echo "  · 用 $a 从 AUR 安装 wechat-universal-bwrap (需编译, 可能要几分钟)..."
    if [ "$(id -u)" -eq 0 ]; then
        runuser -u "$REAL_USER" -- "$a" -S --noconfirm --needed "${WOV[@]}" wechat-universal-bwrap 2>&1 | tee "$WLOG" | tail -5
    else
        "$a" -S --noconfirm --needed "${WOV[@]}" wechat-universal-bwrap 2>&1 | tee "$WLOG" | tail -5
    fi
    for pkg in wechat-universal-bwrap wechat-beta wechat; do
        if pkg_installed "$pkg"; then
            echo "  [✓] 微信已安装($pkg)。数据在 ~/Documents/WeChat_Data(升级不影响)"
            return 0
        fi
    done

    # ── RPC 兜底(2026-09-26 现场: aur.archlinux.org 间歇性连不上) ──
    #   上次构建好的包还在助手 clone 缓存里 → pacman -U 直装, 不联网。
    #   --overwrite 沿用预检结论(孤儿现场必带; 非孤儿为空数组, 不掩盖真冲突)。
    if grep -q 'aur.archlinux.org' "$WLOG" 2>/dev/null; then
        local WPKG=""
        WPKG="$(ls -1t "$REAL_HOME/.cache/paru/clone/wechat-universal-bwrap/"*.pkg.tar.zst 2>/dev/null | head -1 || true)"
        [ -z "$WPKG" ] && WPKG="$(ls -1t "$REAL_HOME/.cache/yay/wechat-universal-bwrap/"*.pkg.tar.zst 2>/dev/null | head -1 || true)"
        if [ -n "$WPKG" ]; then
            echo "  [!] AUR RPC 连不上, 但发现上次构建好的本地包: $WPKG"
            echo "  · pacman -U 直装(不联网; 版本以上次构建为准)..."
            pacman -U --noconfirm --needed "${WOV[@]}" "$WPKG" 2>&1 | tail -6
            for pkg in wechat-universal-bwrap wechat-beta wechat; do
                if pkg_installed "$pkg"; then
                    echo "  [✓] 微信已从本地包装回($pkg)。聊天数据在 ~/Documents/WeChat_Data, 未受影响"
                    return 0
                fi
            done
        else
            echo "  [!] AUR RPC 连不上, 本地也没有已构建的包 → 等网络恢复后重试本项"
        fi
    fi
    echo "  [✗] AUR 安装未成功"
    echo "      排查: ① 报「文件系统中已存在 /opt/wechat-universal/...」= 孤儿文件, 见上"
    echo "            ② 报「error sending request for url (https://aur.archlinux.org/rpc)」"
    echo "               = AUR 站点本身连不上(DNS/代理/被墙), 与脚本无关, 换个网再试"
    echo "            ③ 报「无法锁定数据库」= 有别的 pacman 在跑, 等它结束"
    echo "            ④ 报头文件缺失(zlib.h/string.h)= 先跑 bash fix-missing-dev-files.sh"
    return 1
}

install_dsh_desktop() {
    local s
    s="$(cd "$(dirname "$0")" && pwd)/install-app-home.sh"
    if [ ! -f "$s" ]; then
        echo "  [✗] 找不到 $s"
        return 1
    fi
    echo "  · 调用 install-app-home.sh dsh-desktop (官方 AppImage 约 90MB, 解到 /home)"
    echo "    注意: 它的内核要求可能高于本包 step[7] 固定的 dsh 版本, 装完看输出提示"
    bash "$s" dsh-desktop
}

install_wps_office() {
    local s
    s="$(cd "$(dirname "$0")" && pwd)/install-app-home.sh"
    if [ ! -f "$s" ]; then
        echo "  [✗] 找不到 $s"
        return 1
    fi
    echo "  · 调用 install-app-home.sh wps-office (官方 deb 约 545MB; 解到 /opt 不占 rootfs)"
    echo "    注意: 装前必须完全退出 WPS; 首次会顺带补运行库与中文字体"
    bash "$s" wps-office
}

install_harmony_sans() {
    # 同上: 逻辑都在独立脚本里, 这里薄封装
    local s
    s="$(cd "$(dirname "$0")" && pwd)/install-harmony-sans-home.sh"
    if [ ! -f "$s" ]; then
        echo "  [✗] 找不到 $s"
        return 1
    fi
    echo "  · 调用 install-harmony-sans-home.sh (装进 ~/.local/share/fonts, 扛原子升级)"
    echo "    ⚠ 华为官方 zip 直链带时间戳签名、会过期, 所以脚本没写死地址:"
    echo "      先自己下好 zip, 然后  HARMONY_ZIP=/路径/xxx.zip bash 可选组件安装.sh"
    echo "      或  HARMONY_URL='https://...zip' bash 可选组件安装.sh"
    echo "      取源页: https://developer.huawei.com/consumer/cn/design/resource/"
    # 注: 菜单不转发参数; 要用 --check/--force 请直接跑那个独立脚本
    bash "$s"
}

install_clash_verge() {
    # 官方 Linux 只有 deb/rpm(无 AppImage) → 交给统一引擎: 拆 deb 到 /home
    local s
    s="$(cd "$(dirname "$0")" && pwd)/install-app-home.sh"
    if [ ! -f "$s" ]; then
        echo "  [✗] 找不到 $s"
        return 1
    fi
    echo "  · 调用 install-app-home.sh clash-verge (官方 deb ~98MB → 拆到 ~/.local/opt/clash-verge)"
    echo "    · 本体/图标/桌面项全在 /home → 原子升级**不会被冲**"
    echo "    · 唯一例外: Tauri WebView(webkit2gtk-4.1)在 /usr, 升级会被冲 —— 本项会顺带装上,"
    echo "      升级后重跑本项即可补回(入口也会自检缺库并给出命令, 不会'点了没反应')"
    echo "    · 合规: 本脚本只装软件; 代理节点/订阅与用途请自行遵守所在地法规与网络管理规定"
    bash "$s" clash-verge
}

install_deb_portable() {
    # 通用能力: 任意 deb → /home(与 WPS/Clash Verge 同套路, 但不针对某个软件)
    local s
    s="$(cd "$(dirname "$0")" && pwd)/install-deb-portable.sh"
    if [ ! -f "$s" ]; then
        echo "  [✗] 找不到 $s"
        return 1
    fi
    echo "  · 调用 install-deb-portable.sh (可视化: 选文件/链接 → 选主程序 → 装进 /home)"
    echo "    · 本体 ~/.local/opt/<名> + 入口 ~/.local/bin/<名> + 桌面项/图标 → 全扛原子升级"
    echo "    · 会先用 ldd 体检依赖; 依赖若在 /usr, 入口会自检并在缺库时给出装回命令"
    echo "    · 命令行等价: bash install-deb-portable.sh <URL 或 .deb> --name 名字 --bin bin/xxx"
    echo "    · 升级后体检: bash install-deb-portable.sh --check"
    bash "$s"
}

install_nextkde() {
    # NextKde 自带官方安装器 tools/kosctl, 所以这里是"包装"而不是重写构建
    local s
    s="$(cd "$(dirname "$0")" && pwd)/install-nextkde-home.sh"
    if [ ! -f "$s" ]; then
        echo "  [✗] 找不到 $s"
        return 1
    fi
    echo "  · 调用 install-nextkde-home.sh (clone 到 ~/.local/opt → 上游 kosctl 编译安装)"
    echo "    ⚠️ 三件会改系统的事(脚本会再确认一次):"
    echo "       ① 编译依赖(qt6/kf6/kwin 开发包等几百 MB)会进 **rootfs**, 升级被冲"
    echo "       ② 会把 plasmashellrc 的 ShellPackage 指向 KOS(**切换桌面外壳**)"
    echo "       ③ 会编译 KWin 特效插件(与 KWin 版本耦合, 升级后可能要重编)"
    echo "    只想先看看不装: bash install-nextkde-home.sh --doctor"
    bash "$s"
}

# ── 菜单循环 ──
while true; do
    echo
    echo "════════ 可选组件安装 (必装环境请跑 steamos-setup.sh) ════════"
    i=1
    for key in "${MENU_ORDER[@]}"; do
        mark=" "
        if [ -n "${MENU_CHECK[$key]:-}" ]; then
            "${MENU_CHECK[$key]}" && mark="✓"
        else
            pkg_installed "${MENU_PKGS[$key]}" && mark="✓"
        fi
        printf "  %d. [%s] %s\n" "$i" "$mark" "${MENU_NAME[$key]}"
        i=$((i + 1))
    done
    echo "  0. 退出"
    printf "选择要安装的编号(可多选, 空格分隔, 直接回车=退出): "
    # -t 守卫: 非交互环境(被管道/定时调用)下裸 read 会永久挂起
    read -r -t 300 -a picks || break
    [ "${#picks[@]}" -eq 0 ] && break
    for n in "${picks[@]}"; do
        case "$n" in
            ''|*[!0-9]*) echo "  无效输入: $n"; continue ;;
        esac
        [ "$n" -eq 0 ] && { break 2; }
        idx=$((n - 1))
        if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#MENU_ORDER[@]}" ]; then
            echo "  无效编号: $n"; continue
        fi
        key="${MENU_ORDER[$idx]}"
        case "$key" in
            wechat) install_wechat ;;
            dsh-desktop) install_dsh_desktop ;;
            clash-verge) install_clash_verge ;;
            deb-portable) install_deb_portable ;;
            wps-office) install_wps_office ;;
            harmony-sans) install_harmony_sans ;;
            nextkde) install_nextkde ;;
            *) echo "  [!] $key 尚未实现" ;;
        esac
    done
done
fix_home_owner_opt
echo "可选组件安装器退出。"
exit 0
