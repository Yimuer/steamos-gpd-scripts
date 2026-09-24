#!/usr/bin/env bash
# ===========================================================================
#  verify-upstreams.sh —— 上游依赖体检(只读, 不下载不安装任何东西)
# ---------------------------------------------------------------------------
#  用途: 重装系统前 / 发布前 / 隔一段时间, 跑一次确认所有外部依赖还活着。
#        脚本里那些 release API、下载地址、仓库包名、镜像前缀都是"外部事实",
#        上游随时会变(改名 / 下线 / 加签名 / 换路径), 本工具把它们集中探一遍,
#        免得真到重装那天才发现某个地址 404 了。
#
#  为什么需要它: 本项目 2026-09-24 的一次体检就抓到三个真问题 ——
#    · WPS 官方已换到「Linux2023 通道 + 时间戳签名」, 老的静态 URL 只剩旧版本;
#    · ghfast.top / ghproxy.net 对 api.github.com 一律 403(只代理下载路径);
#    · archlinuxcn 里已经没有任何微信包(可选包那个条目当时必然失败)。
#
#  用法:
#    bash verify-upstreams.sh            # 全查(需要联网)
#    bash verify-upstreams.sh --quick    # 跳过 archlinuxcn 大文件下载
#  退出码: 0 = 关键项全通(可选/建议项失败不影响); 1 = 有关键项失败
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_OK=$'\033[32m'; C_E=$'\033[31m'; C_D=$'\033[2m'
pass() { printf '  %s✓%s %-44s %s\n' "$C_OK" "$C_R" "$1" "${2:-}"; }
fail() { printf '  %s✗%s %-44s %s\n' "$C_E" "$C_R" "$1" "${2:-}"; }
skip() { printf '  %s-%s %-44s %s\n' "$C_D" "$C_R" "$1" "${2:-}"; }
head_() { printf '\n%s%s%s\n' "$C_D" "$1" "$C_R"; }

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1
CRIT_FAIL=0; OPT_FAIL=0

# code_of URL [curl 额外参数...]
code_of() {
    local u="$1"; shift
    curl -s -o /dev/null -w '%{http_code}' -L --connect-timeout 10 --max-time 30 "$@" "$u" 2>/dev/null
}
# 探一个 URL: $1=标签 $2=URL $3=critical(1/0)
probe() {
    local label="$1" url="$2" crit="${3:-1}" code
    code="$(code_of "$url")"
    case "$code" in
        200|206|301|302|303|307|308) pass "$label" "HTTP $code" ;;
        '') fail "$label" "连不上/超时"; [ "$crit" -eq 1 ] && CRIT_FAIL=1 || OPT_FAIL=1 ;;
        *)  fail "$label" "HTTP $code";   [ "$crit" -eq 1 ] && CRIT_FAIL=1 || OPT_FAIL=1 ;;
    esac
}
# 探 GitHub 资源: 脚本实际是"镜像优先、直连兜底", 故按同一顺序判, 命中即通过。
# (这样才不会因为"本机直连 github 不通"就误报关键失败 —— 那正是镜像存在的意义)
probe_gh() {
    local label="$1" url="$2" m
    for m in "https://gh-proxy.com/" "https://ghfast.top/" "https://ghproxy.net/"; do
        if [ "$(code_of "${m}${url}")" = "200" ]; then pass "$label" "${m%/}"; return 0; fi
    done
    if [ "$(code_of "$url")" = "200" ]; then pass "$label" "直连"; return 0; fi
    fail "$label" "镜像+直连全部失败"; CRIT_FAIL=1
}
# 取 GitHub 最新 tag(直连失败走 gh-proxy; 见主脚本 gh_latest_tag 的注释)
gh_tag() {
    local repo="$1" api t=""
    for api in "https://api.github.com" "https://gh-proxy.com/https://api.github.com"; do
        t="$(curl -sL --connect-timeout 8 --max-time 25 "$api/repos/$repo/releases/latest" 2>/dev/null \
             | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        [ -n "$t" ] && break
    done
    printf '%s\n' "$t"
}

echo "════════ 上游依赖体检  $(date '+%F %T') ════════"

