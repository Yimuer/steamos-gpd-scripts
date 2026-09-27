#!/usr/bin/env bash
# ===========================================================================
#  steamos.sh —— 全家桶统一入口（唯一的人机接口）
# ---------------------------------------------------------------------------
#  【为什么要有它】
#    这个备份包有 30+ 个脚本, 名字按"干什么"起(doctor / diag- / fix- / install-)。
#    现场着急时最费时间的往往不是修, 而是"我到底该跑哪个?"。
#    本文件把这件事收敛成**一张注册表**: 菜单 / 清单 / 帮助 / 分发全由它派生 ——
#    以后加一个脚本, 只在注册表里加一行就够了(check.sh 会断言"没人被漏掉")。
#
#  【设计约束(与项目铁律一致)】
#    · 自包含单文件, 不引 lib/, 可单独拷走(铁律 1)。
#    · **不自己提权**: 需要 root 的仍由各脚本自己 sudo。本文件绝不能进 sudoers ——
#      它是用户可写的, 放行它等于放行"任意提权"(铁律 3)。
#    · 只做分发, 不复制逻辑: 判据与修复都在原脚本里, 这里不重写(防双份漂移)。
#    · 非交互环境绝不挂起: 只读项照跑; 需要 root / 需要人确认的, 只打印该跑的命令。
#
#  【用法】
#    bash steamos.sh                 # 交互菜单(按分组, 输入编号或命令名; q 退出)
#    bash steamos.sh list            # 列出全部命令(脚本友好, 无交互)
#    bash steamos.sh <命令> [参数…]   # 直接分发, 例: bash steamos.sh doctor
#    bash steamos.sh selfcheck       # 自检: 注册表↔文件一致 / 跑的是哪一份 / 快照新旧
#    bash steamos.sh pack            # 打发布包: tar.gz + 单文件自安装包 .run
#    bash steamos.sh dist-verify     # 把发布包解到临时目录实跑一遍(验证自包含)
#    bash steamos.sh help | version
#
#  【退出码】
#    透传被调脚本的退出码; 入口自身: 2 = 用法/未知命令, 3 = 缺文件,
#    4 = 非交互环境被拦下(该命令需要终端)。
# ===========================================================================
set -uo pipefail

# 定位"真实的自己"再 cd —— 必须解开符号链接:
#   若被软链到 ~/.local/bin/steamos.sh 再从那里调用, BASH_SOURCE 给的是**软链路径**,
#   dirname 就不是本包目录 → 后面每条命令都会报"缺文件"(一类很难往这想的故障)。
#   这让"软链进来也能用", 同时保持"单文件可独立拷走"。
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
    _dir="$(cd -P "$(dirname "$_src")" 2>/dev/null && pwd)"
    _src="$(readlink "$_src")"
    case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
