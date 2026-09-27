#!/usr/bin/env bash
# ===========================================================================
#  doctor.sh —— 一屏体检：这台机器现在"健康"吗？
# ---------------------------------------------------------------------------
#  为什么要有它: 本项目的知识散在很多脚本里(主脚本 --status、自愈脚本、开发文件
#  补齐器、免密链路、上游体检)。出问题时人不记得该跑哪几个。这里把它们**串成一条**,
#  只做只读检查, 最后给一行结论 + 下一步该跑什么。
#
#  用法:
#    bash doctor.sh            # 默认: 只读体检(不需要 root, 不联网)
#    bash doctor.sh --net      # 额外跑上游依赖体检(需要联网, 约 30 秒)
#
#  退出码: 0 = 全绿; 1 = 有待处理项(具体见输出里的 ✗ / !)
#  特性: 只读 —— 不写任何文件、不调 sudo 执行任何命令(免密只做"查询")。
# ===========================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
cd "$HERE" || exit 1

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'; C_B=$'\033[1m'; C_D=$'\033[2m'
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_R" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_R" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$C_RD" "$C_R" "$*"; }
sub()  { printf '      %s%s%s\n' "$C_D" "$*" "$C_R"; }
head_() { printf '\n%s── %s ──%s\n' "$C_B" "$*" "$C_R"; }

PROBLEMS=0
NET=0
[ "${1:-}" = "--net" ] && NET=1
SNAP="/opt/steamos-backup"        # 免密快照: /opt 是 offload(扛升级) + root 属主(用户改不动)

printf '%s══ 体检报告  %s ══%s\n' "$C_B" "$(date '+%F %T')" "$C_R"

# ── 1. 系统与空间 ───────────────────────────────────────────────────────
head_ "系统与空间"
os_pretty="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"')"
dmi="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo '未知机型')"
sub "$os_pretty  ·  $dmi"
avail_kb="$(df -Pk / | awk 'NR==2{print $4}')"
avail_mb=$(( ${avail_kb:-0} / 1024 ))
if [ "$avail_mb" -ge 600 ]; then ok "rootfs 可用 ${avail_mb}MB"
elif [ "$avail_mb" -ge 300 ]; then warn "rootfs 可用 ${avail_mb}MB —— 偏低, 需要装东西前先跑 free-rootfs.sh --apply"; PROBLEMS=$((PROBLEMS+1))
else bad "rootfs 可用 ${avail_mb}MB —— 告急, 先跑 sudo bash free-rootfs.sh --apply"; PROBLEMS=$((PROBLEMS+1)); fi
home_avail="$(df -Ph /home | awk 'NR==2{print $4}')"
ok "/home 可用 $home_avail"

# ── 2. 必装步骤与系统配置(直接复用主脚本的只读 --status) ──────────────────
head_ "必装组件与系统配置(steamos-setup.sh --status)"
if [ -f steamos-setup.sh ]; then
    st="$(bash steamos-setup.sh --status 2>&1)"
    n_ok=$(printf '%s\n' "$st"  | grep -c '\[✓\]')
    n_warn=$(printf '%s\n' "$st" | grep -c '\[!\]')
    n_bad=$(printf '%s\n' "$st"  | grep -c '\[✗\]')
    [ "$n_bad" -eq 0 ] && ok "关键项: $n_ok ✓ / $n_warn ! / 0 ✗" \
                       || { bad "关键项: $n_ok ✓ / $n_warn ! / $n_bad ✗"; PROBLEMS=$((PROBLEMS+n_bad)); }
    #  ! 是主脚本给的"提示"(很多是'按需手动'或'未安装但你不需要'), 只展示、不计入待处理 ——
    #     否则 doctor 会天天报一个假的"1 项待处理"(同 2026-09-25 那类假红灯)。
    if [ "$n_warn" -gt 0 ]; then
        printf '%s\n' "$st" | grep '\[!\]' | sed "s/^/      ${C_D}/;s/$/${C_R}/"
        sub "(以上为主脚本提示项: 多为'按需手动'或'你不需要该组件', 不阻断)"
    fi
else
    bad "缺 steamos-setup.sh(不是完整的备份包?)"; PROBLEMS=$((PROBLEMS+1))
fi

# ── 3. 升级后自愈链(自愈脚本的只读预演) ──────────────────────────────────
head_ "升级后自愈链(服务 / 定时器 / 落点)"
if [ -f self-heal-after-upgrade.sh ]; then
    sh="$(bash self-heal-after-upgrade.sh --dry-run 2>&1)"
    if printf '%s\n' "$sh" | grep -q '系统级落点完好'; then
        ok "系统级落点(/etc 里的背键/NTP/防火墙等)完好"
    else
        bad "有系统级落点被冲掉:"; printf '%s\n' "$sh" | grep '✗' | sed 's/^/      /'
        PROBLEMS=$((PROBLEMS+1))
    fi
    printf '%s\n' "$sh" | grep -q '开发文件.*缺失' \
        && { warn "开发文件缺失(编译会报缺头文件) → sudo bash fix-missing-dev-files.sh --apply"; PROBLEMS=$((PROBLEMS+1)); } \
        || ok "开发文件齐全"
    printf '%s\n' "$sh" | grep -q '版本变化' && warn "检测到系统版本刚变过(原子升级)" || true
else
    bad "缺 self-heal-after-upgrade.sh"; PROBLEMS=$((PROBLEMS+1))
fi
svc_state="$(systemctl --user is-enabled steamos-self-heal.service 2>/dev/null || echo '未启用')"
tmr_state="$(systemctl --user is-active  steamos-self-heal.timer   2>/dev/null || echo '未运行')"
[ "$svc_state" = enabled ] && ok "自愈服务: 开机启用" || { bad "自愈服务: $svc_state → sudo bash steamos-setup.sh 12"; PROBLEMS=$((PROBLEMS+1)); }
if [ "$tmr_state" = active ]; then
    next="$(systemctl --user list-timers steamos-self-heal.timer --no-legend 2>/dev/null | awk '{print $1" "$2" "$3}')"
    ok "重试定时器: 运行中(下次 ${next:-未知})"
else
    warn "重试定时器: $tmr_state(下次开机仍会拉起; 想立刻起: systemctl --user start steamos-self-heal.timer)"
fi
[ -e "$HOME/.local/opt/steamos-self-heal/NEEDS-ATTENTION.txt" ] && { bad "自愈报了'需要人工处理'(见该文件)"; PROBLEMS=$((PROBLEMS+1)); }

# ── 4. 开发文件(编译前置) ───────────────────────────────────────────────
head_ "开发文件(/usr 的 include/cmake/pkgconfig)"
if [ -f fix-missing-dev-files.sh ]; then
    if dev_out="$(bash fix-missing-dev-files.sh --set kde 2>&1)"; then
        ok "kde/qt6 集合齐全(编译类任务可直接跑)"
    else
        warn "$(printf '%s\n' "$dev_out" | grep -E '共 .* 个包' | tail -1)"
        sub "修: sudo bash fix-missing-dev-files.sh --apply"
        PROBLEMS=$((PROBLEMS+1))
    fi
else
    warn "缺 fix-missing-dev-files.sh"
fi

# ── 5. 免密链路(自动恢复能不能无人值守) ──────────────────────────────────
#  ⚠️ sudo -l 会**按终端宽度折行**: 输出到管道/文件时按 80 列, 命令与参数会被拆到下一行。
#     直接 grep 整条命令行必然匹配不到 → 明明有规则也会报"缺失"(2026-09-25 实测踩到,
#     典型假红灯)。所以先拉平空白, 再用 case 精确匹配。
head_ "免密链路(自愈能否无人值守)"
if sudo_list="$(sudo -n -l 2>&1)"; then
    flat="$(printf '%s' "$sudo_list" | tr -s '[:space:]' ' ')"
    miss=0
    # 第三条(2026-09-27): 便携化应用的依赖补回器 —— 升级后自动补 webkit 等。
    #   它同样必须是 root 属主快照里的脚本(包名写死在脚本内, 不是放行 pacman)。
    MISS_DEPS_ONLY=1
    for p in "/usr/bin/bash $SNAP/steamos-setup.sh" "/usr/bin/bash $SNAP/fix-missing-dev-files.sh" \
             "/usr/bin/bash $SNAP/fix-opt-deps.sh"; do
        case "$flat" in
            *"NOPASSWD: $p"*) ;;
            *) bad "没有免密规则: $p"
               miss=1
               case "$p" in *fix-opt-deps.sh) ;; *) MISS_DEPS_ONLY=0 ;; esac ;;
        esac
    done
    # 反向判据: 规则里**不该**再出现用户可写的脚本(那是提权口子, 2026-09-25 改成快照后清除)
    case "$flat" in
        *"NOPASSWD: $HOME/.local/opt/steamos-self-heal/self-heal-after-upgrade.sh"*|*"NOPASSWD: /usr/bin/bash $HERE/steamos-setup.sh"*)
            bad "免密规则里还有用户可写的脚本 → 任何能以 deck 执行代码的东西都能提权"
            sub "修: sudo bash $HERE/steamos-setup.sh 12"
            miss=1 ;;
    esac
    [ "$miss" -eq 0 ] && ok "免密只放行 root 属主快照(无提权口子)"
    if [ "$miss" -eq 1 ]; then
        PROBLEMS=$((PROBLEMS+1))
        # 只有"补依赖"这条缺失时, 影响面是不同的: 应用本体在 /home 仍幸存,
        # 只是 /usr 里的库不会自动补回 —— 别把它说成"整条自愈链卡死"。
        if [ "${MISS_DEPS_ONLY:-0}" -eq 1 ]; then
            sub "仅『补依赖』这条缺失: 便携化应用本体仍在 /home, 但 /usr 里的库"
            sub "不会自动补回 —— 应用可能打不开。跑一次步骤[12] 即可补齐这条规则。"
        fi
        # 2026-09-26 现场: 免密一丢, 自愈链就陷入**死循环** —— 它恢复系统要靠免密,
        # 而恢复免密本身要跑步骤[12]、步骤[12] 要 root。必须把"这是自举问题"讲清楚,
        # 否则用户会以为"升级后全自动", 一直在等一个永远不会发生的自动恢复。
        if [ "${MISS_DEPS_ONLY:-0}" -ne 1 ]; then
            sub "⚠️ 自愈链会因此**卡死**(免密→步骤[12]→要 root, 死循环), 每 20 分钟失败一次"
        fi
        # 推荐跑**仓库那份**(若本脚本不在快照里): 反正这次要人工输密码、无提权口子,
        # 而仓库那份的步骤[12] 会顺手把过期快照同步成最新 —— 一举两得。
        # 且步骤[12] 不装包、不刷仓库, **不受 pacman 锁影响**(补齐器持锁也能跑)。
        REC="$SNAP"
        [ "$HERE" != "$SNAP" ] && REC="$HERE"
        sub "升级后第一条命令就是它(唯一必须人工输密码的一步):"
        sub "    sudo bash $REC/steamos-setup.sh 12"
        [ "$REC" = "$SNAP" ] && sub "(注意: 这份是快照, 可能落后于仓库; 若另有仓库副本请优先用仓库那份)"
        sub "(步骤[12] 不装包、不刷仓库 —— 补齐器正持锁下载时也能跑)"
    fi
