#!/usr/bin/env bash
# diag-endfield.sh —— 终末地「黑屏 / 无声音」现场取证
#
# 用法：游戏卡在黑屏时（别关游戏），在 Konsole 里跑：
#     bash ~/Downloads/steamos-reinstall-backup/diag-endfield.sh
# 结果写到 ~/endfield-diag-<时间戳>.txt，把那个文件发出来即可。
#
# 只读取，不修改任何东西。

set -uo pipefail

PFX="${HOME}/.local/share/Steam/steamapps/compatdata/2237343548/pfx/drive_c"
LL="${PFX}/users/steamuser/AppData/LocalLow/Hypergryph"
GAME="${HOME}/Downloads/Hypergryph Launcher/games/Arknights Endfield"
OUT="${HOME}/endfield-diag-$(date +%Y%m%d-%H%M%S).txt"

sec() { printf '\n===== %s =====\n' "$*" >>"$OUT"; }

{
  printf '终末地黑屏诊断  %s\n' "$(date '+%F %T')"
  printf '会话: XDG_SESSION_TYPE=%s DISPLAY=%s WAYLAND_DISPLAY=%s\n' \
    "${XDG_SESSION_TYPE:-unset}" "${DISPLAY:-unset}" "${WAYLAND_DISPLAY:-unset}"
  printf '内核: %s\n' "$(uname -r)"

  sec "1. 进程（游戏 / SDK / 网页 / ACE）"
  ps -eo pid,pcpu,pmem,etime,comm --sort=-pcpu 2>/dev/null \
    | grep -iE "endfield|platformprocess|launcher|qtwebengine|cefview|winedevice|proton|wineserver|gamescope" \
    | head -25 || echo "(无匹配进程 —— 游戏已经退出了)"

  sec "2. 窗口列表（谁在显示、多大、在哪）"
  if command -v xdotool >/dev/null 2>&1; then
    xdotool search --onlyvisible . 2>/dev/null | while read -r w; do
      printf '%s | %s | %s\n' "$w" \
        "$(xdotool getwindowname "$w" 2>/dev/null)" \
        "$(xdotool getwindowgeometry "$w" 2>/dev/null | tr '\n' ' ')"
    done | head -20
  else
    echo "(xdotool 未安装，窗口信息跳过)"
  fi
  printf '屏幕: %s\n' "$(xrandr 2>/dev/null | grep -m1 ' current ' || echo '?')"

  sec "3. U8Data 配置文件是否存在（关键：缺失=SDK 拿不到 appCode）"
  for p in "${LL}/Endfield/U8Data" "${GAME}/U8Data" "${LL}/U8Data"; do
    printf '%-70s %s\n' "$p" "$([ -d "$p" ] && echo '存在' || echo '【缺失】')"
    [ -d "$p" ] && find "$p" -maxdepth 3 -printf '    %s  %p\n' 2>/dev/null | head -10
  done
  echo "-- 全盘搜 config.bin / config.gryph / u8ExtraConfig.bin --"
  find "${HOME}" \( -iname 'config.bin' -o -iname 'config.gryph' -o -iname 'u8ExtraConfig.bin' \) \
    -printf '    %s  %p\n' 2>/dev/null | head -10
  echo "(以上为空即表示从未生成)"

  sec "3b. 游戏进程工作目录 CWD（若不是游戏目录，相对路径的 config 就读不到）"
  for pid in $(pgrep -x Endfield.exe 2>/dev/null); do
    printf 'Endfield.exe pid=%s  cwd=%s\n' "$pid" "$(readlink /proc/$pid/cwd 2>/dev/null || echo '?')"
  done
  pgrep -x Endfield.exe >/dev/null 2>&1 || echo "(Endfield.exe 未在运行 —— 请在黑屏时、别关游戏再跑本脚本)"
  printf '期望 cwd = %s\n' "$GAME"
  printf 'config.ini 在游戏目录: %s\n' "$([ -f "$GAME/config.ini" ] && stat -c '%s bytes, mtime=%y' "$GAME/config.ini" || echo '【缺失】')"

  sec "3c. 是否真的在渲染（GFX 峰值内存）"
  PL0="${LL}/Endfield/Player.log"
  if [ -f "$PL0" ]; then
    grep -a -A3 '\[ALLOC_GFX_MAIN\]' "$PL0" 2>/dev/null | grep -a 'Peak Allocated memory' | tail -2
    echo "(几十 KB = 什么都没画，纯黑；几 MB 以上 = 真的渲染了画面)"
    grep -a -c 'Peak usage frame count' "$PL0" 2>/dev/null | sed 's/^/分配器统计出现次数(>0 说明已退出时打印): /'
  fi

  sec "3d. 远程配置接口连通性（extra config 从这里下发）"
  for u in "https://game-config.hypergryph.com/api/remote_config/v2/canary" \
           "https://u8.hypergryph.com" "https://endfield.gryphline.com"; do
    printf '%-58s %s\n' "$u" \
      "$(timeout 10 curl -s -o /dev/null -w 'HTTP=%{http_code} %{time_total}s' "$u" 2>/dev/null || echo 'FAIL')"
  done

  sec "3e. 启动器读到的游戏配置（应有 appCode / region）"
  grep -a 'ReadGameConfig' "${LL}/33a0a6296a20400d503c59ac0fd6341e/logs/games.log" 2>/dev/null | tail -1 | cut -c1-300

  sec "4. 登录状态（启动器是否 login）"
  grep -a -c "user not login" "${LL}/33a0a6296a20400d503c59ac0fd6341e/logs/games.log" 2>/dev/null \
    | sed 's/^/games.log 中 "user not login" 次数: /'
  tail -5 "${LL}/33a0a6296a20400d503c59ac0fd6341e/logs/games.log" 2>/dev/null

  sec "5. Player.log 尾部（过滤 vulkan 噪音）"
  PL="${LL}/Endfield/Player.log"
  [ -f "$PL" ] && grep -vE "vulkan (instance|device) extension|VK_|^UnityEngine\.|^System\.|^Hypergryph\.SpeedTest\.|^Rewired\.|^Beyond\." "$PL" | tail -40 \
    || echo "(无 Player.log)"

  sec "6. SDK 日志"
  for f in u8sdk_pc.log platfrom_process.log u8core_ui_pc.log hgsdk_pc.log; do
    printf -- '--- %s ---\n' "$f"
    tail -20 "${LL}/Endfield/sdklogs/$f" 2>/dev/null || echo "  (无)"
  done

  sec "7. Chromium / QtWebEngine 错误（debug.log）"
  if [ -f "${GAME}/debug.log" ]; then
    stat -c 'debug.log 最后更新: %y' "${GAME}/debug.log"
    echo "-- 非 ICU 报错的行 --"
    grep -v "icu_util.cc" "${GAME}/debug.log" 2>/dev/null | tail -25
    echo "-- ICU 报错行数（应已消失）: $(grep -c 'icu_util.cc' "${GAME}/debug.log" 2>/dev/null) --"
  else
    echo "(无 debug.log)"
  fi

  sec "8. 是否新崩溃"
  find "${PFX}/users/steamuser/AppData/Local/Temp/Hypergryph/Endfield/Crashes" \
    -maxdepth 1 -mindepth 1 -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort -r | head -5
} >"$OUT" 2>&1

echo "诊断已写入: $OUT"
echo
echo "--- 摘要 ---"
grep -nE "【缺失】|cwd=|峰值|Peak Allocated memory|user not login 次数|Crash!!!|FormatException|Parse config fail|appCode is null|Couldn't mmap|HTTP=" "$OUT" | head -25
echo
echo "把 $OUT 这个文件发出来即可。"
