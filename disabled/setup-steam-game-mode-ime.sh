#!/usr/bin/env bash
#
# 修复：Steam 游戏模式（大屏幕）虚拟键盘无法输入中文
#
# 原理：
#   Steam 客户端在游戏模式下是通过 **IBus D-Bus 协议** 跟输入法通信的
#   （会话 target 里 ibus-gamescope.service 就是这个通道）。
#   本机输入法框架是 fcitx5，而系统并没有安装 ibus → 通道是空的，
#   所以虚拟键盘只能打出英文字母，中文候选一个都出不来。
#
#   解决：安装 AUR 包 fcitx5-steam-ibus-frontend，让 fcitx5 直接提供 IBus
#   协议给 Steam；并在进入游戏模式时自动以 steamibusfrontend 模式启动
#   fcitx5（保留现有的小鹤双拼 / rime 配置，不需要迁移）。
#
# 用法：bash setup-steam-game-mode-ime.sh
#
set -euo pipefail

UNIT_DIR="$HOME/.config/systemd/user"
BIN_DIR="$HOME/.local/bin"
UNIT="$UNIT_DIR/fcitx5-steam-ibus.service"
STARTER="$BIN_DIR/fcitx5-steam-ibus-start.sh"
PKG="fcitx5-steam-ibus-frontend"

echo "== 1/4 查找 AUR 助手 =="
HELPER=""
for h in yay paru pikaur aura; do
    if command -v "$h" > /dev/null 2>&1; then HELPER="$h"; break; fi
done
if [[ -z "$HELPER" ]]; then
    echo "错误：没找到 AUR 助手（yay/paru/pikaur）。请先安装，例如：" >&2
    echo "  sudo pacman -S --needed git base-devel && \\" >&2
    echo "  git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si" >&2
    exit 1
fi
echo "  使用: $HELPER"

echo "== 2/4 安装 $PKG =="
if pacman -Q "$PKG" > /dev/null 2>&1 || \
   ls /usr/lib/fcitx5/libsteamibusfrontend.so > /dev/null 2>&1; then
    echo "  已安装，跳过"
elif compgen -G "/tmp/aur-build/fcitx5-steam-ibus-frontend/${PKG}-*.pkg.tar.zst" > /dev/null; then
    # 优先使用已构建好的本地包（避免 AUR 网络问题）
    echo "  使用本地构建好的包安装（需要 sudo 密码）:"
    sudo pacman -U --noconfirm /tmp/aur-build/fcitx5-steam-ibus-frontend/"$PKG"-*.pkg.tar.zst
else
    "$HELPER" -S --noconfirm "$PKG"
fi

echo "== 3/4 写入启动脚本与 systemd 单元 =="
mkdir -p "$BIN_DIR" "$UNIT_DIR"

cat > "$STARTER" << 'EOF'
#!/usr/bin/env bash
# 在游戏模式（gamescope）会话中，以 Steam IBus 前端启动 fcitx5
set -euo pipefail

ENVF="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gamescope-environment"
# gamescope 会话会把 DISPLAY / GAMESCOPE_WAYLAND_DISPLAY 同步到这个文件
[[ -r "$ENVF" ]] && set -a && . "$ENVF" && set +a
export DISPLAY="${DISPLAY:-:0}"

export GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS="@im=fcitx"
export SDL_IM_MODULE=fcitx

# steamibusfrontend 必须与自带的 ibusfrontend 二选一，否则抢 DBus 名
exec /usr/bin/fcitx5 --enable steamibusfrontend --disable ibusfrontend -r
EOF
chmod +x "$STARTER"

cat > "$UNIT" << EOF
[Unit]
Description=Fcitx5 (Steam IBus frontend) for gamescope session
PartOf=gamescope-session.target
After=gamescope-session.service

[Service]
Type=simple
ExecStart=$STARTER
Restart=on-failure
RestartSec=2

[Install]
WantedBy=gamescope-session.target
EOF

echo "== 4/4 启用服务 =="
systemctl --user daemon-reload
systemctl --user enable fcitx5-steam-ibus.service

echo
echo "=============================================="
echo " 配置完成。使用方式："
echo "   1) 切换到游戏模式（或重启后直接进游戏模式）"
echo "   2) STEAM + X 呼出虚拟键盘"
echo "   3) 键盘左下角切换输入法图标 → 选中文（小鹤双拼/rime）"
echo
echo  "排查命令（游戏模式里开终端 / SSH 执行）："
echo "   systemctl --user status fcitx5-steam-ibus.service"
echo "   journalctl --user -u fcitx5-steam-ibus -b --no-pager | tail -30"
echo
echo " 说明：本方案保留桌面模式原有的 fcitx5 配置，"
echo "       不需要迁移到 ibus，也不需要改动 rime 词库。"
echo "=============================================="
