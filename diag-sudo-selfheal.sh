#!/usr/bin/env bash
# ===========================================================================
#  diag-sudo-selfheal.sh —— 复查「升级后自动恢复」为什么需要密码
# ---------------------------------------------------------------------------
#  用途: 自愈服务(steamos-self-heal.service)要**免密**调主脚本才能无人值守恢复。
#        实测出现过"文件在、被 include、内容正确，但 sudo -n 仍要密码"的情况，
#        根因有几类，这个脚本一次性全查清（**只读，不改任何文件**）。
#
#  用法: sudo bash diag-sudo-selfheal.sh          # 需要 root 才能读 /etc/sudoers
#
#  它逐项回答:
#    ① 主 /etc/sudoers 到底 include 了 /etc/sudoers.d 没有（含"被注释掉"的情况）
#    ② sudoers.d 里哪些文件会被 sudo **忽略**（组/他人可写 = sudo 直接跳过）
#    ③ zz-steamos-self-heal 的内容，以及**规则里的路径是否还对得上当前备份包**
#       —— 备份包挪过位置(如从 ~/Downloads 到 /run/media/...)就会失配，这是最常见的坑
#    ④ 用 deck 的视角实测每条命令能不能免密（sudo -n -l <cmd>，只查询不执行）
#    ⑤ 给出结论与修法
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'; C_B=$'\033[1m'; C_D=$'\033[2m'
ok()   { echo "  ${C_G}[✓]${C_R} $*"; }
bad()  { echo "  ${C_RD}[✗]${C_R} $*"; }
warn() { echo "  ${C_Y}[!]${C_R} $*"; }
sub()  { echo "      $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "需要 root(要读 /etc/sudoers, 它是 0440):  sudo bash $0" >&2
    exit 2
fi

SUDOERS=/etc/sudoers
DIR=/etc/sudoers.d
DROPIN="$DIR/zz-steamos-self-heal"
LEGACY="$DIR/steamos-self-heal"

# ── 目标用户与备份包位置(从自愈目录的 main.conf 读, 取不到再兜底) ────────────
TARGET_USER="${SUDO_USER:-deck}"
SH_DIR=""
for d in /home/*/.local/opt/steamos-self-heal; do   # glob(无匹配时字面量, 用 -d 过滤)
    [ -d "$d" ] && { SH_DIR="$d"; break; }
done
MAIN=""
if [ -n "$SH_DIR" ] && [ -f "$SH_DIR/main.conf" ]; then
    # shellcheck disable=SC1090  # main.conf 由步骤[12]生成
    . "$SH_DIR/main.conf" 2>/dev/null || true
    MAIN="${MAIN:-}"
fi
[ -n "$MAIN" ] || MAIN="/home/$TARGET_USER/Downloads/steamos-reinstall-backup/steamos-setup.sh"
# 2026-09-25 起免密指向 /opt 下的 root 属主快照(offload → 扛升级; 用户改不动 → 无提权口子)
SNAP_DIR="/opt/steamos-backup"
SNAP_MAIN="$SNAP_DIR/steamos-setup.sh"
SNAP_DEV="$SNAP_DIR/fix-missing-dev-files.sh"

echo "${C_B}══ 1) 主 sudoers 是否 include sudoers.d ══${C_R}"
INC=""
if grep -qE "^[[:space:]]*@includedir[[:space:]]+$DIR" "$SUDOERS" 2>/dev/null; then
    INC="ok"; ok "@includedir $DIR  （生效）"
elif grep -qE "^[[:space:]]*#[[:space:]]*@includedir[[:space:]]+$DIR" "$SUDOERS" 2>/dev/null; then
    INC="commented"; bad "@includedir $DIR 被**注释掉**了 —— sudoers.d 里的东西全是摆设"
elif grep -qE "^[[:space:]]*#includedir[[:space:]]+$DIR" "$SUDOERS" 2>/dev/null; then
    INC="ok"; ok "#includedir $DIR  （旧的 # 语法，生效）"
elif grep -qE "^[[:space:]]*#[[:space:]]*#includedir[[:space:]]+$DIR" "$SUDOERS" 2>/dev/null; then
    INC="commented"; bad "#includedir $DIR 被注释掉了 —— 免密规则不会生效"
else
    INC="absent"; bad "$SUDOERS 里**找不到** include $DIR 的行（免密规则不会生效）"
fi

echo
echo "${C_B}══ 2) sudoers.d 文件与权限(sudo 会忽略组/他人可写的文件) ══${C_R}"
if [ -d "$DIR" ]; then
    find "$DIR" -maxdepth 1 -type f -printf '  %M %u:%g %10s  %f\n' 2>/dev/null | sort
    while IFS= read -r f; do
        m="$(stat -c '%a' "$f" 2>/dev/null)"
        case "$m" in
            *[2367]|*[2367][0-7]|*[0-7][2367]) bad "$(basename "$f") 权限 $m 太宽松 → sudo 会**跳过**它（应为 440）" ;;
        esac
    done < <(find "$DIR" -maxdepth 1 -type f 2>/dev/null)
    [ -e "$LEGACY" ] && warn "旧文件名 $LEGACY 还在（步骤[12] 会清掉它）"
else
    bad "$DIR 不存在"
fi

echo
echo "${C_B}══ 3) 免密规则内容(应指向 /opt 快照) ══${C_R}"
sub "main.conf 记的主脚本: $MAIN"
[ -f "$MAIN" ] && ok "主脚本存在" || bad "主脚本**不存在** —— 它被挪走/删了?"
if [ -f "$SNAP_MAIN" ]; then
    ok "快照在: $SNAP_MAIN ($(stat -c '%U:%G %s 字节, 改于 %y' "$SNAP_MAIN" 2>/dev/null | cut -d. -f1))"
    [ "$(stat -c '%U:%G' "$SNAP_MAIN" 2>/dev/null)" = "root:root" ] \
        && ok "快照属主 root:root(用户改不动 ✓)" \
        || bad "快照属主不是 root:root —— 提权口子还在"
    # 快照与仓库(或 main.conf 指的那份)是否同一版
    if [ -f "$MAIN" ] && ! cmp -s "$MAIN" "$SNAP_MAIN"; then
        warn "快照与 $MAIN **不是同一版** —— 仓库更新后要重跑步骤[12]刷新快照"
    fi
else
    bad "快照不存在: $SNAP_MAIN (/opt 是 offload, 本该扛升级; 说明步骤[12] 没跑成功)"
    sub "修法: sudo bash $MAIN 12"
fi
if [ -f "$DROPIN" ]; then
    ok "$DROPIN 存在，内容:"
    sed 's/^/        /' "$DROPIN"
    grep -qF "$SNAP_MAIN" "$DROPIN" \
        && ok "规则指向快照 ✓" \
        || { bad "规则**没指向快照** ← 这正是 sudo -n 要密码 / 提权口子的主因"; sub "修法: sudo bash $MAIN 12"; }
    grep -qF "$SNAP_DEV" "$DROPIN" \
        && ok "已放行开发文件补齐器" \
        || warn "未放行开发文件补齐器(升级后开发文件只能手动补)"
else
    bad "$DROPIN 不存在 —— 免密规则从没写成功过（或被升级冲掉了）"
    sub "修法: sudo bash $MAIN 12"
fi

echo
echo "${C_B}══ 4) 以 $TARGET_USER 的视角看免密规则(sudo -n -l) ══${C_R}"
#  ⚠️ 别用 `sudo -n -l <命令>` 逐条判: 本机有 Valve 的 `%wheel ALL=(ALL) ALL`,
#     于是**任何**命令都能"匹配上"并返回 0（只查单个命令时 sudo 还会原样回显该命令），
#     根本判不出 NOPASSWD。必须拉全量清单, 再按**命令行里的路径**去认那几行 NOPASSWD。
RUN=""
command -v runuser >/dev/null 2>&1 && RUN="runuser -u $TARGET_USER --"
[ -n "$RUN" ] || { command -v su >/dev/null 2>&1 && RUN="su - $TARGET_USER -c"; }
SH_SCRIPT=""
[ -n "$SH_DIR" ] && SH_SCRIPT="$SH_DIR/self-heal-after-upgrade.sh"
if [ -n "$RUN" ]; then
    LIST="$($RUN sudo -n -l 2>&1)"
    sub "免密查询结果:"
    printf '%s\n' "$LIST" | sed 's/^/        /' | head -25
    echo
    # ⚠️ sudo -l **会按终端宽度折行**: 输出到管道/文件时按 80 列, 命令与参数被拆到下一行。
    #    直接按整条命令行 grep 必然匹配不到, 会把"有规则"误报成"没有规则"(实测踩过)。
    #    → 先拉平所有空白, 再按路径匹配。
    FLAT="$(printf '%s' "$LIST" | tr -s '[:space:]' ' ')"
    sub "逐条核对(先拉平折行, 再按路径匹配 NOPASSWD 行):"
    # 2026-09-25 起: 免密只放行 /opt/steamos-backup(快照) 里的两个脚本 —— 它是 offload(扛升级)
    # 且 root 属主(用户改不动)。规则若仍指向备份包/自愈脚本(用户可写) = 提权口子, 要重写。
    for pair in "主脚本(快照)|$SNAP_MAIN|1" "开发文件补齐器(快照)|$SNAP_DEV|1" \
                "主脚本(备份包)|$MAIN|0" "自愈脚本(用户可写)|$SH_SCRIPT|0"; do
        desc="${pair%%|*}"; rest="${pair#*|}"; path="${rest%%|*}"; want="${rest##*|}"
        if [ -z "$path" ]; then
            warn "$desc: 路径未知, 跳过"
        elif printf '%s' "$FLAT" | grep -q "NOPASSWD: /usr/bin/bash $path\|NOPASSWD: $path"; then
            if [ "$want" = "1" ]; then ok "$desc 已放行免密"
            else bad "$desc **仍在**免密清单里(用户可写 → 提权口子): $path"; fi
        else
            if [ "$want" = "1" ]; then bad "$desc 没有免密规则: $path"
            else ok "$desc 不在清单里(正确)"; fi
        fi
    done
    if [ ! -f "$SNAP_MAIN" ]; then
        bad "快照不存在: $SNAP_MAIN —— 快照是免密链路的根, 缺它就没法无人值守"
        sub "建/刷新: sudo bash $MAIN 12"
    fi
    printf '%s' "$LIST" | grep -q '需要密码\|password is required' \
        && bad "连清单都查不到(需要密码) → 说明**没有任何** NOPASSWD 规则生效"
else
    warn "没有 runuser/su, 跳过实测"
fi

echo
echo "${C_B}══ 5) 结论 ══${C_R}"
if [ "$INC" = "ok" ] && [ -f "$DROPIN" ] && grep -qF "$MAIN" "$DROPIN" 2>/dev/null; then
    ok "免密链路看起来是通的：升级后可无人值守自动恢复（含开发文件）"
    sub "注: 清单里那条 (ALL) ALL 是 Valve 的 wheel 规则(要密码), 与我们无关;"
    sub "    判定只看带 NOPASSWD 且路径等于上面三条的那几行。"
else
    bad "免密链路**不通** → 自动恢复会在需要 root 时停下, 改为通知你手动跑:"
    sub "sudo bash $MAIN --after-upgrade"
    sub "跑完再执行下面这条把免密规则按当前路径重建(以后就能全自动):"
    sub "sudo bash $MAIN 12"
fi
echo
echo "${C_D}提示: 本脚本只读。自愈服务的日志在 \$HOME/.local/opt/steamos-self-heal/last-report.txt${C_R}"