HERE="$(cd -P "$(dirname "$_src")" 2>/dev/null && pwd)"
unset _src _dir
cd "$HERE" || exit 2

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'; C_B=$'\033[1m'; C_D=$'\033[2m'
info()  { printf '%s[✓]%s %s\n' "$C_G" "$C_R" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_Y" "$C_R" "$*"; }
err()   { printf '%s[✗]%s %s\n' "$C_RD" "$C_R" "$*" >&2; }
sub()   { printf '    %s%s%s\n' "$C_D" "$*" "$C_R"; }
head_() { printf '\n%s%s%s\n' "$C_B" "$*" "$C_R"; }

SELF="steamos.sh"                     # 自己: 覆盖率断言里要排除它
VERSION="$(cat VERSION 2>/dev/null || echo '未知')"
SNAP_DIR="/opt/steamos-backup"        # 免密快照(root 属主, /opt 扛升级)

# ===========================================================================
#  注册表 —— 本文件唯一的事实来源
#  格式:  命令|文件|默认参数|模式|分组|说明
#    · 文件 = `-`  → 内建命令(由本脚本自己实现, 不是转发)
#    · 默认参数    → 自动补上, 用户给的参数追加在后
#    · 模式: ro   = 只读, 可无人值守
#            root = 会自己 sudo(要密码, 要终端)
#            ui   = 需要人在终端前(交互/确认/可能改盘)
#  ⚠️ 改脚本清单只改这里: 菜单 / list / help / 分发 / 自检全部由本表派生。
# ===========================================================================
REG=(
  # ── 体检(只读) ─────────────────────────────────────────────────────────
  "doctor|doctor.sh||ro|health|一屏体检: 这台机器现在健康吗(只读, 免 root, 秒级)"
  "doctor-net|doctor.sh|--net|ro|health|体检 + 联网探一遍上游依赖是否还在(约 30 秒)"
  "status|steamos-setup.sh|--status|ro|health|看必装 16 步各自的落地状态(只读)"
  "check|check.sh||ro|health|改脚本后必跑: 语法 + 不变量断言(只读免 root)"
  "upstream|verify-upstreams.sh||ro|health|发布前/重装前: 一次探完所有外部依赖"

  # ── 重装与恢复 ─────────────────────────────────────────────────────────
  "wizard|重装后先运行我.sh||ui|setup|重装向导: 走完 16 步 → 问是否装可选组件(落盘后停窗)"
  "setup|steamos-setup.sh||root|setup|必装 16 步全量(断点续传; 追加编号可只跑单步)"
  "after-upgrade|steamos-setup.sh|--after-upgrade|root|setup|大版本升级后: 只重建被冲掉的部分"
  "step12|steamos-setup.sh|12|root|setup|★ 重建自愈服务 + 免密规则(升级后第一条命令)"
  "selfheal|self-heal-after-upgrade.sh||ro|setup|立刻手动跑一次升级自愈(平时由开机服务自动跑)"
  "devfiles|fix-missing-dev-files.sh||ro|setup|体检: /usr 的开发文件齐不齐(编译任务前置)"
  "devfiles-apply|fix-missing-dev-files.sh|--apply|root|setup|补回被 SteamOS 镜像裁掉的开发文件(写 /usr)"
  "rootfs|free-rootfs.sh||root|setup|rootfs(5G)空间体检 —— 默认只报告, 不动任何东西"
  "rootfs-apply|free-rootfs.sh|--apply|root|setup|执行安全的瘦身项(余量<600M 才值得)"

  # ── 应用安装与便携化 ───────────────────────────────────────────────────
  "apps|可选组件安装.sh||root|apps|可选项菜单(微信/Clash Verge/WPS/鸿蒙字体/NextKde/任意 deb)"
  "app|install-app-home.sh||ui|apps|单引擎便携安装器(--list 看 profile: firefox/dsh/wps/clash-verge)"
  "portable|install-deb-portable.sh||ui|apps|任意 deb → 拆包装进 /home 扛升级(图形引导)"
  "wb-home|install-workbuddy-home.sh||ui|apps|WorkBuddy 的 /home 自持化(追加 --check 为只读自检)"
  "harmony|install-harmony-sans-home.sh||ui|apps|鸿蒙字体装成系统字体(落 /home 扛升级)"
  "nextkde|install-nextkde-home.sh||ui|apps|NextKde 桌面外壳(需编译; 用户已决定不装)"
  "backkey|setup-win5-backkeys.sh||root|apps|GPD Win5 背键 + inputplumber(--status 只读)"
  "decky|install-decky-loader.sh||root|apps|Decky Loader(--status 只读)"
  "tdp|install-decky-tdp.sh||root|apps|SimpleDeckyTDP 插件(插电/离电分档)"
  "ge-proton|install-ge-proton.sh||ui|apps|GE-Proton 兼容层(游戏跑通用)"
  "dwproton|install-dwproton.sh||ui|apps|DW-Proton(后备, 本机不需要, 见 §6)"

  # ── 故障修复 ───────────────────────────────────────────────────────────
  "inputcycle|fix-inputplumber-cycle.sh||root|fix|修 systemd 依赖死循环(背键失效头号元凶)"
  "wb-ime|fix-workbuddy-wayland-ime.sh||root|fix|WorkBuddy Wayland 输入法加固(非根因, 属无害加固)"
  "optdeps|fix-opt-deps.sh||root|fix|补便携化应用在 /usr 的依赖(如 webkit2gtk; 已进自愈链)"
  "dsh-pty|fix-dsh-node-pty.sh||ui|fix|修 dsh 桌面版 node-pty 编译失败(根因是 PYTHONHOME 中毒)"
  "endfield-qt|fix-endfield-qt.sh||ui|fix|补终末地缺失的 Qt5 WebEngine 运行时资源"
  "endfield-sdk|reset-endfield-sdk.sh||ui|fix|终末地「黑屏无声音」的主修复: 清空 SDK 本地状态"

  # ── 诊断取证(只读; 出问题时先取证再动手) ───────────────────────────────
  "diag-black|diag-black-screen.sh||ro|diag|游戏黑屏取证(黑屏时别关游戏, 另开终端跑)"
  "diag-decky|diag-decky.sh||ro|diag|Decky 插件诊断(--repair / --channels-stable)"
  "diag-endfield|diag-endfield.sh||ro|diag|终末地专项诊断"
  "diag-gpd|diag-gpd-inputs.sh||ro|diag|背键/手柄输入链路诊断"
  "diag-ip|diag-ip.sh||ro|diag|网络与 IP 诊断"
  "diag-sudo|diag-sudo-selfheal.sh||root|diag|自愈免密链路体检(要读 0440 的 sudoers, 故需 root)"
  "boot-slow|诊断-开机慢.sh||ro|diag|开机慢诊断(NTP / 服务等待 / 失败单元)"

  # ── 维护与发布 ─────────────────────────────────────────────────────────
  "compat|switch-compat-tool.py||ui|maint|切换 Steam 兼容层(须先彻底退出 Steam; 支持 --dry-run)"
  "launchopts|set-steam-launchoptions.py||ui|maint|写 Steam 启动选项(自动探测 userid)"
  "upgrade-wb|upgrade-workbuddy-aur.sh||ui|maint|升级 WorkBuddy(AUR)"
  "selfcheck|-||ro|maint|自检: 注册表↔文件一致 / 跑的是哪一份 / 快照是否落后"
  "pack|-||ro|maint|打发布包 dist/steamos-toolbox-<版本>.tar.gz + 单文件 .run (+SHA256SUMS)"
  "dist-verify|-||ro|maint|把发布包解到临时目录实跑一遍, 验证它真的自包含"
  "pack-run|pack-run.sh|--selftest|ro|maint|自测单文件封装器(造玩具包→安装→校验→反例: 偏移/sha/覆盖护栏)"
)

# ⚠️ 名字别用 `GROUPS` —— 那是 bash 的**特殊变量**(当前用户的组 ID 列表),
#    赋值会被无声吞掉: 菜单分组会变成 1000/998/973 这种组号(真踩过)。
CMD_GROUPS=(health setup apps fix diag maint)

group_title() {
    case "$1" in
        health) echo "体检与状态（只读）" ;;
        setup)  echo "重装与升级恢复" ;;
        apps)   echo "应用安装与便携化" ;;
        fix)    echo "故障修复" ;;
        diag)   echo "诊断取证（只读）" ;;
        maint)  echo "维护与发布" ;;
        *)      echo "$1" ;;
    esac
}
mode_label() {
    case "$1" in
        ro)   echo "只读" ;;
        root) echo "sudo" ;;
        ui)   echo "交互" ;;
        *)    echo "$1" ;;
    esac
}
# 用哪个解释器跑(按扩展名判定 —— 这样注册表不必多一列)
interp_for() {
    case "$1" in
        *.py) echo "python3" ;;
        *)    echo "bash" ;;
    esac
}

