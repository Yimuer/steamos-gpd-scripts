#!/usr/bin/env bash
#
# 一键升级 WorkBuddy（Arch / CachyOS，AUR 包）并恢复 Wayland 中文输入参数
#
# 背景：
#   1) 应用内更新提示给的下载链接是 .deb 包（platform=workbuddy-linux-x64-deb），
#      在 Arch 上不能直接装 —— 正确路径是 AUR 的 workbuddy 包，版本号与官方同步。
#   2) AUR 的 PKGBUILD 在 package() 里会重新生成 /usr/bin/workbuddy，
#      内容只有 `exec electron /opt/WorkBuddy/app.asar.unpacked "$@"`，
#      会把手动加的 --enable-wayland-ime 等参数冲掉 → 升级后中文输入失效。
#      所以每次升级后必须重跑一次输入法修复脚本。
#
# 用法：bash upgrade-workbuddy-aur.sh
#
set -euo pipefail

# 输入法修复脚本: 与本脚本同目录(备份包已含), 不再写死旧机器路径。
FIX_SCRIPT="$(cd "$(dirname "$0")" && pwd)/fix-workbuddy-wayland-ime.sh"
ASKPASS="/tmp/wb-askpass.sh"

# 图形密码助手：供无 TTY 环境下 sudo 使用（密码只在 KDE 对话框里输入，不落盘）
make_askpass() {
    cat >"$ASKPASS" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/kdialog --title "WorkBuddy 升级" \
    --password "安装 WorkBuddy 需要管理员权限，请输入登录密码："
EOF
    chmod 700 "$ASKPASS"
}

echo "==> 当前已安装版本："
pacman -Qi workbuddy 2>/dev/null | grep '^版本' || echo "未安装 workbuddy"

echo
echo "==> 开始从 AUR 升级（需要密码，可能弹出图形对话框）..."
make_askpass
if command -v yay >/dev/null 2>&1; then
    SUDO_ASKPASS="$ASKPASS" sudo -A -E true 2>/dev/null || true   # 先缓存一次凭据
    yay -S workbuddy --noconfirm --answerclean=None --answerdiff=None
else
    echo "未找到 yay，请先安装 AUR 助手" >&2
    exit 1
fi

echo
echo "==> 恢复 Wayland 输入法参数..."
if [[ -f "$FIX_SCRIPT" ]]; then
    SUDO_ASKPASS="$ASKPASS" sudo -A -E bash "$FIX_SCRIPT" | tail -20
else
    echo "警告：找不到 $FIX_SCRIPT，跳过输入法修复" >&2
fi

rm -f "$ASKPASS"

echo
echo "=============================================="
echo " 升级完成，请完全退出 WorkBuddy 再重新启动："
echo "   托盘图标右键 → 退出（或 pkill -f WorkBuddy）"
echo "   然后从应用菜单重新打开"
echo "=============================================="
