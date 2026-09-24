#!/usr/bin/env bash
# ============================================================================
#  SteamOS / Arch 重装后一键配置脚本  (rootfs 最小化版)
#
#  设计目标: 用户重装 SteamOS 后, 在无 AI 辅助环境下也能安全、可重跑地
#  重建本机环境。**所有能放 /home 的软件一律放 /home**, 尽可能少占用
#  SteamOS 那很小、且会被系统更新覆盖的 rootfs。
#
#  组件(各步独立可跑, 幂等, 失败可重跑):
#    [0] 环境准备: sudo 提权, SteamOS 只读根解除, pacman-key, 补齐官方源
#    [1] archlinuxcn 源
#    [2] IBus 输入法 —— 已于2026-09-24禁用(不改动系统输入法; 原实现存档于 disabled/)
#    [3] WorkBuddy  → AUR 包(最可靠能打中文)。**/opt 在 SteamOS 上是 bind mount
#         到 /home 分区(/.steamos/offload/opt), 那 818M 不占 rootfs**; 真正落在
#         rootfs 的只有 electron 依赖(约349M) + 编译最小集(约229M), 都在 /usr。
#         输入: 系统自带 IBus(KWin 原生前端), 由系统自身配置维护, 本脚本不碰
#    [4] GPD Win5 背键                    (守护进程 py 放 /home, /etc 只留小unit)
#    [5] Decky Loader + 预置插件          (默认装 SteamGridDB + ProtonDB Badges; DECKY_PLUGINS 可改/置空跳过)
#    [6] 游戏支持: GE-Proton + 鸣潮/终末地 Steam 启动辅助
#    [7] DeepSeek Harness(dsh): 补充的 AI Agent CLI(固定版本, 走 npm)
#    [8] rootfs 瘦身(可选; [3] 空间不够时会自动先跑一次)
#    [9] TDP 控制: SimpleDeckyTDP 插件(游戏模式里分别控制插电/离电功耗。
#        官方 SteamOS 的 QAM 面板只对 Deck 给 TDP 滑块, GPD Win5 不在列表 → 靠这个插件;
#        需先装好[5] Decky。仅 AMD/Intel APU, 有 NVIDIA 独显自动跳过。)
#   [10] 换境内 NTP(可选, 加速开机): SteamOS 默认用 arch.pool.ntp.org, 境内延迟高(实测
#        400ms+), 开机时 atomupd 要等 NTP 校时最多 20 秒才放行 → 开机慢。换成
#        阿里/腾讯 NTP(drop-in, 系统更新不覆盖), 开机同步秒过, atomupd 不再白等。
#
#  用法:
#    bash steamos-setup.sh            全量(0→9); 已成功的步骤会自动跳过
#    bash steamos-setup.sh --status   查看状态(含各步完成情况)
#    bash steamos-setup.sh --device   只检测本机设备画像(免root, 不装任何东西)
#    bash steamos-setup.sh 1 2 4      只装某几步
#    bash steamos-setup.sh clean      只做 rootfs 瘦身(清 locale/man/doc/缓存)
#    bash steamos-setup.sh --reset    清除进度记录(下次全量重跑)
#    bash steamos-setup.sh --help
#
#  断点续传(2026-09-08 新增):
#    - 进度记在 ~/.cache/steamos-setup/state, **每步成功才写**。
#      中断(Ctrl+C / 断网 / 某步报错)后重跑同一条命令, 会跳过已完成步骤, 从断点继续。
#    - 步骤失败不写进度 → 下次自动重试该步, 不会假装完成。
#    - 强制重跑已完成的步骤: FORCE=1 bash steamos-setup.sh 4   (或 --force)
#    - 大文件下载(Decky / GE-Proton)用 curl -C - 续传, 断网重跑不从头下。
#
#  重要:
#    - 本脚本**自包含**, 不依赖原机器任何文件, 拷到 U 盘即可。
#    - 每步需 root(自动 sudo, 密码在终端输入); --status 不需要。
#    - 全程联网。WorkBuddy(AUR)、Decky、GE-Proton、dsh 需联网下载。
#    - [3] 若 WorkBuddy 在跑需整个退出重开。(原[2]输入法步骤已禁用)
#    - [6] 游戏本体需你自行从备份放回下载目录(重装会清盘)。
#    - [4] 只在检测到 GPD Win5 时执行; 换机型重装会自动跳过(见"设备检测")。
#
#  rootfs(SteamOS 只有 5GB,  btrfs 且常无未分配 chunk)已踩过的坑:
#    - Arch 官方源必须 Include /etc/pacman.d/mirrorlist-arch。SteamOS 自带的
#      /etc/pacman.d/mirrorlist 指向 steamdeck-packages.steamos.cloud,
#      取 core.db/extra.db 直接 404。本脚本自建 mirrorlist-arch 并自愈旧配置。
#    - /opt 是 bind mount 到 /home 分区(/.steamos/offload/opt), 别去 mv /opt
#      (会报"设备或资源忙"), 也别按"818M 占 rootfs"做容量预检。
#      真正吃 rootfs 的是 /usr 下的 base-devel + electron。
#    - 混源纪律: 快照源(core-3.9/extra-3.9)必须排在滚动源(core/extra)之前。
#      快照优先 → electron/libisl 命中快照(版本匹配系统); 滚动只兜底新包。
#    - base-devel 是包组, pacman -Q 会展开: 装最小集(make/gcc/binutils/pkgconf
#      fakeroot/debugedit, 约229M)即可让判定通过, 省整组约370M。
#    - electron 是元包(体积0.00K), 真实体积在依赖的具体 electron 版本包。
#    - Electron/Chromium 在 Wayland 打中文: 不支持 Gtk4(只有 chromium/chrome 支持
#      --gtk-version=4); 走原生只能 --enable-wayland-ime(即 text-input-v1), 这是在
#      KWin 下唯一开箱可用的选项。默认用它; 不行再降级 XWayland + GTK_IM_MODULE=ibus。
#    - 手工往终端复制命令时, sed/python 里的反斜杠常被客户端吞($$→LaTeX),
#      本脚本统一用 heredoc 自执行, 避免该坑。
# ============================================================================

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"

# ---------- 颜色 / 工具 ----------
C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_R=$'\033[0m'
info() { printf "${C_OK}[✓]${C_R} %s\n" "$*"; }
warn() { printf "${C_WARN}[!]${C_R} %s\n" "$*"; }
err()  { printf "${C_ERR}[✗]${C_R} %s\n" "$*" >&2; }
step() { printf "\n${C_DIM}════════ %s ════════${C_R}\n" "$*"; }
sub()  { printf "${C_DIM}   • %s${C_R}\n" "$*"; }

# ---------- 下载探活 ----------
# ⚠️ 坑: 境内直连 GitHub 常"能连上但几乎不动", curl 会一直耗到 --max-time 才放弃。
#    原来 Decky 用 --max-time 500 且每个 URL 重试 3 次 → 直连一挂就是二十几分钟没反应。
#    故下载前先用 6s/12s 的短超时探活(只要 HTTP 200/301/302), 不通立刻换下一个镜像。
#    设 DL_PREFLIGHT=0 可关闭探活(比如镜像站不支持 HEAD/重定向探测时)。
url_reachable() {
    [ "${DL_PREFLIGHT:-1}" -eq 1 ] || return 0
    local u="$1" code
    code="$(curl -sIL --connect-timeout 6 --max-time 12 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)"
    case "$code" in 200|301|302|303|307|308) return 0 ;; *) return 1 ;; esac
}

# ---------- 真实用户(经 sudo 保留原用户) ----------
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER="$(logname 2>/dev/null || echo deck)"
fi
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
# 兜底: 某些环境(容器/受限 shell) 下 logname/getent 取不到 → 退回 /home/<user>,
# 否则 $REAL_HOME 为空会让所有以它为前缀的路径判定静默失败(如 Decky 复核)。
[ -n "$REAL_HOME" ] || REAL_HOME="/home/${REAL_USER:-deck}"
[ -n "$REAL_USER" ] || REAL_USER="$(basename "$REAL_HOME")"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"

# 是否 Valve SteamOS(holo 只读根)
IS_STEAMOS=0
if [ -f /etc/os-release ] && grep -qiE "^(ID|ID_LIKE)=.*steamos|steamos" /etc/os-release 2>/dev/null; then
    IS_STEAMOS=1
fi
# 是否 Arch 主仓库源(core/extra)已配置
HAS_CORE=0; HAS_EXTRA=0; HAS_ARCHLINUXCN=0
# 允许行首带 # : 用户可能是"注释掉"而不是删除。若按纯 \[core\] 判定, 就会判定为
# 缺失 → prepare 每次再追加一份, 末尾那份指向错镜像 → core.db 404 永久复现。
grep -qE '^\s*#?\s*\[core\]'     /etc/pacman.conf 2>/dev/null && HAS_CORE=1
grep -qE '^\s*#?\s*\[extra\]'    /etc/pacman.conf 2>/dev/null && HAS_EXTRA=1
grep -qE '^\s*#?\s*\[archlinuxcn\]' /etc/pacman.conf 2>/dev/null && HAS_ARCHLINUXCN=1

# ===========================================================================
#  设备 / GPU 检测(兼容多种机器: GPD Win5 掌机 / AMD 台式 / N 卡机器 / Intel 核显)
# ---------------------------------------------------------------------------
#  这套脚本原生面向 Valve SteamOS(官方只支持 AMD GPU)。但用户还有 N 卡机器
#  (iU+N卡 ITX / iU+N卡游戏本) 和 Intel 核显机器(如 Panther Lake)。
#  - N 卡机器**装不了官方 SteamOS**, 只能走 Bazzite(社区 Fedora 游戏发行版,
#    支持 N 卡 + DLSS) 或纯 SteamOS+N卡 patch。
#  - Intel Panther Lake(Xe3/Arc B390 核显)官方 SteamOS 也不支持(N 卡之外仅 AMD),
#    同样建议 Bazzite; 但 XeSS 在 Xe3 上是硬件加速, 可用。
#  故这里做统一检测, 让各步骤据此路由, 并给出 DLSS/FSR/XeSS 引导(见 [11] gpu 步骤)。
# ===========================================================================
GPU_VENDOR=""        # amd / nvidia / intel / 未知
GPU_IS_APU=0         # 集成显卡(APU/核显) = 1; 独立显卡 = 0
GPU_MODEL=""         # 显卡型号(供提示)
CPU_VENDOR=""        # AuthenticAMD / GenuineIntel / 其它
IS_WIN5=0            # 是否 GPD Win5(第[4]步背键用, 由 detect 统一填)
IS_PANTHER=0         # 是否 Intel Panther Lake(Xe3/Arc B390 核显, 支持硬件 XeSS)

detect_hw() {
    # ── CPU 厂商 ──
    CPU_VENDOR="$(sed -n 's/^vendor_id[[:space:]]*: *//p' /proc/cpuinfo 2>/dev/null | head -1)"

    # ── 显卡: 用 lspci 找 VGA/3D 设备 ──
    local vga_line
    vga_line="$(lspci 2>/dev/null | grep -iE 'VGA compatible|3D controller|Display controller' | head -1)"
    GPU_MODEL="$(printf '%s' "$vga_line" | sed -E 's/^[0-9a-f:.]+ +//; s/.*: //' 2>/dev/null)"

    if printf '%s' "$vga_line" | grep -qi "nvidia"; then
        GPU_VENDOR="nvidia"; GPU_IS_APU=0
    elif printf '%s' "$vga_line" | grep -qi "intel"; then
        # 注意顺序: 先判 intel, 再判 amd。intel 核显描述含 "Integrated" 等,
        # 若 amd 正则含 "ati" 会误命中 "compatible/Integrated"。故 amd 只认 AMD/Radeon。
        GPU_VENDOR="intel"
        # Intel 核显 vs 独显: 核显固定在 PCI 地址 00:02.x(总线0/设备2),
        # 独显(Arc A/B 系列)在别的槽位(如 03:00.0)。比 "Display controller" 描述更可靠
        # (描述会随内核版本变化, 但 00:02.0 是 Intel 核显的固定锚点)。
        if printf '%s' "$vga_line" | grep -qE '^00:02\.[0-9]'; then
            GPU_IS_APU=1
        else
            GPU_IS_APU=0   # 非 00:02.0 → 独立显卡
        fi
        # Panther Lake 检测: Xe3 核显(Arc B370/B380/B390)支持硬件 XeSS(XMX 单元)。
        # 注意: B570/B580/B770 是 Battlemage 独立显卡(Xe2), 不是 Panther Lake,
        # 故只认 B3xx + 核显位置(00:02.x)。Device ID 0xB080~0xB086 是 Panther Lake。
        IS_PANTHER=0
        if [ "$GPU_IS_APU" -eq 1 ] && printf '%s' "$GPU_MODEL" | grep -qiE "Panther|Xe3|Arc B3[0-9]|B370|B380|B390|Core Ultra (X|2|3)"; then
            IS_PANTHER=1
        fi
    elif printf '%s' "$vga_line" | grep -qiE "advanced micro devices|\[amd|radeon"; then
        GPU_VENDOR="amd"
        # AMD 独立显卡 vs APU 集成显卡: 桌面 RX 6000/7000 是独显; APU 集成(8060S/780M)
        # 型号通常不带 "RX xxxx" 桌面命名。
        if printf '%s' "$GPU_MODEL" | grep -qiE "RX [0-9]{4}|Radeon RX|Navi|7900|7800|7700|7600|6900|6800|6700|6600"; then
            GPU_IS_APU=0   # 桌面独立显卡
        else
            GPU_IS_APU=1   # 大概率 APU/核显
        fi
    else
        GPU_VENDOR=""
    fi

    # ── GPD Win5 检测(背键 HID 是最硬证据, DMI 次之) ──
    IS_WIN5=0
    local DMI_VENDOR DMI_PRODUCT BK_HID=""
    DMI_VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"
    DMI_PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
    for _d in /sys/class/hidraw/hidraw*; do
        if grep -q "HID_ID=0003:00002F24:00000137" "$_d/device/uevent" 2>/dev/null; then
            BK_HID="$_d"; break
        fi
    done
    if echo "$DMI_VENDOR" | grep -qi "GPD" && echo "$DMI_PRODUCT" | grep -qiE "G1618-05|Win ?5"; then
        IS_WIN5=1
    elif [ -n "$BK_HID" ]; then
        IS_WIN5=1
    fi
}

# ===========================================================================
#  设备画像(统一机型分类) —— 本项目主目标: AMD核显掌机(GPD Win5)
# ---------------------------------------------------------------------------
#  画像取值(DEVICE_PROFILE):
#    amd-handheld-gpdwin5   AMD核显掌机·GPD Win5  —— 主目标, 全功能(含背键)
#    amd-handheld           AMD核显掌机(其它品牌) —— 全功能, 机型专属件自动跳过
#    amd-desktop            AMD 台式主机(独显或APU/迷你主机) —— 掌机件自动跳过
#    intel-handheld         Intel核显掌机(如 MSI Claw) —— 官方 SteamOS 不支持 → 引导 Bazzite
#    intel-nvidia-desktop   Intel+NVIDIA 台式主机 —— 官方 SteamOS 不支持 → 引导 Bazzite
#    unknown                其它组合 —— 各步骤按自身判据取舍, 欢迎扩充 profile_extra
#  支持度(PROFILE_SUPPORT): full=全功能 / partial=部分 / bazzite=装不了官方 SteamOS
#
#  【未来维护入口】给新机型做适配: 只在 profile_extra() 的 case 里加分支,
#  写该机型专属的修补/参数; 各步骤保持只认 IS_WIN5 / GPU_IS_APU 等底层判据,
#  不散落机型 if —— 避免逻辑碎片化。
# ===========================================================================
DEVICE_PROFILE=""; DEVICE_PROFILE_DESC=""; PROFILE_SUPPORT=""; PROFILE_HINT=""