# ── 注册表查询 ───────────────────────────────────────────────────────────
reg_row() {   # $1 = 命令名 → 打印整行
    local r
    for r in "${REG[@]}"; do
        [ "${r%%|*}" = "$1" ] && { printf '%s\n' "$r"; return 0; }
    done
    return 1
}
reg_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

# 该跑哪条命令(给用户复制用) —— 需要 root 的带上 sudo
print_invoke() {
    local row file defargs mode inv
    row="$(reg_row "$1")" || return 1
    file="$(reg_field "$row" 2)"; defargs="$(reg_field "$row" 3)"; mode="$(reg_field "$row" 4)"
    inv="$(interp_for "$file") \"$HERE/$file\""
    [ -n "$defargs" ] && inv="$inv $defargs"
    if [ "$mode" = root ] && [ "$(id -u)" -ne 0 ]; then inv="sudo $inv"; fi
    printf '%s' "$inv"
}

# ===========================================================================
#  分发
# ===========================================================================
dispatch() {
    local key="${1:-}"; shift || true
    local row file defargs mode rc=0
    [ -n "$key" ] || { cmd_menu; return $?; }

    row="$(reg_row "$key")" || {
        err "未知命令: $key"
        sub "看全部命令: bash $SELF list"
        sub "不知道跑哪个先来: bash $SELF doctor"
        return 2
    }
    file="$(reg_field "$row" 2)"; defargs="$(reg_field "$row" 3)"; mode="$(reg_field "$row" 4)"

    # 内建命令(注册表里文件写 `-`)
    if [ "$file" = "-" ]; then
        "builtin_${key//-/_}" "$@"
        return $?
    fi

    [ -f "$HERE/$file" ] || {
        err "缺文件: $file"
        sub "备份包要整个目录一起拷(把脚本单独拎出来会缺依赖)"
        return 3
    }

    # 非交互守卫: stdin 不是终端时, 需要 root/需要确认的命令**不跑**,
    #   免得停在密码提示或确认问句上永久挂住(项目里踩过 `echo q | bash …` 挂住)。
    #   只读项照跑 —— 无人值守体检/自检正是它的用途。
    if [ ! -t 0 ] && [ "$mode" != ro ]; then
        warn "stdin 不是终端 → 不直接跑「$key」(它需要密码/确认, 会挂住)"
        sub "要跑就执行:  $(print_invoke "$key")"
        return 4
    fi

    # 默认参数(注册表) + 用户追加的参数
    local -a argv=()
    [ -n "$defargs" ] && read -r -a argv <<< "$defargs"
    argv+=("$@")

    head_ "运行: $key  →  $file ${defargs:+[$defargs] }$*"
    "$(interp_for "$file")" "$HERE/$file" "${argv[@]}" || rc=$?
    [ "$rc" -eq 0 ] && info "退出码 0" || warn "退出码 $rc"
    return "$rc"
}

