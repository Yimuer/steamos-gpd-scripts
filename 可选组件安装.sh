#!/bin/bash
# =============================================================================
#  可选组件安装器 —— 必装之外的增强项(与 steamos-setup.sh 十二步主线解耦)
# -----------------------------------------------------------------------------
#  用法: 终端里 bash 本文件; 或由「重装后先运行我」在必装完成后拉起。
#  必装环境(archlinuxcn源/WorkBuddy/Decky/背键/TDP...)请跑 steamos-setup.sh。
#
#  【扩展点】新增可选项: ①写 install_xxx() ②MENU_ORDER/MENU_NAME/MENU_PKGS
#  各加一行 ③case 分支加一行 —— 三处, 不要散落逻辑。
#  非 pacman 安装的项(如 firefox-nightly 是解包官方便携包)额外在 MENU_CHECK
#  注册一个"是否已装"判据函数名, 否则菜单里的 ✓ 标记永远不亮。
# =============================================================================
cd "$(dirname "$0")" || exit 1

# pacman 需要 root: 沿用主脚本的提权模式(-E 保留用户环境)
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -E bash "$0" "$@"
fi

# 以 root 跑时要能定位真用户的家目录(下面有装在 /home 的项)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo deck)}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$REAL_HOME" ] || REAL_HOME="/home/$REAL_USER"

# ── 可选项注册表 ──
MENU_ORDER=(wechat firefox-nightly dsh-desktop wps-office harmony-sans)
declare -A MENU_NAME=(
    [wechat]="微信 (官方原生版沙盒封装 wechat-universal-bwrap, 含中文字体)"
    [firefox-nightly]="Firefox Nightly (官方包解到 /home: 不占 rootfs、无沙箱、扛原子升级)"
    [dsh-desktop]="DeepSeek Harness 桌面版 (Tauri; 官方 AppImage 解到 /home, 不占 rootfs)"
    [wps-office]="WPS Office 中文版 (官方 deb → /opt; 2GB 不占 rootfs、扛原子升级)"
    [harmony-sans]="鸿蒙字体 HarmonyOS Sans (装进 /home 扛升级; 需自备官方 zip)"
)
declare -A MENU_PKGS=(
    [wechat]="wechat-universal-bwrap"
    [firefox-nightly]="firefox-nightly"
    [dsh-desktop]="deepseek-harness-desktop"
    [wps-office]="wps-office"
    [harmony-sans]="harmonyos-sans"
)
# 可选: 自定义"是否已装"判据(函数名)。不设则用 pacman 查 MENU_PKGS 的包名。
declare -A MENU_CHECK=(
    [firefox-nightly]="ffn_installed"
    [dsh-desktop]="dshdesk_installed"
    [wps-office]="wps_installed"
    [harmony-sans]="harmony_installed"
)

pkg_installed() { pacman -Qq "$1" >/dev/null 2>&1; }

# firefox-nightly 不走 pacman(解包官方便携包到 /home), 用可执行文件判据
ffn_installed() { [ -x "$REAL_HOME/.local/opt/firefox-nightly/firefox/firefox" ]; }
# dsh-desktop 同理(解压官方 AppImage 到 /home)
dshdesk_installed() { [ -e "$REAL_HOME/.local/opt/deepseek-harness-desktop/app/AppRun" ]; }
# wps-office 装到 /opt(本体)+~/.local(入口), 都不是 pacman 包
wps_installed() { [ -x "$REAL_HOME/.local/bin/wps" ] && [ -d /opt/kingsoft/wps-office/office6 ]; }
# 鸿蒙字体装到 ~/.local/share/fonts + fontconfig 的 conf.d/
harmony_installed() {
    [ -d "$REAL_HOME/.local/share/fonts/harmonyos-sans-sc" ] && \
    [ -f "$REAL_HOME/.config/fontconfig/conf.d/10-harmony-sans.conf" ]
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
    echo "      若想要「装一次就扛升级」的效果, 可参照 install-wps-office-home.sh 的"
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
    echo "  · 用 $a 从 AUR 安装 wechat-universal-bwrap (需编译, 可能要几分钟)..."
    if [ "$(id -u)" -eq 0 ]; then
        # makepkg 禁 root → 以真实用户身份跑(与主脚本 step[3] 同做法)
        runuser -u "$REAL_USER" -- "$a" -S --noconfirm --needed wechat-universal-bwrap 2>&1 | tail -5
    else
        "$a" -S --noconfirm --needed wechat-universal-bwrap 2>&1 | tail -5
    fi
    for pkg in wechat-universal-bwrap wechat-beta wechat; do
        if pkg_installed "$pkg"; then
            echo "  [✓] 微信已安装($pkg)。注意它在 /usr, 大版本升级后需重装"
            return 0
        fi
    done
    echo "  [✗] AUR 安装未成功(网络/AUR 不可达?)"
    return 1
}

install_firefox_nightly() {
    # 逻辑都在独立脚本里(单独跑也一样), 这里只做薄封装, 保持"一处实现"
    local s
    s="$(cd "$(dirname "$0")" && pwd)/install-firefox-nightly-home.sh"
    if [ ! -f "$s" ]; then
        echo "  [✗] 找不到 $s"
        return 1
    fi
    echo "  · 调用 install-firefox-nightly-home.sh (下载约 100MB, 落到 /home)"
    bash "$s"
}

install_dsh_desktop() {
    # 同上: 逻辑都在独立脚本里, 这里薄封装
    local s
    s="$(cd "$(dirname "$0")" && pwd)/install-dsh-desktop-home.sh"
    if [ ! -f "$s" ]; then
        echo "  [✗] 找不到 $s"
        return 1
    fi
    echo "  · 调用 install-dsh-desktop-home.sh (官方 AppImage 约 90MB, 解到 /home)"
    echo "    注意: 它的内核要求可能高于本包 step[7] 固定的 dsh 版本, 装完看输出提示"
    bash "$s"
}

install_wps_office() {
    # 同上: 逻辑都在独立脚本里, 这里薄封装
    local s
    s="$(cd "$(dirname "$0")" && pwd)/install-wps-office-home.sh"
    if [ ! -f "$s" ]; then
        echo "  [✗] 找不到 $s"
        return 1
    fi
    echo "  · 调用 install-wps-office-home.sh (官方 deb 约 545MB; 解到 /opt 不占 rootfs)"
    echo "    注意: 装前必须完全退出 WPS; 首次会顺带补运行库与中文字体"
    bash "$s"
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
            firefox-nightly) install_firefox_nightly ;;
            dsh-desktop) install_dsh_desktop ;;
            wps-office) install_wps_office ;;
            harmony-sans) install_harmony_sans ;;
            *) echo "  [!] $key 尚未实现" ;;
        esac
    done
done
echo "可选组件安装器退出。"
exit 0
