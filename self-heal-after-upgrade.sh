#!/usr/bin/env bash
# ⚠️ 严格模式(2026-09-27 补齐): 本脚本是**无人值守**跑的(开机/定时器), 变量打错
#    名字不会有人看见 —— 未定义变量静默变空在这里后果最大。已与项目其余脚本统一。
set -uo pipefail
# =============================================================================
#  SteamOS 系统升级自愈钩子 (self-heal-after-upgrade.sh)  v4
# -----------------------------------------------------------------------------
#  触发: systemd user 服务调用。**桌面模式与游戏模式都会跑** —— 两者都会走到 user manager
#        的 default.target(Valve 自己的 gamemoded / dmemcg-booster-user 也是这条链),
#        外加 steamos-self-heal.timer 每 20 分钟重试一次(见步骤[12])。
#
#  职责:
#    1) 版本变更检测: 对比 /etc/os-release 的 VERSION_ID 与上次记录
#       (记录存 /home, 能扛原子更新)。版本变化 = 经历了一次 A/B 原子更新,
#       rootfs 被整块替换。
#    2) 落地物清点: 逐项检查本项目写入 /etc 的系统级修改是否幸存
#       (背键 unit/udev、inputplumber、NTP drop-in、WorkBuddy wrapper、
#        LocalSend 的 firewalld 放行 53317),
#       生成"被冲掉清单" → 报告落盘 + 桌面通知。
#    3) 开发文件清点: 原子升级同样会把 **/usr 的开发文件**(include/cmake/pkgconfig)
#       整块摘掉 —— 表现是"编译任何东西都报缺头文件"(见 SCRIPT-MAINTENANCE §12),
#       而平时完全无感。这里用一个便宜哨兵探一下, 缺了就让补齐器补回来。
#    4) 自动恢复: sudoers 幸存时直接跑主脚本 --after-upgrade
#       (主脚本落地复核: 完好的自动跳过, 只补被冲掉的, 含 pacman 包);
#       sudoers 也被冲掉时, 通知用户一条手动命令(需输一次密码)。
#
#  ⚠️ 游戏模式下的三个现实约束(v4 就是为它们设计的):
#    · 网络可能还没连上 → 要动 pacman 之前先等网络(wait_online, 最多 120 秒);
#      等不到就静默交给定时器, 不写失败标记。
#    · 没有通知守护(镜像里只有 plasmashell 提供 org.freedesktop.Notifications)
#      → notify-send 是哑的, 所以失败必须写一个看得见的标记文件 NEEDS-ATTENTION.txt。
#    · 服务是 oneshot, 一次失败就等下次开机 → 靠 steamos-self-heal.timer 每 20 分钟重试,
#      用户不用切回桌面模式就能被自动修好。
#
#  诚实说明: sudoers 在 /etc, 升级必被冲 → 大版本升级后的首次自动恢复
#  多半需要用户手动跑一次命令; 之后的局部损坏(无版本变化)可全自动修复。
#  免密为何失效可跑 `sudo bash diag-sudo-selfheal.sh` 一次查清。
#
#  本脚本 + main.conf + 版本戳都在 /home, 自身能扛系统升级。
#  主脚本路径固化在 main.conf(部署时由 steamos-setup.sh 步骤[12]写入)。
# =============================================================================

SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
STAMP="$SH_DIR/last-osversion"
REPORT="$SH_DIR/last-report.txt"
CONF="$SH_DIR/main.conf"

# --dry-run: 只体检、不修 —— 打印会做什么, 不执行任何 sudo, 不写版本戳/标记。
# 用途: 排障时先看清楚; 也是 doctor.sh 做只读体检的入口。
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# ── 主脚本定位: 优先用部署时固化的 main.conf, 再兜底探测常见位置 ──
MAIN=""
# shellcheck disable=SC1090  # main.conf 由部署时生成, 路径运行期才确定
[ -f "$CONF" ] && . "$CONF" 2>/dev/null
{ [ -z "${MAIN:-}" ] || [ ! -f "$MAIN" ]; } && MAIN="$SH_DIR/steamos-setup.sh"
[ -f "$MAIN" ] || MAIN="$HOME/Downloads/steamos-reinstall-backup/steamos-setup.sh"
if [ ! -f "$MAIN" ]; then
    echo "[自愈] 找不到 steamos-setup.sh(main.conf: $CONF), 无法自动恢复"
    echo "[自愈] 请把备份包放回原位或修改 $CONF 里的 MAIN 路径"
    exit 1
