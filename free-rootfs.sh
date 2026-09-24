#!/usr/bin/env bash
# ===========================================================================
#  free-rootfs.sh —— 抢救 SteamOS rootfs(5G) 空间不足
# ---------------------------------------------------------------------------
#  背景(实测结论, 别走弯路):
#    · rootfs 是 /dev/nvme0n1p5, 只有 5.0G, 官方镜像本身就吃掉 ~4.2G。
#    · /var/cache/pacman、/var/log、coredump、docker、flatpak 全都已 offload
#      到 p8(918G, 大量空闲) → 清 pacman 缓存/日志对 rootfs 一点用都没有!
#    · workbuddy 的 776M 全在 /opt(也 offload 到 p8) → 删它也不释放 rootfs。
#    · 真正吃 rootfs 的是 pacman 装进 /usr 的包。
#
#  因此本脚本只做这些真正有效的事(按性价比排序):
#    0) **迁移 dsh 到 /home** (281M)  ← 2026-09-09 新发现, 单点收益最大, 零功能损失
#       dsh 是 npm 全局装进 /usr/lib/node_modules 的(主脚本步骤[7]), 没有任何
#       pacman 包拥有它。搬到 ~/.local/lib/node_modules 后重建 /usr/bin/dsh 软链即可,
#       命令照常能用。rootfs 只留一个几字节的软链。
#    1) btrfs 元数据超配回收 (分配 517M / 实占 183M → 可回收 ~334M)  ← 零风险
#    2) 删除无依赖的包 (gcc 182M / 孤儿包)
#    3) 可选: 删除 firefox(290M)、opencv+spectacle(110M)
#    4) 可选(--aggressive): 精简 locale(294M→约 40M)、删壁纸(86M)
#    5) 可选(高级): zstd 重压缩 /usr, 可再省数百 MB~1G(需 ≥500M 余量)
#
#  用法:
#    bash free-rootfs.sh                    # 只体检, 不动任何东西(默认 dry-run)
#    sudo bash free-rootfs.sh --apply       # 执行安全项(0+1+2)
#    sudo bash free-rootfs.sh --apply --with-firefox
#    sudo bash free-rootfs.sh --apply --aggressive        # 含 locale/壁纸精简
#    sudo bash free-rootfs.sh --apply --aggressive --compress
#
#  注意: 需要 steamos-readonly disable(脚本会自动处理)。
#  ⚠️ 可用空间 <500M 时 --compress 会自动跳过, 先跑一遍 --apply 再来。
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'; C_B=$'\033[1m'
info() { echo "${C_G}[✓]${C_R} $*"; }
warn() { echo "${C_Y}[!]${C_R} $*"; }
err()  { echo "${C_RD}[✗]${C_R} $*" >&2; }
head_() { echo; echo "${C_B}── $* ──${C_R}"; }

APPLY=0; WITH_FF=0; WITH_CV=0; DO_COMPRESS=0; AGGRESSIVE=0
for a in "$@"; do
    case "$a" in
        --apply)     APPLY=1 ;;
        --with-firefox) WITH_FF=1 ;;
        --with-opencv)  WITH_CV=1 ;;
        --aggressive)   AGGRESSIVE=1; WITH_FF=1 ;;
        --compress)     DO_COMPRESS=1 ;;
        -h|--help)   sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $a"; exit 1 ;;
    esac
done

# 真实用户家目录(sudo 下 $HOME 是 /root, 必须自己解析)
REAL_USER="${SUDO_USER:-deck}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$REAL_HOME" ] || REAL_HOME="/home/$REAL_USER"
[ -d "$REAL_HOME" ] || REAL_HOME="/home/deck"

# ---------------------------------------------------------------- 环境检查
head_ "环境检查"
[ "$(id -u)" -eq 0 ] || { err "请用 sudo 运行"; exit 1; }
command -v btrfs >/dev/null || { err "缺少 btrfs 工具"; exit 1; }
ROOT_DEV="$(findmnt -no SOURCE / 2>/dev/null)"
ROOT_FSTYPE="$(findmnt -no FSTYPE / 2>/dev/null)"
echo "  rootfs 设备: $ROOT_DEV  文件系统: $ROOT_FSTYPE"
[ "$ROOT_FSTYPE" = "btrfs" ] || { err "rootfs 不是 btrfs, 本脚本的平衡/压缩步骤不适用"; exit 1; }

free_mb() { df -m / | awk 'NR==2{print $4}'; }
BEFORE="$(free_mb)"
echo "  当前 rootfs 可用: ${BEFORE} MB"
[ "$BEFORE" -lt 1024 ] && warn "低于 1GB, 建议立即处理" || info "空间尚可"

