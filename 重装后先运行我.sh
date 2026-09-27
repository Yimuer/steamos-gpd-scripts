#!/bin/bash
# ===========================================================================
#  「重装后先运行我」—— 重装 SteamOS 后的唯一入口(启动器)
# ---------------------------------------------------------------------------
#  这是**唯一实现**; 同目录的 `重装后先运行我.desktop` 只是它的薄壳
#  (双击 .desktop 会调它), 所以逻辑只写这一份。
#
#  怎么跑:
#    · 双击 `重装后先运行我.desktop`(推荐, 会自动开终端)
#    · 或双击本文件 → Dolphin 问"运行/在终端中运行" → 选"在终端中运行"
#    · 或终端里: bash 重装后先运行我.sh
#
#  ⚠️ 拿的是**整个目录**且从 Windows / 网盘 / U 盘 拷过时, 执行位会丢, 双击没反应
#     → 先跑一次: chmod +x *.sh *.desktop
#     (用单文件包 `bash steamos-toolbox-<版本>.run` 则不需要: 模式写在包内 tar 元数据里,
#      安装器会自己补齐)
#
#  它做的事: 装定制图标 → cd 到本目录 → 跑 steamos-setup.sh(16 步, 断点续传)
#            → 问是否装可选组件 → 停住不关窗(方便看输出)
#
#  与 `steamos.sh` 的分工: 本文件是**重装当天的一次性向导**(顺序跑完再问可选项);
#  平时想体检/修复/装单个应用/打包, 用统一入口: bash steamos.sh
# ===========================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || { echo "[✗] 进不去目录: $HERE"; read -r -t 300; exit 1; }

# 装定制图标(与 .desktop 共用 steamos-runme 图标)
ic="$HOME/.local/share/icons/hicolor"
mkdir -p "$ic/scalable/apps" 2>/dev/null
cp -f "$HERE/重装后先运行我.svg" "$ic/scalable/apps/steamos-runme.svg" 2>/dev/null
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f "$ic" 2>/dev/null

# 主脚本必须在场(只拷了启动器没拷全套时, 给句明白话而不是 command not found)
if [ ! -f "$HERE/steamos-setup.sh" ]; then
    echo "[✗] 找不到 $HERE/steamos-setup.sh"
    echo "    整个备份包要一起拷过来(至少要 steamos-setup.sh 与各 install-*.sh)。"
    printf '按回车关闭...'; read -r -t 300 || true
    exit 1
fi

bash ./steamos-setup.sh
rc=$?
echo
printf '是否安装可选组件(微信 / Firefox Nightly / Harness 桌面版 / WPS / 鸿蒙字体 / NextKde)? [y/N] '
# -t 守卫: 无终端时(被管道/定时任务调用)裸 read 会永久挂起
read -r -t 300 opt || opt="n"
opt2="跳过"
case "$opt" in
    y|Y|yes|YES) bash ./可选组件安装.sh; opt2="退出码 $?" ;;
esac
echo
echo "──── 结束：必装退出码 $rc / 可选:$opt2 （检查输出后按回车关闭）────"
read -r -t 300 || true      # 无终端时不等, 直接退出
