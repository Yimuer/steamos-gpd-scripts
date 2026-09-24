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
cd "$(dirname "$0")"
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
for fn in setup_cn setup_wb setup_backkey setup_decky setup_games setup_dsh setup_tdp setup_ntp setup_gpu setup_selfheal setup_wiliwili; do
    grep -q "^$fn() {" "$S" || { bad "步骤函数缺失: $fn"; }
done
grep -q 'state_done\|state_mark\|verify_step' "$S" && pass "断点续传状态机完整" || bad "状态机关键函数缺失"
# 2.5 外层 heredoc 禁用手法不得再现(事故根源)
grep -q "^: <<'EOF'" "$S" && bad "检测到裸的 ': <<EOF' 块禁用手法(事故模式), 请改用逐行注释或移出存档" || pass "无危险 heredoc 块禁用手法"

echo "════════ 3) shellcheck (可选, 未安装则跳过) ════════"
if command -v shellcheck >/dev/null 2>&1; then
    n="$(shellcheck -S warning -f gcc "$S" 2>/dev/null | grep -c "SC[0-9]")"
    [ "$n" -eq 0 ] && pass "shellcheck warning 级 = 0" || bad "shellcheck 发现 $n 个 warning 级问题"
else
    echo "  [i] 未安装 shellcheck, 跳过(Windows 下可在 tools/ 放 shellcheck.exe)"
fi

echo
[ "$FAIL" -eq 0 ] && { echo "════ 全部通过 ════"; exit 0; } || { echo "════ 存在失败项, 请修复后重跑 ════"; exit 1; }