device_profile() {
    # 掌机证据链(按可靠度排序): ①Win5 专属背键 HID ②已知掌机品牌(DMI) ③电池存在
    # ⚠️ 电池只是辅助信号, 不能当硬证据 —— 部分掌机电池可拆卸(如 GPD Win5),
    #    拔电池运行时 HAS_BAT=0, 此时必须靠 ①② 判定; ③仅兜底未知品牌的便携设备
    local HAS_BAT=0 _ps
    for _ps in /sys/class/power_supply/*; do
        [ -e "$_ps" ] || continue
        case "$(basename "$_ps")" in BAT*|bat*) HAS_BAT=1; break ;; esac
    done
    local DMI_VENDOR DMI_PRODUCT KNOWN_HANDHELD=0
    DMI_VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"
    DMI_PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
    echo "$DMI_VENDOR $DMI_PRODUCT" | grep -qiE \
        "GPD|AYANEO|ONE-NETBOOK|OneXPlayer|ANBERNIC|VALVE|Steam Deck|ROG Ally|LEGION Go|Claw" \
        && KNOWN_HANDHELD=1
    [ "$IS_WIN5" -eq 1 ] && KNOWN_HANDHELD=1

    if [ "$GPU_VENDOR" = "amd" ]; then
        if [ "$GPU_IS_APU" -eq 1 ] && { [ "$IS_WIN5" -eq 1 ] || [ "$KNOWN_HANDHELD" -eq 1 ] || [ "$HAS_BAT" -eq 1 ]; }; then
            if [ "$IS_WIN5" -eq 1 ]; then
                DEVICE_PROFILE="amd-handheld-gpdwin5"
                DEVICE_PROFILE_DESC="AMD核显掌机·GPD Win5(本项目主目标, 全功能)"
                PROFILE_SUPPORT="full"; PROFILE_HINT=""
            else
                DEVICE_PROFILE="amd-handheld"
                DEVICE_PROFILE_DESC="AMD核显掌机(${DMI_VENDOR:-未知} ${DMI_PRODUCT:-}; 背键等机型专属件自动跳过)"
                PROFILE_SUPPORT="full"; PROFILE_HINT=""
            fi
        else
            DEVICE_PROFILE="amd-desktop"
            DEVICE_PROFILE_DESC="AMD 台式主机(${GPU_MODEL:-AMD平台}; 掌机专属件自动跳过, TDP 按独显判据处理)"
            PROFILE_SUPPORT="full"; PROFILE_HINT=""
        fi
    elif [ "$GPU_VENDOR" = "intel" ] && [ "$GPU_IS_APU" -eq 1 ]; then
        DEVICE_PROFILE="intel-handheld"
        DEVICE_PROFILE_DESC="Intel核显掌机/便携(${DMI_VENDOR:-未知} ${DMI_PRODUCT:-} ${GPU_MODEL:-})"
        PROFILE_SUPPORT="bazzite"
        PROFILE_HINT="官方 SteamOS 仅支持 AMD GPU。建议改用 Bazzite(对 Intel 核显友好); 本脚本仅 --status/参考价值"
    elif [ "$GPU_VENDOR" = "nvidia" ] && [ "$CPU_VENDOR" = "GenuineIntel" ]; then
        DEVICE_PROFILE="intel-nvidia-desktop"
        DEVICE_PROFILE_DESC="Intel+NVIDIA 台式主机(${GPU_MODEL:-N卡})"
        PROFILE_SUPPORT="bazzite"
        PROFILE_HINT="官方 SteamOS 不支持 NVIDIA。建议改用 Bazzite(支持 N 卡 + DLSS); 本脚本仅 --status/参考价值"
    else
        DEVICE_PROFILE="unknown"
        DEVICE_PROFILE_DESC="未归类组合(CPU:${CPU_VENDOR:-?} / GPU:${GPU_MODEL:-?})"
        PROFILE_SUPPORT="partial"
        PROFILE_HINT="组合较罕见: 各步骤会按自身判据自动取舍; 新机型适配请在 profile_extra() 加分支"
    fi
}

# ── 各机型适配挂载点(未来维护入口, 保持为空壳) ──
profile_extra() {
    case "$DEVICE_PROFILE" in
        # amd-handheld-gpdwin5) : Win5 专属微调(已由步骤[4]覆盖, 此处留空示范) ;;
        # amd-desktop)          : 例: 桌面独显专属的 extra ;;
        # intel-handheld)       : 例: Intel 显卡环境变量/固件补丁 ;;
        *) : ;;
    esac
}

show_device() {
    detect_hw; device_profile
    echo "════════ 设备画像 (bash steamos-setup.sh --device 可随时复查) ════════"
    printf "  画像   : %s\n" "$DEVICE_PROFILE"
    printf "  说明   : %s\n" "$DEVICE_PROFILE_DESC"
    printf "  CPU    : %s\n" "${CPU_VENDOR:-未知}"
    printf "  GPU    : %s (%s)\n" "${GPU_MODEL:-未知}" "$([ "$GPU_IS_APU" -eq 1 ] && echo 核显/APU || echo 独立显卡)"
    printf "  支持度 : %s\n" "$PROFILE_SUPPORT"
    [ -n "$PROFILE_HINT" ] && printf "  提示   : %s\n" "$PROFILE_HINT"
    printf "  细节   : Win5=%s PantherLake=%s 电池=%s\n" "$IS_WIN5" "$IS_PANTHER" "$([ -n "$(ls /sys/class/power_supply/BAT* 2>/dev/null)" ] && echo 有 || echo 无)"
    exit 0
}

# 首次执行一次检测(供 --status / 各步骤使用)
detect_hw
device_profile

# ---------- 帮助 ----------
show_help() {
    awk 'NR==1 {next} { if ($0 !~ /^#/) exit; sub(/^#+ ?/, ""); print }' "$0"
    echo
    echo "步骤: 1/cn=archlinuxcn  2/im=输入法(已禁用)  3/wb=WorkBuddy  4/backkey=GPD背键  5/decky(Decky+预置插件)  6/games=游戏  7/dsh=DeepSeek Harness  8/clean=rootfs瘦身  9/tdp=TDP控制(SimpleDeckyTDP)  10/ntp=换境内NTP(加速开机)  11/gpu=GPU加速建议(DLSS/FSR)  12/selfheal=升级后自愈服务"
    echo "设备画像: --device 只检测本机机型(免root): AMD掌机/AMD台式/Intel掌机/Intel+N卡台式"
    echo "断点续传: 直接重跑即可(已完好的步骤自动跳过, 被系统升级冲掉的会自动重建)"
    echo "         --reset 清进度; FORCE=1 或 --force 强制重跑"
    echo "         --after-upgrade (等价 restore): 升级后一键恢复, 自动检测版本变化并重建被覆盖的配置"
    echo "         --adopt 只检测不安装: 把本机已达标的步骤登记为完成(机器已配好时用它打底)"
    echo "设备检测: 自动识别 GPD Win5 / AMD台式 / N卡机器 / Intel核显(含 Panther Lake), 各步骤据此路由"
    echo "         第[4]步背键只在 Win5 上执行(WIN5_FORCE=1 强跑); 第[9]步TDP只在 APU/核显上执行"
    echo "         第[11]步 gpu: AMD 机提示 FSR, N 卡机提示 DLSS(并引导用 Bazzite, 官方 SteamOS 不支持 N 卡),"
    echo "         Intel Panther Lake(Xe3) 提示 XeSS 硬件加速"
    echo "第[12]步 selfheal: 部署系统升级后自愈服务(SteamOS 大版本升级会冲掉 /etc 下的系统级修改,"
    echo "         本步放一个 user 服务在 /home, 开机自动重建被冲掉的背键/inputplumber/NTP/IME)"
    echo "         (非 systemd / /etc 只读的环境会被拦下, 确认环境无误可 SKIP_ENV_CHECK=1)"
    echo "输入法: [2]步已于2026-09-24禁用(不动系统输入法); WorkBuddy 自身的 IME 适配见下"
    echo "WorkBuddy 输入法适配: WB_IME=wayland(默认,text-input-v1) | wayland3 | x11(退到XWayland,最稳)"
    echo "  若 WorkBuddy 不能输入: 依次试 WB_IME=wayland3 / WB_IME=x11 重跑第[3]步"
    echo "  x11 模式需 GTK_IM_MODULE=ibus: 原[2]步已禁用, 需自行补环境变量(一般用默认 wayland 即可)"
    echo "TDP 默认档位(第[9]步): TDP_AC=插电W TDP_DC=离电W  例: TDP_AC=75 TDP_DC=40 sudo bash $SCRIPT_NAME 9"
    echo "NTP 服务器(第[10]步): NTP_SERVERS='ntp.aliyun.com ntp.tencent.com'  例: sudo bash $SCRIPT_NAME 10"
    echo "Decky 预置插件(第[5]步): DECKY_PLUGINS=\"SteamGridDB ProtonDB Badges\"(默认) | 空格分隔装多个 | DECKY_PLUGINS=\"\" 跳过"
    exit 0
}

# ---------- 仅在 /home 写文件的辅助(不碰 rootfs) ----------
homedir() { mkdir -p "$REAL_HOME/$1" 2>/dev/null; chown -R "$REAL_USER:$REAL_GROUP" "$REAL_HOME/$1" 2>/dev/null; echo "$REAL_HOME/$1"; }

# ---------- 断点续传: 步骤进度 ----------
# 进度放 /home(rootfs 只有 5G 且会被系统更新洗掉)。
# ⚠️ 关键设计: 光看退出码不够 —— 本脚本历史上"命令失败也打印[✓]", 退出码会骗人。
#    故每步跑完还要过一遍 verify_step() 的**落地复核**, 两者都过才算完成、才写进度。
STATE_FILE="${STATE_FILE:-$REAL_HOME/.cache/steamos-setup/state}"
FORCE="${FORCE:-0}"
state_init() {
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
    touch "$STATE_FILE" 2>/dev/null
    chown "$REAL_USER:$REAL_GROUP" "$STATE_FILE" 2>/dev/null
}
state_get()  { [ -f "$STATE_FILE" ] || return 0; sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | tail -1; }
state_done() { local v; v="$(state_get "$1")"; [ -n "$v" ]; }
state_mark() {
    state_init
    local tmp="$STATE_FILE.tmp.$$"
    grep -v "^$1=" "$STATE_FILE" 2>/dev/null > "$tmp"
    echo "$1=${2:-$(date '+%Y-%m-%d %H:%M:%S')}" >> "$tmp"
    mv -f "$tmp" "$STATE_FILE"
    chown "$REAL_USER:$REAL_GROUP" "$STATE_FILE" 2>/dev/null
}
state_reset() { rm -f "$STATE_FILE"; info "已清除进度记录: $STATE_FILE"; }
step_label() {
    case "$1" in
        setup_cn)       echo "1 archlinuxcn 源" ;;
        setup_im)       echo "2 输入法(已禁用)" ;;
        setup_wb)       echo "3 WorkBuddy" ;;
        setup_backkey)  echo "4 GPD Win5 背键" ;;
        setup_decky)    echo "5 Decky Loader" ;;
        setup_games)    echo "6 GE-Proton/游戏" ;;
        setup_dsh)      echo "7 dsh" ;;
        clean_rootfs)   echo "8 rootfs 瘦身" ;;
        setup_tdp)      echo "9 TDP 控制(SimpleDeckyTDP)" ;;
        setup_ntp)      echo "10 换境内 NTP(加速开机)" ;;
        setup_gpu)      echo "11 GPU 加速建议(DLSS/FSR)" ;;
        setup_selfheal) echo "12 升级后自愈服务" ;;
        *)              echo "$1" ;;
    esac
}
# 落地复核: 真正检查东西在不在, 而不是信退出码
verify_step() {
    case "$1" in
        setup_cn)      grep -qE '^\s*\[archlinuxcn\]' /etc/pacman.conf 2>/dev/null ;;
        # 光查 pacman 数据库不够!
        # /var/lib/pacman 在 p7(独立分区, 升级幸存), 而包文件在 /usr(p5, 被整块换掉)。
        # 两者会脱节: 数据库说"装了"但文件其实已被新镜像覆盖。
        # 故凡 pacman 类步骤, 一律 "数据库 + 关键文件" 双判据。
        setup_im)      return 0 ;;   # 步骤2已于2026-09-24禁用(不动系统输入法), 恒视为完成
        setup_wb)      pacman -Qq workbuddy >/dev/null 2>&1 && [ -x /usr/bin/workbuddy ] ;;
        setup_backkey) local _v; _v="$(state_get setup_backkey)"
                       case "$_v" in skipped*) return 0 ;; esac
                       [ -f /etc/systemd/system/gpd-win5-backkeys.service ] && \
                       [ -f /etc/inputplumber/devices.d/20-gpd_win5.yaml ] ;;
        # 光有二进制不算装完(可能只是下载了), 必须连 systemd unit 一起在
        setup_decky)   [ -x "$REAL_HOME/homebrew/services/PluginLoader" ] && \
                       [ -f /etc/systemd/system/plugin_loader.service ] ;;
        # 认"任一自定义兼容层"而非只认 GE-Proton: 只装了 dwproton(终末地 ACE 必需)
        # 而没装 GE-Proton 的机器, 若只判 GE-Proton 会每次都误判缺失、白白重下一次。
        setup_games)   ls -d "$REAL_HOME/.local/share/Steam/compatibilitytools.d/"*/ \
                            "$REAL_HOME/.steam/steam/compatibilitytools.d/"*/ >/dev/null 2>&1 ;;
        setup_dsh)     [ -x "$REAL_HOME/.local/bin/dsh" ] || [ -x /usr/bin/dsh ] ;;   # 新旧布局都认
        # skipped 也要算达标(本机不适用), 否则 --adopt 后重跑会因"未完成"反复装
        setup_tdp)     local _tv; _tv="$(state_get setup_tdp)"
                       case "$_tv" in skipped*) return 0 ;; esac
                       [ -d "$REAL_HOME/homebrew/plugins/SimpleDeckyTDP" ] && \
                       [ -f "$REAL_HOME/homebrew/plugins/SimpleDeckyTDP/package.json" ] ;;
        setup_ntp)     [ -f /etc/systemd/timesyncd.conf.d/ntp.conf ] && \
                       grep -qE 'NTP=.*(aliyun|tencent)' /etc/systemd/timesyncd.conf.d/ntp.conf 2>/dev/null ;;
        setup_gpu)     return 0 ;;   # 纯提示步骤, 无落地物, 恒视为完成
        # 注意: 光查 /home 下两个文件不够 —— sudoers 在 /etc, 升级必被冲;
        # 少了它自愈服务起得来但没权限重建 /etc 下的东西(等于自愈失效)。
        setup_selfheal) [ -f "$REAL_HOME/.config/systemd/user/steamos-self-heal.service" ] && \
                        [ -f "$REAL_HOME/.local/opt/steamos-self-heal/self-heal-after-upgrade.sh" ] && \
                        [ -f /etc/sudoers.d/steamos-self-heal ] ;;
        clean_rootfs)  return 0 ;;
        *)             return 0 ;;
    esac
}

# ===========================================================================
#  [0] 环境准备
# ===========================================================================
prepare() {
    if [ "$(id -u)" -ne 0 ]; then
        warn "需要管理员权限(密码在终端输入), 重新以 sudo 运行..."
        # 不能用 "$@": 各步骤函数是 `prepare "$@"`, 那是**函数自己的参数**
        # (主循环用 "$fn" 调用时不带参 → 为空), 会把 --after-upgrade 之类的
        # 标志丢掉。改用脚本启动时保存的原始参数。
        exec sudo -E bash "$0" "${ORIG_ARGS[@]}"
    fi
    step "环境准备"

    for c in pacman curl tar jq python3; do
        command -v "$c" >/dev/null 2>&1 || { err "缺少基础命令: $c"; exit 1; }
    done
    info "基础命令齐全"

    # ── 环境硬校验 ──
    # 教训: 在容器/受限沙箱里跑本脚本, /etc 只读、也没有 systemd, 每条命令都失败,
    #       但脚本照样刷 [✓] → 全是假成功, 排查时极浪费时间。这里直接拦死。
    if [ "${SKIP_ENV_CHECK:-0}" -ne 1 ]; then
        local ENV_FATAL=0
        if [ ! -d /run/systemd/system ] && ! systemctl list-unit-files >/dev/null 2>&1; then
            err "未检测到运行中的 systemd(PID1 不是 systemd)"
            err "本脚本要装 systemd 服务 / udev 规则, 在这个环境里跑只会得到假成功。"
            ENV_FATAL=1
        fi
        if ! touch /etc/.steamos-setup.wtest 2>/dev/null; then
            err "/etc 不可写(只读根没解除, 或在只读容器里)"
            err "先执行: sudo steamos-readonly disable"
            ENV_FATAL=1
        else
            rm -f /etc/.steamos-setup.wtest
        fi
        if [ "$ENV_FATAL" -eq 1 ]; then
            err "环境校验未通过。确认环境没问题可 SKIP_ENV_CHECK=1 跳过本校验。"
            exit 1
        fi
        info "环境校验: systemd 可用, /etc 可写"
    fi
    printf "  用户: %s (%s)\n  系统: %s\n" "$REAL_USER" "$REAL_HOME" \
        "$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2-)"

    # ── 设备画像与机型门禁(装前检测) ──
    detect_hw; device_profile
    echo "  设备画像: $DEVICE_PROFILE — $DEVICE_PROFILE_DESC"
    profile_extra    # 机型专属适配挂载点(当前为空, 未来维护入口)
    if [ "$PROFILE_SUPPORT" = "bazzite" ] && [ "${SKIP_DEVICE_GATE:-0}" -ne 1 ]; then
        echo
        warn "本机型装不了官方 SteamOS: $PROFILE_HINT"
        if [ -t 0 ]; then
            printf "  仍要继续吗? [y/N] "
            local _ans
            read -r _ans
            case "$_ans" in
                y|Y|yes|YES) info "已确认继续(不支持项会自动跳过)" ;;
                *) err "已取消。改用 Bazzite 或加 SKIP_DEVICE_GATE=1 跳过本门禁"; exit 1 ;;
            esac
        else
            warn "非交互环境, 跳过确认(各步骤将按判据自动取舍)"
        fi
    fi
    [ "$IS_STEAMOS" -eq 1 ] && echo "  类型: Valve SteamOS(holo)  → 将解除只读根" || echo "  类型: Arch 系"

    # 1) SteamOS 只读解除
    if [ "$IS_STEAMOS" -eq 1 ]; then
        if command -v steamos-readonly >/dev/null 2>&1; then
            if ! steamos-readonly status 2>/dev/null | grep -qiE "disabled|已解除|off"; then
                sub "解除 SteamOS 只读根 (steamos-readonly disable)..."
                steamos-readonly disable || { err "解除只读失败"; exit 1; }
                info "只读已解除"
            else
                info "只读根已是可写状态"
            fi
        else
            warn "标记为 SteamOS 但无 steamos-readonly, 假定可写"
        fi
    fi

    # 2) pacman-key
    if [ ! -s /etc/pacman.d/gnupg/pubring.gpg ] || ! pacman-key --list-keys >/dev/null 2>&1; then
        sub "初始化 pacman 密钥环..."
        pacman-key --init || { err "pacman-key --init 失败"; exit 1; }
        if [ "$IS_STEAMOS" -eq 1 ]; then
            pacman-key --populate archlinux 2>/dev/null && info "populate archlinux 完成" || warn "populate archlinux 失败"
            # holo 若存在也 populate
            pacman-key --populate holo 2>/dev/null && info "populate holo 完成" || true
        else
            pacman-key --populate archlinux 2>/dev/null || warn "populate archlinux 失败"
        fi
    else
        info "pacman 密钥环就绪"
    fi

    # 3) Arch 官方仓库 core/extra(依赖它们才有 electron/输入法等)。
    #    ⚠️ 绝不能复用 SteamOS 自带的 /etc/pacman.d/mirrorlist —— 它指向
    #    steamdeck-packages.steamos.cloud, 取 core.db / extra.db 直接 404。
    #    必须自建 mirrorlist-arch(Arch 官方镜像), 并让 core/extra 只 Include 它。
    local MIRROR_ARCH="/etc/pacman.d/mirrorlist-arch"
    if [ "$IS_STEAMOS" -eq 1 ] || [ "$HAS_CORE" -eq 0 ] || [ "$HAS_EXTRA" -eq 0 ]; then
        sub "写 Arch 官方镜像列表 $MIRROR_ARCH ..."
        cat > "$MIRROR_ARCH" <<'EOF'
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF
        info "已写 $MIRROR_ARCH(清华/科大/pkgbuild)"

        # 3a) 缺失才追加(用 python 逐行处理, 绕开 sed 转义被吞的老问题)
        sub "补齐 core/extra 仓库段..."
        python3 - <<PYEOF
import re
conf = "/etc/pacman.conf"
arch_ml = "$MIRROR_ARCH"
txt = open(conf).read()
def has(h):
    return re.search(r'^\s*#?\s*\[' + re.escape(h) + r'\]', txt, re.M) is not None
add = ""
if not has("core"):
    add += "\n[core]\nInclude = %s\n" % arch_ml
if not has("extra"):
    add += "\n[extra]\nInclude = %s\n" % arch_ml
if add:
    open(conf, "a").write(add)
    print("  appended:" + add.strip().replace("\n", " "))
else:
    print("  core/extra 段已存在(可能被注释), 跳过追加")
PYEOF

        # 3b) 自愈: 把已有 core/extra 段里指向 SteamOS mirrorlist 的 Include 改对。
        #     对老脚本留下的错配置能一次性修好 404; 对已正确的配置是幂等操作。
        sub "校正 core/extra 的 Include → mirrorlist-arch..."
        python3 - <<PYEOF
import re
p = "/etc/pacman.conf"
lines = open(p).read().split("\n")
cur = None; hit = 0; out = []
for l in lines:
    m = re.match(r'^\s*#?\s*\[([^\]]+)\]', l)
    if m:
        cur = m.group(1)
    if cur in ("core", "extra") and re.match(r'^\s*Include\s*=', l) and "mirrorlist-arch" not in l:
        l = l.replace("/etc/pacman.d/mirrorlist", "/etc/pacman.d/mirrorlist-arch")
        hit += 1
    out.append(l)
open(p, "w").write("\n".join(out))
print("  修正 Include 行数: %d" % hit)
PYEOF

        # 重新评估
        grep -qE '^\s*#?\s*\[core\]'  /etc/pacman.conf && HAS_CORE=1
        grep -qE '^\s*#?\s*\[extra\]' /etc/pacman.conf && HAS_EXTRA=1
        info "core/extra 就绪(均指向 mirrorlist-arch)"
    fi

    # 3c) 快照源(SteamOS 3.9)与滚动源并存的"混源"纪律:
    #     pacman.conf 里靠前命中的仓库优先。真机已验证的安全结构是
    #     【快照源 core-3.9/extra-3.9 在前, 滚动 core/extra 在后兜底】——
    #     这样 electron/libisl 等同名包都命中快照源(版本与系统匹配), 滚动源
    #     只补快照里没有的新包。若快照源缺失或滚动源排到前面, 会混装 ABI。
    #     此处只检查并给出修复指引, 不自动重排(乱序通常意味着用户手动改过)。
    if [ "$IS_STEAMOS" -eq 1 ]; then
        local snap_pos roll_core_pos
        # 只数"激活"的段(行首无 #)。被注释的快照源不算存在 —— 否则会误判 electron 命中快照。
        snap_pos="$(awk '/^[[:space:]]*\[(extra|core)-3\.9\]/{print NR; exit}' /etc/pacman.conf)"
        roll_core_pos="$(awk '/^[[:space:]]*\[core\]/{print NR; exit}' /etc/pacman.conf)"
        if [ -z "$snap_pos" ]; then
            warn "未找到(激活的)快照源 extra-3.9/core-3.9 —— electron 等会从滚动 extra 拉, 版本可能不匹配系统。"
            warn "检查: SteamOS 重装后自带这些段, 若被注释需取消注释(位置应在滚动 core/extra 之前)。"
        elif [ -n "$roll_core_pos" ] && [ "$roll_core_pos" -lt "$snap_pos" ]; then
            warn "激活的滚动 [core]($roll_core_pos 行)排在快照源($snap_pos 行)之前 —— 同名包会优先命中滚动源, 有混源 ABI 风险。"
            warn "建议: 把末尾激活的滚动 [core]/[extra] 移到快照源(extra-3.9)之后, 保持快照优先。"
        else
            info "源顺序正确: 激活快照源在前(第$snap_pos 行), 滚动源兜底 —— electron 会命中快照源, 版本匹配。"
        fi
    fi

    # 4) 刷新
    sub "刷新仓库(pacman -Sy)..."
    if ! pacman -Sy --noconfirm >/dev/null 2>&1; then
        warn "pacman -Sy 刷新失败 —— 多半还是源的问题, 关键错误如下:"
        pacman -Sy 2>&1 | grep -iE "错误|error|404|failed" | head -6 | sed 's/^/    /'
        warn "排查: ① cat $MIRROR_ARCH ② grep -A2 '^\\[core\\]' /etc/pacman.conf ③ 网络/代理"
        warn "各步会重试; 若持续 404, 确认 core/extra 的 Include 已指向 mirrorlist-arch"
    else
        info "仓库已同步"
    fi
    info "环境准备完成"
}

