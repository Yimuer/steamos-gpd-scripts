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
printf "是否安装可选组件(微信 / Firefox Nightly / Harness 桌面版 / 鸿蒙字体)? [y/N] "
# -t 守卫: 无终端时(被管道/定时任务调用)裸 read 会永久挂起
read -r -t 300 opt || opt="n"
opt2="跳过"
case "$opt" in
    y|Y|yes|YES) bash ./可选组件安装.sh; opt2="退出码 $?" ;;
esac
echo
echo "──── 结束：必装退出码 $rc / 可选:$opt2 （按回车关闭）────"
read -r -t 300 || true      # 无终端时不等, 直接退出