else
    warn "查不到 sudo 规则(/etc/sudoers.d 可能被升级冲掉了)"
    sub "⚠️ 自愈链因此**卡死**(恢复免密要跑步骤[12], 而它要 root)"
    REC2="$SNAP"
    [ "$HERE" != "$SNAP" ] && REC2="$HERE"
    sub "修: sudo bash $REC2/steamos-setup.sh 12   ← 唯一必须人工输密码的一步"
    sub "(步骤[12] 不装包、不刷仓库 —— 补齐器正持锁下载时也能跑)"
    PROBLEMS=$((PROBLEMS+1))
fi

# 快照体检: 在不在 / 属主对不对 / 与仓库是否一致(不一致不是错, 只提示刷新)
if [ -f "$SNAP/steamos-setup.sh" ]; then
    own="$(stat -c '%U:%G' "$SNAP/steamos-setup.sh" 2>/dev/null)"
    [ "$own" = "root:root" ] && ok "快照属主正确($own, 用户改不动)" \
                             || { bad "快照属主是 $own —— 必须 root:root, 否则等于没做"; PROBLEMS=$((PROBLEMS+1)); }
    if [ -f "$HERE/steamos-setup.sh" ]; then
        a="$(sha256sum "$HERE/steamos-setup.sh" 2>/dev/null | cut -d' ' -f1)"
        b="$(sha256sum "$SNAP/steamos-setup.sh" 2>/dev/null | cut -d' ' -f1)"
        if [ "$a" = "$b" ]; then ok "快照与仓库一致(自动恢复跑的就是当前版本)"
        else warn "快照与仓库**不一致**: 仓库改了但快照没刷新"; sub "刷新: sudo bash $HERE/steamos-setup.sh 12"; fi
    fi