# ===========================================================================
#  [1] archlinuxcn 源
# ===========================================================================
setup_cn() {
    step "[1/7] archlinuxcn 软件源"
    prepare "$@"
    # 确保官方源存在(archlinuxcn 依赖它)
    if [ "$HAS_CORE" -eq 0 ] || [ "$HAS_EXTRA" -eq 0 ]; then
        warn "缺少 Arch 官方仓库, 先运行环境准备补源"
    fi
    if [ "$HAS_ARCHLINUXCN" -eq 1 ]; then
        info "archlinuxcn 源已配置"
    else
        printf '\n[archlinuxcn]\nServer = https://repo.archlinuxcn.org/$arch\nServer = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch\nServer = https://mirrors.ustc.edu.cn/archlinuxcn/$arch\n' >> /etc/pacman.conf
        HAS_ARCHLINUXCN=1
        info "已追加 archlinuxcn 源"
    fi
    if ! pacman -Qq archlinuxcn-keyring >/dev/null 2>&1; then
        sub "安装 archlinuxcn-keyring..."
        pacman -Sy --noconfirm --needed archlinuxcn-keyring >/dev/null 2>&1 \
            || warn "archlinuxcn-keyring 安装失败(稍后重跑本步或检查源)"
    fi
    pacman -Qq archlinuxcn-keyring >/dev/null 2>&1 && info "archlinuxcn-keyring 就绪" ||
        warn "archlinuxcn-keyring 未能确认(可能影响后续 AUR/装包)"
    pacman -Sl archlinuxcn >/dev/null 2>&1 && info "archlinuxcn 仓库可查" || warn "archlinuxcn 仓库同步异常"
}

# ===========================================================================
#  [2] IBus —— SteamOS 原生输入法(Wayland 原生前端)
#
#  SteamOS(holo) 自带 ibus, 且 kwinrc 的 [Wayland] InputMethod 默认就指向
#  IBus 的 Wayland 面板 —— 所以直接用原生方案, 不再装 fcitx5。
#
#  三个关键点(与旧的 fcitx5 方案相反, 别再照抄老教程):
#   1) 不设 GTK_IM_MODULE / QT_IM_MODULE —— 让 GTK/Qt 走 Wayland 原生
#      text-input 前端。设了反而会触发"应使用 Wayland 输入法前端"的警告,
#      并导致 Wayland 下候选框闪烁。
#   2) 只设 XMODIFIERS=@im=ibus —— 供 XWayland 应用(Steam 客户端等)走 XIM。
#   3) 屏蔽系统级 /etc/xdg/autostart/ibus.desktop。它会用
#      "ibus-daemon --panel=/usr/lib/kimpanel-ibus-panel" 独立拉起 daemon,
#      破坏"ibus-daemon 必须是 ibus-ui-gtk3 的子进程"这一要求并触发警告。
#      正确链路: KWin → IBus Wayland 面板 → ibus-ui-gtk3 → ibus-daemon。
#
#  中文引擎由环境变量 IBUS_ENGINE 选择(默认 libpinyin):
#    libpinyin → ibus-libpinyin (extra 官方源, 支持小鹤双拼)
#    rime      → ibus-rime      (archlinuxcn/AUR, 与 fcitx5-rime 词库通用)
#    pinyin    → ibus-pinyin    (SteamOS 自带, 最省事)
# ===========================================================================
# ===========================================================================
#  [2] 输入法 —— 已禁用 (2026-09-24)
#  用户要求: 不改动原系统(SteamOS)输入法相关的任何内容。
#  原实现(IBus 安装/环境变量/autostart 屏蔽/kwinrc/dconf)完整存档于:
#      disabled/setup_im.disabled.sh  (仅留档, 不会被任何路径执行)
#  保留函数壳与参数映射: bash steamos-setup.sh 2 会打印说明后跳过,
#  全量运行 / 断点续传 / 落地复核 / --adopt 均正常工作。
# ===========================================================================
setup_im() {
    step "[2/7] 输入法 —— 已禁用"
    info "按 2026-09-24 要求跳过: 不改动系统输入法相关内容"
    return 0
}
OPT_OFFLOAD=0
rootfs_report() {
    local avail_kb opt_src root_src
    avail_kb="$(df -Pk / | awk 'NR==2{print $4}')"
    opt_src="$(findmnt -no SOURCE --target /opt 2>/dev/null)"
    root_src="$(findmnt -no SOURCE / 2>/dev/null)"
    printf "  rootfs 可用: %sMB (设备 %s)\n" "$((avail_kb/1024))" "$root_src"
    if [ -n "$opt_src" ] && [ "$opt_src" != "$root_src" ]; then
        info "/opt 独立挂载($opt_src) → /opt 下的体积不计入 rootfs"
        OPT_OFFLOAD=1
    else
        warn "/opt 与 / 同一文件系统 → /opt 下的体积会占 rootfs"
        OPT_OFFLOAD=0
    fi
    if [ "$(stat -fc %T / 2>/dev/null)" = "btrfs" ] && command -v btrfs >/dev/null 2>&1; then
        local bu
        bu="$(btrfs filesystem usage / 2>/dev/null | grep -E 'Device unallocated|Free \(estimated\)' | tr -s ' ' | sed 's/^ */    /')"
        [ -n "$bu" ] && echo "$bu"
        warn "btrfs 若 Device unallocated 接近 0, 写满会直接 ENOSPC(而非空间不足提示)"
    fi
}