fi

# ── 开发文件补齐器(与主脚本同一个备份包) + 便宜哨兵 ──
#  为什么用哨兵: 原子升级会把 /usr 的 include/cmake/pkgconfig 整块摘掉, 而补齐器
#  全量体检要约 20 秒。开机路径上不能白花这 20 秒, 所以先探一个文件:
#    · 该文件在 → 开发文件基本没事, 跳过体检;
#    · 不在、但**包还在**(pacman -Qq qt6-base 成立) → 确定是被裁/被冲, 再让补齐器给准数。
#  （包不装 qt6 的机器不会误报 —— 那种情况哨兵本来就该缺席。）
DEV_TOOL="$(dirname "$MAIN")/fix-missing-dev-files.sh"
DEV_SENTINEL="/usr/lib/cmake/Qt6/Qt6Config.cmake"
DEV_MISSING=0
if [ -f "$DEV_TOOL" ] && [ ! -e "$DEV_SENTINEL" ] \
   && command -v pacman >/dev/null 2>&1 && pacman -Qq qt6-base >/dev/null 2>&1; then
    bash "$DEV_TOOL" --set kde >/dev/null 2>&1 || DEV_MISSING=1
fi

# ── 网络就绪等待(只在确实要干活时才等) ──
#  用户大多数时间在**游戏模式**: 那里用户 manager 很早就到 default.target, 而 Wi-Fi 常常
#  还没连上 —— 主脚本的 prepare 要 pacman -Sy/装包, 没网必失败。等一等再动手; 等不到就
#  交给 steamos-self-heal.timer 过 20 分钟再来, 不算失败(不写失败标记)。
WAIT_MAX="${SELF_HEAL_WAIT:-120}"
PROBE_URL="https://steamdeck-packages.steamos.cloud/"
wait_online() {
    command -v nm-online >/dev/null 2>&1 && nm-online -q -t 5 >/dev/null 2>&1 && return 0
    local waited=0
    while [ "$waited" -lt "$WAIT_MAX" ]; do
        # ICMP 常被禁 → 用 TCP/HTTP 探上游镜像(与主脚本 url_reachable() 同一思路)
        curl -sI --max-time 4 "$PROBE_URL" >/dev/null 2>&1 && return 0
        sleep 5; waited=$((waited + 5))
    done
    return 1
}
# 失败标记: 游戏模式下**没有通知守护**(镜像里只有 plasmashell 提供 org.freedesktop.Notifications),
# 所以 notify-send 在那里是哑的 —— 失败必须靠一个看得见的文件 + 定时器重试来兜底。
MARK="$SH_DIR/NEEDS-ATTENTION.txt"

# ── 1. 版本变更检测 ──
VER_NOW="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -1 | tr -d '"')"
VER_PREV="$(cat "$STAMP" 2>/dev/null)"
VERSION_CHANGED=0
if [ -n "$VER_NOW" ]; then
    if [ -z "$VER_PREV" ]; then
        printf '%s\n' "$VER_NOW" > "$STAMP"      # 首次部署: 只登记, 不触发
    elif [ "$VER_NOW" != "$VER_PREV" ]; then
        VERSION_CHANGED=1
    fi
fi

