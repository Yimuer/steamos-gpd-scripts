#!/bin/bash
# 备用启动器: 若 .desktop 双击提示"不受信任"或行为异常, 直接双击本文件,
# Dolphin 会询问"运行/在终端中运行", 选"在终端中运行"即可。效果与 .desktop 相同。
cd "$(dirname "$0")" || exit 1
bash ./steamos-setup.sh
rc=$?
echo
echo "──── 结束：退出码 $rc （按回车关闭）────"
read -r
