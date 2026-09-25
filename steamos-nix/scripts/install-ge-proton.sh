#!/usr/bin/env bash
# GE-Proton 镜像加速安装器 —— 替代 ProtonPlus 的下载步骤（ProtonPlus 无换源配置项）
# 用法:
#   bash install-ge-proton.sh                 # 安装最新版
#   bash install-ge-proton.sh GE-Proton10-9   # 安装指定版本
#   MIRROR=direct bash install-ge-proton.sh   # 强制 GitHub 直连（不推荐）
#   MIRROR=https://ghfast.top bash install-ge-proton.sh  # 换其他镜像
set -euo pipefail

REPO="GloriousEggroll/proton-ge-custom"
TOOLS_DIR="$HOME/.local/share/Steam/compatibilitytools.d"
MIRROR="${MIRROR:-https://gh-proxy.com}"   # 实测最快；备选 https://ghfast.top
GH="https://github.com"

info() { printf "\033[32m[✓]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[!]\033[0m %s\n" "$*"; }
err()  { printf "\033[31m[x]\033[0m %s\n" "$*"; exit 1; }

# ---- 版本号：参数 > 最新版 ----
if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
	TAG="$1"
else
	info "查询最新版本..."
	TAG=$(curl -fsS --connect-timeout 10 --max-time 30 \
		"https://api.github.com/repos/$REPO/releases/latest" | jq -r .tag_name)
	[ -n "$TAG" ] && [ "$TAG" != "null" ] || err "无法从 GitHub API 获取版本号"
fi

# ---- 组装 URL ----
if [ "$MIRROR" = "direct" ]; then
	BASE="$GH"
else
	BASE="$MIRROR/$GH"
fi
TARBALL="${TAG}-x86_64.tar.gz"
URL="$BASE/$REPO/releases/download/$TAG/$TARBALL"
SUM_URL="$BASE/$REPO/releases/download/$TAG/${TAG}-x86_64.sha512sum"

info "版本: $TAG"
info "源:   $URL"
info "目标: $TOOLS_DIR/$TAG"

mkdir -p "$TOOLS_DIR"
TMP=$(mktemp -d /tmp/ge-proton.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# ---- 下载（断点续传 + 重试）----
info "下载主包（约 509MB）..."
curl -fL --connect-timeout 10 --retry 3 --retry-delay 2 -C - \
	-o "$TMP/$TARBALL" "$URL" || err "下载失败，可换镜像重试：MIRROR=https://ghfast.top bash $0 $TAG"

info "下载校验文件..."
curl -fsSL --connect-timeout 10 --retry 3 -o "$TMP/${TAG}-x86_64.sha512sum" "$SUM_URL" \
	|| warn "校验文件下载失败，跳过完整性检查"

if [ -s "$TMP/${TAG}-x86_64.sha512sum" ]; then
	info "校验 SHA512..."
	(cd "$TMP" && sha512sum -c "${TAG}-x86_64.sha512sum") || err "SHA512 校验不通过！请勿使用该文件"
	info "校验通过"
fi

# ---- 解压安装 ----
info "解压到 $TOOLS_DIR ..."
rm -rf "$TOOLS_DIR/$TAG"
tar -xzf "$TMP/$TARBALL" -C "$TOOLS_DIR"
chmod +x "$TOOLS_DIR/$TAG/proton" 2>/dev/null || true

info "==================== 安装完成 ===================="
echo "完全退出 Steam 再重开（不是关窗口）：Steam → 电源 → 退出"
echo "然后：游戏右键 → 属性 → 兼容性 → 勾选「强制使用特定兼容性工具」→ 选 $TAG"
echo
echo "提示：也可继续用 ProtonPlus 管理已装版本，但它的下载走 GitHub 直连，"
echo "      会很慢甚至卡死 —— 下载环节请用本脚本替代。"