# ── 2. 落地物清点(每项: "描述|路径|判断方式|修复步骤编号") ──
declare -a CHECKS=(
    "背键守护单元|/etc/systemd/system/gpd-win5-backkeys.service|file|4"
    "背键 udev 规则|/etc/udev/rules.d/70-gpd-backkeys.rules|file|4"
    "inputplumber 覆盖配置|/etc/inputplumber/devices.d/20-gpd_win5.yaml|file|4"
    "inputplumber 能力表|/etc/inputplumber/capability_maps.d/20-gpd_win5.yaml|file|4"
    "Decky Loader 系统单元|/etc/systemd/system/plugin_loader.service|file|5"
    "境内 NTP|/etc/systemd/timesyncd.conf.d/ntp.conf|file|10"
    "WorkBuddy Wayland IME|/usr/bin/workbuddy|ime|3"
    # fwport 的 path 字段是 firewalld 配置**目录**(不是文件): 区域文件名不一定叫
    # public.xml, 故用 grep -r 递归找; 端口号写在下面的分支里。
    # 但仅有 grep 不够 —— 出厂范围规则(1024-65535)覆盖时字面量不会存在, 分支里还会
    # 补问 firewall-cmd。判据的完整说明见主脚本 fw_53317_ok()。
    "LocalSend 防火墙(53317)|/etc/firewalld|fwport|14"
    # 装在 /opt 的 AUR 包: /opt 是 offload(文件幸存), 但 pacman 台账与 /usr 入口会被冲
    # → 现象是"菜单里凭空消失"。2026-09-26 微信就这么没了, 且当时**没有任何提示**。
    # 这里只报告、不自动装(可选组件不在必装清单, 自愈不该替用户决定装不装; 步骤写 "-" 表示不自动修)。
    "微信(可选: 装回见 可选组件安装.sh 或 pacman -U 本地缓存包)|/opt/wechat-universal|orphanpkg|-|wechat-universal-bwrap"
)
MISSING=(); NEED_REPAIR=()
for entry in "${CHECKS[@]}"; do
    IFS='|' read -r desc path how step pkg <<< "$entry"
    missing=0
    case "$how" in
        file) [ -e "$path" ] || missing=1 ;;
        ime)  { [ -f "$path" ] && grep -q -- "--enable-wayland-ime" "$path" 2>/dev/null; } || missing=1 ;;
        fwport)
            # 放行规则在 /etc(原子升级必被冲) → 丢了就重跑步骤[14]补回。
            # 没装 firewalld 的机器不算缺失, 否则每次开机都白报一次。
            # ⚠️ 判据不能只看字面 '53317': SteamOS 出厂 public zone 已开 1024-65535,
            #    端口被范围覆盖时 firewalld 会拒写显式规则(ALREADY_ENABLED) → 字面量
            #    永远不存在, 于是每次开机都白报"LocalSend 防火墙缺失"(2026-09-25 实测)。
            #    与主脚本 fw_53317_ok() 是同一套判断 —— 改一处必须同步另一处。
            if command -v firewall-cmd >/dev/null 2>&1; then
                if ! grep -rqs '53317' "$path" 2>/dev/null; then
                    _fwp_ok=0
                    case "$(firewall-cmd --permanent --list-ports 2>/dev/null)" in
                        *1024-65535*) _fwp_ok=1 ;;
                    esac
                    # 兜底: 让 firewalld 自己判(--query-port 会认范围规则)
                    firewall-cmd --permanent --query-port=53317/tcp >/dev/null 2>&1 \
                        && firewall-cmd --permanent --query-port=53317/udp >/dev/null 2>&1 \
                        && _fwp_ok=1
                    [ "$_fwp_ok" -eq 1 ] || missing=1
                fi
            fi
            ;;
        orphanpkg)
            # 目录在(升级幸存) + pacman 台账没了 = 孤儿现场 → 报告。
            # 包名走第 5 字段, 判据保持通用(不把 wechat 写死在分支里)。
            if [ -n "${pkg:-}" ] && [ -e "$path" ] && ! pacman -Qq "$pkg" >/dev/null 2>&1; then
                missing=1
            fi
            ;;
    esac
    if [ "$missing" -eq 1 ]; then
        MISSING+=("$desc → $path")
        # 步骤写 "-" = 只报告不自动修(可选组件 / 需人工判断的项)
        [ "$step" = "-" ] || NEED_REPAIR+=("$step")
    fi
done

NOTHING_MISSING=0
[ "${#MISSING[@]}" -eq 0 ] && NOTHING_MISSING=1
if [ "$NOTHING_MISSING" -eq 1 ] && [ "$VERSION_CHANGED" -eq 0 ] && [ "$DEV_MISSING" -eq 0 ] && [ "$DRY" -eq 0 ]; then
    # 系统现在完好 → 此前失败留下的标记已过期, 顺手清掉。
    # (2026-09-26 实测: 早上失败写的 NEEDS-ATTENTION.txt 在系统修好后一直残留,
    #  doctor.sh 因此永远报红 —— 因为这条秒退路径绕过了收尾的 rm -f "$MARK"。
    #  注意 dry-run 永远进不了这里, 只读承诺不受影响。)
    rm -f "$MARK" 2>/dev/null
    exit 0    # 完好且无版本变化: 静默退出, 不刷日志(--dry-run 时永远出报告)
fi

