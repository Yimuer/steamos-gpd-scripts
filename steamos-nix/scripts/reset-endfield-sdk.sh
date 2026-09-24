#!/usr/bin/env bash
# ===========================================================================
#  reset-endfield-sdk.sh —— 清空《明日方舟:终末地》的 U8 SDK 本地状态, 让它重新生成
# ---------------------------------------------------------------------------
#  为什么要清(2026-09-09 定案, 已由实机验证):
#    终末地"同意协议后黑屏、无声音"的根因链条是:
#      u8sdkdata.cpp:88  ParseConfig fail
#        → U8SDK.cpp:521  SetGameVersion:INVALID_EXTRA_CONFIG1.5.3
#        → u8sdkimpl.cpp:1284  appCode is null, try use appid:-1
#        → Unity: FormatException @ Beyond.GameInitState._DoInit
#    即: SDK 解不出 appCode → 初始化协程被打断 → 进程活着但什么都没画。
#
#    根因不是"缺 U8Data/config/*.bin"(见下), 而是 SDK 本地状态目录
#    (sdkdata/、sdk_data_*/)里是**从备份恢复过来的空壳**: 文件在、内容全 0,
#    导致 ParseConfig 读得到文件却解不出内容。清空后由启动器重新下发即可。
#
#  ⚠️ 已证伪的旧假设(别再往这个方向查):
#    "缺失 U8Data/config/config.bin|.gryph|u8ExtraConfig.bin 导致 ParseConfig 失败"
#    —— 2026-09-09 22:42 成功进游戏后复查: 这三个文件**依然全盘零命中**,
#       而 SetGameVersion 已从 INVALID_EXTRA_CONFIG1.5.3 变成 prod_obt1.5.3。
#       说明 U8Data 缺失是常态而非病因, 当时的归因是错的。
#
#  这个脚本做的: 把 SDK 本地状态改名备份(不是直接删), 下次启动时由启动器重新生成。
#  **不碰**: 游戏安装目录、游戏本体、兼容层、prefix 其它内容、Steam 登录态。
#  存档在服务器侧(鹰角系游戏都是), 清这些缓存不会丢号。
#
#  用法:
#    bash reset-endfield-sdk.sh             # 直接执行(会做备份)
#    bash reset-endfield-sdk.sh --dry-run   # 只看会动什么, 不真改
#    bash reset-endfield-sdk.sh --force     # 跳过"SDK 已健康"的自动保护, 强制清
#
#  内置的自我保护(2026-09-09 加):
#    · SDK 已健康(SetGameVersion 是 prod_* 而非 INVALID_EXTRA_CONFIG*) → 拒绝执行。
#      修好后重复跑会把刚下发的正常配置清掉, 反而要重走一遍「修复客户端」。
#    · 跳过 *.bak-* 备份文件, 不会把上次备份再备份一次(原来会套娃成 .bak.bak)。
#
#  执行后: 打开鹰角启动器 → 先点「修复客户端」→ 再启动游戏。
#          若仍黑屏, 把新生成的 sdklogs/*.log 发出来继续定位。
#  成功的硬判据: sdklogs/u8sdk_pc.log 里出现 SetGameVersion:prod_<版本>
#                (带 prod_ 前缀 = 正常; 带 INVALID_EXTRA_CONFIG = 仍坏)。
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'; C_B=$'\033[1m'
info() { echo "${C_G}[✓]${C_R} $*"; }
warn() { echo "${C_Y}[!]${C_R} $*"; }
err()  { echo "${C_RD}[✗]${C_R} $*"; exit 1; }

DRY=0; FORCE=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --force)   FORCE=1 ;;
    esac
done
[ "$DRY" = 1 ]   && echo "${C_B}(--dry-run 演练模式, 不会真的改动)${C_R}"
[ "$FORCE" = 1 ] && echo "${C_Y}(--force 已开启: 跳过 SDK 健康检测)${C_R}"
{ [ "$DRY" = 1 ] || [ "$FORCE" = 1 ]; } && echo