# ===========================================================================
#  内建命令
# ===========================================================================
builtin_selfcheck() {
    local problems=0 g r f key file n_reg=0 n_miss=0 n_file=0 n_unreg=0 n_bad=0

    printf '%s══ 入口自检 ══%s\n' "$C_B" "$C_R"
    printf '  版本 %s\n  副本: %s\n' "$VERSION" "$HERE"

    # ── 1. 注册表 → 文件(注册了就必须在) ──
    head_ "1. 注册表 → 文件"
    for r in "${REG[@]}"; do
        file="$(reg_field "$r" 2)"
        [ "$file" = "-" ] && continue
        n_reg=$((n_reg + 1))
        [ -f "$HERE/$file" ] || { err "注册了但文件不在: $file"; n_miss=$((n_miss + 1)); }
    done
    if [ "$n_miss" -eq 0 ]; then info "注册 $n_reg 个脚本, 全部在位"
    else problems=1; fi

    # ── 2. 文件 → 注册表(不许有漏网的脚本) ──
    #    这条与 check.sh 的断言是同一个不变量: 新脚本必须进注册表,
    #    否则它会"存在于目录里, 但没有任何入口指向它"。
    head_ "2. 文件 → 注册表"
    for f in *.sh *.py; do
        [ -f "$f" ] || continue
        [ "$f" = "$SELF" ] && continue          # 自己不必登记自己
        n_file=$((n_file + 1))
        grep -qF "|$f|" "$SELF" || { warn "没登记进注册表: $f(它不该被遗忘)"; n_unreg=$((n_unreg + 1)); }
    done
    if [ "$n_unreg" -eq 0 ]; then info "根目录 $n_file 个脚本全部已登记"
    else problems=1; fi

    # ── 3. 语法自检(在解包出来的发布包里也能跑, 不需要 git) ──
    head_ "3. 语法(bash -n)"
    for f in *.sh; do
        [ -f "$f" ] || continue
        bash -n "$f" 2>/dev/null || { err "语法错: $f"; n_bad=$((n_bad + 1)); }
    done
    if [ "$n_bad" -eq 0 ]; then info "全部 .sh 语法通过"
    else problems=1; fi

    # ── 4. 副本可见性(多副本设计的必修课, 见维护手册 §13.8b) ──
    head_ "4. 副本与快照"
    if [ "$HERE" = "$SNAP_DIR" ]; then
        warn "你跑的是**快照**那份(root 属主, /opt 扛升级)"
        sub "它是自动恢复用的那份; 人工排障请用仓库/备份包里那份"
    else
        info "你跑的是备份包/仓库这份(人工操作的正确副本)"
    fi
    if [ -f "$SNAP_DIR/steamos-setup.sh" ]; then
        local sa sb
        sa="$(sha256sum "$HERE/steamos-setup.sh" 2>/dev/null | cut -d' ' -f1)"
        sb="$(sha256sum "$SNAP_DIR/steamos-setup.sh" 2>/dev/null | cut -d' ' -f1)"
        if [ -n "$sa" ] && [ -n "$sb" ] && [ "$sa" != "$sb" ]; then
            warn "免密快照落后于本副本(主脚本 sha256 不一致)"
            sub "刷新(要输一次密码): sudo bash $HERE/steamos-setup.sh 12"
        else
            info "免密快照与本副本一致"
        fi
        [ "$(stat -c '%U:%G' "$SNAP_DIR/steamos-setup.sh" 2>/dev/null)" = "root:root" ] \
            && info "快照属主正确(root:root, 用户改不动)" \
            || { warn "快照属主不是 root:root —— 等于没做成快照"; sub "重做: sudo bash $HERE/steamos-setup.sh 12"; }
    else
        warn "还没有免密快照($SNAP_DIR) —— 自动恢复链没建立"
        sub "建立(要输一次密码): sudo bash $HERE/steamos-setup.sh 12"
    fi

    printf '\n%s══ 结论 ══%s\n' "$C_B" "$C_R"
    if [ "$problems" -eq 0 ]; then
        info "入口与脚本一致。"
        return 0
    fi
    err "有不一致项(见上面 ✗ / !)。"
    return 1
}