# ── 1. GitHub release API(脚本查版本用) ────────────────────────────────
head_ "① GitHub release API"
for repo in localsend/localsend dsh-tauri/deepseek-harness-desktop \
            xfangfang/wiliwili SteamDeckHomebrew/decky-loader; do
    t="$(gh_tag "$repo")"
    if [ -n "$t" ]; then pass "$repo" "最新 $t"
    else fail "$repo" "取不到 tag(API 不通?)"; CRIT_FAIL=1; fi
done

# ── 2. 镜像前缀(下载 vs API 是两回事) ──────────────────────────────────
head_ "② 镜像前缀  (下载路径 = 关键; API 路径 = 可选)"
DL_TEST="https://github.com/localsend/localsend/releases/download/$(gh_tag localsend/localsend || echo v1.18.2)/LocalSend-1.18.2-linux-x86-64.AppImage"
API_TEST="https://api.github.com/repos/localsend/localsend/releases/latest"
for m in "https://gh-proxy.com/" "https://ghfast.top/" "https://ghproxy.net/"; do
    probe "${m%/} 下载路径" "${m}${DL_TEST}" 1
    # 镜像对 API 的代理属"可选": 实测 ghfast/ghproxy.net 一律 403 → 只提示, 不算失败
    code="$(code_of "${m}${API_TEST}")"
    if [ "$code" = "200" ]; then pass "${m%/} API 路径" "HTTP 200"
    else printf '  %s-%s %-42s %s\n' "$C_D" "$C_R" "${m%/} API 路径" "HTTP ${code:-000} (不代理 API, 正常)"; fi
done
probe "直连 下载路径(可选)" "$DL_TEST" 0

# ── 3. 各应用的下载地址 ────────────────────────────────────────────────
head_ "③ 下载地址(HEAD 探测, 不下载)"
probe "Mozilla Nightly zh-CN 解析" \
      "https://download.mozilla.org/?product=firefox-nightly-latest-l10n-ssl&os=linux64&lang=zh-CN" 1
probe "archive.mozilla.org(脚本首选源)" \
      "https://archive.mozilla.org/pub/firefox/nightly/latest-mozilla-central-l10n/" 0

LS_TAG="$(gh_tag localsend/localsend)"; LS_VER="${LS_TAG#v}"
if [ -n "$LS_VER" ]; then
    probe_gh "LocalSend AppImage $LS_VER" \
          "https://github.com/localsend/localsend/releases/download/$LS_TAG/LocalSend-${LS_VER}-linux-x86-64.AppImage"
else
    skip "LocalSend AppImage" "拿不到版本, 跳过"
fi

DSH_TAG="$(gh_tag dsh-tauri/deepseek-harness-desktop)"; DSH_VER="${DSH_TAG#v}"
if [ -n "$DSH_VER" ]; then
    probe_gh "dsh 桌面版 AppImage $DSH_VER" \
          "https://github.com/dsh-tauri/deepseek-harness-desktop/releases/download/$DSH_TAG/Deepseek.Harness.Desktop_${DSH_VER}_amd64.AppImage"
else
    skip "dsh 桌面版 AppImage" "拿不到版本, 跳过"
fi

# WPS: 现行通道要带时间戳签名(k = md5(key+uri+t)), 老通道只对 ≤11.x 有效
WPS_VER="${WPS_VER:-12.1.2.28080}"
WPS_KEY="${WPS_SIGN_KEY:-7f8faaaa468174dc1c9cd62e5f218a5b}"
WPS_URI="/wps/download/ep/Linux2023/${WPS_VER##*.}/wps-office_${WPS_VER}.AK.preread.sw.Personal_765474_amd64.deb"
WPS_T="$(date '+%s')"
WPS_K="$(printf '%s' "${WPS_KEY}${WPS_URI}${WPS_T}" | md5sum | cut -d' ' -f1)"
probe "WPS 官方签名通道 $WPS_VER" \
      "https://wps-linux-personal.wpscdn.cn${WPS_URI}?t=${WPS_T}&k=${WPS_K}" 1
probe "WPS 老通道(仅 ≤11.x 有效, 可选)" \
      "https://wdl1.pcfg.cache.wpscdn.com/wpsdl/wpsoffice/download/linux/11723/wps-office_11.1.0.11723.XA_amd64.deb" 0