# ---- 1. 定位 prefix(自动找含 Endfield 的 compatdata) ----
BASE="$HOME/.local/share/Steam/steamapps/compatdata"
PFX=""
for d in "$BASE"/*/; do
    [ -d "${d}pfx" ] || continue
    if [ -d "${d}pfx/drive_c/users/steamuser/AppData/LocalLow/Hypergryph/Endfield" ]; then
        PFX="${d}pfx"; APPID="$(basename "$d")"; break
    fi
done
[ -n "$PFX" ] || err "没找到终末地的 prefix (在 $BASE 下没找到 LocalLow/Hypergryph/Endfield)"

E="$PFX/drive_c/users/steamuser/AppData/LocalLow/Hypergryph/Endfield"
info "prefix: $PFX"
info "AppID : $APPID"
info "数据目录: $E"
echo

# ---- 2. 健康检测: SDK 已经好了就别动它 ----
# 判据: u8sdk_pc.log 里最后一条 SetGameVersion 的前缀
#   prod_obt1.5.3              → 正常, SDK 已成功初始化
#   INVALID_EXTRA_CONFIG1.5.3  → 坏的, 才需要清
LAST_VER="$(grep -ahoE 'SetGameVersion:[^[:space:]]*' "$E"/sdklogs/u8sdk_pc*.log 2>/dev/null | tail -1)"
LAST_VER="${LAST_VER#SetGameVersion:}"
case "$LAST_VER" in
    prod_*)
        if [ "$FORCE" = 1 ]; then
            warn "SDK 状态看起来是好的(SetGameVersion:$LAST_VER), 但 --force 已指定, 继续。"
        else
            info "SDK 已经是健康状态(SetGameVersion:$LAST_VER) —— 不需要清理。"
            echo
            echo "  现在清掉反而会把启动器刚下发的正常配置弄没, 又要重走一遍「修复客户端」。"
            echo "  若游戏其实还有问题, 那病因不在这里, 先跑:"
            echo "    bash $(cd "$(dirname "$0")" && pwd)/diag-black-screen.sh"
            echo
            echo "  确有把握要强制清, 加 --force。"
            exit 0
        fi
        ;;
    INVALID_EXTRA_CONFIG*)
        info "SDK 状态确认为损坏(SetGameVersion:$LAST_VER) —— 需要清理。"
        ;;
    "")
        warn "读不到 SetGameVersion(日志缺失或无此行), 无法自动判断健康度。"
        [ "$FORCE" != 1 ] && { echo "  若确定要清, 加 --force 重跑。"; exit 0; }
        ;;
    *)
        warn "未知的 SetGameVersion 前缀: $LAST_VER"
        [ "$FORCE" != 1 ] && { echo "  若确定要清, 加 --force 重跑。"; exit 0; }
        ;;
esac
echo

# ---- 3. 检查游戏是否还在跑 ----
# 注意: read 在非交互终端(比如被管道/定时任务调用)会永久挂起, 必须先判 -t 0
if pgrep -f "Endfield.exe" >/dev/null 2>&1; then
    if [ "$DRY" = 1 ]; then
        warn "检测到 Endfield.exe 正在运行 —— 正式执行前请先退出游戏和启动器。"
    elif [ ! -t 0 ]; then
        err "检测到 Endfield.exe 正在运行, 且当前不是交互式终端(无法询问)。请先退出游戏和启动器后重跑。"
    else
        warn "检测到 Endfield.exe 仍在运行 —— 请先完全退出游戏和启动器再执行本脚本。"
        read -r -t 30 -p "  现在强制结束它们? [y/N] " a
        case "${a:-N}" in
            y|Y) pkill -f "Endfield.exe"; pkill -f "Launcher.exe"; pkill -f "Games.exe"; sleep 2
                 info "已结束相关进程" ;;
            *)   echo "  已取消。请手动退出游戏后重跑。"; exit 1 ;;
        esac
    fi
fi

# ---- 4. 要清理的目标 ----
STAMP="$(date +%m%d-%H%M)"
TARGETS=()
for pat in sdkdata "sdk_data_"; do
    for p in "$E"/$pat*; do
        [ -e "$p" ] || continue
        # 跳过本脚本之前的备份, 否则重复跑会套娃成 .bak-xxx.bak-yyy
        case "$(basename "$p")" in *.bak-*) continue ;; esac
        TARGETS+=("$p")
    done
done
# 日志单独处理: 保留一份现场再清空, 便于对比
LOGS=()
for p in "$E"/Player.log "$E"/Player-prev.log "$E"/sdklogs/*.log; do
    [ -f "$p" ] || continue
    case "$(basename "$p")" in *.bak-*) continue ;; esac
    LOGS+=("$p")
done

if [ ${#TARGETS[@]} -eq 0 ] && [ ${#LOGS[@]} -eq 0 ]; then
    warn "没有找到可清理的 SDK 状态(目录已经是干净的) —— 说明问题不在本地缓存, 别重复跑本脚本。"
    exit 0
fi

echo "${C_B}=== 将要处理 ===${C_R}"
for p in "${TARGETS[@]}"; do echo "  [改名备份] $(basename "$p")  ($(du -sh "$p" 2>/dev/null | cut -f1))"; done
for p in "${LOGS[@]}";     do echo "  [改名备份] $(basename "$p")"; done
echo

if [ "$DRY" = 1 ]; then
    warn "演练结束, 未做任何改动。去掉 --dry-run 才会真正执行。"
    exit 0
fi

# ---- 4. 执行(全部改名, 不直接删) ----
for p in "${TARGETS[@]}" "${LOGS[@]}"; do
    b="${p}.bak-$STAMP"
    mv "$p" "$b" 2>/dev/null && info "已备份为 $(basename "$b")" || warn "改名失败(跳过): $p"
done

echo
info "清理完成。备份都带 .bak-$STAMP 后缀, 确认没问题后可自行删除。"
echo
echo "${C_B}接下来请这么做:${C_R}"
echo "  1) 打开鹰角启动器(不要直接双击 Endfield.exe)"
echo "  2) 先点游戏旁边的「修复客户端」/ 设置里的修复选项, 让它重新下发配置"
echo "  3) 再启动游戏"
echo
echo "  若仍黑屏: 把新生成的 $E/sdklogs/*.log 发出来。"
echo "  回滚: 把 .bak-$STAMP 改回原名即可。"
