#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 安装 SimpleDeckyTDP —— 游戏模式里分别控制「插电 / 离电」TDP
#
# 适用: GPD Win 5 (Ryzen AI Max+ 395, Strix Halo) + SteamOS + Decky Loader
#   官方 SteamOS 的 QAM 性能面板只对 Steam Deck 给 TDP 滑块, GPD 设备不在列表里,
#   必须靠这个插件。ETA PRIME 实测同系列 Strix Halo 上可调 4W~120W。
#
# 用法:
#   sudo bash install-decky-tdp.sh
#   sudo bash install-decky-tdp.sh --uninstall     # 卸载
#   VERSION=v1.0.6 sudo bash install-decky-tdp.sh  # 装指定版本
#
# 装完后进游戏模式: QAM(右下 KB 键) → 找到 SimpleDeckyTDP 图标
#   首次使用要打开 "AC Profiles" 开关, 才能分别设插电/离电两套 TDP。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
HOME_DIR="${REAL_HOME:-/home/deck}"
PLUGIN_DIR="$HOME_DIR/homebrew/plugins"
PLUGIN_NAME="SimpleDeckyTDP"
REPO="aarron-lee/SimpleDeckyTDP"
VERSION="${VERSION:-latest}"

C_0=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_D=$'\033[2m'
info() { printf "${C_G}[✓]${C_0} %s\n" "$*"; }
warn() { printf "${C_Y}[!]${C_0} %s\n" "$*"; }
err()  { printf "${C_R}[✗]${C_0} %s\n" "$*" >&2; }
sub()  { printf "${C_D}   • %s${C_0}\n" "$*"; }
step() { printf "\n${C_G}════════ %s ════════${C_0}\n" "$*"; }

# ── 默认档位(W), 装完自动写进插件: 插电/离电两套 ──
#   TDP_AC=55 TDP_DC=30 sudo bash install-decky-tdp.sh  ← 想改默认值这样跑
TDP_AC="${TDP_AC:-75}"
TDP_DC="${TDP_DC:-40}"

[ "$(id -u)" -eq 0 ] || { err "需要 root: sudo bash $SCRIPT_NAME"; exit 1; }

# ── 卸载 ──
if [ "${1:-}" = "--uninstall" ]; then
    step "卸载 $PLUGIN_NAME"
    rm -rf "$PLUGIN_DIR/$PLUGIN_NAME"
    systemctl restart plugin_loader 2>/dev/null || true
    info "已卸载并重启 Decky"
    exit 0
fi

# ---------- 探活: 连不上就立刻换源(不要干等超时) ----------
url_reachable() {
    local code
    code="$(curl -sIL --connect-timeout 6 --max-time 12 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)"
    case "$code" in 200|301|302|303|307|308) return 0 ;; *) return 1 ;; esac
}

step "安装 $PLUGIN_NAME (游戏模式 TDP 控制)"

# ── 前置检查 ──
sub "检查 Decky Loader..."
if [ ! -d "$HOME_DIR/homebrew" ]; then
    err "未发现 ~/homebrew —— Decky Loader 没装。先跑: bash steamos-setup.sh decky"
    exit 1
fi
if ! systemctl list-unit-files 2>/dev/null | grep -q plugin_loader; then
    warn "plugin_loader 服务不存在, Decky 可能未装好(继续尝试)"
else
    info "Decky Loader 已装$(cat "$HOME_DIR/homebrew/services/.loader.version" 2>/dev/null | sed 's/^/ (v/;s/$/)/')"
fi

# ── 查版本号 ──
sub "查询最新版本..."
if [ "$VERSION" = "latest" ]; then
    TAG="$(curl -sL --connect-timeout 8 --max-time 25 \
        "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)"
    [ -n "$TAG" ] || TAG="v1.0.7"      # 兜底: API 不通时用已知版本
else
    TAG="$VERSION"
fi
info "目标版本: $TAG"

DLURL="https://github.com/$REPO/releases/download/$TAG/${PLUGIN_NAME}.zip"