btrfs_usage_line() { btrfs filesystem usage / 2>/dev/null | grep -E "Metadata,DUP|Data,single"; }

# dsh 的探测逻辑单独抽出来, 体检和执行两处都要用
DSH_SRC="/usr/lib/node_modules/@deepseek-ai"
DSH_DST="$REAL_HOME/.local/lib/node_modules/@deepseek-ai"
dsh_size_mb() { [ -d "$DSH_SRC" ] && du -sm "$DSH_SRC" 2>/dev/null | cut -f1 || echo 0; }
DSH_MB="$(dsh_size_mb)"

show_plan() {
    head_ "将要执行的操作"
    if [ "$DSH_MB" -gt 0 ]; then
        info "⓪ 迁移 dsh 到 /home (${DSH_MB} MB) —— npm 全局包, 无 pacman 归属, 搬走后软链调用, 零功能损失"
    else
        info "⓪ dsh 迁移: 未发现 @deepseek-ai, 跳过"
    fi
    info "① btrfs 元数据平衡 (musage 30/60/90) —— 回收超配的元数据, 零数据风险"
    info "② 删除孤儿包: $(pacman -Qtdq 2>/dev/null | tr '\n' ' ')"
    if pacman -Qi gcc >/dev/null 2>&1; then
        info "③ 删除 gcc (212M, 无任何包依赖它)"
    fi
    [ "$WITH_FF" -eq 1 ] && warn "④ 删除 firefox (290M) —— 你确认不用自带浏览器"
    [ "$WITH_CV" -eq 1 ] && warn "⑤ 删除 opencv + spectacle (110M) —— 会失去 KDE 截图工具"
    if [ "$AGGRESSIVE" -eq 1 ]; then
        warn "⑥ 精简 /usr/share/locale (294M → ~40M, 只保留 zh_CN/en/C)"
        warn "⑦ 删除 /usr/share/wallpapers (86M)"
    fi
    [ "$DO_COMPRESS" -eq 1 ] && warn "⑧ zstd 重压缩 /usr —— ⚠ 本机实测已启用压缩, 大概率会被自动跳过"
}

head_ "当前 btrfs 块组占用"
btrfs_usage_line | sed 's/^/  /'

if [ "$APPLY" -eq 0 ]; then
    show_plan
    head_ "这是体检模式(未做任何修改)"
    echo "  确认无误后加 --apply 执行: sudo bash $0 --apply"
    exit 0
fi

show_plan
echo
if [ ! -t 0 ]; then
    warn "非交互终端, 自动确认继续"
else
    read -r -t 30 -p "以上操作是否继续? [y/N] " ans || ans="n"
    case "$ans" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0;; esac
fi

# ---------------------------------------------------------- 解除只读
head_ "解除 rootfs 只读"
if command -v steamos-readonly >/dev/null; then
    steamos-readonly disable 2>/dev/null && info "已 disable" || warn "disable 未成功(可能已是 disabled)"
fi

# ---------------------------------------------------------- ⓪ 迁移 dsh
head_ "⓪ 迁移 dsh 到 /home"
if [ "$DSH_MB" -eq 0 ]; then
    info "未发现 $DSH_SRC, 跳过"
