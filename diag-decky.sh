#!/usr/bin/env bash
# ===========================================================================
#  diag-decky.sh —— Decky 插件体检 / 修复
# ---------------------------------------------------------------------------
#  为什么要有它: Decky 插件崩起来是"游戏模式整个插件面板变成一屏报错"
#  (典型 `Minified React error #130` = 组件 undefined), 而根因通常只有两类:
#     ① Decky 的 **Pre-Release / Testing 通道**开着 → 装到带哈希的 nightly 构建,
#        与当前 Steam 客户端不匹配 → 渲染即崩(崩了会被反复 unload, 日志里刷屏);
#     ② 插件包半损坏(缺 dist/index.js)。
#  这两类都能在命令行一次看清 —— 不用在游戏模式里一屏屏猜。
#
#  用法:
#    bash diag-decky.sh                     # 只读体检(不需要 root)
#    bash diag-decky.sh --repair            # 用商店**稳定版**重装预置插件(需 root)
#    bash diag-decky.sh --repair SteamGridDB   # 只重装指定插件(可多个, 空格分隔)
#    bash diag-decky.sh --channels-stable   # 把 Decky 的 branch/store 通道改回稳定(备份后改)
#
#  退出码: 0 = 没发现问题; 1 = 有问题(见输出); 2 = 用法/前提错误
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'; C_B=$'\033[1m'; C_D=$'\033[2m'
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_R" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_R" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$C_RD" "$C_R" "$*"; }
sub()  { printf '      %s%s%s\n' "$C_D" "$*" "$C_R"; }
head_() { printf '\n%s── %s ──%s\n' "$C_B" "$*" "$C_R"; }

# ── 定位: Decky 的家目录 + 免密快照里的主脚本(它才是能免密跑的那份) ──
HB="${DECKY_HOME:-}"
if [ -z "$HB" ]; then
    for d in "$HOME/homebrew" /home/*/homebrew; do [ -d "$d" ] && { HB="$d"; break; }; done
fi
[ -n "$HB" ] || { echo "找不到 Decky 目录(~/homebrew) —— 没装 Decky?" >&2; exit 2; }

SNAP="/opt/steamos-backup/steamos-setup.sh"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/steamos-setup.sh"
MAIN=""; [ -f "$SNAP" ] && MAIN="$SNAP"; [ -n "$MAIN" ] || MAIN="$REPO"

MODE="check"; REPAIR_LIST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repair)   MODE="repair" ;;
        --channels-stable) MODE="channels" ;;
        -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         echo "未知参数: $1" >&2; exit 2 ;;
        *)          MODE="repair"; REPAIR_LIST="$REPAIR_LIST $1" ;;
    esac
    shift
done

PROBLEMS=0

# ── 1. Decky 本体与通道 ─────────────────────────────────────────────────
head_ "Decky 本体与更新通道"
ver="$(cat "$HB/services/.loader.version" 2>/dev/null | tr -d '\n')"
case "$ver" in v*) ;; ?*) ver="v$ver" ;; esac        # 文件里本来就带 v, 别拼成 vv3.2.9
[ -n "$ver" ] && ok "Decky Loader $ver" || warn "读不到 ~/homebrew/services/.loader.version"
LOADER_JSON="$HB/settings/loader.json"
BRANCH=""; STORE=""
if [ -f "$LOADER_JSON" ]; then
    command -v jq >/dev/null 2>&1 || { echo "需要 jq 读 loader.json" >&2; exit 2; }
    BRANCH="$(jq -r '.branch // "?"' "$LOADER_JSON" 2>/dev/null)"
    STORE="$(jq -r '.store // "?"' "$LOADER_JSON" 2>/dev/null)"
    case "$BRANCH" in
        0) ok "Decky 本体通道: Stable" ;;
        *) bad "Decky 本体通道 = Pre-Release(branch=$BRANCH) —— 本体也吃 nightly, 出问题更难查"; PROBLEMS=$((PROBLEMS+1)) ;;
    esac
    case "$STORE" in
        0) ok "插件商店通道: Stable" ;;
        *) bad "插件商店通道 = Testing(store=$STORE) —— **装到的插件是带哈希的 nightly 构建**"
           sub "这是插件崩掉最常见的原因; 切回稳定: bash $0 --channels-stable(或界面里把 Pre-Release 切回 Stable)"
           PROBLEMS=$((PROBLEMS+1)) ;;
    esac
else
    warn "没有 $LOADER_JSON(Decky 从没跑过?)"
fi

# ── 2. 插件清单: 版本 / 是否 testing 构建 / 包是否完整 ─────────────────────
head_ "插件清单"
shopt -s nullglob
for pdir in "$HB"/plugins/*/; do
    name="$(basename "$pdir")"
    pver=""
    [ -f "$pdir/package.json" ] && pver="$(jq -r '.version // ""' "$pdir/package.json" 2>/dev/null)"
    [ -n "$pver" ] || pver="$(jq -r '.version // ""' "$pdir/plugin.json" 2>/dev/null)"
    [ -n "$pver" ] || pver="?"
    # 带 -<7位以上十六进制> 后缀 = 从 main 编出来的测试构建(Decky 的 testing 通道制品)
    testing=0
    case "$pver" in *-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) testing=1 ;; esac
    miss=""
    [ -f "$pdir/plugin.json" ] || miss="$miss plugin.json"
    [ -f "$pdir/dist/index.js" ] || miss="$miss dist/index.js"
    if [ -n "$miss" ]; then
        bad "$name $pver —— 包不完整, 缺:$miss"; PROBLEMS=$((PROBLEMS+1))
    elif [ "$testing" -eq 1 ]; then
        warn "$name $pver —— 带哈希 = **测试构建**(nightly)"
        PROBLEMS=$((PROBLEMS+1))
    else
        ok "$name $pver"
    fi
done
shopt -u nullglob

# ── 3. 崩溃循环证据: 日志里短时间内反复 unload ─────────────────────────────
head_ "崩溃循环证据(最近日志里的反复 unload)"
looping=0
shopt -s nullglob
for ldir in "$HB"/logs/*/; do
    pname="$(basename "$ldir")"
    n=0
    for lf in "$ldir"*.log; do
        # ⚠️ 别写 `grep -c … || echo 0`: grep -c 无匹配时**已经输出 0** 但返回 1,
        #    那个 `|| echo 0` 会再补一个 0 → 变量成了 "0\n0", 下一行算术直接炸(踩过)。
        c="$(grep -c 'Unloaded' "$lf" 2>/dev/null)"
        n=$((n + ${c:-0}))
    done
    if [ "$n" -ge 4 ]; then
        bad "$pname: 日志里出现 $n 次 Unloaded —— 前端在反复崩→被卸载(这就是报错屏的来源)"
        sub "看细节: tail -40 \"$ldir\"\$(ls -1t \"$ldir\" | head -1)"
        looping=1; PROBLEMS=$((PROBLEMS+1))
    elif [ "$n" -gt 0 ]; then
        sub "$pname: $n 次 unload(正常量级)"
    fi
done
shopt -u nullglob
[ "$looping" -eq 0 ] && ok "没有发现崩溃循环"

# ── 4. 结论与修法 ───────────────────────────────────────────────────────
printf '\n%s══ 结论 ══%s\n' "$C_B" "$C_R"
if [ "$PROBLEMS" -eq 0 ]; then
    ok "Decky 这边的通道、插件包、日志都正常"
    exit 0
fi
bad "有 $PROBLEMS 项要注意。修法(按推荐顺序):"
sub "① 游戏模式里那张报错屏上直接点「Disable <插件名>」—— 立刻止血, Decky 其它功能照常"
sub "② 切回稳定通道: bash $0 --channels-stable   (或 Decky 设置里把 Pre-Release 切回 Stable)"
sub "③ 用商店**稳定版**重装插件: bash $0 --repair            (默认重装 SteamGridDB + ProtonDB Badges)"
sub "   只重装某个: bash $0 --repair SteamGridDB"
sub "④ 重装后要重启 Steam 才会注入: 完全退出 Steam(不是关窗口)再开"

# ── 5. 执行动作(--repair / --channels-stable) ───────────────────────────
if [ "$MODE" = "channels" ]; then
    printf '\n%s── 切回稳定通道 ──%s\n' "$C_B" "$C_R"
    if [ ! -f "$LOADER_JSON" ]; then bad "没有 $LOADER_JSON, 无从下手"; exit 1; fi
    bak="$LOADER_JSON.bak.$(date +%m%d-%H%M%S)"
    cp -a "$LOADER_JSON" "$bak" && ok "已备份 → $bak"
    tmp="$(mktemp)"
    jq '.branch = 0 | .store = 0' "$LOADER_JSON" > "$tmp" && mv "$tmp" "$LOADER_JSON" \
        && ok "branch/store 已改为 0(Stable)" \
        || { bad "改写失败"; exit 1; }
    warn "要让 Decky 重新读它: 重启 Decky(界面里的 Restart Decky, 或 sudo systemctl restart plugin_loader)"
    sub "若它又被改回 1: 说明界面里还选着 Pre-Release, 用界面下拉切更稳"
fi

if [ "$MODE" = "repair" ]; then
    printf '\n%s── 用稳定版重装插件 ──%s\n' "$C_B" "$C_R"
    # 用主脚本步骤[5] 装(= 走 deckbrew **不带 testing** 的清单, 拿到的是纯 semver 稳定版);
    # 用 --decky-plugins= 开关而不是环境变量: 环境变量会被 sudo 的 env_reset 剥掉(项目老教训)。
    list="${REPAIR_LIST:- SteamGridDB|ProtonDB Badges}"
    list="${list# }"; list="${list// /|}"
    sub "主脚本: $MAIN"
    sub "插件清单: $list"
    if sudo -n bash "$MAIN" 5 --decky-plugins="$list"; then
        ok "重装完成 —— 现在完全退出 Steam 再开, 插件面板应恢复正常"
    else
        bad "重装未成功(需要 root; 若提示要密码, 先 sudo bash $MAIN 12 重建免密)"
        exit 1
    fi
fi
exit 1
