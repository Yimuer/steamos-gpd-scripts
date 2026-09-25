#!/usr/bin/env bash
# ============================================================================
#  Decky Loader 安装脚本
#  针对 CachyOS 掌机版（steam-jupiter-stable / steamos-manager）适配
#
#  用法:
#    sudo bash install-decky-loader.sh              安装稳定版（默认）
#    sudo bash install-decky-loader.sh --prerelease 安装预发布版
#    sudo bash install-decky-loader.sh --restart-steam   装完自动重启 Steam
#    sudo bash install-decky-loader.sh --uninstall  卸载（保留插件与配置）
#    bash install-decky-loader.sh --status          查看当前状态
#
#  为什么不用官方 install_prerelease.sh:
#    1. 它第一步 `curl -Is https://github.com`，该域名在本机网络会挂起（无超时保护）
#    2. 它从 raw.githubusercontent.com 拉 service 文件，该域名时通时不通
#    本脚本改为：release 二进制走 GitHub 下载端点（稳定可达），
#               systemd unit 直接内联写入，不依赖 raw.githubusercontent.com
# ============================================================================

set -euo pipefail

REPO="SteamDeckHomebrew/decky-loader"
SERVICE_NAME="plugin_loader"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
API_URL="https://api.github.com/repos/${REPO}/releases?per_page=20"

CHANNEL="${CHANNEL:-stable}"
DO_UNINSTALL=0
DO_STATUS=0
RESTART_STEAM=0

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
	case "$1" in
	--prerelease)   CHANNEL="prerelease" ;;
	--stable)       CHANNEL="stable" ;;
	--uninstall)    DO_UNINSTALL=1 ;;
	--status)       DO_STATUS=1 ;;
	--restart-steam) RESTART_STEAM=1 ;;
	-h | --help)
		sed -n '2,20p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
		exit 0
		;;
	*) echo "未知参数: $1（用 --help 查看用法）" >&2; exit 1 ;;
	esac
	shift
done

# ---------------------------------------------------------------------------
# 提权：非 root 时自动用 sudo 重跑
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ] && [ "$DO_STATUS" -eq 0 ]; then
	exec sudo env CHANNEL="$CHANNEL" RESTART_STEAM="$RESTART_STEAM" "$0" "$@"
fi

# ---------------------------------------------------------------------------
# 目标用户（sudo 下保留真实用户，不要装到 root 家目录）
# ---------------------------------------------------------------------------
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
	TARGET_USER="$SUDO_USER"
elif [ "$DO_STATUS" -eq 1 ]; then
	TARGET_USER="$(id -un)"
else
	TARGET_USER="$(logname 2>/dev/null || echo deck)"
fi
USER_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
HOMEBREW_FOLDER="${USER_DIR}/homebrew"

C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_DIM='\033[2m'; C_R='\033[0m'
info() { printf "${C_OK}[✓]${C_R} %s\n" "$*"; }
warn() { printf "${C_WARN}[!]${C_R} %s\n" "$*"; }
err()  { printf "${C_ERR}[✗]${C_R} %s\n" "$*" >&2; }
step() { printf "\n${C_DIM}── %s ──${C_R}\n" "$*"; }

# ---------------------------------------------------------------------------
# 下载函数：主源 + 重试；备选镜像需显式开启（第三方代理，默认关闭）
# ---------------------------------------------------------------------------
download() {
	local url="$1" dest="$2"
	local -a mirrors=("$url")
	if [ "${USE_MIRROR:-0}" = "1" ]; then
		mirrors+=(
			"https://ghfast.top/${url}"
			"https://gh-proxy.com/${url}"
			"https://mirror.ghproxy.com/${url}"
		)
	fi
	local i m
	for m in "${mirrors[@]}"; do
		for i in 1 2 3; do
			if curl -fL --connect-timeout 10 --max-time 400 \
				--retry 2 --retry-delay 2 "$m" -o "${dest}.part" 2>/dev/null; then
				mv -f "${dest}.part" "$dest"
				return 0
			fi
			[ "$i" -lt 3 ] && sleep 2
		done
	done
	rm -f "${dest}.part"
	return 1
}