clean_rootfs() {
    step "[8] rootfs 瘦身"
    if [ "$(id -u)" -ne 0 ]; then
        warn "需要管理员权限(密码在终端输入), 重新以 sudo 运行..."
        exec sudo -E bash "$0" clean
    fi
    local before after
    before="$(df -Pk / | awk 'NR==2{print $4}')"
    rootfs_report

    # ① locale —— 最安全, 本机实测回收约 250M
    sub "清理 /usr/share/locale(仅保留 zh_CN/zh_TW/en_US/en_GB)..."
    if [ -d /usr/share/locale ]; then
        find /usr/share/locale -mindepth 1 -maxdepth 1 \
             ! -name 'zh_CN' ! -name 'zh_TW' ! -name 'en_US' ! -name 'en_GB' \
             ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null
        info "locale 剩余: $(du -sh /usr/share/locale 2>/dev/null | cut -f1)"
    fi

    # ② man / doc —— 安全, 几十 M
    sub "清理 /usr/share/man 与 /usr/share/doc..."
    rm -rf /usr/share/man/* /usr/share/doc/* 2>/dev/null
    info "man=$(du -sh /usr/share/man 2>/dev/null | cut -f1) doc=$(du -sh /usr/share/doc 2>/dev/null | cut -f1)"

    # ③ pacman 缓存
    sub "清理 pacman 缓存..."
    pacman -Scc --noconfirm >/dev/null 2>&1 && info "缓存已清" || warn "清缓存失败(可忽略)"

    after="$(df -Pk / | awk 'NR==2{print $4}')"
    info "回收约 $(( (after - before) / 1024 ))MB, 当前可用 $((after/1024))MB"

    echo
    sub "其他可回收项(脚本不自动删, 自行判断):"
    for d in /usr/share/fonts /usr/share/icons /usr/lib/modules /usr/lib/firmware; do
        [ -d "$d" ] && printf "    %-8s %s\n" "$(du -sh "$d" 2>/dev/null | cut -f1)" "$d"
    done
    echo "    ⚠️ 绝不能动: /usr/lib/firmware(硬件要) /usr/lib32(Proton 依赖) /usr/lib/steam(Steam 本体)"
    local kcount
    kcount="$(ls -1 /usr/lib/modules 2>/dev/null | wc -l)"
    if [ "$kcount" -gt 1 ]; then
        warn "存在 $kcount 个内核(每个 100~200M):"
        du -sh /usr/lib/modules/* 2>/dev/null | sed 's/^/    /'
        warn "删旧内核请用 pacman -R(手动 rm 会让 pacman 数据库错乱)"
    fi
}
# ===========================================================================
#  [3] WorkBuddy (AUR 包)  — 最可靠能打中文的方案(用户选定)
#  AUR workbuddy 已处理好 asar/原生模块; 依赖系统 electron(装 /usr, extra 源)。
#  ⚠️ 中文输入真正根因是 KWin 未配 InputMethod(见 [2] setup_im 的 kwinrc 修复),
#     所有 Wayland 应用(含 WorkBuddy)都靠它。此处对 wrapper 加 wayland-ime 参数
#     仅是让 Electron 走原生 Wayland 的无害加固(非必需), 与 setup_im 配合使用。
# ===========================================================================
setup_wb() {
    step "[3/7] WorkBuddy (AUR 包, 最可靠能打中文)"
    prepare "$@"

    # ── rootfs 空间预检 ──
    # 只算真正落 /usr 的部分: 编译最小集(约 229M) + electron 依赖(约 349M) ≈ 580M,
    # 再留 200M 缓冲 → 目标约 768M。/opt 若已 offload 到 /home 分区则不计入。
    #
    # ⚠️ 修正(2026-09-08): 上面是"从零安装"口径, 重装后二次运行时这些早已在盘上,
    #    真实增量接近 0, 却被 768M 硬门槛误拦(实测 rootfs 剩 717M 被拦、且瘦身已无
    #    可回收项, 陷入死循环)。改为【自适应】: 只累加尚未安装的部分 + 固定缓冲。
    sub "预检 rootfs 空间..."
    rootfs_report
    local avail_kb need_kb
    avail_kb="$(df -Pk / | awk 'NR==2{print $4}')"

    local BD_MIN="make gcc binutils pkgconf fakeroot debugedit"
    local buffer_kb=204800                  # 200MB 缓冲(btrfs 未分配空间接近 0 时留余量)
    need_kb=$buffer_kb
    local -a need_items=("固定缓冲 200M")
    if [ "${OPT_OFFLOAD:-0}" -ne 1 ]; then
        need_kb=$(( need_kb + 838860 ))     # WorkBuddy 本体约 818M 会落 /usr
        need_items+=("WorkBuddy 本体 818M(/opt 未 offload)")
    else
        info "/opt 已 offload → WorkBuddy 本体体积不计入 rootfs"
    fi
    if pacman -Q electron >/dev/null 2>&1; then
        info "electron 已装 → 不计入需求"
    else
        need_kb=$(( need_kb + 357376 ))     # 约 349M
        need_items+=("electron 约 349M(未装)")
    fi
    # shellcheck disable=SC2086  # BD_MIN 是包名列表, 分词是有意的
    if pacman -Qq $BD_MIN >/dev/null 2>&1; then
        info "最小编译集已装 → 不计入需求"
    else
        need_kb=$(( need_kb + 234496 ))     # 约 229M
        need_items+=("最小编译集 约 229M(未装)")
    fi
    sub "实际需求明细(仅未安装项 + 缓冲):"
    printf '    - %s\n' "${need_items[@]}"
    info "合计需要 $((need_kb/1024))MB"
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$need_kb" ]; then
        warn "rootfs 可用 $((avail_kb/1024))MB < 需要 $((need_kb/1024))MB"
        if [ "${ROOTFS_NOCLEAN:-0}" -ne 1 ]; then
            warn "先自动瘦身(只清 locale/man/doc/pacman 缓存 等安全项)..."
            clean_rootfs
            avail_kb="$(df -Pk / | awk 'NR==2{print $4}')"
        fi
        if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$need_kb" ]; then
            err "瘦身仍不够(现 $((avail_kb/1024))MB / 需要 $((need_kb/1024))MB)"
            warn "可选: ① pacman -R 删旧内核(每个 100~200M) ② 清理 /usr/share/fonts、icons"
            warn "      ③ 放弃 AUR 版, 改用 Flatpak/AppImage 把 WorkBuddy 装进 /home"
            if [ "${FORCE_WB:-0}" -eq 1 ]; then
                warn "FORCE_WB=1 已设置, 强行继续(btrfs 无未分配空间时有 ENOSPC 风险)"
            else
                exit 1
            fi
        fi
    fi
    info "rootfs 空间检查通过"

    # ── makepkg 构建目录挪到 /home(/tmp 是 tmpfs, 800MB deb 解包会吃内存) ──
    local MKCONF="/etc/makepkg.conf" BUILDDIR="$REAL_HOME/.cache/makepkg"
    if [ -f "$MKCONF" ] && ! grep -qE '^\s*BUILDDIR=' "$MKCONF"; then
        sub "设置 makepkg BUILDDIR=$BUILDDIR ..."
        printf '\n# 由 steamos-setup.sh 添加: /tmp 是 tmpfs, 大包构建放 /home\nBUILDDIR="%s"\n' "$BUILDDIR" >> "$MKCONF"
        mkdir -p "$BUILDDIR"
        chown -R "$REAL_USER:$REAL_GROUP" "$BUILDDIR" 2>/dev/null || true
        info "已设置(避免 makepkg 在 tmpfs /tmp 里解 800MB 包)"
    fi

    # ── 需编译工具链(AUR 需要) + git + AUR helper ──
    # ⚠️ base-devel 是"包组": pacman -Q base-devel 会把它展开为已装成员,
    #    只要装了下述最小集(gcc/make/binutils/…), 判断就判为"已装"从而跳过整组。
    #    整组约 600M, 最小集仅约 229M —— SteamOS 5GB rootfs 上差这 370M 很关键。
    #    WorkBuddy 的 AUR 本质只是解包 deb, 不需要 autoconf/automake/bison 等重家伙。
    local BD_MIN="make gcc binutils pkgconf fakeroot debugedit"
    if ! pacman -Qq base-devel >/dev/null 2>&1; then
        sub "安装编译工具链(最小集, 约 229M; 比整组 base-devel 省约 370M)..."
        # --noconfirm --needed 不交互; 大 gcc 用 --noprogressbar 避免刷屏
        # shellcheck disable=SC2086  # 同上
        pacman -S --noconfirm --needed --asdeps $BD_MIN git 2>&1 | tail -4 || {
            err "编译工具链安装失败"
            warn "若报找不到包, 请先确认快照源(extra-3.9)存在, 再跑环境准备补 core/extra。"
            warn "手工最小集: sudo pacman -S --needed --asdeps make gcc binutils pkgconf fakeroot debugedit"
            exit 1
        }
        # 装后复核: 最小集能让 pacman -Q base-devel 判为已装(组查询展开)
        pacman -Qq base-devel >/dev/null 2>&1 && info "工具链就绪(base-devel 组判定通过)" \
            || warn "最小集未让 base-devel 判定通过——手工补装后重跑本步"
    else
        info "编译工具链已就绪(base-devel 判定通过)"
    fi
    info "git: $(pacman -Qq git 2>/dev/null || echo 缺)"
    # 确认依赖 electron/asar 在仓库可及(asar 是 makedepends, electron 是 depends)
    # ⚠️ electron 是"元包"(Meta package, 体积显示 0.00K), 真实体积在其依赖的
    #    具体 electronX 版本包。下面用 pacman -S --print-format 估算整棵依赖的真实
    #    落盘体积(不含已装部分, -u 只算未装), 供空间预检参考。
    if pacman -Si electron >/dev/null 2>&1; then
        info "electron: 仓库可见(应来自 extra-3.9 快照源, 与系统版本匹配)"
    else
        warn "electron 未在仓库找到——确认已配快照源 extra-3.9(重跑环境准备)"
    fi
    pacman -Si asar >/dev/null 2>&1 && info "asar: 仓库可见(extra, 构建所需)" \
        || warn "asar(makedepends) 未在仓库找到——确认已配 extra 源"
    # 真实落盘体积估算(仅信息性; 已装则无需再算)
    if ! pacman -Q electron >/dev/null 2>&1; then
        local real_mb
        real_mb="$({ pacman -S --print-format '%s %n' electron 2>/dev/null || pacman -S --noconfirm -p --print-format '%s %n' electron 2>/dev/null; } \
                    | awk '{s+=$1} END{printf "%.0f", s/1024/1024}')"
        [ -n "$real_mb" ] && [ "$real_mb" -gt 0 ] && info "electron 真实落盘约 ${real_mb}MB(元包本身仅 0.00K, 体积在依赖的具体版本包)" \
            || warn "无法估算 electron 真实体积(仓库未同步或格式不同), 空间按保守 349M 计"
    fi
    # AUR helper(yay 优先): 官方源无 yay, 需 archlinuxcn 或 AUR 构建
    local AURHELP=""
    command -v yay >/dev/null 2>&1 && AURHELP=yay
    if [ -z "$AURHELP" ]; then
        command -v paru >/dev/null 2>&1 && AURHELP=paru
    fi
    if [ -z "$AURHELP" ]; then
        # 尝试 archlinuxcn(已由 [1] 配置); yay 在其内
        sub "尝试从 archlinuxcn 安装 yay..."
        if grep -qE '^\s*\[archlinuxcn\]' /etc/pacman.conf 2>/dev/null; then
            pacman -S --noconfirm --needed yay 2>&1 | tail -3
        fi
        command -v yay >/dev/null 2>&1 && AURHELP=yay
        if [ -z "$AURHELP" ]; then
            # 兜底: 从 AUR git 构建(在用户家目录做, 避免 /tmp 权限问题)
            sub "从 AUR 源码构建 yay(约几分钟)..."
            local YAYDIR; YAYDIR="$(homedir .cache/yay-aur-build)"
            rm -rf "$YAYDIR/yay"
            if runuser -u "$REAL_USER" -- git clone --depth 1 https://aur.archlinux.org/yay.git "$YAYDIR/yay" 2>&1 | tail -2; then
                ( cd "$YAYDIR/yay" && runuser -u "$REAL_USER" -- makepkg -si --noconfirm --needed 2>&1 | tail -5 )
            fi
            command -v yay >/dev/null 2>&1 && AURHELP=yay
        fi
        [ -n "$AURHELP" ] || { err "AUR helper 安装失败"; exit 1; }
    fi
    info "AUR helper: $AURHELP"

    # 装 workbuddy(AUR)。yay/paru 需以普通用户跑(makepkg 禁 root)。
    if ! pacman -Qq workbuddy >/dev/null 2>&1; then
        sub "从 AUR 安装 workbuddy(联网下载约 800MB deb + 解包, 需 10~20 分钟)..."
        warn "本步下载大且耗时, 请勿中途断开; 失败后重跑本步即可(幂等)。"
        # 清屏输出保留给用户看(不用 tail 吞掉, 失败也看得到原因)
        if [ "$AURHELP" = "yay" ]; then
            runuser -u "$REAL_USER" -- yay -S --noconfirm --needed \
                --answerclean=N --answerdiff=N --answeredit=N workbuddy 2>&1
        else
            runuser -u "$REAL_USER" -- paru -S --noconfirm --needed --skipreview workbuddy 2>&1
        fi
        if ! pacman -Qq workbuddy >/dev/null 2>&1; then
            err "workbuddy 安装失败"
            warn "常见原因与排查:"
            warn "  ① 网络无法下载 800MB deb(codebuddy CDN) → 检查网络后重跑本步"
            warn "  ② base-devel/asar/electron 未装 → 先跑环境准备确认 extra 源"
            warn "  ③ 磁盘空间不足 → 上一步已预检, 若仍失败查看 df -h /"
            exit 1
        fi
    fi
    info "WorkBuddy: $(pacman -Q workbuddy 2>/dev/null)"

    # 修复 wrapper 的 IME 参数(AUR 每次升级会冲掉, 需重写)
    #
    # ⚠️ Electron/Chromium 在 Wayland 下输入https:// 的真实约束(踩过坑才确认):
    #   1) Electron 不支持 Gtk4, 所以 "--gtk-version=4" 这条路走不通(仅 chromium/chrome 支持)。
    #   2) 走 wayland 原生只有 "--enable-wayland-ime", 它启用的是 text-input-v1。
    #      Chromium 官方称 v1 不稳定/曾崩溃, 但对 KWin 而言它是"唯一开箱可用"的选项
    #      (fcitx5 wiki 明确: kwin 环境推荐用 --enable-wayland-ime)。
    #   3) 之前写死 "--wayland-text-input-version=3" 是错的/风险: KWin 对 v3 的协议理解
    #      有差异, 易导致候选框位置错乱。故默认改为官方推荐的 v1 组合(不带 version 参数)。
    #   4) 备选(最稳): 不加 --ozone-platform=wayland, 让 Electron 跑 XWayland,
    #      由 GTK_IM_MODULE=ibus + XMODIFIERS 走成熟路径。本机 IBus 已带 XIM(--xim)。
    #   用 WB_IME=wayland|wayland3|x11 切换; 默认 wayland。
    local WRAPPER="/usr/bin/workbuddy"
    local WB_IME_MODE="${WB_IME:-wayland}"
    local FLAGS MARKTXT
    case "$WB_IME_MODE" in
        wayland3)
            FLAGS=("--enable-features=UseOzonePlatform" "--ozone-platform=wayland"
                   "--enable-wayland-ime" "--wayland-text-input-version=3")
            MARKTXT="--wayland-text-input-version=3"
            warn "WB_IME=wayland3: 强制 text-input-v3 —— KWin 下候选框可能错位, 非必要勿用"
            ;;
        x11)
            # 走 XWayland: 靠 GTK_IM_MODULE=ibus + XMODIFIERS=@im=ibus
            FLAGS=()
            MARKTXT="WB_IME_MODE_XWAYLAND"
            info "WB_IME=x11: 走 XWayland + GTK_IM_MODULE=ibus(最成熟路径)"
            ;;
        *)
            FLAGS=("--enable-features=UseOzonePlatform" "--ozone-platform=wayland"
                   "--enable-wayland-ime")
            MARKTXT="--enable-wayland-ime"
            info "WB_IME=wayland: text-input-v1(KWin/Electron 官方推荐组合)"
            ;;
    esac
    if [ -f "$WRAPPER" ]; then
        sub "确保 workbuddy wrapper 含正确的 IME 参数..."
        if [ ! -f "${WRAPPER}.orig.bak" ]; then
            cp -a "$WRAPPER" "${WRAPPER}.orig.bak" 2>/dev/null || true
        fi
        # 从 orig 重建, 避免重复叠加参数(每次跑都追加会越来越长)
        if [ -f "${WRAPPER}.orig.bak" ]; then
            cp -a "${WRAPPER}.orig.bak" "$WRAPPER"
        else
            printf '#!/usr/bin/bash\nexec electron /opt/WorkBuddy/app.asar.unpacked "$@"\n' > "$WRAPPER"
        fi
        if [ "$WB_IME_MODE" = "x11" ]; then
            # XWayland 模式: 不注入 ozone 参数, 保证跑在 X11/XWayland 上
            info "wrapper: 保持原生(不注入 wayland 参数), 由环境 GTK_IM_MODULE/XMODIFIERS 接管"
        elif ! grep -q -- "--enable-wayland-ime" "$WRAPPER"; then
            sed -i 's#app\.asar\.unpacked#app.asar.unpacked '"${FLAGS[*]}"'#' "$WRAPPER"
            info "已写入 IME 参数(MARK: $MARKTXT)"
        else
            info "wrapper 已含 wayland-ime 参数"
        fi
        chmod 755 "$WRAPPER"
        bash -n "$WRAPPER" 2>/dev/null && info "wrapper 语法OK" || {
            warn "wrapper 语法异常, 回滚"
            [ -f "${WRAPPER}.orig.bak" ] && cp -a "${WRAPPER}.orig.bak" "$WRAPPER"
        }
        echo "当前 wrapper: $(cat "$WRAPPER")"
        if [ "$WB_IME_MODE" = "x11" ]; then
            info "x11 模式需 GTK_IM_MODULE=ibus: [2]步已禁用, 需自行补环境变量(一般用默认 wayland 即可)"
        fi
    else
        warn "未找到 $WRAPPER(AUR 安装可能异常), 跳过 IME 修复"
    fi

    cat <<EOF
  ${C_WARN}完成! 彻底退出 WorkBuddy(pkill -f WorkBuddy)后从应用菜单重开。${C_R}
  验证: 输入框 Super+Space 能出候选即成功(IBus 默认切换键)。
  若不能输入, 依次降级试:
     WB_IME=wayland3 sudo bash $SCRIPT_NAME 3     (换 text-input-v3)
     WB_IME=x11      sudo bash $SCRIPT_NAME 3     (退到 XWayland, 最稳)
EOF
}

# ===========================================================================
#  [4] GPD Win5 背键
#  (守护进程 py 放 /home, /etc 只留 systemd unit + udev + inputplumber 配置)
# ===========================================================================
setup_backkey() {
    step "[4/7] GPD Win5 背键 + InputPlumber(deck 手柄 / 背键 / Home / KB)"
    prepare "$@"

    # ── 设备检测: 换机型重装时自动跳过本步 ──
    # 判据(满足其一): ① DMI 是 GPD 且 product 属 Win5 系(G1618-05)
    #                  ② 系统里存在背键 HID(VID:PID = 2F24:0137, 最硬的证据)
    # 都不满足 → 不是 Win5(或背键硬件不在), 跳过, 不写一堆对别的机器有害的配置。
    local DMI_VENDOR DMI_PRODUCT IS_WIN5=0 BK_HID=""
    DMI_VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo unknown)"
    DMI_PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
    local _d
    for _d in /sys/class/hidraw/hidraw*; do
        [ -r "$_d/device/uevent" ] || continue
        if grep -q "HID_ID=0003:00002F24:00000137" "$_d/device/uevent" 2>/dev/null; then
            BK_HID="/dev/$(basename "$_d")"; break
        fi
    done
    printf "  机型: %s / %s    背键 HID: %s\n" "$DMI_VENDOR" "$DMI_PRODUCT" "${BK_HID:-未发现}"
    if echo "$DMI_VENDOR" | grep -qi "GPD" && echo "$DMI_PRODUCT" | grep -qiE "G1618-05|Win ?5"; then
        IS_WIN5=1; info "检测到 GPD Win5 → 配置背键"
    elif [ -n "$BK_HID" ]; then
        IS_WIN5=1; warn "DMI 不是 Win5, 但找到背键 HID($BK_HID) → 按 Win5 处理"
    fi
    if [ "$IS_WIN5" -ne 1 ] && [ "${WIN5_FORCE:-0}" -ne 1 ]; then
        warn "未检测到 GPD Win5(也没找到背键 HID 2F24:0137) → 跳过第[4]步"
        warn "确认就是 Win5 的话: WIN5_FORCE=1 sudo bash $SCRIPT_NAME 4"
        state_mark setup_backkey "skipped(非Win5: $DMI_VENDOR/$DMI_PRODUCT)"
        return 0
    fi
    [ "${WIN5_FORCE:-0}" -eq 1 ] && [ "$IS_WIN5" -ne 1 ] && \
        warn "WIN5_FORCE=1: 强制按 Win5 配置(当前机型 $DMI_VENDOR/$DMI_PRODUCT)"

    # inputplumber(SteamOS 游戏模式自带; 桌面模式若无则需装)
    if ! systemctl list-unit-files 2>/dev/null | grep -qi inputplumber && \
       ! command -v inputplumber >/dev/null 2>&1; then
        sub "尝试安装 inputplumber..."
        pacman -S --noconfirm --needed inputplumber 2>/dev/null || \
            warn "inputplumber 装不上(可能在 archlinuxcn)。若 SteamOS 游戏模式已内置可忽略"
    fi

    # 守护进程脚本放 /home
    local BK_HOME
    BK_HOME="$(homedir .local/opt/gpd-win5-backkeys)"
    local DAEMON_DST="$BK_HOME/gpd-win5-backkeys.py"
    local UNIT_PATH="/etc/systemd/system/gpd-win5-backkeys.service"
    local UDEV_RULE="/etc/udev/rules.d/70-gpd-backkeys.rules"
    local IP_CFG="/etc/inputplumber/devices.d/20-gpd_win5.yaml"
    local IP_DEFAULT="/usr/share/inputplumber/devices/50-gpd_win5.yaml"
    # inputplumber 模拟的目标手柄: deck=Steam Deck Controller(Steam 里显示为
    # Steam Controller, 可用完整布局 + 背键); xbox-elite=还原成 Xbox 手柄。
    # 可选值见 schema: mouse/keyboard/gamepad/hori-steam/xb360/xbox-elite/
    #                  xbox-series/deck/ds5/ds5-edge/touchpad/touchscreen
    local IP_TARGET="${IP_TARGET:-deck}"
    # 自定义能力表(KB 键 → QuickAccess 右侧边栏; 上游 gpd4 给的是屏幕键盘)
    local IP_CAPMAP="/etc/inputplumber/capability_maps.d/20-gpd_win5.yaml"
    local CAPMAP_SRC="${CAPMAP_SRC:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)/20-gpd_win5.capmap.yaml}"
    local SERVICE="gpd-win5-backkeys"

    sub "写入背键守护进程(到 /home)..."
    cat > "$DAEMON_DST" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GPD Win 5 背键守护进程: L4/R4 -> uinput F14/F15 (由 steamos-setup.sh 生成)"""
import glob, os, struct, sys, time
TARGET_VID, TARGET_PID = 0x2F24, 0x0137
REPORT_ID = 0x01
L4_BYTE, R4_BYTE = 9, 10
L4_CODE, R4_CODE = 0x69, 0x6A
KEY_F14, KEY_F15 = 184, 185
EV_SYN, EV_KEY = 0x00, 0x01
BUS_BLUETOOTH = 0x05
UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_SETUP, UI_DEV_CREATE = 0x405C5503, 0x5501
INPUT_EVENT = struct.Struct("llHHi")
UINPUT_NAME = "GPD Win 5 Back Buttons"
DEBUG = os.environ.get("GPD_BACKKEYS_DEBUG") == "1"

def log(m): sys.stdout.write(m + "\n"); sys.stdout.flush()

def find_hidraw():
    for path in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            with open(path + "/device/uevent") as f:
                for line in f:
                    if not line.startswith("HID_ID="): continue
                    p = line.strip().split(":")
                    if len(p) < 3: continue
                    if int(p[1][-4:] or "0", 16) == TARGET_VID and int(p[2], 16) == TARGET_PID:
                        return "/dev/" + os.path.basename(path)
        except OSError: continue
    return None

def create_uinput():
    import fcntl
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY); fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    fcntl.ioctl(fd, UI_SET_KEYBIT, KEY_F14); fcntl.ioctl(fd, UI_SET_KEYBIT, KEY_F15)
    s = struct.pack("HHHH", BUS_BLUETOOTH, TARGET_VID, 0x9001, 1)
    s += UINPUT_NAME.encode().ljust(80, b"\x00") + struct.pack("I", 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, s); fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd

def emit(fd, t, c, v): os.write(fd, INPUT_EVENT.pack(0, 0, t, c, v))
def press(fd, c): emit(fd, EV_KEY, c, 1); emit(fd, EV_SYN, 0, 0)
def release(fd, c): emit(fd, EV_KEY, c, 0); emit(fd, EV_SYN, 0, 0)

def main():
    if "--monitor" in sys.argv:
        prev = None
        while True:
            path = find_hidraw()
            if not path: log("未找到设备,2s重试"); time.sleep(2); continue
            log("监听 %s" % path)
            try: fd = os.open(path, os.O_RDONLY)
            except OSError: time.sleep(2); continue
            try:
                while True:
                    data = os.read(fd, 128)
                    if not data: break
                    if data.hex() != prev:
                        prev = data.hex(); m = []
                        if len(data) > L4_BYTE and data[L4_BYTE] == L4_CODE: m.append("L4↓")
                        if len(data) > R4_BYTE and data[R4_BYTE] == R4_CODE: m.append("R4↓")
                        log("  " + " ".join("%02x" % b for b in data[:16]) + ("  <- " + " ".join(m) if m else ""))
            except OSError: pass
            finally: os.close(fd)
            time.sleep(1)
    if os.geteuid() != 0: print("需root", file=sys.stderr); return 1
    log("GPD Win5 背键守护进程启动")
    ufd = create_uinput()
    log("uinput 键盘 %s (F14=L4 F15=R4)" % UINPUT_NAME)
    l4d = r4d = False; prevr = None
    while True:
        path = find_hidraw()
        if not path: log("未找到设备,2s重试"); time.sleep(2); continue
        log("监听 %s" % path)
        try: fd = os.open(path, os.O_RDONLY)
        except OSError as e: log("打开失败 %s" % e); time.sleep(2); continue
        try:
            while True:
                data = os.read(fd, 128)
                if not data: log("设备EOF,重发现"); break
                if DEBUG and data.hex() != prevr:
                    prevr = data.hex(); log("  report: " + " ".join("%02x" % b for b in data[:24]))
                if len(data) <= max(L4_BYTE, R4_BYTE) or data[0] != REPORT_ID: continue
                l4n, r4n = data[L4_BYTE] == L4_CODE, data[R4_BYTE] == R4_CODE
                if l4n and not l4d: log("L4↓ F14"); press(ufd, KEY_F14)
                elif not l4n and l4d: log("L4↑"); release(ufd, KEY_F14)
                l4d = l4n
                if r4n and not r4d: log("R4↓ F15"); press(ufd, KEY_F15)
                elif not r4n and r4d: log("R4↑"); release(ufd, KEY_F15)
                r4d = r4n
        except OSError as e: log("读取中断 %s" % e)
        finally: os.close(fd)
        time.sleep(1)

if __name__ == "__main__": sys.exit(main())
PYEOF
    chmod 755 "$DAEMON_DST"
    chown "$REAL_USER:$REAL_GROUP" "$DAEMON_DST" 2>/dev/null || true
    info "守护进程: $DAEMON_DST"

    sub "安装 udev 规则(/etc, 小)..."
    cat > "$UDEV_RULE" <<'EOF'
SUBSYSTEM=="input", ATTRS{name}=="GPD Win 5 Back Buttons", ENV{ID_BUS}="bluetooth"
EOF
    udevadm control --reload 2>/dev/null || true

    sub "安装 systemd 服务(/etc, 小)..."
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=GPD Win 5 back buttons (L4/R4) to uinput translator
# 切勿写 After=multi-user.target: 它与下面的 Before=inputplumber.service 以及
# WantedBy=multi-user.target 构成 ordering cycle(multi-user.target → inputplumber
# → backkeys → multi-user.target), systemd 会报 "Unable to break cycle" 并丢弃
# inputplumber 的启动任务 → 游戏模式无输入管理, 手柄退回原始 Xbox 360, 背键/Home/KB 全失效。
# After=systemd-modules-load.service 只保证 uinput 模块就绪, 处于 sysinit 阶段, 不会成环。
After=systemd-modules-load.service
# 守护进程在 /home 下, 必须等 /home 挂载完成(local-fs 阶段, 早于 multi-user, 不成环)
RequiresMountsFor=/home
Before=inputplumber.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $DAEMON_DST
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    # ── ordering cycle 自检(血泪坑, 必须留着) ──
    # 本 unit 若写成 After=multi-user.target + Before=inputplumber.service
    # + WantedBy=multi-user.target, 三者成环: systemd 报 "Unable to break cycle"
    # 后直接丢弃 inputplumber 的启动任务 → 游戏模式没有输入管理,
    # 手柄退回原始 Xbox 360, 背键/Home/KB 全部失效, 而桌面模式手动 start 却正常。
    if command -v systemd-analyze >/dev/null 2>&1; then
        local CYCLE
        CYCLE="$(systemd-analyze verify "$UNIT_PATH" 2>&1 | grep -i cycle || true)"
        if [ -n "$CYCLE" ]; then
            err "unit 依赖成环, inputplumber 不会开机启动, 必须修:"
            echo "$CYCLE" | sed 's/^/      /'
        else
            info "unit 依赖自检: 无 ordering cycle"
        fi
    fi
    systemctl enable "$SERVICE" >/dev/null 2>&1
    systemctl restart "$SERVICE" 2>/dev/null
    info "服务已装(/etc, 仅几百字节)"

    # InputPlumber 覆盖配置
    if [ -f "$IP_DEFAULT" ]; then
        sub "生成 InputPlumber 覆盖配置(/etc)..."
        mkdir -p "$(dirname "$IP_CFG")"
        python3 - "$IP_DEFAULT" "$IP_CFG" "$IP_TARGET" <<'PYEOF'
import re, sys
src, dst, target = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()
extra = ("  - group: keyboard\n    evdev:\n"
         '      name: "GPD Win 5 Back Buttons"\n'
         "      handler: event*\n")
# ── 把默认目标 xbox-elite 换成 deck ──
# 默认配置(SteamOS 自带 50-gpd_win5.yaml)的 target_devices 是 xbox-elite,
# 于是内置手柄在 Steam 里被当成 Xbox 360 手柄。改成 deck 后 inputplumber 会
# 模拟成「Steam Deck Controller」, Steam 才能按 Steam Controller 走完整布局。
# 想还原成 Xbox 手柄: sudo IP_TARGET=xbox-elite bash steamos-setup.sh 4
text, n = re.subn(r'(?m)^(\s*)-\s*xbox-elite\s*$',
                  lambda m: "%s- %s" % (m.group(1), target), text)
if n == 0:
    print("警告: 默认配置里没找到 '- xbox-elite', target_devices 未改动")
else:
    print("target_devices: xbox-elite -> %s" % target)
# ── 复合设备改用自定义能力表 gpd_win5_custom ──
# 上游 gpd4 把右下 KB 键映射成 "Keyboard"(屏幕键盘), 用户要的是右侧边栏(QAM);
# 自定义表里改成了 QuickAccess。只替换【行首无缩进】的复合级那个,
# 源设备上缩进的 capability_map_id: gpd_menu 不能动。
text, m = re.subn(r'(?m)^capability_map_id:\s*gpd4\s*$',
                  'capability_map_id: gpd_win5_custom', text)
print("复合级 capability_map_id: gpd4 -> gpd_win5_custom" if m
      else "警告: 没找到行首的 'capability_map_id: gpd4'")
out, ins = [], False
for line in text.splitlines(keepends=True):
    if not ins and line.startswith("options:"):
        out.append("# === 追加: 背键虚拟键盘 ===\n"); out.append(extra); out.append("\n"); ins = True
    out.append(line)
if not ins: sys.exit("未找到 options: 插入点")
open(dst, "w").write("".join(out))
print("已生成 %s" % dst)
PYEOF
        # 自定义能力表: /etc/inputplumber/capability_maps.d/ (inputplumber 会读该目录)
        sub "写入自定义能力表 $IP_CAPMAP ..."
        mkdir -p "$(dirname "$IP_CAPMAP")"
        if [ -f "$CAPMAP_SRC" ]; then
            install -m 644 "$CAPMAP_SRC" "$IP_CAPMAP" && info "已安装 $CAPMAP_SRC"
        elif [ -f /usr/share/inputplumber/capability_maps/gpd_type4.yaml ]; then
            # 脚本自带文件丢了也能自愈: 直接从上游 gpd4 派生 —— 改 id,
            # 并把「右下 KB 键」的目标从 Keyboard(屏幕键盘) 改成 QuickAccess(右侧边栏)。
            sub "从上游 gpd4 派生自定义表(改 id + KB 键 Keyboard→QuickAccess)..."
            python3 - /usr/share/inputplumber/capability_maps/gpd_type4.yaml "$IP_CAPMAP" <<'PYEOF'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(src))
d['id'] = 'gpd_win5_custom'
n = 0
for m in d.get('mapping', []):
    g = (m.get('target_event') or {}).get('gamepad') or {}
    if g.get('button') == 'Keyboard':
        g['button'] = 'QuickAccess'; n += 1
with open(dst, 'w') as f:
    yaml.safe_dump(d, f, allow_unicode=True, sort_keys=False)
print("  派生完成: id=gpd_win5_custom, Keyboard→QuickAccess %d 条" % n)
PYEOF
        else
            warn "既无 $CAPMAP_SRC 也无 gpd_type4.yaml, 回退写入内嵌的最小映射"
            cat > "$IP_CAPMAP" <<'CAPEOF'
version: 1
kind: CapabilityMap
name: GPD Win 5 (custom)
id: gpd_win5_custom
mapping:
  - name: L4 背键
    source_events:
      - keyboard: KeyF14
    target_event:
      gamepad:
        button: LeftPaddle1
  - name: R4 背键
    source_events:
      - keyboard: KeyF15
    target_event:
      gamepad:
        button: RightPaddle1
  - name: Home 键
    source_events:
      - keyboard: KeyLeftMeta
      - keyboard: KeyD
    target_event:
      gamepad:
        button: Guide
  - name: KB 键 -> 右侧边栏
    source_events:
      - keyboard: KeyLeftMeta
      - keyboard: KeyLeftCtrl
      - keyboard: KeyO
    target_event:
      gamepad:
        button: QuickAccess
filtered_events: []
CAPEOF
        fi
        # 写进去的东西必须能解析, 否则 inputplumber 会静默忽略(不报错)
        python3 - "$IP_CAPMAP" <<'PYEOF'
import sys, yaml
p = sys.argv[1]
try:
    d = yaml.safe_load(open(p))
    print("  能力表校验 OK: id=%s, 映射 %d 条" % (d.get('id'), len(d.get('mapping', []))))
except Exception as e:
    print("  [!] 能力表解析失败, inputplumber 会忽略它: %s" % e); sys.exit(1)
PYEOF
        systemctl restart inputplumber 2>/dev/null || warn "inputplumber 未运行(游戏模式才需要)"
        info "InputPlumber 覆盖配置已生成"
    else
        warn "无 InputPlumber 默认配置 $IP_DEFAULT; 若游戏模式已接管背键可忽略"
    fi

    sleep 2
    systemctl is-active --quiet "$SERVICE" && info "背键守护进程运行中" ||
        warn "守护进程未运行: journalctl -u $SERVICE -n 30"
    grep -qs "GPD Win 5 Back Buttons" /sys/devices/virtual/input/*/name 2>/dev/null &&
        info "uinput 虚拟键盘已创建" || warn "虚拟键盘未出现(守护进程可能没读到设备)"
    cat <<EOF
  ${C_OK}必须重启后进游戏模式验证${C_R}(inputplumber 只在游戏模式接管设备):
    sudo reboot → 设置 → 控制器 → 确认选中"内置手柄" → 按 L4/R4/Home/KB
    期望: 背键=L4/R4   Home=Steam 大菜单   KB=右侧边栏 QAM
  桌面模式自检:
    sudo systemctl start inputplumber
    sudo inputplumber devices list ; sudo inputplumber device 0 test
    busctl get-property org.shadowblip.InputPlumber \\
      /org/shadowblip/InputPlumber/CompositeDevice0 \\
      org.shadowblip.Input.CompositeDevice Name      # 应为 GPD Win5
  调试: journalctl -u $SERVICE -f   或   python3 $DAEMON_DST --monitor
  若怀疑 inputplumber 没开机启动:
    journalctl -u inputplumber -b | grep -i "ordering cycle"   ← 有输出就是依赖成环
  InputPlumber 升级后失效: rm -f $IP_CFG && 重跑本步
EOF
}

