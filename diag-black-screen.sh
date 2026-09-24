#!/usr/bin/env bash
# ============================================================================
#  黑屏取证脚本 —— 游戏黑屏时(不要关游戏)在另一个终端跑一次
#
#  用途: 一次性区分黑屏的三大类原因, 省得反复猜
#    A. 在编译 shader / 解压资源  → CPU 高, 应耐心等
#    B. 渲染 API 失败(DX12/Vulkan) → GPU 0% 且日志有 RHI 报错
#    C. 窗口位置/遮挡/最小化       → 窗口几何异常或不可见
#
#  用法:
#    bash diag-black-screen.sh            # 自动识别鸣潮/终末地
#    bash diag-black-screen.sh 鸣潮
#  产物: ~/black-screen-diag-<时间戳>.txt
# ============================================================================

set -uo pipefail
OUT="$HOME/black-screen-diag-$(date +%m%d-%H%M%S).txt"
GAME="${1:-auto}"

exec > >(tee "$OUT") 2>&1

C_R=$'\033[0m'; C_RD=$'\033[31m'
hr()  { printf '\n════════ %s ════════\n' "$*"; }
sub() { printf '  %s\n' "$*"; }

hr "0. 基本信息"
printf '  时间: %s\n' "$(date '+%F %T')"
printf '  机型: %s / %s\n' "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" \
                          "$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
printf '  系统: %s\n' "$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2-)"
printf '  会话: XDG_SESSION_TYPE=%s  WAYLAND_DISPLAY=%s  DISPLAY=%s\n' \
    "${XDG_SESSION_TYPE:-未设}" "${WAYLAND_DISPLAY:-未设}" "${DISPLAY:-未设}"

# ── 显卡占用(需要有权限读; 失败不致命) ──
hr "1. GPU 占用(Radeon 专有接口)"
GPU_BUSY=""
for f in /sys/class/drm/card*/device/gpu_busy_percent; do
    [ -r "$f" ] && GPU_BUSY="$(cat "$f" 2>/dev/null)" && sub "$(dirname "$(dirname "$f")") gpu_busy_percent=${GPU_BUSY}%"
done
[ -z "$GPU_BUSY" ] && sub "读不到 gpu_busy_percent(权限或路径不同), 跳过"

# ── 2. 游戏进程 CPU: 判定是不是在编译 shader ──
hr "2. 游戏进程 CPU(关键判定)"
PAT='Wuthering|Endfield|Launcher|Client-Win64|steam'
ps -eo pid,pcpu,etime,rss,comm,args --sort=-pcpu 2>/dev/null \
  | grep -aiE "$PAT" | grep -v grep | head -15 \
  | while read -r pid pcpu etime rss _comm args; do
        printf '  PID=%-7s CPU=%-6s%% 已运行=%-10s 内存=%-8s %s\n' \
            "$pid" "$pcpu" "$etime" "$((rss/1024))M" \
            "$(printf '%s' "$args" | cut -c1-90)"
    done
cat <<'EOF'

  怎么判:
    · 主游戏进程 CPU > 50%  → 在干活(编译 shader / 解压) → 耐心等 10~20 分钟
    · 主游戏进程 CPU ≈ 0%  → 卡死了或在等什么 → 看下面第 4 段日志
EOF

# ── 3. 窗口几何: 是不是在屏幕外 / 尺寸异常 ──
hr "3. 窗口列表与几何"
if command -v kdotool >/dev/null 2>&1; then
    kdotool search --class . 2>/dev/null | while read -r w; do
        printf '  %s | %s | %s\n' "$w" \
            "$(kdotool getwindowname "$w" 2>/dev/null)" \
            "$(kdotool getwindowgeometry "$w" 2>/dev/null | tr '\n' ' ')"
    done
elif command -v xdotool >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
    xdotool search --onlyvisible . 2>/dev/null | while read -r w; do
        printf '  %s | %s | %s\n' "$w" \
            "$(xdotool getwindowname "$w" 2>/dev/null)" \
            "$(xdotool getwindowgeometry "$w" 2>/dev/null | tr '\n' ' ')"
    done