else
    warn "快照不在 $SNAP(升级冲掉? 或步骤[12] 从没跑成功)"; sub "建/刷新: sudo bash $HERE/steamos-setup.sh 12"
    PROBLEMS=$((PROBLEMS+1))
fi

# ── 6. 上游依赖(可选, 需联网) ───────────────────────────────────────────
if [ "$NET" -eq 1 ]; then
    head_ "上游依赖(联网体检)"
    if net_out="$(bash verify-upstreams.sh --quick 2>&1)"; then
        cnt="$(printf '%s\n' "$net_out" | grep -c '✓')"
        ok "上游地址全部可达(通过 $cnt 项)"
    else
        bad "有上游不可达:"
        printf '%s\n' "$net_out" | grep -E '✗' | sed 's/^/      /'
        PROBLEMS=$((PROBLEMS+1))
    fi
else
    head_ "上游依赖"
    sub "跳过(加 --net 可跑联网体检: bash doctor.sh --net)"
fi

# ── 结论 ────────────────────────────────────────────────────────────────
printf '\n%s══ 结论 ══%s\n' "$C_B" "$C_R"
if [ "$PROBLEMS" -eq 0 ]; then
    ok "全绿。升级后自愈会在开机时自动跑; 你平时不需要做任何事。"
    exit 0
fi
bad "有 $PROBLEMS 项待处理(见上面 ✗ / ! 行)。常见修法:"
sub "配置/落点被冲:   sudo bash steamos-setup.sh --after-upgrade"
sub "免密失效:         sudo bash steamos-setup.sh 12"
sub "开发文件缺失:     sudo bash fix-missing-dev-files.sh --apply"
sub "rootfs 紧张:      sudo bash free-rootfs.sh --apply"
sub "免密为何失效:     sudo bash diag-sudo-selfheal.sh"
exit 1