# ===========================================================================
#  [5] Decky Loader  (二进制在 /home/homebrew, /etc 只留小 unit)
# ===========================================================================
setup_decky() {
    step "[5/7] Decky Loader"
    prepare "$@"

    local SERVICE_NAME="plugin_loader"
    local UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
    local HOMEBREW_FOLDER="$REAL_HOME/homebrew"

    for c in curl jq; do command -v "$c" >/dev/null 2>&1 || { err "缺依赖 $c"; exit 1; }; done

    mkdir -p "${HOMEBREW_FOLDER}/services" "${HOMEBREW_FOLDER}/plugins"
    touch "$REAL_HOME/.steam/steam/.cef-enable-remote-debugging" 2>/dev/null || true

    local NEED_DL=1
    # ⚠️ 修正(2026-09-08): 原来只在"服务正在运行"时才跳过下载。常见场景是
    #    二进制已下好(27MB)、但 systemd 服务还没装/没起 —— 这时重跑本步会
    #    白白再下一次, 而境内直连 GitHub 极慢(实测 8 秒 0 字节), 一卡几十分钟。
    #    改为: 二进制在 + 版本文件在 → 跳过下载, 直接装服务。
    #    确实要升级时用 DECKY_FORCE=1 强制重下。
    if [ -x "${HOMEBREW_FOLDER}/services/PluginLoader" ] &&
       [ -s "${HOMEBREW_FOLDER}/services/.loader.version" ] &&
       [ "${DECKY_FORCE:-0}" -ne 1 ]; then
        NEED_DL=0
        info "PluginLoader 已存在(版本 $(cat "${HOMEBREW_FOLDER}/services/.loader.version" 2>/dev/null)), 跳过下载"
        info "  强制重新下载: sudo DECKY_FORCE=1 bash $SCRIPT_NAME decky"
    fi

    if [ "$NEED_DL" -eq 1 ]; then
        # 版本查询: 直连 GitHub API 在境内常失败 → 依次试镜像 API
        sub "查询 Decky 最新版本(GitHub)..."
        local REL VERSION DLURL
        REL=""
        for api in "https://api.github.com" "https://ghfast.top/https://api.github.com" \
                   "https://gh-proxy.com/https://api.github.com"; do
            REL="$(curl -fsS --connect-timeout 10 --max-time 30 "$api/repos/SteamDeckHomebrew/decky-loader/releases?per_page=20" 2>/dev/null)" \
                && [ -n "$REL" ] && break
        done
        [ -n "$REL" ] || { err "无法访问 GitHub API(网络/代理), 本步跳过"; warn "重试: sudo bash $SCRIPT_NAME decky"; return 0; }
        VERSION="$(jq -r 'first(.[] | select(.prerelease|not)) | .tag_name' <<<"$REL")"
        [ -n "$VERSION" ] && [ "$VERSION" != "null" ] || { err "解析版本失败"; exit 1; }
        DLURL="$(jq -r --arg v "$VERSION" \
            'first(.[]|select(.tag_name==$v))|.assets[].browser_download_url|select(endswith("PluginLoader"))' <<<"$REL")"
        [ -n "$DLURL" ] || { err "未找到 PluginLoader 资产"; exit 1; }
        info "版本 $VERSION, 开始下载..."
        rm -f "${HOMEBREW_FOLDER}/services/PluginLoader.part"   # 清掉上次中断的残片
        local ok=0 u
        # 镜像加速: 国内直连 GitHub 常失败/挂死 → 【镜像优先】+ 每个 URL 先探活。
        #   MIRROR=https://xxx 可指定自定义镜像前缀; USE_MIRROR=1 等价 MIRROR=https://ghfast.top。
        #   直连放到最后: 它一旦半死不活会拖很久, 探活也只是尽力而为。
        local -a mirrors=()
        [ -n "${MIRROR:-}" ] && mirrors+=("${MIRROR}/$DLURL")
        if [ "${USE_MIRROR:-0}" -eq 1 ] || [ -n "${MIRROR:-}" ]; then
            mirrors+=("https://ghfast.top/$DLURL" "https://gh-proxy.com/$DLURL" "https://ghproxy.net/$DLURL")
            mirrors+=("$DLURL")
        else
            mirrors+=("https://ghfast.top/$DLURL" "https://gh-proxy.com/$DLURL" "https://ghproxy.net/$DLURL" "$DLURL")
        fi
        for u in "${mirrors[@]}"; do
            sub "尝试: $u"
            if ! url_reachable "$u"; then warn "  探活失败, 换下一个"; continue; fi
            for _ in 1 2; do
                curl -fL --connect-timeout 10 --max-time 240 --retry 1 "$u" \
                    -o "${HOMEBREW_FOLDER}/services/PluginLoader.part" 2>/dev/null && {
                        mv -f "${HOMEBREW_FOLDER}/services/PluginLoader.part" \
                            "${HOMEBREW_FOLDER}/services/PluginLoader"; ok=1; break 2; }
            done
        done
        [ "$ok" -eq 1 ] || { err "下载失败; 可重试: sudo MIRROR=https://ghfast.top bash $SCRIPT_NAME decky"; exit 1; }
        chmod +x "${HOMEBREW_FOLDER}/services/PluginLoader"
        echo "$VERSION" > "${HOMEBREW_FOLDER}/services/.loader.version"
        info "PluginLoader 就绪"
    else
        info "Decky 已装并运行, 跳过下载(重跑本步=更新)"
    fi

    sub "安装 systemd 服务(/etc, 小)..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    cat > "$UNIT_PATH" <<EOF
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
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"
    chown -R "$REAL_USER:$REAL_GROUP" "$HOMEBREW_FOLDER" 2>/dev/null || true
    sleep 2
    systemctl is-active --quiet "$SERVICE_NAME" && info "plugin_loader 运行中" ||
        warn "未运行: journalctl -u $SERVICE_NAME -n 30"

    # ── 安装预置插件(Decky 装好后) ──
    # 默认装 SteamGridDB(库封面美化) + ProtonDB Badges(兼容度角标); DECKY_PLUGINS="A B" 空格分隔自定义;
    # DECKY_PLUGINS="" 显式置空则跳过。单插件失败不影响 Decky 本体与后续插件。
    local _pl _pl_failed=0
    for _pl in ${DECKY_PLUGINS-"SteamGridDB ProtonDB Badges"}; do
        install_decky_plugin "$_pl" || { warn "插件 $_pl 安装失败, 可稍后在 Decky 商店手动装"; _pl_failed=1; }
    done
    systemctl restart "$SERVICE_NAME" 2>/dev/null \
        && info "plugin_loader 已重启(加载新插件)" || warn "重启 Decky 失败(未运行?)"

    if pgrep -u "$REAL_USER" -x steam >/dev/null 2>&1 || pgrep -u "$REAL_USER" -f steam.sh >/dev/null 2>&1; then
        cat <<EOF
  ${C_WARN}Steam 运行中 —— 必须完全退出重启 Steam, Decky 才会注入。${C_R}
EOF
    else
        info "Steam 未运行, 启动 Steam 后 ... 菜单出现 Decky 图标"
    fi
}


# ---------- Decky 插件安装(走官方插件商店分发, 不依赖 GitHub Releases) ----------
# 用法: install_decky_plugin <商店名>   例: install_decky_plugin SteamGridDB
# 流程: 拉 plugins.deckbrew.xyz 清单 → 取最新版 hash/artifact → CDN 下载 zip →
#       校验 package.json → 解压到 ~/homebrew/plugins/<目录> → 修属主。
# 幂等: 已装则备份旧版再覆盖(与 SimpleDeckyTDP 同套路)。
# 说明: 商店分发源是 cdn.tzatzikiweeb.moe(非 GitHub, gh 镜像不适用); 插件包都很小
#       (几 MB), 直连重试 3 次即可。商店名可在 https://plugins.deckbrew.xyz 查。
install_decky_plugin() {
    local STORE_NAME="$1"
    local PLUGIN_DIR="$REAL_HOME/homebrew/plugins"
    local API="https://plugins.deckbrew.xyz/plugins"
    local JSON="$REAL_HOME/.cache/decky-store.json"

    step "Decky 插件: $STORE_NAME"
    sub "拉取商店清单..."
    mkdir -p "$REAL_HOME/.cache" 2>/dev/null
    if ! curl -fL --connect-timeout 10 --max-time 60 "$API" -o "$JSON" 2>/dev/null || [ ! -s "$JSON" ]; then
        err "商店清单下载失败: $API"; return 1
    fi

    local META VER HASH ART ZIPURL TMPZIP
    META="$(jq -c --arg n "$STORE_NAME" '[.[] | select(.name == $n)][0]' "$JSON" 2>/dev/null)"
    if [ -z "$META" ] || [ "$META" = "null" ]; then
        err "商店里没有名为 $STORE_NAME 的插件(名字区分大小写)"; return 1
    fi
    VER="$(printf '%s' "$META" | jq -r '.versions[0].name')"
    HASH="$(printf '%s' "$META" | jq -r '.versions[0].hash')"
    ART="$(printf '%s' "$META" | jq -r '.versions[0].artifact // empty')"
    ZIPURL="${ART:-https://cdn.tzatzikiweeb.moe/file/steam-deck-homebrew/versions/$HASH.zip}"
    info "目标版本: $VER"
    sub "下载: $ZIPURL"

    TMPZIP="$REAL_HOME/.cache/decky-plugin.$STORE_NAME.zip"
    local ok=0 i
    for i in 1 2 3; do
        if curl -fL --connect-timeout 10 --max-time 300 "$ZIPURL" -o "$TMPZIP" 2>/dev/null && [ -s "$TMPZIP" ]; then
            ok=1; info "  已下载 $(du -h "$TMPZIP" 2>/dev/null | cut -f1)"; break
        fi
        sub "  第${i}次下载失败, 重试..."
        sleep 2
    done
    [ "$ok" -eq 1 ] || { rm -f "$TMPZIP"; err "下载失败: $ZIPURL"; return 1; }

    # 校验: 不是有效 zip / 缺 package.json 都不装(防 CDN 错误页)
    if ! unzip -l "$TMPZIP" >/dev/null 2>&1 ||
       ! unzip -l "$TMPZIP" 2>/dev/null | grep -q "package.json"; then
        rm -f "$TMPZIP"; err "下载内容不是有效插件包"; return 1
    fi

    local TMPX="${TMPZIP}.x"
    rm -rf "$TMPX"; mkdir -p "$TMPX"
    unzip -q "$TMPZIP" -d "$TMPX"
    local SRC=""
    [ -f "$TMPX/package.json" ] && SRC="$TMPX"
    if [ -z "$SRC" ]; then
        SRC="$(find "$TMPX" -maxdepth 2 -name package.json -printf '%h\n' 2>/dev/null | head -1)"
    fi
    if [ -z "$SRC" ] || [ ! -f "$SRC/package.json" ]; then
        rm -rf "$TMPX" "$TMPZIP"; err "包内找不到 package.json, 结构异常"; return 1
    fi

    local DIRNAME BAKDIR
    DIRNAME="$(basename "$SRC")"
    if [ -d "$PLUGIN_DIR/$DIRNAME" ]; then
        BAKDIR="$PLUGIN_DIR/${DIRNAME}.bak.$(date +%m%d-%H%M%S)"
        mv "$PLUGIN_DIR/$DIRNAME" "$BAKDIR" && info "已备份旧版 → $BAKDIR"
    fi
    if ! mv "$SRC" "$PLUGIN_DIR/$DIRNAME"; then
        rm -rf "$TMPX" "$TMPZIP"; err "安装失败: 无法写入 $PLUGIN_DIR (权限不足?)"; return 1
    fi
    rm -rf "$TMPX" "$TMPZIP"
    # Decky 以普通用户身份读插件; 属主不对会导致界面里看不到插件
    chown -R "$REAL_USER:$REAL_GROUP" "$PLUGIN_DIR/$DIRNAME" 2>/dev/null \
        || warn "改属主失败, 若插件不显示: sudo chown -R $REAL_USER:$REAL_GROUP $PLUGIN_DIR/$DIRNAME"
    info "已安装插件: $PLUGIN_DIR/$DIRNAME ($VER)"
    return 0
}

# ===========================================================================
#  [9] TDP 控制: SimpleDeckyTDP 插件(游戏模式里分别控制插电 / 离电功耗)
# ---------------------------------------------------------------------------
#  ⚠️ 官方 SteamOS 的 QAM 性能面板**只对 Steam Deck** 提供 TDP 滑块, GPD Win5 等
#     第三方掌机不在支持列表里 → 必须靠插件。
#     SimpleDeckyTDP 自带 ryzenadj(实测 Strix Halo 上 4W~120W 可调), 且支持
#     「插电(AC)」与「离电(Battery)」两套 TDP, 插拔电源时自动切换 —— 正是本步的目的。
#  依赖: 必须先装好 Decky Loader(第[5]步)。
#  设备检测: 仅 AMD/Intel APU; 有 NVIDIA 独显则跳过(插件明确不支持)。
# ===========================================================================
setup_tdp() {
    step "[9/9] TDP 控制 (SimpleDeckyTDP 插件)"
    prepare "$@"

    local PLUGIN_DIR="$REAL_HOME/homebrew/plugins"
    local PLUGIN_NAME="SimpleDeckyTDP"
    local REPO="aarron-lee/SimpleDeckyTDP"
    local VERSION="${TDP_VERSION:-latest}"

    # ── 可配置默认档位(W) ──
    # 装完自动把插件里「插电/离电」两套默认 TDP 写成下面这两个值, 不用再手动拖滑块。
    #   TDP_AC=… 插电档(默认 75)   TDP_DC=… 离电档(默认 40)
    #   例: TDP_AC=55 TDP_DC=30 sudo bash $SCRIPT_NAME 9
    #   (RogAlly 那类"每游戏双档"机制无关; 这里写的是全局 default profile)
    local TDP_AC="${TDP_AC:-75}"
    local TDP_DC="${TDP_DC:-40}"

    # ── 设备检测 ──
    # SimpleDeckyTDP(ryzenadj)只对 APU/核显 有意义: 它调的是 SoC/APU 的 TDP。
    # 桌面独立显卡(AMD RX 6000/7000、NVIDIA 全系)的功耗不由 ryzenadj 管, 装了也没用。
    # 判据: ① CPU 厂商; ② 是否有 NVIDIA 独显; ③ 是否是桌面 AMD 独显(非 APU)。
    sub "检测 CPU / 显卡..."
    local SKIP_REASON=""
    detect_hw   # 刷新全局 GPU_VENDOR / GPU_IS_APU / GPU_MODEL / CPU_VENDOR
    case "$CPU_VENDOR" in
        AuthenticAMD) ;;
        GenuineIntel) ;;
        *)            SKIP_REASON="CPU 厂商为 ${CPU_VENDOR:-未知}(插件仅支持 AMD/Intel APU)" ;;
    esac
    if [ -z "$SKIP_REASON" ] && [ "$GPU_VENDOR" = "nvidia" ]; then
        SKIP_REASON="检测到 NVIDIA 独显(插件仅支持 APU 的 ryzenadj)"
    fi
    if [ -z "$SKIP_REASON" ] && [ "$GPU_VENDOR" = "amd" ] && [ "$GPU_IS_APU" -eq 0 ]; then
        SKIP_REASON="检测到 AMD 桌面独显($GPU_MODEL), 非 APU → ryzenadj 不适用"
    fi
    if [ -n "$SKIP_REASON" ] && [ "${TDP_FORCE:-0}" -ne 1 ]; then
        warn "未检测到支持的 APU → 跳过第[9]步"
        sub "$SKIP_REASON"
        sub "确认支持可强制: TDP_FORCE=1 sudo bash $SCRIPT_NAME tdp"
        state_mark setup_tdp "skipped(非APU: $SKIP_REASON)"
        return 0
    fi
    sub "  CPU: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)"
    sub "  GPU: ${GPU_MODEL:-未知} (${GPU_VENDOR:-未知}, $([ "$GPU_IS_APU" -eq 1 ] && echo APU/核显 || echo 独立))"

    # ── 依赖 Decky ──
    if [ ! -d "$REAL_HOME/homebrew" ]; then
        err "未发现 ~/homebrew —— 请先装 Decky Loader: sudo bash $SCRIPT_NAME 5"
        return 1
    fi

    # ── 目录可写性预检 ──
    # 只看 id -u 不够: 容器/受限环境里 uid 可能显示 0 但实际无权限,
    # 那样会在 mv 时才裸失败并留下临时文件。
    mkdir -p "$PLUGIN_DIR" 2>/dev/null || true
    if [ ! -w "$PLUGIN_DIR" ]; then
        err "插件目录不可写: $PLUGIN_DIR (属主 $(stat -c '%U:%G' "$PLUGIN_DIR" 2>/dev/null))"
        sub "请用 sudo 运行本脚本"
        return 1
    fi

    # ── 查版本 ──
    sub "查询最新版本..."
    local TAG="$VERSION"
    if [ "$TAG" = "latest" ]; then
        TAG="$(curl -sL --connect-timeout 8 --max-time 25 \
            "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        [ -n "$TAG" ] || TAG="v1.0.7"    # API 不通时的已知兜底版本
    fi
    info "目标版本: $TAG"

    # ── 下载(镜像优先, 直连垫底) ──
    local DLURL="https://github.com/$REPO/releases/download/$TAG/${PLUGIN_NAME}.zip"
    local TMPZIP="$REAL_HOME/.cache/${PLUGIN_NAME}.download.zip"
    mkdir -p "$REAL_HOME/.cache" 2>/dev/null
    local ok=0 u
    for prefix in "https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/" ""; do
        u="${prefix}${DLURL}"
        sub "尝试: $u"
        url_reachable "$u" || { sub "  探活失败, 换源"; continue; }
        if curl -fL --connect-timeout 10 --max-time 300 "$u" -o "$TMPZIP" 2>/dev/null \
           && [ -s "$TMPZIP" ]; then
            ok=1; info "  已下载 $(du -h "$TMPZIP" 2>/dev/null | cut -f1)"; break
        fi
        sub "  下载失败, 换源"
    done
    if [ "$ok" -ne 1 ]; then
        rm -f "$TMPZIP"; err "全部源下载失败。可手动下载: $DLURL"; return 1
    fi

    # ── 校验: 镜像有时返回 HTML 错误页, 别当 zip 装 ──
    if ! unzip -l "$TMPZIP" >/dev/null 2>&1 ||
       ! unzip -l "$TMPZIP" 2>/dev/null | grep -q "package.json"; then
        rm -f "$TMPZIP"
        err "下载到的不是有效插件包(可能是镜像错误页)。手动下载: $DLURL"
        return 1
    fi
    info "zip 校验通过"

    # ── 解压安装 ──
    local TMPX="${TMPZIP}.x"
    rm -rf "$TMPX"; mkdir -p "$TMPX"
    unzip -q "$TMPZIP" -d "$TMPX"
    local SRC=""
    [ -f "$TMPX/package.json" ]               && SRC="$TMPX"
    [ -f "$TMPX/$PLUGIN_NAME/package.json" ]  && SRC="$TMPX/$PLUGIN_NAME"
    if [ -z "$SRC" ]; then
        SRC="$(find "$TMPX" -maxdepth 2 -name package.json -printf '%h\n' 2>/dev/null | head -1)"
    fi
    if [ -z "$SRC" ] || [ ! -f "$SRC/package.json" ]; then
        rm -rf "$TMPX" "$TMPZIP"; err "包内找不到 package.json, 结构异常"; return 1
    fi

    if [ -d "$PLUGIN_DIR/$PLUGIN_NAME" ]; then
        local BAK
        BAK="$PLUGIN_DIR/${PLUGIN_NAME}.bak.$(date +%m%d-%H%M%S)"
        mv "$PLUGIN_DIR/$PLUGIN_NAME" "$BAK" && info "已备份旧版 → $BAK"
    fi
    if ! mv "$SRC" "$PLUGIN_DIR/$PLUGIN_NAME"; then
        rm -rf "$TMPX" "$TMPZIP"
        err "安装失败: 无法写入 $PLUGIN_DIR (权限不足?)"; return 1
    fi
    rm -rf "$TMPX" "$TMPZIP"
    # Decky 以普通用户身份读插件; 属主不对会导致界面里看不到图标
    chown -R "$REAL_USER:$REAL_GROUP" "$PLUGIN_DIR/$PLUGIN_NAME" 2>/dev/null \
        || warn "改属主失败, 若插件不显示请手动: sudo chown -R $REAL_USER:$REAL_GROUP $PLUGIN_DIR/$PLUGIN_NAME"
    info "已安装 $PLUGIN_DIR/$PLUGIN_NAME"

    systemctl restart plugin_loader 2>/dev/null \
        && info "Decky 已重启" || warn "重启 Decky 失败(未运行?)"

    # ── 写默认 TDP 配置(插电/离电) ──
    # SimpleDeckyTDP 的配置在 ~/homebrew/settings/SimpleDeckyTDP/settings.json。
    # 我们要写的结构:
    #   advanced.acPowerProfiles = true        → 打开 "AC Profiles"(否则只有一套 TDP)
    #   tdpProfiles["default"].tdp             → 离电档 TDP_DC
    #   tdpProfiles["default-ac-power"].tdp    → 插电档 TDP_AC
    #   enableTdpProfiles = false              → 用全局 default, 不做每游戏 profile
    # 注意: 首次运行前设置文件可能不存在 → 先建骨架(缺失的键由插件 .read() 补默认)。
    local CFG_DIR="$REAL_HOME/homebrew/settings/$PLUGIN_NAME"
    local CFG="$CFG_DIR/settings.json"
    mkdir -p "$CFG_DIR" 2>/dev/null
    chown -R "$REAL_USER:$REAL_GROUP" "$CFG_DIR" 2>/dev/null || true
    if python3 - "$CFG" "$TDP_AC" "$TDP_DC" <<'PYEOF'