# ---------------------------------------------------------------------------
# 状态查看
# ---------------------------------------------------------------------------
if [ "$DO_STATUS" -eq 1 ]; then
	step "Decky Loader 状态"
	printf "  目标用户   : %s\n" "$TARGET_USER"
	printf "  安装目录   : %s\n" "$HOMEBREW_FOLDER"
	[ -f "${HOMEBREW_FOLDER}/services/.loader.version" ] &&
		printf "  已装版本   : %s\n" "$(cat "${HOMEBREW_FOLDER}/services/.loader.version")" ||
		warn "未检测到版本文件（可能未安装）"
	# 注意：systemctl is-active/is-enabled 对未安装的单元会同时输出文本并返回非零码，
	# 不能直接 `$(cmd || echo 兜底)`，否则会打印两行。用 --quiet 判定。
	if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
		printf "  服务状态   : 运行中\n"
	elif [ -f "$UNIT_PATH" ]; then
		printf "  服务状态   : 已安装但未运行（%s）\n" \
			"$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null)"
	else
		printf "  服务状态   : 未安装\n"
	fi
	if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
		printf "  开机自启   : 已启用\n"
	else
		printf "  开机自启   : 未启用\n"
	fi
	# 用 glob 而不是 ls|grep: 插件目录名可能含空格等字符
	for _p in "${HOMEBREW_FOLDER}"/plugins/*/; do
		[ -d "$_p" ] && printf '  插件: %s\n' "$(basename "$_p")"
	done
	exit 0
fi

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
if [ "$DO_UNINSTALL" -eq 1 ]; then
	step "卸载 Decky Loader"
	systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
	systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
	rm -f "$UNIT_PATH"
	systemctl daemon-reload
	rm -f "${HOMEBREW_FOLDER}/services/PluginLoader" \
		"${HOMEBREW_FOLDER}/services/.loader.version"
	info "服务已移除"
	info "插件与配置保留在 ${HOMEBREW_FOLDER}（如需彻底清理，手动删除该目录）"
	warn "请重启 Steam 使改动生效"
	exit 0
fi

# ===========================================================================
#  安装
# ===========================================================================
step "环境检查"
for c in curl jq systemctl; do
	command -v "$c" >/dev/null 2>&1 || { err "缺少依赖: $c"; exit 1; }
done
info "依赖齐全（curl / jq / systemctl）"
printf "  目标用户 : %s (%s)\n" "$TARGET_USER" "$USER_DIR"
printf "  安装目录 : %s\n" "$HOMEBREW_FOLDER"
printf "  通道     : %s\n" "$CHANNEL"

step "创建目录结构"
mkdir -p "${HOMEBREW_FOLDER}/services" "${HOMEBREW_FOLDER}/plugins"
# 开启 Steam 的 CEF 远程调试（Decky 靠这个注入 Steam UI）
touch "${USER_DIR}/.steam/steam/.cef-enable-remote-debugging" 2>/dev/null || true
[ -d "${USER_DIR}/.var/app/com.valvesoftware.Steam/data/Steam/" ] &&
	touch "${USER_DIR}/.var/app/com.valvesoftware.Steam/data/Steam/.cef-enable-remote-debugging"
info "目录已就绪，CEF 远程调试标记已写入"

step "查询最新版本"
RELEASES="$(curl -fsS --connect-timeout 10 --max-time 30 "$API_URL")" ||
	{ err "无法访问 GitHub API，请检查网络"; exit 1; }
if [ "$CHANNEL" = "prerelease" ]; then
	VERSION="$(jq -r 'first(.[] | select(.prerelease == true))  | .tag_name' <<<"$RELEASES")"
else
	VERSION="$(jq -r 'first(.[] | select(.prerelease == false)) | .tag_name' <<<"$RELEASES")"
fi
[ -n "$VERSION" ] && [ "$VERSION" != "null" ] || { err "解析版本号失败"; exit 1; }
DOWNLOAD_URL="$(jq -r --arg v "$VERSION" \
	'first(.[] | select(.tag_name == $v)) | .assets[].browser_download_url
	 | select(endswith("PluginLoader"))' <<<"$RELEASES")"
[ -n "$DOWNLOAD_URL" ] || { err "未找到 PluginLoader 资产"; exit 1; }
info "版本: $VERSION"
printf "  %s\n" "$DOWNLOAD_URL"

step "下载 PluginLoader（约 26 MB）"
if download "$DOWNLOAD_URL" "${HOMEBREW_FOLDER}/services/PluginLoader"; then
	chmod +x "${HOMEBREW_FOLDER}/services/PluginLoader"
	info "下载完成"
else
	err "下载失败。可尝试：USE_MIRROR=1 sudo bash $0（走第三方镜像加速）"
	err "或手动下载后放到 ${HOMEBREW_FOLDER}/services/PluginLoader"
	exit 1
fi
echo "$VERSION" >"${HOMEBREW_FOLDER}/services/.loader.version"

step "安装 systemd 服务"
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

# unit 内联写入（不依赖 raw.githubusercontent.com）
cat >"$UNIT_PATH" <<EOF
[Unit]
Description=SteamDeck Plugin Loader
After=network.target
[Service]
Type=simple
User=root
Restart=always
KillMode=process
TimeoutStopSec=15
ExecStart=${HOMEBREW_FOLDER}/services/PluginLoader
WorkingDirectory=${HOMEBREW_FOLDER}/services
Environment=UNPRIVILEGED_PATH=${HOMEBREW_FOLDER}
Environment=PRIVILEGED_PATH=${HOMEBREW_FOLDER}
Environment=LOG_LEVEL=INFO
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
systemctl restart "${SERVICE_NAME}"
info "服务已安装并启动（开机自启）"

step "修正文件属主"
chown -R "${TARGET_USER}:$(id -gn "$TARGET_USER")" "${HOMEBREW_FOLDER}" 2>/dev/null || true
chown "${TARGET_USER}:$(id -gn "$TARGET_USER")" \
	"${USER_DIR}/.steam/steam/.cef-enable-remote-debugging" 2>/dev/null || true
info "属主已设为 ${TARGET_USER}"

# ---------------------------------------------------------------------------
# 验证
# ---------------------------------------------------------------------------
step "验证"
sleep 2
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
	info "plugin_loader 运行中"
else
	warn "服务未运行 —— 查看日志: journalctl -u ${SERVICE_NAME} -n 30"
fi
printf "  二进制    : %s\n" "$(ls -lh "${HOMEBREW_FOLDER}/services/PluginLoader" | awk '{print $5}')"
printf "  已装版本  : %s\n" "$(cat "${HOMEBREW_FOLDER}/services/.loader.version")"

# ---------------------------------------------------------------------------
# Steam 处理
# ---------------------------------------------------------------------------
step "收尾"
if pgrep -u "$TARGET_USER" -x steam >/dev/null 2>&1 ||
	pgrep -u "$TARGET_USER" -f "steam.sh" >/dev/null 2>&1; then
	if [ "$RESTART_STEAM" -eq 1 ]; then
		warn "正在重启 Steam（3 秒后）……未保存的游戏进度会丢失！"
		sleep 3
		pkill -u "$TARGET_USER" -f "steam.sh" 2>/dev/null || true
		pkill -u "$TARGET_USER" -x steam 2>/dev/null || true
		sleep 2
		info "Steam 已关闭，请从菜单重新启动"
	else
		warn "检测到 Steam 正在运行 —— 必须完全退出并重启 Steam，Decky 才会注入"
		printf "      操作：Steam → 电源 → 退出，然后重新打开\n"
		printf "      或重跑：sudo bash %s --restart-steam\n" "$0"
	fi
else
	info "Steam 未运行，直接启动即可"
fi

cat <<EOF

${C_OK}==================== 安装完成 ====================${C_R}

  Decky Loader ${VERSION}（${CHANNEL} 通道）

  使用方式:
    进入 Steam 大屏幕模式（或 gamescope 掌机会话），
    右侧「...」快捷菜单最下方出现 Decky 图标即成功
    插件商店：Decky 界面 → 商店（需联网）

  常用命令:
    查看状态   bash $0 --status
    更新版本   重跑本脚本（插件与设置会保留）
    卸载       sudo bash $0 --uninstall
    服务日志   journalctl -u ${SERVICE_NAME} -f

  提示:
    插件装到 ${HOMEBREW_FOLDER}/plugins

EOF