builtin_pack() {
    local ver out n
    ver="$(cat VERSION 2>/dev/null || echo 0)"
    out="$HERE/dist/steamos-toolbox-$ver.tar.gz"
    mkdir -p "$HERE/dist" || { err "建不了 dist/"; return 1; }
    head_ "打包 → dist/steamos-toolbox-$ver.tar.gz + 单文件 .run"

    # 成员按"该是什么模式"分两趟显式写进包 (--mode), **不看文件系统位**:
    #   Windows/NTFS 上 chmod 是空操作、网盘/Windows 拷贝会丢执行位(2026-09-27 实测, §13.10.9),
    #   靠 FS 位打包会把 .desktop 打成 644 → 到 Linux 双击没反应(8977c11 同类事故)。
    #   执行位集合 = 名字规则(.sh/.desktop/目录) ∪ git 索引里的 100755
    #   (覆盖 hooks/pre-commit 这种无扩展名也必须可执行的; 索引在 Windows 上同样可信)。
    #   没有 .git(发布副本再打包)时退回 名字规则 + FS 位(那时在 Linux 上, FS 位是真的)。
    local tmp list_x list_r p tarf _e
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/steamos-pack-XXXXXX")" || { err "建不了临时目录"; return 1; }
    list_x="$tmp/exec.list"; list_r="$tmp/plain.list"

    local -A _xset=()
    if [ -d .git ]; then
        while IFS= read -r -d '' _e; do
            [ "${_e%% *}" = "100755" ] && _xset["./${_e#*$'\t'}"]=1
        done < <(git ls-files -s -z 2>/dev/null)
    fi

    # 排除(按基名在任意层级生效, 与原 tar --exclude 同语义): 版本库元数据 / 会话产物 /
    #   缓存 / 运行时状态 / 可选二进制(6MB 的 shellcheck)。
    #   ⚠️ 必须按基名: 只锚顶层会漏掉 steamos-nix/.workbuddy(真踩过, 被 dist-verify 抓到)。
    find . \( -name .git -o -name .workbuddy -o -name __pycache__ -o -name .cache \
              -o -name dist -o -name todo -o -name shellcheck -o -name shellcheck.exe \
              -o -name .snapmeta -o -name last-osversion -o -name last-report.txt \
              -o -name NEEDS-ATTENTION.txt \) -prune -o -print \
        | LC_ALL=C sort > "$tmp/all" || { err "枚举文件失败"; rm -rf "${tmp:?}"; return 1; }
    : > "$list_x"; : > "$list_r"
    while IFS= read -r p; do
        case "$p" in
            *.pyc) continue ;;
            *.sh|*.desktop) printf '%s\n' "$p" >> "$list_x" ;;
            *)  if [ -d "$p" ] || [ -n "${_xset[$p]:-}" ] || { [ ! -d .git ] && [ -x "$p" ]; }; then
                    printf '%s\n' "$p" >> "$list_x"
                else
                    printf '%s\n' "$p" >> "$list_r"
                fi ;;
        esac
    done < "$tmp/all"

    # 两趟写包: 第一趟 755(目录+执行位集合), 第二趟 644(其余)。
    #   ⚠️ --no-recursion 必加: 清单已含全部成员; 不加的话目录子树会被 tar 按
    #      **文件系统位**再塞一遍 —— 显式模式就白显式了。
    tarf="$tmp/pkg.tar"
    if tar -cf "$tarf" --no-recursion --mode='u=rwx,go=rx' -T "$list_x" \
       && tar -rf "$tarf" --no-recursion --mode='u=rw,go=r' -T "$list_r" \
       && gzip -nc "$tarf" > "$out"; then
        rm -rf "${tmp:?}"
    else
        err "tar 失败"; rm -rf "${tmp:?}"; return 1
    fi

    ( cd "$HERE/dist" && sha256sum "$(basename "$out")" > SHA256SUMS ) \
        || warn "校验和没写成(SHA256SUMS)"
    n="$(tar -tzf "$out" 2>/dev/null | grep -c .)"
    info "已生成: $out"
    sub "文件数 $n · 体积 $(du -h "$out" 2>/dev/null | cut -f1)"
    sub "校验和: dist/SHA256SUMS"

    # ── 单文件自安装包(交付物的**主形态**) ────────────────────────────────
    #   为什么不只给 tar.gz: 那要求用户"解压 + chmod +x"两步手工前置
    #   (文档里曾有 5 处写着这条, 2026-09-25 那次双击没反应的事故就是它引起的)。
    #   .run 一个文件拷过去 `bash` 一下即可: 执行位写在 tar 元数据里, 头部自己会
    #   校验载荷 sha256、拒绝覆盖已有目录、失败时不留半个安装。
    local run="$HERE/dist/steamos-toolbox-$ver.run"
    if bash "$HERE/pack-run.sh" "$out" "$run" "$ver"; then
        ( cd "$HERE/dist" && sha256sum "$(basename "$out")" "$(basename "$run")" > SHA256SUMS ) \
            || warn "两个产物的校验和没写成(SHA256SUMS)"
        sub "单文件包: $run"
    else
        err "单文件包没打成 —— 发布物不完整(只给 tar.gz 等于把 chmod 的负担丢给用户)"
        sub "验证: bash $SELF dist-verify"
        return 1
    fi
    sub "验证: bash $SELF dist-verify"
    return 0
}