# ── 3. 生成报告 ──
{
    echo "══ SteamOS 升级自愈报告  $(date '+%F %T') ══"
    if [ "$VERSION_CHANGED" -eq 1 ]; then
        echo "版本变化: ${VER_PREV:-未知} → $VER_NOW (原子更新已发生)"
    fi
    if [ "$NOTHING_MISSING" -eq 0 ]; then
        echo "本次检测到被冲掉的内容:"
        printf '  ✗ %s\n' "${MISSING[@]}"
        echo "(pacman 包等其余系统级内容由主脚本 --after-upgrade 的落地复核接管)"
    else
        echo "系统级落点完好; pacman 包等由主脚本落地复核接管"
    fi
    if [ "$DEV_MISSING" -eq 1 ]; then
        echo "开发文件(/usr 的 include/cmake/pkgconfig): 缺失"
        echo "  → 编译类需求会报「找不到头文件」, 由本脚本自动补齐(需免密 sudo)"
    fi
# --dry-run 只打到屏幕, 不落盘: doctor.sh 靠它做只读体检, 不能把报告写到目录里
# (2026-09-25 实测踩到: 报告落盘会在仓库根目录留下 last-report.txt 这种运行时垃圾)。
} | { if [ "$DRY" -eq 1 ]; then cat; else tee "$REPORT"; fi; }

notify() {
    command -v notify-send >/dev/null 2>&1 \
        && notify-send -u critical -a "SteamOS 自愈" "$1" "$2" 2>/dev/null
    return 0
}

rc=0
# ── 4. 有活要干 → 先等网络(游戏模式下开机瞬间常没网) ──
NEED_WORK=0
{ [ "$VERSION_CHANGED" -eq 1 ] || [ "${#NEED_REPAIR[@]}" -gt 0 ] || [ "$DEV_MISSING" -eq 1 ]; } && NEED_WORK=1
if [ "$NEED_WORK" -eq 1 ] && ! wait_online; then
    {
        echo "[自愈] 网络未就绪(等了 ${WAIT_MAX}s) → 本次不做需要 root 的动作"
        echo "[自愈] steamos-self-heal.timer 会在 20 分钟后再试(游戏模式下同样会跑)"
    } | tee -a "$REPORT"
    exit 0        # 不算失败: 没写标记, 也没推进版本戳, 下次重试仍会走同一条路
fi

if [ "$VERSION_CHANGED" -eq 1 ]; then
    # ── 4a. 版本变了 → 全量自动恢复(--after-upgrade: 只补被冲掉的) ──
    echo "[自愈] 检测到版本变更 → 尝试全量自动恢复(需免密 sudo)..."
    # shellcheck disable=SC2024  # 重定向发生在用户侧, 报告文件属主是 deck, 正合需求
    if [ "$DRY" -eq 1 ]; then
        echo "[dry-run] 会执行: sudo -n bash $MAIN --after-upgrade"
    elif sudo -n bash "$MAIN" --after-upgrade >>"$REPORT" 2>&1; then
        echo "[自愈] 全量恢复完成, 详情见 $REPORT"
        notify "SteamOS 升级自愈" "系统已更新到 $VER_NOW, 配置已自动恢复。详情: $REPORT"
    else
        echo "[自愈] 自动恢复未执行成功(多半是 sudoers 也被升级冲掉, 或备份包挪了位置)。"
        echo "[自愈] 请手动跑一次(需输密码):"
        echo "        sudo bash $MAIN --after-upgrade"
        echo "        再重建免密规则(以后就能全自动): sudo bash $MAIN 12"
        echo "        免密为何失效: sudo bash $(dirname "$MAIN")/diag-sudo-selfheal.sh"
        notify "SteamOS 升级自愈" "检测到升级到 $VER_NOW, 有配置被冲掉。请手动执行: sudo bash $MAIN --after-upgrade"
        rc=1
    fi
    [ "$DRY" -eq 0 ] && printf '%s\n' "$VER_NOW" > "$STAMP"
else
    # ── 4b. 无版本变化但有缺失(局部损坏) → 逐点重建 ──
    mapfile -t STEPS < <(printf '%s\n' "${NEED_REPAIR[@]}" | sort -u)
    if [ "${#STEPS[@]}" -gt 0 ]; then
        echo "[自愈] 检测到局部缺失, 需要重跑步骤: ${STEPS[*]}"
        for s in "${STEPS[@]}"; do
            if [ "$DRY" -eq 1 ]; then
                echo "[dry-run] 会执行: sudo -n bash $MAIN $s"
                continue
            fi
            echo "[自愈] 重建步骤 $s ..."
            # shellcheck disable=SC2024  # 同上
            if sudo -n bash "$MAIN" "$s" >>"$REPORT" 2>&1; then
                echo "[自愈] 步骤 $s 完成"
            else
                echo "[自愈] 步骤 $s 未执行(需免密 sudo, 见 steamos-setup.sh 12)"
                rc=1
            fi
        done
    fi
