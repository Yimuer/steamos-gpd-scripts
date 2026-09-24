#!/usr/bin/env bash
#
# 修复：WorkBuddy (Electron 43) 在 KDE Plasma 6.7 Wayland 下无法使用 fcitx5
#
# ⚠️ 重要更正 (2026-09-06)：本脚本【不是】WorkBuddy 无法输入中文的根因修复。
#   实测（WAYLAND_DEBUG 抓包）：Electron 43 默认就已使用 text-input-v3，
#   加不加 --wayland-text-input-version=3 在协议层面完全一致，属无效改动。
#   真正根因：KWin 未配置输入法进程（kwinrc 缺 [Wayland] InputMethod），
#   按键根本不会被转发给 fcitx5 → 所有 Wayland 原生应用都无法输入中文。
#   诊断: check-wayland-ime.sh   修复: 系统设置 → 键盘 → 虚拟键盘 → 选 Fcitx 5
#   本脚本保留仅用于确保 Electron 走原生 Wayland，属无害加固，非必需。
#
# 参考原理：
#     --enable-wayland-ime               开启 wayland IME（否则不连 text-input）
#     --ozone-platform=wayland           保证原生 Wayland 而非 XWayland
#     --enable-features=UseOzonePlatform 让 Electron 接受 ozone 参数
#
# 用法：sudo bash fix-workbuddy-wayland-ime.sh
#
set -euo pipefail

WRAPPER="/usr/bin/workbuddy"
MARK="--wayland-text-input-version=3"
FLAGS=("--enable-features=UseOzonePlatform" "--ozone-platform=wayland"
       "--enable-wayland-ime" "--wayland-text-input-version=3")

if [[ $EUID -ne 0 ]]; then
    echo "错误：请以 root 运行（sudo bash $0）" >&2
    exit 1
fi

if [[ ! -f "$WRAPPER" ]]; then
    echo "错误：找不到 $WRAPPER" >&2
    exit 1
fi

# 首次修改时备份原始包装脚本（备份只做一次，保留最原始版本）
if [[ ! -f "${WRAPPER}.orig.bak" ]]; then
    cp -a "$WRAPPER" "${WRAPPER}.orig.bak"
    echo "已备份原始文件 → ${WRAPPER}.orig.bak"
fi

if grep -q -- "$MARK" "$WRAPPER"; then
    echo "✔ 已是最新（含 text-input-v3），无需修改。"
else
    # 从最原始的备份重建，避免多次运行累积重复 flag
    cp -a "${WRAPPER}.orig.bak" "$WRAPPER"
    sed -i 's#app\.asar\.unpacked#app.asar.unpacked '"${FLAGS[*]}"'#' "$WRAPPER"
    echo "✔ 已写入：${FLAGS[*]}"
fi

echo
echo "修改后的 $WRAPPER："
echo "----------------------------------------"
cat "$WRAPPER"
echo "----------------------------------------"

if bash -n "$WRAPPER"; then
    echo "✔ 语法检查通过"
else
    echo "✘ 语法检查失败，正在回滚..." >&2
    cp -a "${WRAPPER}.orig.bak" "$WRAPPER"
    exit 1
fi

echo
echo "=============================================="
echo " 完成。请完全退出 WorkBuddy 后重新启动："
echo "   1) 托盘图标右键 → 退出（或 pkill -f WorkBuddy）"
echo "   2) 从应用菜单重新打开 WorkBuddy"
echo
echo " 注意：必须整个进程退出再启动，光关窗口不够。"
echo " 验证：在输入框按 Ctrl+Space 切换，能出候选框即成功。"
echo " 若 WorkBuddy 自动更新后中文输入再次失效，重跑本脚本即可。"
echo "=============================================="