builtin_dist_verify() {
    local ver tgz tmp rc=0 f n_miss=0
    ver="$(cat VERSION 2>/dev/null || echo 0)"
    tgz="$HERE/dist/steamos-toolbox-$ver.tar.gz"
    [ -f "$tgz" ] || { err "还没有发布包: $tgz"; sub "先跑: bash $SELF pack"; return 3; }

    head_ "验证发布包(解到临时目录实跑)"

    # ── 1. 校验和 ──
    if [ -f "$HERE/dist/SHA256SUMS" ] \
       && ( cd "$HERE/dist" && sha256sum -c --status SHA256SUMS ) 2>/dev/null; then
        info "校验和一致"
    else
        warn "校验和校验没过(包装好后又改过?)"
    fi

    # ── 2. 解包 ──
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/steamos-dist-XXXXXX")" || { err "建不了临时目录"; return 1; }
    if ! tar -xzf "$tgz" -C "$tmp" 2>/dev/null; then
        err "解包失败"; rm -rf "${tmp:?}"; return 1
    fi
    info "解包到 $tmp"

    # ── 3. 关键文件在位 + 执行位(发布包必须能直接跑/直接双击) ──
    for f in steamos.sh steamos-setup.sh 可选组件安装.sh install-app-home.sh \
             fix-missing-dev-files.sh 20-gpd_win5.capmap.yaml VERSION README.md; do
        [ -e "$tmp/$f" ] || { err "发布包里缺: $f"; n_miss=$((n_miss + 1)); }
    done
    [ -x "$tmp/steamos.sh" ] || { err "发布包里 steamos.sh 没有执行位"; n_miss=$((n_miss + 1)); }
    [ "$n_miss" -eq 0 ] && info "关键文件齐全, 入口可执行" || rc=1
    # 全部 .sh 都要带执行位(项目踩过: 拷来拷去执行位丢了, 双击静默无反应)
    n_x=0
    for f in "$tmp"/*.sh; do
        [ -f "$f" ] || continue
        [ -x "$f" ] || { err "发布包里没有执行位: $(basename "$f")"; n_x=$((n_x + 1)); }
    done
    [ "$n_x" -eq 0 ] && info "全部 .sh 都带执行位" || rc=1

    # ── 3b. 包内**存储的**执行位(读 tar 元数据 —— 这是跨平台的判据) ──
    #    为什么非要这步: 在 Windows/NTFS 上打包时, chmod 是空操作, 无 shebang 的文件
    #    (.desktop) 会被按 644 存进包 → 到 Linux 上双击没反应(8977c11 同类事故)。
    #    而解包后在 Windows 上做 -x 测试又必然假红 → 唯一能两边都信的判据是 tar 里存的模式。
    n_mode=0
    while IFS= read -r _e; do
        case "${_e:0:10}" in
            *x*) ;;   # 任意一类执行位都行(包只要带回 Linux 能跑/能双击)
            *) err "包里存的模式丢了执行位: ${_e#./}"; n_mode=$((n_mode + 1)) ;;
        esac
    done < <(tar -tvzf "$tgz" 2>/dev/null | awk '$NF ~ /\.(sh|desktop)$/ {print $1, $NF}')
    if [ "$n_mode" -eq 0 ]; then info "包内全部 .sh/.desktop 都带着执行位(tar 元数据)"
    else
        err "这个包是在存不了执行位的环境(典型: Windows)里打的 —— 到 Linux 上重跑 pack"
        rc=1
    fi

    # ── 4. 不该被打进去的东西 ──
    #    发布包要能公开分发: 版本库元数据、会话记录、缓存都不该在里面。
    #    这一步是**真抓到过 bug 的**: 排除规则原先只锚定顶层, steamos-nix/ 子目录里的
    #    .workbuddy/ 与 __pycache__/ 被打了进来 —— 所以这里宁可查得宽一点。
    n_leak=0
    for pat in .git .workbuddy __pycache__ .cache dist todo '*.pyc'; do
        hit="$(find "$tmp" -name "$pat" -print -quit 2>/dev/null)"
        [ -n "$hit" ] && { err "发布包里混进了 $pat"; n_leak=$((n_leak + 1)); }
    done
    if [ "$n_leak" -eq 0 ]; then info "没有混进版本库元数据/会话产物/缓存"
    else rc=1; fi

    # ── 5. 在包内实跑入口自检(证明它是自包含的, 不依赖本仓库) ──
    #    注意: 这里不跑完整 check.sh —— 它有若干断言依赖 git 台账,
    #    在"没有 .git 的解包目录"里会假红。发布的包按"自包含"标准验。
    head_ "包内实跑: bash steamos.sh selfcheck"
    if ( cd "$tmp" && bash steamos.sh selfcheck ); then
        info "包内自检通过(注册表↔文件一致, 语法全过)"
    else
        err "包内自检没通过 —— 这个包不完整"
        rc=1
    fi

    # ── 6. 单文件包(.run)真装一遍 —— 交付物的主形态必须能被它自己验证 ──
    #    刻意**不用** tar 手工解压, 而是调用 .run 本身: 只有这样才证明
    #    "一个文件拷过去, bash 一下就位"这句话是真的(偏移 / sha / 执行位 / 拒绝覆盖)。
    head_ "单文件包实装: bash <run> --no-run <临时目录>"
    local run="$HERE/dist/steamos-toolbox-$ver.run" dst_run dl
    dst_run="$tmp-run"
    rm -rf "${dst_run:?}"
    if [ ! -f "$run" ]; then
        err "没有单文件包: $run —— 重新 pack(只给 tar.gz 等于把 chmod 的负担丢给用户)"
        rc=1
    elif ! bash "$run" --no-run "$dst_run" >/dev/null 2>&1; then
        err ".run 装不上(偏移/sha/解包 出问题了)"
        sub "手工看原因: bash $run --check; bash $run --list | head"
        rc=1
    else
        info "单文件包装成功(全程没碰过 tar)"
        if [ -x "$dst_run/steamos.sh" ]; then info "  装出来的入口带执行位"
        else err "  装出来的 steamos.sh 没有执行位"; rc=1; fi
        if ( cd "$dst_run" && bash steamos.sh selfcheck >/dev/null 2>&1 ); then
            info "  装出来的副本自检通过"
        else
            err "  装出来的副本自检没过"; rc=1
        fi
        # 成员清单逐行对: .run 与 tar.gz 必须是同一份内容
        #   (唯一允许的差集是 .run 自己写的 .installed-from 安装标记)
        dl="$tmp/run-members.diff"
        if diff <(tar -tzf "$tgz" | grep -v '/$' | LC_ALL=C sort) \
                <( cd "$dst_run" && find . -type f | LC_ALL=C sort ) > "$dl" 2>&1; then
            info "  成员清单与 tar.gz 一致"
        elif [ "$(grep -c '^[<>]' "$dl")" -eq 1 ] && grep -q '^> \./\.installed-from$' "$dl"; then
            info "  成员清单与 tar.gz 一致(多的 1 项是 .run 写的安装标记)"
        else
            err "  .run 装出来的内容与 tar.gz 不一致:"
            sed 's/^/        /' "$dl" | head -10
            rc=1
        fi
        rm -f "$dl"
    fi
    rm -rf "${dst_run:?}"

    rm -rf "${tmp:?}"
    printf '\n%s══ 结论 ══%s\n' "$C_B" "$C_R"
    if [ "$rc" -eq 0 ]; then info "发布包可用: $(du -h "$tgz" | cut -f1)"; else err "发布包有问题(见上)"; fi
    return "$rc"
}

# ===========================================================================
#  清单 / 帮助 / 版本 / 菜单
# ===========================================================================
cmd_list() {
    local g r
    printf 'SteamOS 工具箱 %s —— %s\n' "$VERSION" "$HERE"
    for g in "${CMD_GROUPS[@]}"; do
        printf '\n── %s ──\n' "$(group_title "$g")"
        for r in "${REG[@]}"; do
            [ "$(reg_field "$r" 5)" = "$g" ] || continue
            printf '  %-14s %-4s %s\n' \
                "$(reg_field "$r" 1)" \
                "$(mode_label "$(reg_field "$r" 4)")" \
                "$(reg_field "$r" 6)"
        done
    done
    printf '\n用法: bash %s <命令> [参数…]    例: bash %s doctor\n' "$SELF" "$SELF"
    printf '模式: 只读 = 不改任何东西; sudo = 会提权(要密码); 交互 = 需要你在终端前\n'
}

cmd_help() {
    cat <<EOF
SteamOS 工具箱 $VERSION —— 全家桶统一入口($HERE)

用法:
  bash $SELF                 交互菜单(按分组, 输入编号或命令名; q 退出)
  bash $SELF list            列出全部命令(脚本友好, 无交互)
  bash $SELF <命令> [参数…]   直接分发, 例: bash $SELF doctor
  bash $SELF selfcheck       自检: 注册表↔文件一致 / 跑的是哪一份 / 快照是否落后
  bash $SELF pack            打发布包: dist/*.tar.gz + 单文件自安装包 *.run
  bash $SELF dist-verify     把发布包解到临时目录实跑一遍(验证自包含)
  bash $SELF help | version

说明:
  · 本文件只做**分发**: 每条命令都在做它自己那份工作, 这里不重写逻辑。
  · 需要 root 的项由各脚本自己 sudo —— 本文件不进 sudoers(用户可写的不能放行)。
  · 非交互环境(stdin 不是终端)下, 只跑「只读」项; 其余只打印该跑的命令, 不会挂住。
  · 退出码透传被调脚本; 入口自身: 2=用法错, 3=缺文件, 4=非交互被拦。
EOF
    printf '\n── 全部命令 ──\n'
    cmd_list | sed -n '/^── /,$p'
}

cmd_version() {
    printf 'steamos.sh %s\n' "$VERSION"
    printf '副本: %s\n' "$HERE"
    if [ -f "$SNAP_DIR/.snapmeta" ]; then
        printf '免密快照: %s(同步于 %s)\n' "$SNAP_DIR" \
            "$(sed -n 's/^TIME=//p' "$SNAP_DIR/.snapmeta" 2>/dev/null | head -1)"
    else
        printf '免密快照: 未建立(跑 sudo bash steamos-setup.sh 12 建立)\n'
    fi
}

cmd_menu() {
    # 非交互(管道/定时任务/无终端)时不能开菜单: read 会挂住或空转。
    if [ ! -t 0 ]; then
        warn "stdin 不是终端 → 不开菜单, 只列清单"
        cmd_list
        sub "非交互用法: bash $SELF <命令>   例: bash $SELF doctor / list / selfcheck"
        return 0
    fi

    local sel key rc
    while :; do
        printf '\n%s══ SteamOS 工具箱 %s ══%s\n' "$C_B" "$VERSION" "$C_R"
        sub "$HERE"
        local -a IDX=(); local i=0 g r
        for g in "${CMD_GROUPS[@]}"; do
            head_ "── $(group_title "$g") ──"
            for r in "${REG[@]}"; do
                [ "$(reg_field "$r" 5)" = "$g" ] || continue
                i=$((i + 1)); IDX[$i]="$(reg_field "$r" 1)"
                printf '  %2d) %-14s %-4s %s\n' "$i" "$(reg_field "$r" 1)" \
                    "$(mode_label "$(reg_field "$r" 4)")" "$(reg_field "$r" 6)"
            done
        done
        printf '\n选择(编号或命令名; q 退出): '
        # -t 守卫: 没有输入时超时退出, 不永久挂住(项目铁律)
        if ! read -r -t 300 sel; then printf '\n(等输入超时, 退出)\n'; break; fi
        sel="$(printf '%s' "$sel" | tr -d '[:space:]')"
        case "$sel" in
            '' ) continue ;;
            q|Q|quit|exit|退出) break ;;
        esac
        if printf '%s' "$sel" | grep -qE '^[0-9]+$'; then
            key="${IDX[$sel]:-}"
            [ -n "$key" ] || { warn "没有编号 $sel"; continue; }
        else
            key="$sel"
        fi

        printf '\n'
        dispatch "$key"; rc=$?
        printf '\n%s──── 「%s」结束(退出码 %s)。回车回到菜单 ────%s\n' "$C_D" "$key" "$rc" "$C_R"
        read -r -t 300 _ || break
    done
    return 0
}

# ===========================================================================
#  入口
# ===========================================================================
case "${1:-}" in
    ""|menu)                  cmd_menu ;;
    -h|--help|help)           cmd_help ;;
    -V|--version|version)     cmd_version ;;
    list)                     cmd_list ;;
    *)                        dispatch "$@"; exit $? ;;
esac
