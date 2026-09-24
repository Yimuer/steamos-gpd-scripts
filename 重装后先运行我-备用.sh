#!/bin/bash
# 备用启动器: 若 .desktop 双击提示"不受信任"或行为异常, 直接双击本文件,
# Dolphin 会询问"运行/在终端中运行", 选"在终端中运行"即可。效果与 .desktop 相同。
# 首次运行会把同目录的 .svg 装进用户图标主题(与 .desktop 共用 steamos-runme 图标)。
ic="$HOME/.local/share/icons/hicolor"
mkdir -p "$ic/scalable/apps"
cp -f "$(dirname "$0")/重装后先运行我.svg" "$ic/scalable/apps/steamos-runme.svg" 2>/dev/null
gtk-update-icon-cache -f "$ic" 2>/dev/null
cd "$(dirname "$0")" || exit 1
bash ./steamos-setup.sh
rc=$?
echo
echo "──── 结束：退出码 $rc （按回车关闭）────"
read -r
