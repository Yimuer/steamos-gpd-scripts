#!/usr/bin/env bash
# ===========================================================================
#  check.sh —— 备份包自检脚本 (只读, 不改任何系统配置, 无需 root)
# ---------------------------------------------------------------------------
#  背景: 2026-09-24 曾因 heredoc 注入禁用段的方式击穿, 导致整包脚本语法损坏。
#  本脚本做三件事, 防止同类事故复发:
#    1) 对所有 .sh 跑 bash -n 语法检查
#    2) 断言关键不变量(输入法禁用 / 预置插件 / 断点续传状态机完整)
#    3) 若机器上有 shellcheck, 顺带静态扫描(warning 级)
#  用法: bash check.sh        (在备份包任意位置跑; exit 0 = 全过)
# ===========================================================================
set -u
cd "$(dirname "$0")" || exit 1
FAIL=0
pass() { echo "  [✓] $1"; }
bad()  { echo "  [✗] $1"; FAIL=1; }

echo "════════ 1) bash -n 语法检查 ════════"
while IFS= read -r f; do
    case "$f" in ./archive/*|./disabled/*|*/nix/store/*) continue ;; esac
    if err="$(bash -n "$f" 2>&1)"; then
        pass "$f"
    else
        bad "$f 语法错误"; echo "$err" | sed 's/^/        /'
    fi
done < <(find . -type f -name "*.sh" -not -path "./archive/*" -not -path "./disabled/*")

echo "════════ 2) 关键不变量断言 ════════"
S=steamos-setup.sh
[ -f "$S" ] && pass "$S 存在" || { bad "$S 缺失"; }

# 2.1 输入法约束(2026-09-24): setup_im 必须保持空函数, 不得有任何改系统输入法的动作
body="$(sed -n '/^setup_im() {/,/^}/p' "$S" 2>/dev/null)"
if [ -n "$body" ] && ! printf '%s' "$body" | grep -qE 'pacman +-S|kwinrc|dconf|autostart|ibus\.conf|GTK_IM_MODULE|XMODIFIERS|ENV_DIR|FISH_CONF'; then
    pass "setup_im 保持禁用(函数体内无输入法写入动作)"
else
    bad "setup_im 断言失败 —— 函数体为空或包含输入法相关写入, 立即检查!"
fi
# 2.2 输入法相关历史脚本必须留在 disabled/, 不能被移回执行位
for f in fix-ibus-simplified.sh setup-fcitx5-flypy.sh setup-steam-game-mode-ime.sh; do
    [ -f "disabled/$f" ] && [ ! -f "$f" ] \
        && pass "$f 已归档于 disabled/" || bad "$f 位置异常(应在 disabled/)"
done
# 2.3 Decky 预置插件配置存在
grep -q 'DECKY_PLUGINS-"SteamGridDB ProtonDB Badges"' "$S" \
    && pass "Decky 预置插件列表正确(SteamGridDB + ProtonDB Badges)" \
    || bad  "Decky 预置插件配置丢失"
grep -q 'install_decky_plugin()' "$S" \
    && pass "install_decky_plugin 助手存在" \
    || bad  "install_decky_plugin 缺失"
# 2.4 断点续传状态机关键节点
for fn in setup_cn setup_wb setup_backkey setup_decky setup_games setup_dsh setup_tdp setup_ntp setup_gpu setup_selfheal setup_wiliwili setup_localsend; do
    grep -q "^$fn() {" "$S" || { bad "步骤函数缺失: $fn"; }
done
grep -q 'state_done\|state_mark\|verify_step' "$S" && pass "断点续传状态机完整" || bad "状态机关键函数缺失"
# 2.5 外层 heredoc 禁用手法不得再现(事故根源)
grep -q "^: <<'EOF'" "$S" && bad "检测到裸的 ': <<EOF' 块禁用手法(事故模式), 请改用逐行注释或移出存档" || pass "无危险 heredoc 块禁用手法"
# 2.6 WorkBuddy /home 自持化(2026-09-24): 脚本在, 且步骤[3]确实调用它
if [ -f install-workbuddy-home.sh ]; then
    pass "install-workbuddy-home.sh 存在"
    bash -n install-workbuddy-home.sh 2>/dev/null || bad "install-workbuddy-home.sh 语法错误"
    grep -q 'install-workbuddy-home.sh' "$S" \
        && pass "步骤[3] 已接入 /home 自持化调用" \
        || bad "步骤[3] 未调用 install-workbuddy-home.sh"
    # 自持化路径与主体路径必须与 PKGBUILD 的硬编码一致
    grep -q '"/opt/WorkBuddy"' install-workbuddy-home.sh \
        && pass "主体路径 /opt/WorkBuddy 与 AUR 硬编码一致" \
        || bad "主体路径被改动 —— AUR 已把 process.resourcesPath 硬编码为 /opt/WorkBuddy, 改则必崩"
else
    bad "install-workbuddy-home.sh 缺失(WorkBuddy 会被原子升级冲掉)"
fi
# 2.7 可选组件: Firefox Nightly 的 /home 自持脚本
if [ -f install-firefox-nightly-home.sh ]; then
    pass "install-firefox-nightly-home.sh 存在"
    bash -n install-firefox-nightly-home.sh 2>/dev/null || bad "install-firefox-nightly-home.sh 语法错误"
    grep -q 'FF_HOME="\$REAL_HOME/.local/opt/firefox-nightly"' install-firefox-nightly-home.sh \
        && pass "安装目标在 /home 下(原子升级幸存的前提)" \
        || bad "安装目标被改出 /home —— 那样就白做了"
    grep -q 'install-firefox-nightly-home.sh' 可选组件安装.sh \
        && pass "可选组件菜单已接入 Firefox Nightly" \
        || bad "可选组件菜单未接入 install-firefox-nightly-home.sh"
    grep -q 'MENU_CHECK' 可选组件安装.sh \
        && pass "可选组件菜单支持自定义已装判据(MENU_CHECK)" \
        || bad "MENU_CHECK 机制丢失 —— firefox-nightly 的 ✓ 标记会永远不亮"
else
    bad "install-firefox-nightly-home.sh 缺失(Firefox Nightly 会被原子升级冲掉)"
fi
# 2.8 可选组件: DeepSeek Harness 桌面版的 /home 自持脚本
if [ -f install-dsh-desktop-home.sh ]; then
    pass "install-dsh-desktop-home.sh 存在"
    bash -n install-dsh-desktop-home.sh 2>/dev/null || bad "install-dsh-desktop-home.sh 语法错误"
    grep -q 'APP_ROOT="\$REAL_HOME/.local/opt/deepseek-harness-desktop"' install-dsh-desktop-home.sh \
        && pass "安装目标在 /home 下(原子升级幸存的前提)" \
        || bad "安装目标被改出 /home —— 那样就白做了"
    grep -q '_amd64\.AppImage' install-dsh-desktop-home.sh \
        && pass "取的是 AppImage 资产" \
        || bad "资产选择被改: 那个 deb 依赖 libwebkit2gtk-4.1-0 + libappindicator3-1 + libgtk-3-0, SteamOS 上装不了还占 rootfs"
    grep -q 'install-dsh-desktop-home.sh' 可选组件安装.sh \
        && pass "可选组件菜单已接入 dsh-desktop" \
        || bad "可选组件菜单未接入 install-dsh-desktop-home.sh"
else
    bad "install-dsh-desktop-home.sh 缺失"
fi
# 2.9 步骤[14] LocalSend: 三处接入缺一不可
#     —— 最容易烂掉的是"自愈清单": 防火墙规则在 /etc, 升级必被冲,
#        若没登记进 self-heal 的 CHECKS, 升级后就会"程序在但搜不到对端"且永不自动修。
grep -q '^setup_localsend() {' "$S" \
    && pass "步骤[14] setup_localsend 存在" \
    || bad "步骤[14] setup_localsend 缺失"
grep -q '14|localsend' "$S" \
    && pass "map_step 已认 localsend(可 sudo bash steamos-setup.sh 14)" \
    || bad "map_step 未接 localsend —— 步骤号参数无法直达"
grep -q 'fwport|14' self-heal-after-upgrade.sh \
    && pass "自愈的 fwport 项已挂到步骤[14](数值对得上)" \
    || bad "自愈的 fwport 项没挂到步骤[14] —— 检测到缺失也不会去重建它(自愈清单是按步骤号挂的)"
grep -q 'fwport' self-heal-after-upgrade.sh \
    && pass "自愈清单含 fwport 判据(端口放行类)" \
    || bad "自愈清单缺 fwport 判据 —— 升级后防火墙规则不会被重建"
grep -q '53317' self-heal-after-upgrade.sh \
    && pass "自愈清单盯住 53317(LocalSend 发现+传输)" \
    || bad "自愈清单没盯 53317"
grep -q 'linux-x86-64\.AppImage' "$S" \
    && pass "步骤[14] 取的是含运行时的 AppImage(tar.gz 依赖系统 gtk3)" \
    || bad "步骤[14] 资产选择被改 —— tar.gz 依赖系统 gtk3, SteamOS 上不一定有"
# 2.10 可选组件: WPS Office 的 /opt + /home 脚本
#      —— 两条不能退让的不变量: ①装到 /opt(官方 Relocations) ②桌面项 Exec/TryExec 改绝对路径
if [ -f install-wps-office-home.sh ]; then
    pass "install-wps-office-home.sh 存在"
    bash -n install-wps-office-home.sh 2>/dev/null || bad "install-wps-office-home.sh 语法错误"
    grep -q 'OPT_DIR="/opt/kingsoft/wps-office"' install-wps-office-home.sh \
        && pass "本体装到 /opt/kingsoft(官方 Relocations 目标)" \
        || bad "本体目标被改出 /opt/kingsoft —— 该 deb 声明 Relocations: /opt/kingsoft 且 1.55GB, 换到 /usr 必炸 rootfs"
    # 只看代码行(注释里正解释"为什么别走 /usr/lib/office6", 不该误伤)
    grep -v '^[[:space:]]*#' install-wps-office-home.sh | grep -q '/usr/lib/office6' \
        && bad "代码里出现 AUR 那种 /usr/lib/office6 布局 —— 1.55GB 进 rootfs 会 ENOSPC" \
        || pass "代码没走 AUR 的 /usr/lib/office6 布局"
    grep -q 'Exec|TryExec' install-wps-office-home.sh \
        && pass "桌面项 Exec/TryExec 会改成绝对路径(TryExec 找不到会隐藏菜单项)" \
        || bad "桌面项没有改 Exec/TryExec —— 菜单项可能因 TryExec 找不到而不显示"
    grep -q 'install-wps-office-home.sh' 可选组件安装.sh \
        && pass "可选组件菜单已接入 wps-office" \
        || bad "可选组件菜单未接入 install-wps-office-home.sh"
else
    bad "install-wps-office-home.sh 缺失"
fi
# 2.11 可选组件: 鸿蒙字体 —— 三条不能退让的约定
if [ -f install-harmony-sans-home.sh ]; then
    pass "install-harmony-sans-home.sh 存在"
    bash -n install-harmony-sans-home.sh 2>/dev/null || bad "install-harmony-sans-home.sh 语法错误"
    grep -q 'FONT_DIR="$REAL_HOME/.local/share/fonts' install-harmony-sans-home.sh \
        && pass "字体装到 /home(原子升级幸存的前提)" \
        || bad "字体目标被改出 /home —— AUR 那套装到 /usr/share/fonts, 升级必被冲"
    grep -q 'FC_DIR="$REAL_HOME/.config/fontconfig/conf.d"' install-harmony-sans-home.sh \
        && pass "fontconfig 落 conf.d/(不覆盖用户已有的 fonts.conf)" \
        || bad "fontconfig 落点变了 —— 直接写 fonts.conf 会覆盖用户已有配置"
    # monospace 一旦被 prefer, 终端/代码字体会错乱(鸿蒙是比例字体)
    grep -A6 '<family>monospace</family>' install-harmony-sans-home.sh | grep -q prefer \
        && bad "给 monospace 写了 prefer —— 鸿蒙是比例字体, 会让终端/代码字体错乱" \
        || pass "monospace 未被改写(终端/代码字体不受影响)"
    grep -q 'install-harmony-sans-home.sh' 可选组件安装.sh \
        && pass "可选组件菜单已接入 harmony-sans" \
        || bad "可选组件菜单未接入 install-harmony-sans-home.sh"
else
    bad "install-harmony-sans-home.sh 缺失"
fi

echo "════════ 3) shellcheck (可选, 未安装则跳过) ════════"
# 找 shellcheck: 先在 PATH 里找, 再找本目录 tools/ 下的(shellcheck 或 shellcheck.exe)
SC=""
for c in shellcheck ./tools/shellcheck ./tools/shellcheck.exe; do
    if command -v "$c" >/dev/null 2>&1; then SC="$c"; break; fi
done
if [ -n "$SC" ]; then
    n=0
    while IFS= read -r f; do
        case "$f" in ./archive/*|./disabled/*|./steamos-nix/*) continue ;; esac
        c="$("$SC" -S warning -f gcc "$f" 2>/dev/null | grep -c 'SC[0-9]')"
        [ -n "$c" ] && n=$((n + c))
    done < <(find . -type f -name "*.sh")
    [ "$n" -eq 0 ] && pass "shellcheck warning 级 = 0 (全部脚本)" \
                   || bad "shellcheck 发现 $n 个 warning 级问题"
else
    echo "  [i] 未安装 shellcheck —— 放一个到 tools/shellcheck(.exe) 即可启用;"
    echo "      当前全部脚本的 warning 级已清零, 装上后应保持 0"
fi

echo
[ "$FAIL" -eq 0 ] && { echo "════ 全部通过 ════"; exit 0; } || { echo "════ 存在失败项, 请修复后重跑 ════"; exit 1; }