WTAG="$(gh_tag xfangfang/wiliwili)"; WTAG="${WTAG:-v1.6.0}"
probe_gh "wiliwili flatpak 包 $WTAG" \
      "https://github.com/xfangfang/wiliwili/releases/download/$WTAG/wiliwili-Linux-x86_64.flatpak"

# NextKde: 只发源码、不发 release, 所以探的是"上游安装器还在不在原路径"
# (install-nextkde-home.sh 依赖 tools/kosctl; 上游改结构就会失效)
probe "NextKde 上游 tools/kosctl 路径" \
      "https://raw.githubusercontent.com/SuceV587/NextKde/main/tools/kosctl" 1

# ── 4. AUR 包(主脚本 step3 装 WorkBuddy 靠它) ──────────────────────────
# ⚠ AUR RPC 会限流: 连续快速查询可能返回空体。故重试一次, 且"无响应"只算提示不判死。
head_ "④ AUR 包"
for p in workbuddy wps-office wps-office-cn; do
    v=""
    for _ in 1 2; do
        v="$(curl -s --connect-timeout 10 --max-time 30 \
             "https://aur.archlinux.org/rpc/v5/info?arg[]=$p" 2>/dev/null \
             | sed -n 's/.*"Version":"\([^"]*\)".*/\1/p' | head -1)"
        [ -n "$v" ] && break
        sleep 2
    done
    if [ -n "$v" ]; then pass "AUR $p" "$v"
    else printf '  %s-%s %-42s %s\n' "$C_D" "$C_R" "AUR $p" "查询无响应(限流?) — 稍后手工复查"; OPT_FAIL=1; fi
done

# ── 5. 仓库包(可选组件依赖) ────────────────────────────────────────────
head_ "⑤ 仓库包(archlinuxcn / 官方源)"
if [ "$QUICK" -eq 1 ]; then
    skip "archlinuxcn 包清单" "--quick 跳过"
else
    DB="$(mktemp /tmp/acn-db.XXXXXX.tar.gz)"
    if curl -s --connect-timeout 15 --max-time 120 \
            -o "$DB" "https://mirrors.ustc.edu.cn/archlinuxcn/x86_64/archlinuxcn.db.tar.gz" 2>/dev/null \
       && [ -s "$DB" ]; then
        D="$(mktemp -d /tmp/acn-x.XXXXXX)"
        tar -xzf "$DB" -C "$D" 2>/dev/null
        n="$(ls "$D" 2>/dev/null | wc -l)"
        pass "archlinuxcn 包清单" "$n 个包"
        for p in wechat-universal-bwrap wechat-beta wechat; do
            if compgen -G "$D/${p}-*" >/dev/null 2>&1; then pass "  archlinuxcn $p" "有"
            else printf '  %s-%s %-42s %s\n' "$C_D" "$C_R" "archlinuxcn $p" "无(可选包会退到 AUR)"; fi
        done
        if compgen -G "$D/localsend-*" >/dev/null 2>&1; then pass "  archlinuxcn localsend" "有"
        else fail "  archlinuxcn localsend" "无"; OPT_FAIL=1; fi
        if compgen -G "$D/wps*" >/dev/null 2>&1; then pass "  archlinuxcn wps" "有(注意会装进 /usr)"
        else printf '  %s-%s %-42s %s\n' "$C_D" "$C_R" "archlinuxcn wps" "无(本项目走官方 deb, 正常)"; fi
        rm -rf "$D"
    else
        fail "archlinuxcn 包清单" "下载失败"; OPT_FAIL=1
    fi
    rm -f "$DB"
fi

# ── 汇总 ───────────────────────────────────────────────────────────────
echo
if [ "$CRIT_FAIL" -eq 0 ] && [ "$OPT_FAIL" -eq 0 ]; then
    echo "════ 全部通过：上游依赖都在 ════"; exit 0
fi
if [ "$CRIT_FAIL" -eq 0 ]; then
    echo "════ 关键项全通；有『可选』项失败(见上面 - 行)，不影响重装 ════"; exit 0
fi
echo "════ 有关键项失败：重装前请先处理(改地址/换源/更新兜底版本) ════"; exit 1