import json, os, sys
path, tdp_ac, tdp_dc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    d = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
except Exception:
    d = {}
d.setdefault("advanced", {})["acPowerProfiles"] = True     # 打开 AC Profiles
d["enableTdpProfiles"] = False                              # 用全局 default
d.setdefault("tdpProfiles", {})
tp = d["tdpProfiles"]
tp.setdefault("default", {}).setdefault("tdp", tdp_dc)      # 离电档(只在不显式设过时写)
tp.setdefault("default-ac-power", {}).setdefault("tdp", tdp_ac)  # 插电档
json.dump(d, open(path, "w"), indent=2)
print("  settings.json 已更新")
PYEOF
    then
        chown "$REAL_USER:$REAL_GROUP" "$CFG" 2>/dev/null || true
        info "已预设: 插电=${TDP_AC}W / 离电=${TDP_DC}W (AC Profiles 已打开)"
    else
        warn "写默认 TDP 配置失败(可能缺 python3), 需进插件手动设置"
    fi

    cat <<EOF

  ${C_OK}已把插电/离电默认档写好, 游戏模式里直接生效:${C_R}
      · 插电 (AC)      ${TDP_AC}W
      · 离电 (Battery) ${TDP_DC}W
   插件会在 ACAD/online 变化(插拔电源)时自动切换两档。

  改档位: 游戏模式 QAM → SimpleDeckyTDP → 拖滑块即可(会覆盖上面的值)。
  想重装后就用新档位: TDP_AC=55 TDP_DC=30 sudo bash $SCRIPT_NAME 9
EOF
}

# ===========================================================================
#  [6] 游戏(鸣潮/终末地): GE-Proton + Steam 非Steam启动辅助
#  - 只自动化【装 GE-Proton】与【探测游戏本体】。
#  - 游戏需 Steam 内手动「添加非 Steam 游戏」指向对应启动器 exe,
#    再用下方写好的 python 写入启动选项。本体文件请用户自行备份放回。
# ===========================================================================
setup_games() {
    step "[6/7] 游戏支持(GE-Proton + 鸣潮/终末地)"
    prepare "$@"

    local REPO="GloriousEggroll/proton-ge-custom"
    local TOOLS_DIR="$REAL_HOME/.local/share/Steam/compatibilitytools.d"
    local MIRROR="${MIRROR:-https://gh-proxy.com}"
    local GH="https://github.com"

    # --- 1) 装 GE-Proton ---
    local TAG
    TAG="${GE_PROTON_TAG:-}"
    if [ -z "$TAG" ]; then
        sub "查询 GE-Proton 最新版本..."
        for api in "https://api.github.com" "https://ghfast.top/https://api.github.com" \
                   "https://gh-proxy.com/https://api.github.com"; do
            TAG="$(curl -fsS --connect-timeout 10 --max-time 30 \
                "$api/repos/$REPO/releases/latest" 2>/dev/null | jq -r .tag_name 2>/dev/null)"
            [ -n "$TAG" ] && [ "$TAG" != "null" ] && break
        done
    fi
    if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
        warn "获取 GE-Proton 版本失败(网络)。可设 GE_PROTON_TAG=GE-Proton10-9 重跑"
    else
        mkdir -p "$TOOLS_DIR"
        if [ -d "$TOOLS_DIR/$TAG" ]; then
            info "GE-Proton $TAG 已存在"
        else
            local TARBALL="${TAG}-x86_64.tar.gz"
            # ⚠️ /tmp 在 SteamOS 上是 tmpfs(吃内存), 500MB 的包别往里下 ——
            #    与 makepkg 的 BUILDDIR 同理, 挪到 /home 下的缓存目录。
            mkdir -p "$REAL_HOME/.cache" 2>/dev/null
            local TMP; TMP="$(mktemp -d "$REAL_HOME/.cache/gep.XXXXXX")"
            local ok=0 u
            # 依次试多个镜像(境内直连 GitHub 常失败)
            local -a bases=("$MIRROR/$GH/$REPO" "$GH/$REPO" \
                            "https://ghfast.top/$GH/$REPO" "https://gh-proxy.com/$GH/$REPO" \
                            "https://ghproxy.net/$GH/$REPO")
            sub "下载 GE-Proton $TAG (约500M, 多镜像重试)..."
            for b in "${bases[@]}"; do
                u="$b/releases/download/$TAG/$TARBALL"
                sub "  尝试: $u"
                if ! url_reachable "$u"; then warn "    探活失败, 换下一个"; continue; fi
                if curl -fL --connect-timeout 10 --max-time 1200 --retry 2 -C - \
                    -o "$TMP/$TARBALL" "$u"; then ok=1; break; fi
            done
            if [ "$ok" -eq 1 ]; then
                rm -rf "${TOOLS_DIR:?}/${TAG:?}"
                tar -xzf "$TMP/$TARBALL" -C "$TOOLS_DIR" 2>/dev/null
                chmod +x "$TOOLS_DIR/$TAG/proton" 2>/dev/null || true
                chown -R "$REAL_USER:$REAL_GROUP" "$TOOLS_DIR" 2>/dev/null || true
                info "GE-Proton $TAG 安装完成"
            else
                warn "GE-Proton 下载失败(所有镜像)。可设 GE_PROTON_TAG=... 或换 MIRROR=https://ghfast.top 重跑"
            fi
            rm -rf "$TMP"
        fi
    fi

    # --- 2) 探测游戏本体 ---
    echo
    step "游戏本体检测"
    local GAME_DIR="${GAME_DIR:-/home/deck/Downloads}"
    # SteamOS deck 下载目录通常是 ~/Downloads 或 ~/下载
    if [ -d "$REAL_HOME/下载" ]; then GAME_DIR="$REAL_HOME/下载"; fi
    for g in "Wuthering Waves" "Hypergryph Launcher"; do
        if [ -d "$GAME_DIR/$g" ]; then
            info "检测到: $GAME_DIR/$g"
        else
            warn "未找到: $GAME_DIR/$g (请把游戏本体备份放回该目录)"
        fi
    done

    # --- 2.5) 修复鸣潮启动器黑屏(WPF AllowsTransparency 透明窗口 bug) ---
    # 鸣潮启动器 launcher_main.exe 是 WPF 程序, 用了 AllowsTransparency=True 透明窗口,
    # Wine/Proton 对 WPF 透明窗口支持有 bug → 窗口"透明", 只见边框、透出下层(看似黑屏)。
    # 修法: 把 launcher_main.dll 里的 AllowsTransparency 字节串替换成无效值(社区验证有效)。
    # 用 python3 做二进制替换(不依赖 bbe/编译环境)。幂等: 已 patch 过则跳过。
    patch_wuwa_launcher() {
        local WW_DIR="$1" ver dll out
        # 找版本目录下的 launcher_main.dll(如 2.6.5.0/launcher_main.dll)
        for ver in "$WW_DIR"/*/; do
            dll="$ver/launcher_main.dll"
            [ -f "$dll" ] || continue
            out="$(python3 - "$dll" 2>/dev/null <<'PYEOF'
import sys
p = sys.argv[1]
d = open(p, "rb").read()
old = b"\x12AllowsTransparency"
new = b"\x09IsEnabled\x1bA\x00\x03AAAAA"
if old in d:
    n = d.count(old)
    open(p + ".orig", "wb").write(d)          # 自动备份原文件(可还原)
    open(p, "wb").write(d.replace(old, new))
    print("OK(%d)" % n)
elif new in d:
    print("ALREADY")                          # 已替换过, 无需重复
else:
    # 宽松发现: 找所有含 "Transparen"(覆盖 Transparency/Transparent) 且前面带 \x12 的字节串
    import re
    cand = set(re.findall(rb"\x12[a-zA-Z]*Transparen[a-zA-Z]*", d))
    if len(cand) == 1:
        old2 = cand.pop()
        n = d.count(old2)
        # 用等长填充, 破坏该属性名, 保持文件长度不变(最安全的替换)
        new2 = b"\x09" + b"X" * (len(old2) - 1)
        open(p + ".orig", "wb").write(d)
        open(p, "wb").write(d.replace(old2, new2))
        print("AUTO(%d,%s)" % (n, old2[1:].decode("latin1")))
    elif len(cand) >= 2:
        print("AMBIG(%s)" % ",".join(x[1:].decode("latin1") for x in sorted(cand)))
    else:
        print("MISSING")                      # 彻底没有 → 结构大改, 需人工
PYEOF
)"
            case "$out" in
                OK*)    info "  鸣潮启动器 patch: $out (已备份 .orig, $dll)" ;;
                ALREADY*) info "  鸣潮启动器 patch: 已修好, 跳过 ($dll)" ;;
                AUTO*)  info "  鸣潮启动器 patch: 自动适配新字节串 $out (已备份 .orig, $dll)" ;;
                AMBIG*)
                    warn "  鸣潮启动器 patch: 发现多个候选字节串($out), 不敢自动改,"
                    warn "  请人工确认 ($dll)" ;;
                MISSING*)
                    warn "  鸣潮启动器 patch: 未找到 Transparency 相关字节串 → 启动器结构大改,"
                    warn "  需人工查社区最新解法 ($dll)" ;;
            esac
        done
    }
    if [ -d "$GAME_DIR/Wuthering Waves" ]; then
        sub "修复鸣潮启动器黑屏(AllowsTransparency)..."
        patch_wuwa_launcher "$GAME_DIR/Wuthering Waves"
    fi

    # --- 2.6) 修复终末地 "no Qt platform plugin could be initialized" ---
    # 根因(2026-09-09 实测): 游戏目录 games/Arknights Endfield/ 自带全套 Qt5 DLL,
    # 但**缺 Qt 平台插件**(全盘搜不到 qwindows.dll); 而启动器目录 <版本>/plugins/
    # platforms/qwindows.dll 是有的, 且两边同为 Qt 5.15.8 → 复制过去即可。
    # 游戏更新后可能再次丢失, 故做成可重跑的独立脚本。
    if [ -d "$GAME_DIR/Hypergryph Launcher" ]; then
        sub "修复终末地 Qt 平台插件缺失(qwindows.dll)..."
        local _sd _tool
        _sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
        _tool="$(homedir .local/bin)"
        if [ -f "$_sd/fix-endfield-qt.sh" ]; then
            install -m 0755 "$_sd/fix-endfield-qt.sh" "$_tool/fix-endfield-qt.sh" 2>/dev/null \
                && chown "$REAL_USER:$REAL_GROUP" "$_tool/fix-endfield-qt.sh" 2>/dev/null
        fi
        if [ -x "$_tool/fix-endfield-qt.sh" ]; then
            bash "$_tool/fix-endfield-qt.sh" 2>&1 | sed 's/^/    /'
        else
            warn "  未找到 fix-endfield-qt.sh → 跳过(可手动跑备份包里的同名脚本)"
        fi
    fi

    # --- 2.7) 备好终末地黑屏的自救工具(只安装到 ~/.local/bin, 不执行) ---
    # 2026-09-09 定案([6h]): 终末地"同意协议后黑屏、无声音"的真因是 SDK 本地状态
    # (sdkdata/、sdk_data_*/) 是从备份恢复来的空壳文件 → ParseConfig 解不出 appCode。
    # 解法 = 清空让它重新下发, 即 reset-endfield-sdk.sh。
    #
    # 这里**只装不跑**: 本步执行时玩家多半还没通过 Steam 启动过游戏,
    # prefix 和 SDK 目录都还不存在, 此刻清理毫无意义(脚本自身也会因找不到目录而退出)。
    # 装到 ~/.local/bin 是为了将来黑屏时能随手 `reset-endfield-sdk.sh` 直接跑。
    local _sd7 _bin7 _t7
    _sd7="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    _bin7="$(homedir .local/bin)"
    mkdir -p "$_bin7" 2>/dev/null
    for _t7 in reset-endfield-sdk.sh diag-black-screen.sh; do
        [ -f "$_sd7/$_t7" ] || continue
        if install -m 0755 "$_sd7/$_t7" "$_bin7/$_t7" 2>/dev/null; then
            chown "$REAL_USER:$REAL_GROUP" "$_bin7/$_t7" 2>/dev/null
            info "  已备好自救工具: ~/.local/bin/$_t7"
        else
            warn "  安装 $_t7 失败(不影响, 可手动跑备份包里的同名脚本)"
        fi
    done
    info "  终末地若「同意协议后黑屏」→ 跑: reset-endfield-sdk.sh  然后启动器点「修复客户端」"
    info "  任何游戏黑屏想取证 → 别关游戏, 另开终端跑: diag-black-screen.sh"

    # --- 3) 生成启动选项写入器(探测userid, 不硬编码) ---
    # 依赖 python-vdf(extra, 供 steam-launch-games.py 读写 vdf)
    if ! python3 -c "import vdf" >/dev/null 2>&1; then
        sub "安装 python-vdf(写入 Steam 启动选项所需)..."
        pacman -S --noconfirm --needed python-vdf 2>&1 | tail -2 || warn "python-vdf 装不上(extra 应有)"
    fi
    sub "生成 Steam 启动选项写入器..."
    mkdir -p "$(homedir .local/bin)"
    local TOOL
    TOOL="$(homedir .local/bin)"
    cat > "$TOOL/steam-launch-games.py" <<'PYEOF'
#!/usr/bin/env python3
"""写入 Steam 非 Steam 游戏(鸣潮/终末地)启动选项。自动探测 userid。
用法: python3 steam-launch-games.py
"""
import sys, os, glob, shutil
# 找 localconfig
cands = glob.glob(os.path.expanduser("~/.local/share/Steam/userdata/*/config/localconfig.vdf"))
cands += glob.glob(os.path.expanduser("~/.steam/steam/userdata/*/config/localconfig.vdf"))
if not cands:
    print("未找到 Steam localconfig.vdf, 请先启动一次 Steam"); sys.exit(1)
LC = cands[0]
try:
    import vdf
except ImportError:
    print("缺少 python-vdf, 请: sudo pacman -S python-vdf"); sys.exit(1)
# 启动器(WPF/.NET)不需要 FSR 变量; 上采样交给游戏内原生 FSR + SteamOS 系统级 FSR。
# 空选项 = 干净无副作用(见 SCRIPT-MAINTENANCE.md 步骤[6] 铁律: 别再塞 FSR4/DLSS 变量)。
OPT = ('%command%')
NAMES = {"鸣潮启动器": None, "鹰角启动器": None, "终末地启动器": None, "Wuthering Waves": None}
with open(LC) as f:
    d = vdf.load(f)
apps = d["UserLocalConfigStore"]["Software"]["Valve"]["Steam"]["apps"]
changed = []
for appid, node in apps.items():
    name = node.get("name", "")
    if any(k in str(name) for k in ("鸣潮", "鹰角", "终末地", "Wuthering", "Hypergryph")):
        cur = node.get("LaunchOptions")
        if cur == OPT:
            print(f"  {appid} ({name}): 已是目标值")
        else:
            node["LaunchOptions"] = OPT; changed.append(f"{appid} ({name})")
if not changed:
    print("没有找到要改的游戏快捷方式。请先在 Steam 库 → 添加非Steam游戏 → 指向启动器 exe")
    sys.exit(0)
shutil.copy(LC, LC + ".bak")
with open(LC, "w") as f:
    vdf.dump(d, f, pretty=True)
print("已写入启动选项:", ", ".join(changed))
print("重启 Steam 生效")
PYEOF
    chmod +x "$TOOL/steam-launch-games.py"
    chown "$REAL_USER:$REAL_GROUP" "$TOOL/steam-launch-games.py" 2>/dev/null || true

    cat <<EOF
  ==================== 游戏设置指引 ====================
  1. 游戏本体: 从备份恢复到 $GAME_DIR/
     - 鸣潮  → $GAME_DIR/Wuthering Waves/2.x/Wuthering Waves Game/  (launcher exe)
     - 终末地→ $GAME_DIR/Hypergryph Launcher/1.x/Launcher.exe
  2. Steam 大屏幕/桌面 → 库 → 添加非Steam游戏 → 分别指向两个启动器 exe
  3. 运行:  python3 $TOOL/steam-launch-games.py   (写入干净启动选项, 无 FSR4 变量)
  4. 每个游戏: 右键 → 属性 → 兼容性 → 强制使用 GE-Proton $TAG
  5. 重启 Steam 生效。
  ${C_WARN}提醒: 需先在 Steam 添加好非Steam游戏, 第3步才找得到 appid 写入。${C_R}
EOF
}