else
    echo "  源: $DSH_SRC (${DSH_MB} MB)"
    echo "  目标: $DSH_DST"
    # 安全网: 先确认没有 pacman 包拥有它(万一将来被打包进系统, 别误搬)
    OWNER="$(pacman -Qo "$DSH_SRC" 2>/dev/null)"
    if [ -n "$OWNER" ]; then
        warn "该路径已被 pacman 包拥有: $OWNER —— 为安全起见跳过迁移"
    elif [ -e "$DSH_DST" ]; then
        warn "目标已存在 $DSH_DST —— 跳过(避免覆盖)"
    else
        # 记录原软链目标, 失败时可还原
        OLD_LINK="$(readlink /usr/bin/dsh 2>/dev/null)"
        mkdir -p "$(dirname "$DSH_DST")" 2>/dev/null
        if mv "$DSH_SRC" "$DSH_DST" 2>/dev/null; then
            chown -R "$REAL_USER":"$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")" \
                "$REAL_HOME/.local/lib/node_modules" 2>/dev/null
            # 原软链是相对路径(../lib/node_modules/...), 必须重建为绝对路径
            if ln -sfn "$DSH_DST/dsh/lib/bin.js" /usr/bin/dsh 2>/dev/null; then
                info "已迁移并重建 /usr/bin/dsh → $DSH_DST/dsh/lib/bin.js"
                info "释放约 ${DSH_MB} MB"
                # 额外在 ~/.local/bin/dsh 放一份(幂等)。
                #   /usr/bin/dsh 不属任何 pacman 包, SteamOS 原子升级整块换 rootfs 后会被抹掉;
                #   而 ~/.local/bin 在 /home 存活, 且 ~/.bashrc 已 source ~/.local/bin/env
                #   把它 prepend 进 PATH → 升级后 dsh 命令照样能用。
                mkdir -p "$REAL_HOME/.local/bin" 2>/dev/null
                if ln -sfn "$DSH_DST/dsh/lib/bin.js" "$REAL_HOME/.local/bin/dsh" 2>/dev/null; then
                    chown -h "$REAL_USER" "$REAL_HOME/.local/bin/dsh" 2>/dev/null
                    info "另置 ~/.local/bin/dsh (在 /home, 升级后仍可用)"
                fi
            else
                warn "迁移成功但软链重建失败, 正在回滚..."
                mv "$DSH_DST" "$DSH_SRC" 2>/dev/null
                [ -n "$OLD_LINK" ] && ln -sfn "$OLD_LINK" /usr/bin/dsh 2>/dev/null
                warn "已回滚, dsh 保持原样"
            fi
        else
            warn "迁移失败(权限或跨设备?), 跳过"
        fi
    fi
    echo "  现在可用: $(free_mb) MB"
fi

# ---------------------------------------------------------- ① 元数据平衡
head_ "① btrfs 元数据平衡"
for u in 30 60 90; do
    echo -n "  balance -musage=$u ... "
    if btrfs balance start -musage="$u" / >/dev/null 2>&1; then
        echo "完成 (现可用 $(free_mb) MB)"
    else
        echo "跳过或失败(空间不足时正常, 继续)"
    fi
done
btrfs_usage_line | sed 's/^/  /'
info "平衡后可用: $(free_mb) MB  (之前 ${BEFORE} MB)"

# ---------------------------------------------------------- ② 孤儿包
head_ "② 清理孤儿包"
ORPH="$(pacman -Qtdq 2>/dev/null)"
if [ -n "$ORPH" ]; then
    echo "  将删除: $(echo "$ORPH" | tr '\n' ' ')"
    echo "$ORPH" | xargs -r pacman -Rns --noconfirm >/dev/null 2>&1 \
        && info "已删除孤儿包" || warn "部分孤儿包删除失败(无影响)"
else
    info "无孤儿包"
fi

# ---------------------------------------------------------- ③ gcc
head_ "③ 删除 gcc"
if pacman -Qi gcc >/dev/null 2>&1; then
    pacman -R --noconfirm gcc >/dev/null 2>&1 && info "已删除 gcc" || warn "gcc 删除失败"
else
    info "gcc 不存在, 跳过"
fi

# ---------------------------------------------------------- ④ firefox
if [ "$WITH_FF" -eq 1 ]; then
    head_ "④ 删除 firefox"
    pacman -Qi firefox >/dev/null 2>&1 && {
        pacman -Rns --noconfirm firefox >/dev/null 2>&1 && info "已删除 firefox" || warn "firefox 删除失败"
    } || info "firefox 不存在"
fi

# ---------------------------------------------------------- ⑤ opencv
if [ "$WITH_CV" -eq 1 ]; then
    head_ "⑤ 删除 opencv + spectacle"
    pacman -Rns --noconfirm opencv spectacle >/dev/null 2>&1 \
        && info "已删除 opencv/spectacle" || warn "删除失败(可能 spectacle 正被依赖)"
fi

