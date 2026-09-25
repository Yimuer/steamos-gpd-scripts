#!/usr/bin/env bash
#
# ⚠️ 已废弃(2026-09-16) —— 输入法统一到 **IBus**，不再用 fcitx5。
#
#    原因：
#      ① SteamOS 自带 ibus；
#      ② Steam 游戏模式(gamescope)**只认 IBus D-Bus 协议**，fcitx5 得靠 AUR
#         桥接包 fcitx5-steam-ibus-frontend 冒充，多一层就多一处坏点；
#      ③ 两套框架并存会抢 DBus 名和 GTK/QT IM 模块。
#
#    请改用：  sh scripts/setup-ibus-xiaohe.sh        （配置 IBus + 小鹤双拼）
#              sh scripts/setup-ibus-xiaohe.sh --check（体检）
#              bash scripts/setup-steam-game-mode-ime.sh（游戏模式）
#
#    本文件保留仅供回滚参考，直接运行会退出。
#
# ==========================================================================
echo "本脚本已废弃：输入法改用 IBus（SteamOS 自带）。请用: sh scripts/setup-ibus-xiaohe.sh" >&2
exit 1

# ---------- 以下为历史实现，保留备查 -----------------------------------
#
# Fcitx5 + Rime「小鹤双拼」一键安装配置脚本
# 适用：CachyOS / Arch Linux，KDE Plasma (Wayland)
#
# 用法：sudo bash setup-fcitx5-flypy.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "错误：请以 root 运行（sudo bash $0）" >&2
    exit 1
fi

REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
REAL_GROUP="$(id -gn "$REAL_USER")"

FCITX_CONF="$REAL_HOME/.config/fcitx5"
RIME_DIR="$REAL_HOME/.local/share/fcitx5/rime"

PKGS=(
    # 核心框架 + 图形配置工具 + GTK/Qt 集成
    fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt
    # 内置拼音引擎（全拼备用）
    fcitx5-chinese-addons
    # Rime 引擎
    fcitx5-rime
    # Rime 方案：小鹤双拼（自动带上 rime-luna-pinyin / rime-stroke）+ 基础文件 + emoji
    rime-double-pinyin rime-essay rime-prelude rime-emoji
    # 维基百科大词库
    rime-pinyin-zhwiki
)

echo "=============================================="
echo " 目标用户 : $REAL_USER  ($REAL_HOME)"
echo " 会话类型 : ${XDG_SESSION_TYPE:-unknown}"
echo "=============================================="
echo

echo "==> [1/5] 安装软件包（pacman 会列出清单让你确认）"
pacman -S --needed "${PKGS[@]}"

echo
echo "==> [2/5] 写入 fcitx5 配置：Rime 为默认输入法"
mkdir -p "$FCITX_CONF" "$RIME_DIR" \
         "$REAL_HOME/.config/environment.d" \
         "$REAL_HOME/.config/fish/conf.d"

cat > "$FCITX_CONF/profile" <<'EOF'
[Groups/0]
# 分组名
Name=Default
# 默认布局
Default Layout=us
# 默认输入法
DefaultIM=rime
# 输入法列表
IMs=rime,keyboard-us,pinyin

[Groups/0/Items/0]
Name=rime
Layout=

[Groups/0/Items/1]
Name=keyboard-us
Layout=

[Groups/0/Items/2]
Name=pinyin
Layout=

[GroupOrder]
0=Default
EOF

echo
echo "==> [3/5] 写入 Rime 配置：小鹤双拼设为默认方案"
cat > "$RIME_DIR/default.custom.yaml" <<'EOF'
# Rime 用户配置 —— 小鹤双拼（flypy）为默认方案
# 修改后需「重新部署」生效（Ctrl+` → 重新部署）
patch:
  # 方案选单顺序，第一项为默认方案
  schema_list:
    - schema: double_pinyin_flypy   # 小鹤双拼
    - schema: luna_pinyin           # 明月拼音（全拼）
    - schema: double_pinyin_zrm     # 自然码双拼
    - schema: double_pinyin_mspy    # 微软双拼
    - schema: emoji                 # emoji
  # 每页候选词数量
  menu/page_size: 7
EOF

echo
echo "==> [4/5] 写入环境变量与自启动"
cat > "$REAL_HOME/.config/environment.d/fcitx5.conf" <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
EOF

cat > "$REAL_HOME/.config/fish/conf.d/fcitx5.fish" <<'EOF'
# fcitx5 输入法环境变量（终端里启动的程序也能用）
set -gx GTK_IM_MODULE fcitx
set -gx QT_IM_MODULE fcitx
set -gx XMODIFIERS @im=fcitx
set -gx SDL_IM_MODULE fcitx
EOF

# 自启动：fcitx5 通常自带 /etc/xdg/autostart 条目，缺失时补一份用户级
if [[ -f /etc/xdg/autostart/org.fcitx.Fcitx5.desktop ]]; then
    echo "自启动项已由 fcitx5 包提供（/etc/xdg/autostart），跳过"
elif [[ -f /usr/share/applications/org.fcitx.Fcitx5.desktop ]]; then
    mkdir -p "$REAL_HOME/.config/autostart"
    cp /usr/share/applications/org.fcitx.Fcitx5.desktop \
       "$REAL_HOME/.config/autostart/org.fcitx.Fcitx5.desktop"
    echo "已添加用户级自启动项"
else
    echo "警告：未找到 org.fcitx.Fcitx5.desktop，请手动把 fcitx5 加入自启动"
fi

echo
echo "==> [5/5] 修正文件属主"
chown "$REAL_USER:$REAL_GROUP" "$FCITX_CONF/profile" \
    "$RIME_DIR/default.custom.yaml" \
    "$REAL_HOME/.config/environment.d/fcitx5.conf" \
    "$REAL_HOME/.config/fish/conf.d/fcitx5.fish" \
    2>/dev/null || true

echo
echo "=============================================="
echo " 安装配置完成！"
echo "=============================================="
echo
echo " 已安装方案目录：/usr/share/rime-data"
echo " Rime 用户目录  ：$RIME_DIR"
echo
echo " 下一步：注销并重新登录（或重启），让环境变量生效。"
echo " 登录后首次 Rime 部署需 1~2 分钟（正在编译维基大词库）。"
echo
cat <<'EOF'

 常用快捷键：
   Ctrl + Space        切换中文 / 英文输入
   Ctrl + `(反引号) 或 F4   打开方案选单，可切到「小鹤双拼」「明月拼音(全拼)」「emoji」
   Ctrl + .            中英文标点切换（部分方案）
EOF