# ===========================================================================
#  [7] DeepSeek Harness(dsh) — WorkBuddy 之外的补充 AI Agent CLI
#  官方开源 Agent harness, CLI 名 dsh, 走 npm 分发(@deepseek-ai/dsh)。
#  需 nodejs+npm(extra)。用「固定版本」避免 dev-preview 破坏性变更。
#  用法: dsh web(浏览器 Web UI, 127.0.0.1:3080) / dsh run "任务"
# ===========================================================================
setup_dsh() {
    step "[7/7] DeepSeek Harness (dsh, 补充 AI CLI)"
    prepare "$@"

    # 固定到已实测可用的版本(dev-preview 会破坏兼容, 不追 latest)
    local DSH_VER="${DSH_VER:-0.1.2-rc.1}"

    # 依赖: nodejs + npm(extra 源, prepare 已补 extra)。优先系统 /usr/bin 版
    # ⚠️ 必须给初值: 本脚本开了 set -u(第56行), 若系统没装 npm,
    #    NPM_BIN 会处于"未赋值"状态, 下面 [ -z "$NPM_BIN" ] 直接抛
    #    "NPM_BIN: unbound variable" 而崩掉 —— 根本走不到安装 npm 的分支。
    local NPM_BIN="" NODE_BIN=""
    if [ -x /usr/bin/npm ]; then NPM_BIN=/usr/bin/npm; NODE_BIN=/usr/bin/node; else
        command -v npm >/dev/null 2>&1 && NPM_BIN="$(command -v npm)"
        command -v node >/dev/null 2>&1 && NODE_BIN="$(command -v node)"
    fi
    if [ -z "$NPM_BIN" ] || [ -z "$NODE_BIN" ]; then
        sub "安装 nodejs+npm(extra 源)..."
        pacman -S --noconfirm --needed nodejs npm 2>&1 | tail -3 || {
            err "nodejs/npm 安装失败(确认已配 extra 源)"
            exit 1
        }
        NPM_BIN=/usr/bin/npm; NODE_BIN=/usr/bin/node
    fi
    info "node: $("$NODE_BIN" --version 2>/dev/null)  npm: $("$NPM_BIN" --version 2>/dev/null)"

    # ---- 2026-09-09 改: dsh 装到 ~/.local, 不再装 /usr ----
    #   实测 dsh 本体 281M。rootfs 只有 5.0G, 装进 /usr 单这一个包就吃掉 5.6%;
    #   更糟的是 SteamOS 原子升级整块换 rootfs 后, 本步骤会重装 → 281M 卷土重来。
    #   改 --prefix $REAL_HOME/.local → 落在 /home(p8): 升级不丢, 也不占 rootfs。
    #   npm --prefix 会自动在 $prefix/bin/dsh 建软链, 无需再碰 /usr/bin。
    local DSH_PREFIX DSH_BIN
    DSH_PREFIX="$(homedir .local)"
    DSH_BIN="$DSH_PREFIX/bin/dsh"

    # 已装且版本正确则跳过(以 dsh --version 为准, 比 grep package.json 可靠)
    local CURRENT="" DSH_AT=""
    if [ -x "$DSH_BIN" ]; then
        DSH_AT="$DSH_BIN"; CURRENT="$("$DSH_BIN" --version 2>/dev/null | head -1)"
    fi
    if [ -z "$CURRENT" ] && [ -x /usr/bin/dsh ]; then
        # 旧布局(落在 rootfs): 能用, 但白占 281M → 提示迁移, 绝不重复装一份
        DSH_AT=/usr/bin/dsh; CURRENT="$(/usr/bin/dsh --version 2>/dev/null | head -1)"
        [ "$CURRENT" = "$DSH_VER" ] && \
            warn "dsh 当前装在 /usr(白占 rootfs 281M) → 跑 free-rootfs.sh --apply 可迁到 ~/.local"
    fi
    if [ -n "$CURRENT" ] && [ "$CURRENT" = "$DSH_VER" ]; then
        info "dsh $DSH_VER 已安装(路径: $DSH_AT)"
    else
        [ -n "$CURRENT" ] && sub "已装 dsh $CURRENT, 改为固定版本 $DSH_VER ..." \
                        || sub "全局安装 dsh $DSH_VER (npm, 纯JS无编译, 约需几分钟)..."
        # 装到 $REAL_HOME/.local(见上方 2026-09-09 说明), 显式 --prefix 防止被
        # npm 配置/沙箱 prefix 带偏回 /usr。
        # 国内镜像: 依次试 npmmirror 淘宝镜像 → 官方 registry.npmjs.org(直连常慢/失败)
        local okreg=0 reg NPM_LOG
        NPM_LOG="$(mktemp /tmp/dsh-npm.XXXXXX.log)"
        local -a REGS=(
            "${NPM_REGISTRY:-https://registry.npmmirror.com}"
            "https://registry.npmjs.org"
        )
        for reg in "${REGS[@]}"; do
            sub "  npm 源: $reg"
            : > "$NPM_LOG"
            "$NPM_BIN" install -g --prefix "$DSH_PREFIX" --registry="$reg" \
                "@deepseek-ai/dsh@$DSH_VER" >"$NPM_LOG" 2>&1
            local rc=$?
            tail -6 "$NPM_LOG"
            # --prefix ~/.local → ~/.local/bin/dsh。用文件存在判断, 不依赖 PATH 是否刷新
            if [ "$rc" -eq 0 ] && [ -x "$DSH_BIN" ]; then
                # 以 root 跑时 npm 落地的文件属主是 root, 必须还给真实用户
                chown -R "$REAL_USER:$REAL_GROUP" "$DSH_PREFIX/lib/node_modules/@deepseek-ai" 2>/dev/null
                chown -h "$REAL_USER:$REAL_GROUP" "$DSH_BIN" 2>/dev/null
                okreg=1; break
            fi
            echo "    ↑ 该源失败(rc=$rc), 尝试下一个..."
        done
        rm -f "$NPM_LOG"
        if [ "$okreg" -ne 1 ]; then
            err "dsh 安装失败(所有 npm 源)"
            warn "排查: ①nodejs/npm 已装 ②网络 ③/usr 可写(root)。可设 NPM_REGISTRY=https://xxx 指定源重跑"
            exit 1
        fi
        [ -x "$DSH_BIN" ] || { err "安装后 $DSH_BIN 不存在"; exit 1; }
        DSH_AT="$DSH_BIN"
        CURRENT="$("$DSH_BIN" --version 2>/dev/null | head -1)"
        if [ "$CURRENT" != "$DSH_VER" ]; then
            err "dsh 版本校验不符(期望 $DSH_VER, 得 $CURRENT)"
            exit 1
        fi
        info "dsh $DSH_VER 安装完成"
    fi
    # 兜底: 确保 ~/.local/bin/dsh 存在(幂等)。
    #   为什么必须补: /usr/bin/dsh 是我们手建的软链, 不属任何 pacman 包 ——
    #   SteamOS 原子升级整块换 rootfs 后它会被抹掉, 而 ~/.local/bin 在 /home 能存活,
    #   且 ~/.bashrc 已经 source 了 ~/.local/bin/env(把该目录 prepend 进 PATH)。
    #   不补这一下, 升级后 dsh 命令就彻底找不到了。
    local _lb
    _lb="$(homedir .local/bin)"
    if [ ! -e "$_lb/dsh" ]; then
        local _tgt="$DSH_PREFIX/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"
        [ -e "$_tgt" ] && ln -sf "$_tgt" "$_lb/dsh" && sub "已补 ~/.local/bin/dsh 软链(升级后仍可用)"
    fi

    info "dsh 位置: ${DSH_AT:-$DSH_BIN}"

    # 状态行也加一条(便于复查), 首次使用配置在 /root 或 $REAL_HOME 由用户 dsh web 设置
    cat <<EOF
  ${C_OK}DeepSeek Harness 安装完成!${C_R}
  两种用法:
    dsh web          → 启动浏览器 Web UI (http://127.0.0.1:3080), 补充 WorkBuddy 之外用
    dsh run "任务"    → 命令行一次性任务
  首次用: dsh web 后进 Settings → Models 填 DeepSeek API key(platform.deepseek.com)。
  版本固定为 $DSH_VER(dev-preview 会破坏兼容, 需升级时改脚本顶部 DSH_VER 或用)
    npm install -g @deepseek-ai/dsh@latest
  ${C_WARN}说明: nodejs+npm 由 pacman 装 /usr(无法避免); 但 dsh 本体(281M)装 ~/.local,${C_R}
  ${C_WARN}      不占 rootfs。若 ~/.local/bin 不在 PATH, 加一行到 ~/.bashrc:${C_R}
  ${C_WARN}        export PATH="\$HOME/.local/bin:\$PATH"${C_R}
EOF
}

# ===========================================================================
#  [10] 换境内 NTP(可选, 加速开机)
# ---------------------------------------------------------------------------
#  问题: SteamOS 默认 NTP 用 arch.pool.ntp.org, 境内延迟高(实测 400ms+, 服务器
#        2.arch.pool.ntp.org)。开机时 atomupd(原子更新守护)的 ExecStartPre 会执行
#        `timeout 20s systemd-time-wait-sync` 等系统时钟首次 NTP 同步, 同步不上就
#        干等 20 秒 → 开机时长被它独占 20 秒(systemd-analyze blame 里 atomupd 第一)。
#  方案: 把 NTP 换成阿里/腾讯(延迟降到几 ms), 开机首次同步秒过, atomupd 不再白等。
#        用 drop-in(/etc/systemd/timesyncd.conf.d/ntp.conf), 系统更新不覆盖, 可逆。
#  副作用: 无。只改时间同步服务器, 不动 atomupd 本身。
# ===========================================================================
setup_ntp() {
    step "[10/10] 换境内 NTP(加速开机)"
    prepare "$@"

    # 可配置 NTP 服务器(空格分隔), 默认阿里 + 腾讯
    local NTP_SERVERS="${NTP_SERVERS:-ntp.aliyun.com ntp.tencent.com}"
    local NTP_DROPIN_DIR="/etc/systemd/timesyncd.conf.d"
    local NTP_DROPIN="$NTP_DROPIN_DIR/ntp.conf"

    # ── 判断当前是否已是境内 NTP(幂等) ──
    if [ -f "$NTP_DROPIN" ] && grep -qE 'NTP=.*(aliyun|tencent|ntp\.cn|pool\.ntp\.org)' "$NTP_DROPIN" 2>/dev/null; then
        info "境内 NTP 已配置(见 $NTP_DROPIN), 无需重复"
    else
        sub "写入 NTP drop-in: $NTP_DROPIN ..."
        mkdir -p "$NTP_DROPIN_DIR"
        cat > "$NTP_DROPIN" <<EOF
[Time]
NTP=$NTP_SERVERS
FallbackNTP=$NTP_SERVERS time.cloud.tencent.com
EOF
        info "已写入(系统更新不会覆盖此 drop-in)"
    fi

    # ── 重启 timesyncd 使生效 ──
    if systemctl restart systemd-timesyncd 2>/dev/null; then
        info "systemd-timesyncd 已重启"
    else
        warn "重启 timesyncd 失败(可能未运行), 下次开机自动生效"
    fi

    # ── 报当前同步状态(供确认) ──
    echo
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl timesync-status 2>/dev/null | sed 's/^/    /' || \
            echo "    (timesyncd 尚未同步, 稍等几秒重试 timedatectl timesync-status)"
    fi

    cat <<EOF

  ${C_OK}已把 NTP 换成境内服务器, 开机不再被 atomupd 的校时等待拖 20 秒:${C_R}
      NTP = $NTP_SERVERS
   验证: sudo reboot 后
     · systemd-analyze blame | head -3   → atomupd.service 应从 ~20s 降到 1~2s
     · timedatectl timesync-status       → Server 变成阿里/腾讯, Delay 降到几 ms~几十 ms
   还原: sudo rm -f $NTP_DROPIN && sudo systemctl restart systemd-timesyncd
   自定义: NTP_SERVERS='ntp.example.com' sudo bash $SCRIPT_NAME 10
EOF
}

# ===========================================================================
#  [11] GPU 加速建议: DLSS(N卡) / FSR(A卡)
# ---------------------------------------------------------------------------
#  纯提示步骤, 无落地物。目的: 装完后按显卡给出正确的超采样/帧生成建议,
#  并提醒 N 卡用户「官方 SteamOS 不支持 N 卡」这一硬事实, 引导走 Bazzite。
#  要点(2026 现状, 已核实):
#    - NVIDIA DLSS 4.5(2026-01 CES 发布): Linux 上靠 Proton + NVIDIA 驱动 +
#      社区工具(dlss-updater 3.3.0 已支持 Linux / dxvk-nvapi 的 preset override)。
#    - AMD FSR 4: RDNA4 硬件专属(绑 FP8 AI 单元); RDNA3(7900XTX)/RDNA3.5(8060S) 目前
#      不支持, AMD 官方明确「FSR4 暂不计划支持 RDNA3.5 核显」; 2026-07 起才把
#      FSR4 移植到 RDNA3/3.5(跑 INT8, 画质/性能打折), SteamOS 跟进时间未知。
#    - Intel XeSS: Xe3(Panther Lake, Arc B390)有 XMX 硬件单元, XeSS 硬件加速可用;
#      老 Intel 核显/独显可能回退软件模式。Linux 支持: kernel 6.18+/Mesa 25.3+。
# ===========================================================================
setup_gpu() {
    step "[11/11] GPU 加速建议(DLSS/FSR)"
    prepare "$@"

    detect_hw   # 刷新检测

    echo
    step "设备识别结果"
    printf "  CPU: %s\n" "$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)"
    printf "  GPU: %s (%s)\n" "${GPU_MODEL:-未知}" "${GPU_VENDOR:-未知}"
    printf "  类型: %s\n" "$([ "$GPU_IS_APU" -eq 1 ] && echo 'APU/核显' || echo '独立显卡')"
    if [ "$IS_WIN5" -eq 1 ]; then printf "  机型: GPD Win5 (背键已支持)\n"; fi
    printf "  画像: %s — %s [支持度: %s]\n" "$DEVICE_PROFILE" "$DEVICE_PROFILE_DESC" "$PROFILE_SUPPORT"

    echo
    case "$GPU_VENDOR" in
        nvidia)
            cat <<EOF
  ${C_WARN}⚠️ 本机是 NVIDIA 显卡, 官方 SteamOS 不支持 N 卡。${C_R}
  ${C_WARN}   Valve SteamOS 3.8 目前只支持 AMD GPU(N 卡官方支持最早 2026 年底/2027)。${C_R}

  若你想把这台 N 卡机器做成 SteamOS 风格主机, 有两条路:
    · 推荐: Bazzite(社区 Fedora 游戏发行版, N 卡支持最好, DLSS/光追/HDR/VRR 开箱即用)
        下载: bazzite.gg  选 "NVIDIA" 镜像。
    · 进阶: 纯 SteamOS + N 卡 patch(把最新 N 卡驱动打进 SteamOS 镜像, 社区方案 gnugent)

  DLSS 4.5(N 卡专属)在 Linux 上的落地:
    · 前提: NVIDIA 最新驱动(≥570) + 新 Proton/GE-Proton + N 卡镜像(Bazzite)。
    · 升级工具: dlss-updater(3.3.0 起官方支持 Linux) 一键替换游戏里的 DLSS 版本;
        或用 dxvk-nvapi 的 DLSS preset override(换 transformer 模型/Preset K)。
    · 帧生成/多帧生成: RTX 40/50 系支持; 50 系才有 6x 多帧生成。
EOF
            ;;
        amd)
            if [ "$GPU_IS_APU" -eq 0 ]; then
                cat <<EOF
  ${C_OK}本机是 AMD 独立显卡, 官方 SteamOS 3.8 完全支持(这正是 Valve 主推的 DIY 组合)。${C_R}

  FSR 建议:
    · 系统级: SteamOS 自带 FSR(在 QAM 性能面板里开, Gamescope 合成层生效),
        游戏内降渲染分辨率, 系统帮你放大, 免游戏原生支持。
    · RDNA3(如 RX 7900 XTX): 原生 FSR 4 是 RDNA4 专属, 目前不支持;
        先用 FSR 3.1(大部分游戏已支持), 2026-07 后 AMD 才移植 FSR4 到 RDNA3。
    · RDNA4(RX 9060/9070): 可直接用 FSR 4。
    · 桌面独显功耗: 用 BIOS/软件(如 LACT)调, 不归 ryzenadj 管 → 第[9]步已自动跳过。
EOF
            else
                cat <<EOF
  ${C_OK}本机是 AMD APU/核显(掌机/带核显 CPU)。${C_R}

  FSR 建议:
    · 系统级 FSR(SteamOS QAM 面板)最省心; 游戏内降分辨率 + 系统放大。
    · 8060S(RDNA3.5)等新核显: 当前只能用 FSR 3.1 / 系统级 FSR; FSR 4 是 RDNA4
        专属、AMD 明确暂不支持 RDNA3.5 核显(2026-07 才移植, SteamOS 跟进未定)。
    · 别给启动器塞 PROTON_FSR4_UPGRADE 之类变量——对 8060S 完全无效。
    · TDP: 第[9]步 SimpleDeckyTDP 可调插电/离电功耗(掌机有用, 台式核显意义不大)。
EOF
            fi
            ;;
        intel)
            if [ "$IS_PANTHER" -eq 1 ]; then
                cat <<EOF
  ${C_OK}本机是 Intel Panther Lake 核显(Xe3 / Arc B390 系列)。${C_R}

  XeSS(Intel 上采样)建议:
    · Xe3 有 XMX 硬件单元, XeSS / XeSS 3 / 多帧生成是硬件加速, 不是软件回退。
    · 前提: 新内核(≥6.18/6.19) + Mesa(≥25.3/26) + 最新 linux-firmware(Intel GuC 固件)。
    · 游戏内选 XeSS 即可; 别用 FSR(那是 AMD 的)。
  ${C_WARN}性能坑(实测已知):${C_R} 部分 OEM 把 balanced 平台档的 PL1 调低(最低 15W),
    Linux 默认 balanced 档下 Xe3 性能可能跑不满 → 切到 performance 平台档 + 装
    thermald / LPMD(Intel Low Power Mode Daemon) 才能发挥。可用 powerprofilesctl 切档。
EOF
            else
                cat <<EOF
  ${C_WARN}本机是 Intel 核显/独显(非 Panther Lake)。${C_R}
  XeSS 在老 Intel 核显/独显上可能回退软件模式, 效果一般; 可试 XeSS 或直接降分辨率。
EOF
            fi
            ;;
        *)
            cat <<EOF
  ${C_WARN}未识别出显卡(可能缺 lspci 或新硬件)。${C_R}
  可先: sudo pacman -S --needed pciutils  再重跑本步。
EOF
            ;;
    esac

    echo
    info "以上为提示信息, 无需安装任何东西。"
    echo "  (若你在 N 卡机器上误装了官方 SteamOS, 请改走 Bazzite; 本脚本的 pacman/输入法/Decky"
    echo "   等步骤在 Bazzite 上部分不适用, 因 Bazzite 是 Fedora 系, 包管理是 rpm-ostree 而非 pacman)"
}


# ===========================================================================
#  [12] 系统升级后自愈 (self-heal)
# ---------------------------------------------------------------------------
#  背景(2026-09-09 实测): SteamOS 3.8→3.9 原子升级会把本脚本写进 /etc 的系统级
#  修改(背键 unit / udev / inputplumber 覆盖配置 / NTP drop-in / WorkBuddy wrapper)
#  全部冲掉, 只有 /home 里的东西幸存。用户只能事后发现。
#
#  本步解决: 部署一个「用户级自愈服务」(systemd user 服务, 放 /home, 本身扛升级),
#  开机时自动检测这些落点, 缺了就用 sudo 调本脚本对应步骤(FORCE=1)重建。
#
#  落地物(全在 /home, 可扛系统升级):
#    1. $REAL_HOME/.local/opt/steamos-self-heal/self-heal-after-upgrade.sh  (自愈脚本)
#    2. $REAL_HOME/.config/systemd/user/steamos-self-heal.service           (user 服务)
#    3. /etc/sudoers.d/steamos-self-heal  (免密 sudo, 仅放行自愈脚本一条命令)
#  注意: sudoers 文件在 /etc(系统分区), 升级会被冲 → 自愈服务首次触发时会发现
#  sudo 失效, 但服务本身仍会跑(只是重建动作降级为"下次再试")。要彻底解决需
#  每次升级后重跑一次本步。这已是最优解(无法把 sudoers 放 /home, systemd 不认)。
# ===========================================================================
setup_selfheal() {
    step "[12/12] 系统升级后自愈服务"
    prepare "$@"

    local SH_DIR="$REAL_HOME/.local/opt/steamos-self-heal"
    local SH_SCRIPT="$SH_DIR/self-heal-after-upgrade.sh"
    local USER_UNIT="$REAL_HOME/.config/systemd/user/steamos-self-heal.service"
    local SUDOERS="/etc/sudoers.d/steamos-self-heal"

    # ── 1. 安装自愈脚本(若备份包里没有, 就内嵌生成) ──
    local SH_SRC MAIN_ABS
    SH_SRC="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/self-heal-after-upgrade.sh"
    MAIN_ABS="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/steamos-setup.sh"
    mkdir -p "$SH_DIR"
    if [ -f "$SH_SRC" ]; then
        install -m 755 "$SH_SRC" "$SH_SCRIPT"
        info "自愈脚本: 从 $SH_SRC 安装"
    else
        err "备份包缺少 self-heal-after-upgrade.sh —— 自愈逻辑必须与主脚本同源,"
        err "不再内嵌副本(曾因双份漂移难维护)。请从 git 仓库恢复该文件后重跑本步。"
        return 1
    fi
    chown "$REAL_USER:$REAL_GROUP" "$SH_SCRIPT" 2>/dev/null || true

    # ── 1b. main.conf: 固化主脚本路径(自愈脚本部署目录里没有主脚本, 必须指路) ──
    printf 'MAIN="%s"\n' "$MAIN_ABS" > "$SH_DIR/main.conf"
    chown "$REAL_USER:$REAL_GROUP" "$SH_DIR/main.conf" 2>/dev/null || true

    # ── 2. 写 user 服务单元 ──
    mkdir -p "$(dirname "$USER_UNIT")"
    cat > "$USER_UNIT" <<EOF
[Unit]
Description=SteamOS 升级后自愈(重建被原子更新冲掉的系统级配置)
# user 服务在 /home, 能扛系统升级。开机后 30 秒再跑, 避开输入法/显卡尚未就绪的窗口。

[Service]
Type=oneshot
ExecStart=/bin/bash $SH_SCRIPT
# 用 sudo -n 调主脚本需要 root; 免密规则见 /etc/sudoers.d/steamos-self-heal

[Install]
WantedBy=default.target
EOF
    chown "$REAL_USER:$REAL_GROUP" "$USER_UNIT" 2>/dev/null || true

    # ── 3. sudoers 免密(放行自愈脚本 + 主脚本, 仅用于重建被升级冲掉的配置) ──
    if [ -f "$SUDOERS" ] && grep -q "steamos-setup.sh" "$SUDOERS" 2>/dev/null; then
        info "sudoers 免密已配置(含主脚本调用)"
    else
        mkdir -p /etc/sudoers.d
        cat > "$SUDOERS" <<EOF
# SteamOS 自愈服务: 免密执行自愈脚本与主脚本(仅用于重建被升级冲掉的配置)
$REAL_USER ALL=(ALL) NOPASSWD: $SH_SCRIPT
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/bash $MAIN_ABS
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/bash $MAIN_ABS *
EOF
        chmod 440 "$SUDOERS"
        # 校验 sudoers 语法, 语法错会锁死 sudo, 必须拦住
        if visudo -cf "$SUDOERS" >/dev/null 2>&1; then
            info "sudoers 免密已写入并通过 visudo 校验"
        else
            rm -f "$SUDOERS"
            warn "sudoers 语法校验失败, 已删除(避免锁死 sudo)。请手动检查"
        fi
    fi

    # ── 4. 启用 user 服务(用目标用户身份, 不用 root) ──
    if command -v systemctl >/dev/null 2>&1; then
        su - "$REAL_USER" -c "systemctl --user daemon-reload && systemctl --user enable --now steamos-self-heal.service" 2>/dev/null \
            && info "user 服务已启用(开机自愈生效)" \
            || warn "启用 user 服务失败(可能缺 linger, 桌面登录后仍会触发)"
        # 无 linger 时用户不登录 user 服务不跑; 给个提示
        if ! loginctl show-user "$REAL_USER" 2>/dev/null | grep -q "Linger=yes"; then
            warn "建议开启 linger(无头也能跑): sudo loginctl enable-linger $REAL_USER"
        fi
    else
        warn "无 systemctl, 跳过 user 服务启用"
    fi

    cat <<EOF

  ${C_OK}自愈服务部署完成。${C_R}
  版本钩子(每次开机自动执行):
    · 对比系统版本号, 检测到原子更新(如 3.8→3.9)即清点被冲掉的内容
    · 报告落盘: ~/.local/opt/steamos-self-heal/last-report.txt (+桌面通知)
    · sudoers 幸存时全自动恢复(主脚本 --after-upgrade, 完好的自动跳过)
    · sudoers 也被冲掉时, 通知你一条手动命令(输一次密码即可)
  清点范围: 背键单元/udev/inputplumber 配置/Decky 系统单元/NTP/WorkBuddy IME
  手动触发一次试试:  su - $REAL_USER -c "systemctl --user start steamos-self-heal.service"
  查看日志:          journalctl --user -u steamos-self-heal.service

  注意: sudoers 免密文件在 /etc, 升级必被冲 → 大版本升级后的首次恢复仍需
        手动跑一次( sudo bash $SCRIPT_NAME --after-upgrade ), 之后可全自动。
EOF
}