# ---------------------------------------------------------- ⑥⑦ locale / 壁纸
if [ "$AGGRESSIVE" -eq 1 ]; then
    head_ "⑥ 精简 locale(只保留 zh_CN / en / C)"
    before_loc="$(du -sm /usr/share/locale 2>/dev/null | cut -f1)"
    # 只删一级子目录, 保留 zh_CN* en* C* 和 locale.alias
    find /usr/share/locale -mindepth 1 -maxdepth 1 \
        ! -name 'zh_CN*' ! -name 'en*' ! -name 'C*' ! -name 'locale.alias' \
        -exec rm -rf {} + 2>/dev/null
    after_loc="$(du -sm /usr/share/locale 2>/dev/null | cut -f1)"
    info "locale: ${before_loc} MB → ${after_loc} MB"
    warn "提示: 若某些程序界面变英文, 把对应 locale 装回来即可(不影响功能)"

    head_ "⑦ 删除壁纸"
    if [ -d /usr/share/wallpapers ]; then
        pacman -Qo /usr/share/wallpapers >/dev/null 2>&1 \
            && warn "/usr/share/wallpapers 被 pacman 包拥有, 改用 pacman 卸载更安全, 跳过" \
            || { rm -rf /usr/share/wallpapers/* 2>/dev/null && info "已清空壁纸(86M)"; }
    fi
    echo "  现在可用: $(free_mb) MB"
fi

# ---------------------------------------------------------- ⑧ 压缩
if [ "$DO_COMPRESS" -eq 1 ]; then
    head_ "⑧ zstd 重压缩 /usr"

    # 2026-09-09 实测修正: rootfs **已经全局启用 zstd 压缩**了
    #   (抽样 10/10 个 >5M 的文件都带 btrfs.compression="zstd" xattr)。
    #   旧注释写的"rootfs 默认未启用压缩"是错的 → 再 defrag 一遍几乎没有收益,
    #   反而有实打实的风险: defrag 会打断 reflink / 硬链接共享, 让多份副本各自
    #   独立占空间, 空间**可能不降反升**。所以先检测, 已压缩就别动了。
    COMP_N=0; COMP_Z=0
    while IFS= read -r _f; do
        [ -f "$_f" ] || continue
        COMP_N=$((COMP_N+1))
        getfattr -m 'btrfs.compression' -d "$_f" 2>/dev/null | grep -qi zstd && COMP_Z=$((COMP_Z+1))
    done < <(find /usr/lib /usr/bin -type f -size +5M 2>/dev/null | head -10)

    if [ "$COMP_N" -gt 0 ] && [ "$COMP_Z" -eq "$COMP_N" ]; then
        warn "检测到 rootfs 已全局启用 zstd 压缩 (抽样 ${COMP_Z}/${COMP_N} 个文件均带压缩属性)"
        info "→ 跳过重压缩。再跑一次几乎没有收益, 且 defrag 会打断 reflink/硬链接共享,"
        info "  可能让空间不降反升。这是 2026-09-09 实测后的结论。"
    elif [ "$(free_mb)" -lt 500 ]; then
        warn "可用空间 <500MB, 跳过压缩(先跑 --apply 回收空间后再执行)"
    else
        warn "正在重压缩, 请勿中断(可能耗时数分钟)..."
        btrfs filesystem defrag -r -czstd:3 /usr >/dev/null 2>&1 \
            && info "重压缩完成" || warn "重压缩部分失败(属正常, 部分文件被占用)"
        btrfs filesystem sync / >/dev/null 2>&1
    fi
fi

# ---------------------------------------------------------------- 收尾
head_ "最终结果"
echo "  操作前可用: ${BEFORE} MB"
echo "  操作后可用: $(free_mb) MB"
echo "  释放了:     $(( $(free_mb) - BEFORE )) MB"
echo
df -h / | sed 's/^/  /'
echo
AFTER="$(free_mb)"
if [ "$AFTER" -ge 800 ]; then
    info "可用 ${AFTER} MB —— 已经够用了, 建议停手。"
    echo "  参考: SteamOS 官方镜像装完就占 4.2G/5.0G (约 84%), 你现在比官方还宽裕。"
    echo "  下次大版本升级需要 ≥600M 余量, 当前已满足。"
    echo
    echo "  若仍想再挤 ~320M, 可跑: sudo bash $0 --apply --aggressive"
    echo "  但请注意: --aggressive 是删 pacman 包内的文件(locale/wallpapers),"
    echo "  属于不干净的状态, 且 SteamOS 原子升级会整块换 rootfs → 收益不持久。"
    echo "  --compress 不必再跑: 实测本机已全局启用 zstd 压缩, 收益接近 0 且有风险。"
elif [ "$AFTER" -ge 600 ]; then
    info "可用 ${AFTER} MB —— 满足大版本升级的 600M 门槛, 但余量不算宽裕。"
    echo "  若还想再挤 ~320M: sudo bash $0 --apply --aggressive"
    echo "  (--aggressive 删的是 pacman 包内文件, 升级后会被覆盖回去, 收益不持久)"
else
    warn "可用 ${AFTER} MB —— 低于大版本升级所需的 600M, 建议再跑:"
    echo "    sudo bash $0 --apply --aggressive"
    echo "  若仍不够, 检查 /home 上是否有大件可以迁走(游戏本体/兼容层都在 p8, 不影响)"
fi