else
    sub "无 kdotool/xdotool, 跳过窗口几何"
fi
sub "当前输出模式:"
xrandr 2>/dev/null | grep -E " connected|\*" | head -6 | sed 's/^/    /'
[ -z "$(xrandr 2>/dev/null)" ] && sub "  (Wayland 会话, xrandr 不可用)"

# ── 3.5 终末地: 一眼判定"在编译 shader" 还是 "SDK 坏了" ──
# 这是 2026-09-09 实战总结出的最快判据, 不用读几百行日志
hr "3.5 终末地: 一键判据(最关键)"
EF_BASE=""
for d in "$HOME"/.local/share/Steam/steamapps/compatdata/*/; do
    [ -d "${d}pfx/drive_c/users/steamuser/AppData/LocalLow/Hypergryph/Endfield" ] && { EF_BASE="${d}pfx/drive_c/users/steamuser/AppData/LocalLow/Hypergryph/Endfield"; break; }
done
if [ -n "$EF_BASE" ]; then
    sub "数据目录: $EF_BASE"
    # (a) SDK 健康度
    V="$(grep -ahoE 'SetGameVersion:[^[:space:]]*' "$EF_BASE"/sdklogs/u8sdk_pc*.log 2>/dev/null | tail -1)"
    V="${V#SetGameVersion:}"
    case "$V" in
        prod_*)              sub "SDK 状态     : 健康 (SetGameVersion:$V)" ;;
        INVALID_EXTRA_CONFIG*) sub "SDK 状态     : ${C_RD}损坏 (SetGameVersion:$V)${C_R} → 跑 reset-endfield-sdk.sh" ;;
        "")                  sub "SDK 状态     : 未知(读不到 SetGameVersion)" ;;
        *)                   sub "SDK 状态     : ${V:0:60}" ;;
    esac
    # (b) PSO 缓存大小: 空/极小 = 首次编译中, 几十 MB = 已编译过
    P="$EF_BASE/vulkan_pso_cache.bin"
    if [ -f "$P" ]; then
        SZ="$(stat -c '%s' "$P")"
        MB=$((SZ/1024/1024))
        if [ "$SZ" -lt 100000 ]; then
            sub "PSO 缓存     : ${SZ} 字节 (≈空) → ${C_RD}首次 shader 编译中, 纯黑屏是正常的, 耐心等${C_R}"
        else
            sub "PSO 缓存     : ${MB} MB → 已编译过, 黑屏就另有原因"
        fi
    else
        sub "PSO 缓存     : 不存在 → 首次启动, 正在编译 shader"
    fi
    # (c) 是否真的画了东西(注意: 必须按数值排序, 字符串排序会让 "9.5 MB" > "73.2 MB")
    GFX="$(grep -aoE 'Peak Allocated memory [0-9.]+ ?[KMG]?B' "$EF_BASE/Player.log" 2>/dev/null \
          | awk '{v=$4+0; u=($5==""?"MB":$5); if(u=="KB")v/=1024; else if(u=="GB")v*=1024; printf "%.1f\n", v}' \
          | sort -g | tail -1)"
    if [ -n "$GFX" ]; then
        sub "GPU 峰值内存 : ${GFX} MB  ← 取 Player.log 里最大值"
        awk -v v="$GFX" 'BEGIN{printf "  " ; if (v+0 < 1) print "判读: 几乎没画东西 → 初始化被打断(SDK 问题)" ; else print "判读: 已渲染出画面 → 黑屏另有原因"}'
    fi
else
    sub "未找到终末地数据目录(跳过)"
fi

# ── 4. 游戏日志尾部 ──
hr "4. 游戏日志(尾部)"
WW_LOG="$HOME/Downloads/Wuthering Waves/Wuthering Waves Game/Client/Saved/Logs/Client.log"
EF_LOG="${EF_BASE:+$EF_BASE/Player.log}"
[ -z "$EF_LOG" ] && EF_LOG="$HOME/.local/share/Steam/steamapps/compatdata/<未找到>/pfx/.../Endfield/Player.log"

dump() { # $1=文件 $2=说明
    if [ -f "$1" ]; then
        printf '  ── %s (%-10s, %s 字节)\n' "$2" "$(stat -c '%y' "$1" 2>/dev/null | cut -c1-19)" "$(stat -c '%s' "$1" 2>/dev/null)"
        # 加密/二进制日志别整段贴, 全是乱码没信息量
        # 不能用 grep -P(本机 grep 未编译 PCRE), 改用 tr 统计可打印字符比例, POSIX 可靠
        _tot="$(tail -c 4096 "$1" 2>/dev/null | wc -c)"
        _prn="$(tail -c 4096 "$1" 2>/dev/null | LC_ALL=C tr -dc '[:print:]\n\t' | wc -c)"
        if [ "${_tot:-0}" -gt 0 ] && [ $(( _prn * 100 / _tot )) -lt 80 ]; then
            printf '     (该日志为加密/二进制格式, 可打印字符仅 %s%%, 已跳过内容)\n' $(( _prn * 100 / _tot ))
            printf '     鸣潮 Client.log 本身就是加密的, 别在上面浪费时间 —— 看第 2 段 CPU 即可。\n'
        else
            tail -25 "$1" 2>/dev/null | sed 's/^/     /'
        fi
    else
        printf '  ── %s: 不存在 (%s)\n' "$2" "$1"
    fi
}

case "$GAME" in
    鸣潮|wuwa|ww)  dump "$WW_LOG" "鸣潮 Client.log" ;;
    终末地|ef)     dump "$EF_LOG" "终末地 Player.log" ;;
    *)             dump "$WW_LOG" "鸣潮 Client.log"; dump "$EF_LOG" "终末地 Player.log" ;;
esac

# ── 5. Steam 环境变量(是否误判成 Steam Deck) ──
hr "5. Steam 环境(关键: SteamDeck 变量)"
sub "以下从正在运行的 Steam/游戏进程环境读取:"
for p in $(pgrep -f "steam.sh|Wuthering|Endfield" 2>/dev/null | head -5); do
    [ -r "/proc/$p/environ" ] || continue
    printf '  PID %s: %s\n' "$p" \
        "$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null \
            | grep -aiE '^(SteamDeck|SteamGamepadUI|SteamOS|SDL_|ENABLE_|PROTON_|DXVK_|VKD3D_|RADV_|gamescope)' \
            | tr '\n' ' ' | cut -c1-200)"
done
cat <<'EOF'

  ⚠️ 若看到 SteamDeck=1 → 游戏会套用 Steam Deck 默认配置(1280x800 系),
     而 GPD Win5 是 1920x1080。解决办法: 启动选项加  SteamDeck=0 %command%

  注(2026-09-09 实测): 本机进程环境里**没有** SteamDeck=1, 鸣潮
  GameUserSettings.ini 里的 DesiredScreenWidth=1280x720 是 UE4 引擎自身默认值,
  不是 Deck 配置。所以除非上面真的打出 SteamDeck=1, 否则别去加 SteamDeck=0。
EOF

# ── 6. Proton / DXVK 状态 ──
hr "6. 兼容层与着色器缓存"
printf '  已装兼容层:\n'
ls -1 "$HOME/.local/share/Steam/compatibilitytools.d/" 2>/dev/null | sed 's/^/    /'
printf '  鸣潮 shader 缓存:\n'
find "$HOME/.local/share/Steam/steamapps/shadercache" -maxdepth 1 -newermt "-2 days" \
    -printf '    %f  %TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | head -10
sub "(刚重装系统时这里几乎为空 → 首次启动必然要现编译 shader, 黑屏一段时间是正常的)"

hr "完成"
printf '  结果已存: %s\n' "$OUT"
printf '  把这个文件发出来即可定位。\n'