fi

# ── 5. 开发文件(两种情况都要管: 原子升级必摘, 局部删除也会缺) ──
#    只补 /usr 的三类开发文件, 不碰运行时、不带 locale/doc —— 见 fix-missing-dev-files.sh
if [ "$DEV_MISSING" -eq 1 ]; then
    echo "[自愈] 开发文件缺失(编译会报缺头文件/cmake) → 尝试补齐..."
    # shellcheck disable=SC2024  # 同上: 重定向在用户侧
    if [ "$DRY" -eq 1 ]; then
        echo "[dry-run] 会执行: sudo -n bash $DEV_TOOL --apply --set kde"
    elif sudo -n bash "$DEV_TOOL" --apply --set kde >>"$REPORT" 2>&1; then
        echo "[自愈] 开发文件已补齐"
    else
        echo "[自愈] 开发文件未补齐 —— 手动跑: sudo bash $DEV_TOOL --apply"
        echo "        (若提示需要密码, 先 sudo bash $MAIN 12 重建免密规则)"
        notify "SteamOS 自愈" "开发文件缺失(编译会报缺头文件)。请执行: sudo bash $DEV_TOOL --apply"
        rc=1
    fi
fi

# ── 5b. 便携化应用的系统依赖(如 Tauri 的 webkit2gtk) ──
#    应用本体在 /home(幸存), 但依赖装在 /usr(被冲) → 这里补回。
#    走**专用的 root 属主脚本**(包名写死, 不是放行 pacman) —— 见 fix-opt-deps.sh 头部。
#    只在"确实装过便携化应用"时才动手(脚本自己会判), 没装就秒退。
DEPS_TOOL="$(dirname "$MAIN")/fix-opt-deps.sh"
if [ -f "$DEPS_TOOL" ]; then
    echo "[自愈] 检查便携化应用的系统依赖(webkit 等, 在 /usr 会被冲)..."
    # shellcheck disable=SC2024  # 同上: 重定向发生在用户侧(sudo 管不到), 这是有意的
    if [ "$DRY" -eq 1 ]; then
        echo "[dry-run] 会执行: sudo -n bash $DEPS_TOOL"
    elif sudo -n bash "$DEPS_TOOL" >>"$REPORT" 2>&1; then
        echo "[自愈] 便携化应用依赖齐全"
    else
        echo "[自愈] 依赖未补齐 —— 应用可能打不开。手动: sudo bash $DEPS_TOOL"
        echo "        (若提示需要密码, 先 sudo bash $MAIN 12 重建免密规则)"
        notify "SteamOS 自愈" "便携化应用的系统依赖缺失(应用可能打不开)。请执行: sudo bash $DEPS_TOOL"
        rc=1
    fi
fi

# ── 6. 收尾: 失败就留下"看得见"的标记 ──
#  游戏模式(本机大多数时间)里**没有通知守护** —— 镜像里只有 plasmashell 提供
#  org.freedesktop.Notifications, 所以那里的 notify-send 是哑的。失败信息必须靠
#  ① 标记文件 ② journal ③ 定时器持续重试, 三者兜底; 等用户切回桌面模式时
#  notify-send 才会真正弹出来。
if [ "$DRY" -eq 1 ]; then
    echo "[dry-run] 结束: 未做任何修改(无 sudo 调用、未写报告/标记/版本戳)。"
    exit 0
fi
if [ "$rc" -ne 0 ]; then
    {
        echo "══ $(date '+%F %T') 自动恢复没做完, 需要你手动跑一次 ══"
        echo "多半原因: /etc/sudoers.d/zz-steamos-self-heal 被原子升级冲掉了(或备份包挪了位置)"
        echo
        echo "修复(任意终端, 会要一次密码):"
        echo "  sudo bash $MAIN --after-upgrade     # 先补齐被冲掉的系统级配置"
        echo "  sudo bash $MAIN 12                  # 再按当前路径重建免密 → 以后恢复全自动"
        echo
        echo "报告:     $REPORT"
        echo "免密体检: sudo bash $(dirname "$MAIN")/diag-sudo-selfheal.sh"
    } > "$MARK"
    echo "[自愈] 已写标记文件: $MARK"
else
    rm -f "$MARK" 2>/dev/null
fi
exit $rc
