#!/bin/bash
# =============================================================================
#  可选组件安装器 —— 必装之外的增强项(与 steamos-setup.sh 十二步主线解耦)
# -----------------------------------------------------------------------------
#  用法: 终端里 bash 本文件; 或由「重装后先运行我」在必装完成后拉起。
#  必装环境(archlinuxcn源/WorkBuddy/Decky/背键/TDP...)请跑 steamos-setup.sh。
#
#  【扩展点】新增可选项: ①写 install_xxx() ②MENU_ORDER/MENU_NAME/MENU_PKGS
#  各加一行 ③case 分支加一行 —— 三处, 不要散落逻辑。
# =============================================================================
cd "$(dirname "$0")" || exit 1

# pacman 需要 root: 沿用主脚本的提权模式(-E 保留用户环境)
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -E bash "$0" "$@"
fi

# ── 可选项注册表 ──
MENU_ORDER=(wechat)
declare -A MENU_NAME=(
    [wechat]="微信 (官方原生版沙盒封装 wechat-universal-bwrap, 含中文字体)"
)
declare -A MENU_PKGS=(
    [wechat]="wechat-universal-bwrap"
)

pkg_installed() { pacman -Qq "$1" >/dev/null 2>&1; }

# ── 各组件安装函数 ──
install_wechat() {
    # SteamOS 缺 CJK 字体, 不装微信会显示方块
    echo "  · 安装中文字体(notoso-cjk)..."
    pacman -S --noconfirm --needed noto-fonts-cjk 2>&1 | tail -2
    # 候选包名可能随 archlinuxcn 上游调整, 逐个探测
    local pkg hit=""
    for pkg in wechat-universal-bwrap wechat-beta wechat; do
        if pacman -Si "$pkg" >/dev/null 2>&1; then hit="$pkg"; break; fi
    done
    if [ -z "$hit" ]; then
        echo "  [✗] 软件源里没有微信包。请确认第[1]步 archlinuxcn 源已配置并执行过 pacman -Sy"
        echo "      或手动从 AUR 安装: wechat-universal-bwrap"
        return 1
    fi
    echo "  · 安装 $hit ..."
    pacman -S --noconfirm --needed "$hit" 2>&1 | tail -3
    if pkg_installed "$hit"; then
        echo "  [✓] 微信已安装($hit)。桌面/游戏模式的应用列表里会出现 WeChat"
        return 0
    fi
    echo "  [✗] 安装失败"; return 1
}

# ── 菜单循环 ──
while true; do
    echo
    echo "════════ 可选组件安装 (必装环境请跑 steamos-setup.sh) ════════"
    i=1
    for key in "${MENU_ORDER[@]}"; do
        mark=" "
        pkg_installed "${MENU_PKGS[$key]}" && mark="✓"
        printf "  %d. [%s] %s\n" "$i" "$mark" "${MENU_NAME[$key]}"
        i=$((i + 1))
    done
    echo "  0. 退出"
    printf "选择要安装的编号(可多选, 空格分隔, 直接回车=退出): "
    read -r -a picks || break
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
            *) echo "  [!] $key 尚未实现" ;;
        esac
    done
done
echo "可选组件安装器退出。"
exit 0