# ── 目标目录可写性预检 ──
# 注意: 只看 id -u 不够 —— 容器/受限环境里 uid 可能显示为 0 但实际没权限,
# 那会导致后面 mv 裸失败并留下临时文件。这里实测一下。
mkdir -p "$PLUGIN_DIR" 2>/dev/null || true
if [ ! -w "$PLUGIN_DIR" ]; then
    err "插件目录不可写: $PLUGIN_DIR"
    sub "属主: $(stat -c '%U:%G %a' "$PLUGIN_DIR" 2>/dev/null)"
    sub "请在真机终端里用 sudo 执行: sudo bash $SCRIPT_NAME"
    exit 1
fi

TMPZIP="$(mktemp "${HOME_DIR}/.cache/tdp.XXXXXX.zip" 2>/dev/null || mktemp /tmp/tdp.XXXXXX.zip)"
trap 'rm -f "$TMPZIP"' EXIT

ok=0
for prefix in "https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/" ""; do
    u="${prefix}${DLURL}"
    sub "尝试: $u"
    url_reachable "$u" || { sub "  探活失败, 换下一个"; continue; }
    if curl -fL --connect-timeout 10 --max-time 300 "$u" -o "$TMPZIP" 2>/dev/null \
       && [ -s "$TMPZIP" ]; then
        ok=1; info "  下载完成 ($(du -h "$TMPZIP" | cut -f1))"; break
    fi
    sub "  下载失败, 换下一个"
done
[ "$ok" -eq 1 ] || { err "全部源下载失败。可手动下 $DLURL 放到 $PLUGIN_DIR/"; exit 1; }

# ── 校验是 zip 且内容合理 ──
if ! unzip -l "$TMPZIP" >/dev/null 2>&1; then
    err "下载到的不是有效 zip(可能是镜像返回的错误页)。请手动下载: $DLURL"
    exit 1
fi
if ! unzip -l "$TMPZIP" 2>/dev/null | grep -q "package.json"; then
    err "zip 里没有 package.json, 结构异常。请手动下载: $DLURL"
    exit 1
fi
info "zip 校验通过"

# ── 安装 ──
if [ -d "$PLUGIN_DIR/$PLUGIN_NAME" ]; then
    BAK="$PLUGIN_DIR/${PLUGIN_NAME}.bak.$(date +%m%d-%H%M%S)"
    mv "$PLUGIN_DIR/$PLUGIN_NAME" "$BAK" && info "已备份旧版 → $BAK"
fi

TMPX="$(mktemp -d "${TMPZIP}.x.XXXXXX")"
unzip -q "$TMPZIP" -d "$TMPX"

# 有的版本解压后自带一层目录, 有的直接是文件
if [ -f "$TMPX/package.json" ]; then
    SRC="$TMPX"
elif [ -f "$TMPX/$PLUGIN_NAME/package.json" ]; then
    SRC="$TMPX/$PLUGIN_NAME"
else
    SRC="$(find "$TMPX" -maxdepth 2 -name package.json -printf '%h\n' | head -1)"
fi
[ -n "${SRC:-}" ] && [ -f "$SRC/package.json" ] || { err "找不到 package.json"; exit 1; }

if ! mv "$SRC" "$PLUGIN_DIR/$PLUGIN_NAME"; then
    rm -rf "$TMPX"
    err "安装失败: 无法写入 $PLUGIN_DIR (权限不足?)"
    sub "请改用: sudo bash $SCRIPT_NAME"
    exit 1
fi
rm -rf "$TMPX"
# Decky 以普通用户身份读插件; 属主错了插件会加载失败(界面里看不到图标)
chown -R "${SUDO_USER:-deck}:${SUDO_USER:-deck}" "$PLUGIN_DIR/$PLUGIN_NAME" 2>/dev/null \
    || warn "改属主失败(可能非 sudo 环境), 若插件不显示请手动: sudo chown -R deck:deck $PLUGIN_DIR/$PLUGIN_NAME"