# ===========================================================================
#  --status
# ===========================================================================
show_status() {
    echo
    step "组件状态"
    printf "  用户 : %s (%s)\n" "$REAL_USER" "$REAL_HOME"
    printf "  系统 : %s\n" "$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2-)"
    [ "$IS_STEAMOS" -eq 1 ] && echo "  类型 : SteamOS(holo)" || echo "  类型 : Arch系"
    # ── 设备识别(新增, 兼容多种机型) ──
    detect_hw
    printf "  GPU  : %s (%s, %s)\n" "${GPU_MODEL:-未知}" "${GPU_VENDOR:-未知}" \
        "$([ "$GPU_IS_APU" -eq 1 ] && echo 'APU/核显' || echo '独立显卡')"
    if [ "$IS_WIN5" -eq 1 ]; then
        info "机型: GPD Win5(背键步骤适用)"
    else
        info "机型: 非 Win5(第[4]步背键会自动跳过)"
    fi
    case "$GPU_VENDOR" in
        nvidia) warn "N 卡: 官方 SteamOS 不支持 → 建议用 Bazzite(见第[11]步 gpu)" ;;
        amd)    info "AMD 卡: SteamOS 支持(FSR 建议见第[11]步 gpu)" ;;
        intel)  [ "$IS_PANTHER" -eq 1 ] && info "Intel Panther Lake(Xe3): XeSS 硬件可用(见第[11]步 gpu)" \
                    || info "Intel 核显/独显(见第[11]步 gpu)" ;;
        *)      ;;
    esac
    printf "  rootfs : 可用 %sMB    /opt: %s\n" \
        "$(( $(df -Pk / | awk 'NR==2{print $4}') / 1024 ))" \
        "$(findmnt -no SOURCE --target /opt 2>/dev/null || echo '与 / 同分区')"
    grep -qE '^\s*#?\s*\[core\]' /etc/pacman.conf 2>/dev/null && info "Arch 源 core: 已配" \
        || warn "Arch 源 core: 未配(重跑任一步会自动补)"
    if grep -A3 -E '^\s*#?\s*\[core\]' /etc/pacman.conf 2>/dev/null | grep -q 'mirrorlist-arch'; then
        info "core Include: mirrorlist-arch(正确, 不会 404)"
    else
        warn "core Include 未指向 mirrorlist-arch → pacman -Sy 会 404(重跑任一步自动修)"
    fi
    grep -qE '^\s*\[archlinuxcn\]' /etc/pacman.conf 2>/dev/null && info "archlinuxcn: 已配" || warn "archlinuxcn: 未配"
    pacman -Qq ibus >/dev/null 2>&1 && info "IBus: $(pacman -Q ibus 2>/dev/null)" || warn "IBus: 未安装"
    local KWIM
    KWIM="$(grep -A1 '^\[Wayland\]' "$REAL_HOME/.config/kwinrc" 2>/dev/null | grep '^InputMethod=' | cut -d= -f2-)"
    if [ -n "$KWIM" ]; then
        case "$KWIM" in
            *IBus*) info "KWin 输入法: $(basename "$KWIM")" ;;
            *)      warn "KWin 输入法: $KWIM (非 IBus, 建议重跑第[2]步)" ;;
        esac
    else
        warn "KWin 输入法: 未设置(Wayland 应用无法输入)"
    fi
    [ -f "$REAL_HOME/.config/environment.d/ibus.conf" ] && info "IBus 环境变量: 已配" || warn "IBus 环境变量: 未配"
    if grep -qE '^[[:space:]]*(GTK|QT)_IM_MODULE' "$REAL_HOME/.config/environment.d"/*.conf 2>/dev/null; then
        warn "仍在设置 GTK/QT_IM_MODULE —— 应取消, 改走 Wayland 原生前端"
    fi
    pacman -Qq workbuddy >/dev/null 2>&1 && {
        info "WorkBuddy: $(pacman -Q workbuddy 2>/dev/null)"
        # ⚠️ 修正(2026-09-08): 原来检测 "--wayland-text-input-version=3", 但 v3 在 KWin 下
        #    会导致候选框错位、已被本脚本默认弃用(见 setup_wb 里 WB_IME 注释)。
        #    默认值是 v1 组合, 判据应与默认一致, 否则会一直误报"未修复"。
        local WB_MODE
        if grep -q -- "--wayland-text-input-version=3" /usr/bin/workbuddy 2>/dev/null; then
            WB_MODE="text-input-v3(非默认)"
            grep -q -- "--enable-wayland-ime" /usr/bin/workbuddy 2>/dev/null \
                && echo "    Wayland IME: 已修复($WB_MODE)" || warn "    Wayland IME: 未修复"
        elif grep -q -- "--enable-wayland-ime" /usr/bin/workbuddy 2>/dev/null; then
            echo "    Wayland IME: 已修复(text-input-v1, KWin/Electron 官方推荐)"
        else
            warn "    Wayland IME: 未修复(wrapper 缺 --enable-wayland-ime)"
        fi
    } || warn "WorkBuddy: 未安装"
    # ── 第[4]步的决定性检查: inputplumber 到底起没起来 ──
    # 教训: 配置全对也可能无效 —— 若 unit 依赖成环, systemd 会丢弃 inputplumber
    # 的启动任务, 游戏模式里它压根没运行, 手柄就退回原始 Xbox 360。
    if command -v inputplumber >/dev/null 2>&1; then
        systemctl is-active --quiet inputplumber 2>/dev/null \
            && info "inputplumber: 运行中" \
            || warn "inputplumber: 未运行(桌面模式属正常; **游戏模式必须跑起来**)"
        if journalctl -u inputplumber -b --no-pager 2>/dev/null | grep -qi "ordering cycle"; then
            err "inputplumber 存在 ordering cycle → 它不会开机启动! 跑: sudo bash $SCRIPT_NAME 4 修"
        fi
        if [ -f /etc/inputplumber/devices.d/20-gpd_win5.yaml ]; then
            grep -qE '^\s*-\s*deck\s*$' /etc/inputplumber/devices.d/20-gpd_win5.yaml 2>/dev/null \
                && info "手柄模拟目标: deck(Steam Deck Controller)" \
                || warn "手柄模拟目标: 非 deck(Steam 里会显示成 Xbox 手柄)"
        else
            warn "无 inputplumber 覆盖配置(第[4]步没跑, 或本机非 Win5)"
        fi
        [ -f /etc/inputplumber/capability_maps.d/20-gpd_win5.yaml ] \
            && info "自定义能力表: 已装(Home=Steam键, KB=右侧边栏)" \
            || warn "自定义能力表: 未装(KB 键仍是屏幕键盘)"
        systemctl is-active --quiet gpd-win5-backkeys 2>/dev/null \
            && info "GPD背键守护: 运行中" || warn "GPD背键守护: 未运行"
    else
        warn "inputplumber: 未安装"
    fi

    systemctl is-active --quiet plugin_loader 2>/dev/null && info "Decky: 运行中" || warn "Decky: 未运行"
    if [ -d "$REAL_HOME/homebrew/plugins" ]; then
        local _pl _pl_list=""
        for _pl in "$REAL_HOME/homebrew/plugins"/*; do
            [ -d "$_pl" ] || continue
            case "$_pl" in *.bak.*) continue ;; esac
            _pl_list+="$(basename "$_pl") "
        done
        [ -n "$_pl_list" ] && info "已装插件: $_pl_list" || info "已装插件: (无)"
    fi
    [ -x /usr/bin/dsh ] && info "dsh: $(/usr/bin/dsh --version 2>/dev/null | head -1)" || warn "dsh: 未安装"
    if [ -d "$REAL_HOME/homebrew/plugins/SimpleDeckyTDP" ]; then
        info "TDP 插件: 已装"
        # 提示 AC profile 是否开了(需要插件配置, 界面手动; 只能提醒)
        warn "  AC/Battery 双 profile 需进游戏模式在插件里手动打开 'AC Profiles'"
    else
        warn "TDP 插件: 未装 (可跑: sudo bash $SCRIPT_NAME 9)"
    fi

    # ── 开机耗时 / NTP 自查 ──
    # atomupd 是 SteamOS 开机慢的头号元凶: 它等 NTP 校时最多 20s, 默认 arch.pool.ntp.org
    # 境内延迟高导致同步慢 → 白等。已跑第[10]步换境内 NTP 后应降到 1~2s。
    if command -v systemd-analyze >/dev/null 2>&1; then
        local _boot_total _slowest
        _boot_total="$(systemd-analyze 2>/dev/null | sed -n 's/.*= \(.*\)$/\1/p' | tail -1)"
        _slowest="$(systemd-analyze blame 2>/dev/null | head -1)"
        [ -n "$_boot_total" ] && echo "  开机总耗时: ${_boot_total}"
        [ -n "$_slowest" ] && echo "  最慢服务  : $(echo "$_slowest" | sed 's/^ *//')"
        if echo "$_slowest" | grep -q "atomupd"; then
            warn "  atomupd 占时偏长 → 多半是默认 NTP 同步慢, 跑: sudo bash $SCRIPT_NAME 10"
        fi
    fi
    if [ -f /etc/systemd/timesyncd.conf.d/ntp.conf ] && \
       grep -qE 'NTP=.*(aliyun|tencent)' /etc/systemd/timesyncd.conf.d/ntp.conf 2>/dev/null; then
        info "NTP: 已换境内(阿里/腾讯)"
    else
        warn "NTP: 仍用默认 arch.pool(开机可能被 atomupd 拖慢) → sudo bash $SCRIPT_NAME 10"
    fi

    # ── 自愈服务自查(第[12]步) ──
    if [ -f "$REAL_HOME/.config/systemd/user/steamos-self-heal.service" ] && \
       [ -f "$REAL_HOME/.local/opt/steamos-self-heal/self-heal-after-upgrade.sh" ]; then
        info "自愈服务: 已部署(系统升级后开机自动重建被冲掉的配置)"
        [ -f /etc/sudoers.d/steamos-self-heal ] \
            && info "  自愈 sudo 免密: 已配" \
            || warn "  自愈 sudo 免密: 缺失(系统升级冲掉了? 重跑: sudo bash $SCRIPT_NAME 12)"
    else
        warn "自愈服务: 未部署(建议装: sudo bash $SCRIPT_NAME 12, 免得下次升级再手动恢复)"
    fi

    echo
    step "步骤进度(断点续传)"
    if [ -s "$STATE_FILE" ]; then
        local _k _v
        while IFS='=' read -r _k _v; do
            case "$_k" in
                setup_*|clean_rootfs) info "$(step_label "$_k"): $_v" ;;
            esac
        done < "$STATE_FILE"
        echo "  重跑同一条命令会跳过以上步骤; FORCE=1 强制重跑, --reset 清进度"
    else
        warn "无进度记录(首次运行, 或已 --reset)"
    fi
    echo
}

# ===========================================================================
#  参数解析
# ===========================================================================
map_step() {
    case "$1" in
        1|cn|source) echo setup_cn ;;
        2|im|ibus|input|pinyin|rime) echo setup_im ;;
        3|wb|workbuddy) echo setup_wb ;;
        4|backkey|gpd) echo setup_backkey ;;
        5|decky) echo setup_decky ;;
        6|games|game|proton|鸣潮|终末地) echo setup_games ;;
        7|dsh|harness|deepseek) echo setup_dsh ;;
        8|clean|rootfs|slim)   echo clean_rootfs ;;
        9|tdp|tdpctl|power)    echo setup_tdp ;;
        10|ntp|ntpcn|time|timesync) echo setup_ntp ;;
        11|gpu|dlss|fsr|upscale|显卡) echo setup_gpu ;;
        12|selfheal|heal|自愈) echo setup_selfheal ;;
        *) echo "" ;;
    esac
}

# ---------- 认领当前已达标的步骤(只检测登记, 不安装) ----------
# 用途: 本机已经是"目标状态"(比如手工配好的机器)时, 用它把已达标的步骤登记为完成,
#       这样日后重跑全量会自动跳过, 不必白白重装一遍 WorkBuddy / 重配 IBus 等。
#       只做落地复核, 不改动任何系统配置, 不联网。
adopt_state() {
    step "认领当前已达标的步骤(只检测, 不安装)"
    echo "  判据: 各步骤的落地复核(文件/包/systemd unit 是否真实存在)"
    echo
    local fn adopted=0 pending=0
    for fn in setup_cn setup_im setup_wb setup_backkey setup_decky setup_games setup_dsh setup_tdp setup_ntp setup_gpu setup_selfheal; do
        if verify_step "$fn"; then
            state_mark "$fn"
            info "[认领] $(step_label "$fn") —— 已达标"
            adopted=$((adopted + 1))
        else
            warn "[待做] $(step_label "$fn") —— 尚未达标"
            pending=$((pending + 1))
        fi
    done
    echo
    info "认领 $adopted 步 / 待做 $pending 步"
    [ "$pending" -gt 0 ] && echo "  接着跑: sudo bash $SCRIPT_NAME --status 复查, 或直接跑未完成的那几步"
    exit 0
}

# 原始参数快照: prepare() 里 exec sudo 重跑脚本时要原样带上(见 prepare 内注释)
ORIG_ARGS=("$@")

FUNCS=()
DO_RESET=0
AFTER_UPGRADE=0
ARGC=$#
for arg in "$@"; do
    case "$arg" in
        --status) show_status; exit 0 ;;
        --device) show_device; exit 0 ;;
        --adopt) state_init; adopt_state ;;
        --reset) DO_RESET=1 ;;
        --force|-f) FORCE=1 ;;
        # 升级后一键恢复: 语义同"全量重跑", 靠落地复核只补被冲掉的那些
        --after-upgrade|restore) AFTER_UPGRADE=1 ;;
        -h|--help|help) show_help ;;
        *)
            fn="$(map_step "$arg")"
            [ -n "$fn" ] && FUNCS+=("$fn")
            ;;
    esac
done
# --after-upgrade 刻意**不**另立一份"恢复子集", 直接走下面的默认全量:
#   ① 单独维护子集迟早和全量列表漂移(实测已经漏过 setup_dsh);
#   ② 恢复哪些本就该由主循环的落地复核决定 —— 完好的自动跳过, 被冲掉的才重建,
#      多跑几个"其实没坏"的步骤只是多几次判空, 代价远小于漏恢复一项;
#   ③ 以后新增步骤(如 [13])自动纳入恢复范围, 不用记得回来补两处。
# AFTER_UPGRADE 只用于: 版本变化提示 + rootfs 空间预检。
[ ${#FUNCS[@]} -eq 0 ] && FUNCS=(setup_cn setup_im setup_wb setup_backkey setup_decky setup_games setup_dsh setup_tdp setup_ntp setup_gpu setup_selfheal)

if [ "$DO_RESET" -eq 1 ]; then
    state_reset
    [ "$ARGC" -le 1 ] && exit 0      # 只给了 --reset, 不要顺便跑全量
fi
state_init

# ── 系统版本变化检测 ──
# SteamOS 大版本升级(A/B 原子更新)会整块替换 rootfs, 把 /etc /usr /opt 下的
# 一切修改覆盖掉, 但进度文件在 /home 会幸存。若不主动提示, 用户只会觉得
# "改动莫名其妙没了"。记录上次的 VERSION_ID, 变了就明确告知并自动重建。
detect_os_upgrade() {
    [ -f /etc/os-release ] || return 0
    local cur prev
    cur="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"')"
    [ -n "$cur" ] || return 0
    prev="$(state_get __osversion)"
    if [ -z "$prev" ]; then
        state_mark __osversion "$cur"
        return 0
    fi
    if [ "$cur" != "$prev" ]; then
        echo
        warn "检测到系统版本变化: $prev → $cur"
        echo "       SteamOS 大版本升级会整块替换 rootfs 镜像,"
        echo "       /etc /usr /opt 下的修改(pacman 包 / 背键 unit / udev 规则 /"
        echo "       inputplumber 配置 / NTP drop-in)已被新版覆盖。"
        echo "       正在自动重建 —— 只补缺失项, 已完好的步骤会跳过。"
        echo
        state_mark __osversion "$cur"
    fi
}

# 升级后一键恢复时, 先告警 rootfs 空间(新镜像更大, 重装 pacman 包需要余量)
if [ "$AFTER_UPGRADE" -eq 1 ]; then
    _avail="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "$_avail" ] && [ "$_avail" -lt 600 ]; then
        warn "rootfs 仅剩 ${_avail}MB。恢复需要重装 pacman 包(WorkBuddy/electron 等), 建议先腾空间:"
        echo "       sudo bash $(dirname "$(readlink -f "$0")")/free-rootfs.sh --apply"
        echo
    fi
fi

# 全量时先 prepare 一次(避免每步重复), 单步时由各函数自行 prepare
if [ $# -eq 0 ]; then
    prepare
    detect_os_upgrade
else
    detect_os_upgrade
fi

# ── 断点续传主循环 ──
# 记过"完成"的步骤先做落地复核: 真的还在才跳过; 落地物没了就自动重跑。
#
# 为什么不能只信进度文件(踩过的坑, 别改回去):
#   SteamOS 大版本升级是 A/B 原子更新, 整块替换 rootfs 镜像 →
#   /etc /usr /opt 下的一切(背键 unit / udev 规则 / inputplumber 配置 /
#   NTP drop-in / pacman 装的包)全部被新镜像覆盖。
#   但进度文件在 $REAL_HOME/.cache/ 下(属 /home 分区)会**幸存**。
#   于是升级后重跑脚本, 若只看进度文件, 会认为"全都已完成"而全部跳过 →
#   一个都恢复不了。故跳过前必须 verify_step 复核落地物。
for fn in "${FUNCS[@]}"; do
    # 升级恢复模式: 只补"曾经装过、现在被冲掉"的, **不趁机新装从没装过的**。
    # 例: dsh 用户从没装过(state 无记录), 不该在一次"恢复"里冒出来。
    # 新装机请直接跑全量(不带 --after-upgrade); FORCE=1 时不拦。
    if [ "$AFTER_UPGRADE" -eq 1 ] && [ "$FORCE" -ne 1 ] && ! state_done "$fn"; then
        info "[跳过] $(step_label "$fn") —— 此前未安装过(升级恢复只补曾经有过的)"
        continue
    fi
    if [ "$FORCE" -ne 1 ] && state_done "$fn"; then
        # 注意: 主循环在顶层, 不能用 local(bash 会报 "local: 只能在函数中使用")
        _sv="$(state_get "$fn")"
        case "$_sv" in
            skipped*)
                info "[跳过] $(step_label "$fn") —— 本机不适用($_sv)"
                continue ;;
        esac
        if verify_step "$fn"; then
            info "[跳过] $(step_label "$fn") —— 已完成于 $_sv  (FORCE=1 可强制重跑)"
            continue
        fi
        # 记过完成但落地物没了 → 几乎必然是系统升级冲掉的, 自动重建
        warn "[重建] $(step_label "$fn") —— 记录已完成但落地物缺失"
        echo "        (多半是 SteamOS 大版本升级整块替换了 rootfs, 正在自动恢复...)"
    fi
    if "$fn" 2>&1; then
        # 退出码 0 也不全信: 再做一次落地复核, 防止"假成功"被记成已完成
        if verify_step "$fn"; then
            state_get "$fn" | grep -q "^skipped" || state_mark "$fn"
            info "[完成] $(step_label "$fn")  $(state_get "$fn")"
        else
            warn "$(step_label "$fn") 退出正常但落地复核未通过 → 不记进度, 下次重跑会重试"
        fi
    else
        warn "$(step_label "$fn") 未完整成功 → 不记进度, 修好后重跑会自动续上"
    fi
    echo
done
echo
step "全部完成"
echo "  复查: bash $SCRIPT_NAME --status"
echo "  分步: bash $SCRIPT_NAME 1 2 3 4 5 6 7 8 9 10"