info "已安装到 $PLUGIN_DIR/$PLUGIN_NAME"

# ── 重启 Decky ──
systemctl restart plugin_loader 2>/dev/null \
    && info "Decky 已重启" || warn "重启 Decky 失败(未装/未运行?)"

# ── 写默认 TDP 配置(插电/离电) ──
# SimpleDeckyTDP 配置在 ~/homebrew/settings/SimpleDeckyTDP/settings.json。
#   advanced.acPowerProfiles = true            → 打开 "AC Profiles"
#   tdpProfiles["default"].tdp                 → 离电档 TDP_DC
#   tdpProfiles["default-ac-power"].tdp        → 插电档 TDP_AC
#   enableTdpProfiles = false                  → 用全局 default, 不做每游戏 profile
CFG_DIR="$HOME_DIR/homebrew/settings/$PLUGIN_NAME"
CFG="$CFG_DIR/settings.json"
mkdir -p "$CFG_DIR" 2>/dev/null
chown -R "${SUDO_USER:-deck}:${SUDO_USER:-deck}" "$CFG_DIR" 2>/dev/null || true
if python3 - "$CFG" "$TDP_AC" "$TDP_DC" <<'PYEOF'
import json, os, sys
path, tdp_ac, tdp_dc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    d = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
except Exception:
    d = {}
d.setdefault("advanced", {})["acPowerProfiles"] = True
d["enableTdpProfiles"] = False
d.setdefault("tdpProfiles", {})
tp = d["tdpProfiles"]
tp.setdefault("default", {}).setdefault("tdp", tdp_dc)
tp.setdefault("default-ac-power", {}).setdefault("tdp", tdp_ac)
json.dump(d, open(path, "w"), indent=2)
PYEOF
then
    chown "${SUDO_USER:-deck}:${SUDO_USER:-deck}" "$CFG" 2>/dev/null || true
    info "已预设: 插电=${TDP_AC}W / 离电=${TDP_DC}W (AC Profiles 已打开)"
else
    warn "写默认 TDP 配置失败(可能缺 python3), 需进插件手动设置"
fi

step "完成 —— 已预设插电 ${TDP_AC}W / 离电 ${TDP_DC}W"
cat <<EOF
  游戏模式里 QAM 侧边栏 → SimpleDeckyTDP, 应直接显示两套档位:
      · 插电 (AC)      ${TDP_AC}W
      · 离电 (Battery) ${TDP_DC}W
   插件会在插拔电源时自动切换。想改档位直接在里面拖滑块即可。

  验证切换: 拔掉电源, 看当前生效 TDP 是否变到 ${TDP_DC}W; 插回则回到 ${TDP_AC}W。
  建议再勾上:
     · "Set TDP on resume"  睡眠唤醒后重新应用(建议开)
     · "TDP Polling"        后台有程序偷偷改 TDP 时, 强制拉回设定值

  重装后用别的默认档: TDP_AC=55 TDP_DC=30 sudo bash $SCRIPT_NAME
EOF

echo
warn "如果插件里 TDP 拖不动或提示 ryzenadj 失败:"
cat <<'EOF'
  多半是内核没开 iomem=relaxed(ryzenadj 需要它访问 SMU)。
  先确认安全启动是关的:  sudo mokutil --sb-state   (这台机器已确认关闭)
  再给内核加参数:  iomem=relaxed
  SteamOS 用 systemd-boot, 改完需重建启动项; 不确定就先试插件,
  很多情况下 SimpleDeckyTDP 自带的实现不需要这个参数。
EOF

echo
warn "本机是外置电池设计: 电池拆下时 /sys/class/power_supply 只有 ACAD(无 BAT*)。"
cat <<'EOF'
 这是正常的(电池没接上), 不是驱动问题。装上外置电池后会出现 BAT* 设备。
 插件判断「插电/离电」用的是 ACAD/online(1=插电, 0=拔掉), 不依赖电池设备,
 所以拆不拆电池都能在两档间切换。建议拔插一次电源实测切换是否生效。
EOF
