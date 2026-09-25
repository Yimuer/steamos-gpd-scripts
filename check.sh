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
# 2.7-2.10 可选组件的三个"下载便携包"类应用
#       —— 三者共用 install-app-home.sh 单引擎(骨架只写一遍, 各应用一段 profile)。
#          断言盯住的仍是每个应用"不能退让的那条不变量"。
if [ -f install-app-home.sh ]; then
    pass "install-app-home.sh 存在(单引擎)"
    bash -n install-app-home.sh 2>/dev/null || bad "install-app-home.sh 语法错误"
    # 3 个 app 都必须注册在引擎里
    for a in firefox-nightly dsh-desktop wps-office; do
        grep -qE "^ *$a\)" install-app-home.sh \
            && pass "引擎已注册 $a" || bad "引擎缺 $a 的 profile"
    done
    # Firefox: 装到 /home
    grep -q 'VENDOR_DIR="\$LOCAL/opt/firefox-nightly"' install-app-home.sh \
        && pass "firefox 安装目标在 /home 下(原子升级幸存的前提)" \
        || bad "firefox 目标被改出 /home —— 那样就白做了"
    # dsh: 装到 /home, 且取 AppImage
    grep -q 'VENDOR_DIR="\$LOCAL/opt/deepseek-harness-desktop"' install-app-home.sh \
        && pass "dsh 安装目标在 /home 下" \
        || bad "dsh 目标被改出 /home"
    grep -q '_amd64\.AppImage' install-app-home.sh \
        && pass "dsh 取的是 AppImage 资产" \
        || bad "dsh 资产选择被改: 那个 deb 依赖 libwebkit2gtk-4.1-0 + libappindicator3-1, SteamOS 上装不了还占 rootfs"
    # WPS: 装到 /opt + 桌面项改绝对路径 + 不走 AUR 的 /usr/lib
    grep -q 'DEST_DIR="/opt/kingsoft/wps-office"' install-app-home.sh \
        && pass "WPS 本体装到 /opt/kingsoft(官方 Relocations 目标)" \
        || bad "WPS 目标被改出 /opt/kingsoft —— 该 deb 声明 Relocations: /opt/kingsoft 且 2GB, 换到 /usr 必炸 rootfs"
    grep -v '^[[:space:]]*#' install-app-home.sh | grep -q '/usr/lib/office6' \
        && bad "代码里出现 AUR 那种 /usr/lib/office6 布局 —— 2GB 进 rootfs 会 ENOSPC" \
        || pass "代码没走 AUR 的 /usr/lib/office6 布局"
    # 引擎里是两条独立 sed: Exec 与 TryExec 都必须被重写到 $BIN_DIR
    if grep -q 'Exec=\$BIN_DIR' install-app-home.sh && grep -q 'TryExec=\$BIN_DIR' install-app-home.sh; then
        pass "WPS 桌面项 Exec/TryExec 都会改成绝对路径(TryExec 找不到会隐藏菜单项)"
    else
        bad "WPS 桌面项没同时改 Exec 与 TryExec —— 菜单项可能因 TryExec 找不到而不显示"
    fi
    # 菜单接入(三项都走同一个引擎)
    for a in firefox-nightly dsh-desktop wps-office; do
        grep -q "install-app-home.sh $a\|bash \"\$s\" $a" 可选组件安装.sh \
            && pass "可选组件菜单已接入 $a" \
            || bad "可选组件菜单未接入 $a"
    done
    grep -q 'MENU_CHECK' 可选组件安装.sh \
        && pass "可选组件菜单支持自定义已装判据(MENU_CHECK)" \
        || bad "MENU_CHECK 机制丢失 —— firefox-nightly 的 ✓ 标记会永远不亮"
    # 引擎自身的两条硬约束(踩过坑的)
    grep -q '>&2' install-app-home.sh \
        && pass "引擎的 fetch 提示走 stderr(stdout 只留路径)" \
        || bad "fetch 提示没走 stderr —— ARCHIVE=\$(fetch ...) 会把日志一起吞进去, 后面 bsdtar 找不到文件"
    grep -q '已是 \$ver → 跳过' install-app-home.sh \
        && pass "引擎有'同版本跳过重活'的快速路径(2GB 不该白复制)" \
        || bad "同版本快速路径丢了 —— 重跑会白复制 2GB"
else
    bad "install-app-home.sh 缺失(firefox/dsh/wps 都会被原子升级冲掉)"
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
# 2.10 (WPS 的断言已并入上面的"单引擎"块)
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
# 2.12 可选组件: NextKde(KOS 桌面外壳) —— 它必须"包装上游", 不能自己重写构建
if [ -f install-nextkde-home.sh ]; then
    pass "install-nextkde-home.sh 存在"
    bash -n install-nextkde-home.sh 2>/dev/null || bad "install-nextkde-home.sh 语法错误"
    grep -q 'tools/kosctl' install-nextkde-home.sh \
        && pass "包装上游官方安装器 kosctl(不自己重写构建)" \
        || bad "没有调上游 kosctl —— 重写构建逻辑会与上游脱节"
    grep -q 'NEXTKDE_DIR:-$REAL_HOME/.local/opt/NextKde' install-nextkde-home.sh \
        && pass "源码/构建目录在 /home(原子升级幸存)" \
        || bad "源码目录被改出 /home"
    # 三条必须提前告知用户的后果(rootfs 依赖 / 切外壳 / KWin 插件耦合)
    grep -q 'rootfs' install-nextkde-home.sh \
        && pass "已告知编译依赖会进 rootfs(升级被冲)" \
        || bad "没告知 rootfs 后果"
    grep -q 'ShellPackage' install-nextkde-home.sh \
        && pass "已告知会切换桌面外壳(plasmashellrc ShellPackage)" \
        || bad "没告知切换外壳的后果(壁纸会重置)"
    grep -q 'kwin-version-at-build' install-nextkde-home.sh \
        && pass "记录了构建时的 KWin 版本(用于升级后判定插件要不要重编)" \
        || bad "没记录 KWin 版本 —— KWin 升级后无法判定插件是否失配"
    grep -q '输入 yes' install-nextkde-home.sh \
        && pass "换桌面外壳前有显式确认(非交互环境会安全退出)" \
        || bad "缺确认步骤 —— 不该默默把桌面外壳换掉"
    grep -q 'install-nextkde-home.sh' 可选组件安装.sh \
        && pass "可选组件菜单已接入 nextkde" \
        || bad "可选组件菜单未接入 install-nextkde-home.sh"
else
    bad "install-nextkde-home.sh 缺失"
fi
# 2.13 启动器: 执行位 + 薄壳约束
#      —— "双击没反应"最常见的原因就是执行位丢了(.desktop 必须可执行 Dolphin 才肯跑),
#         而 TryExec 写终端会让没装该终端的机器上整个入口消失。
#      只在 git 仓库里查执行位(备份包可能是纯文件拷贝, 没有 .git)
if [ -d .git ]; then
    for f in steamos-setup.sh 可选组件安装.sh 重装后先运行我.sh; do
        [ -f "$f" ] || { bad "$f 缺失"; continue; }
        [ "$(git ls-files -s -- "$f" 2>/dev/null | awk '{print $1}')" = "100755" ] \
            && pass "$f 在 git 里可执行(100755)" \
            || bad "$f 在 git 里不是 100755 —— 拷到 Linux 后会直接运行失败"
    done
    if [ -f 重装后先运行我.desktop ]; then
        [ "$(git ls-files -s -- 重装后先运行我.desktop 2>/dev/null | awk '{print $1}')" = "100755" ] \
            && pass "启动器 .desktop 在 git 里可执行(否则 Dolphin 双击静默无反应)" \
            || bad "启动器 .desktop 不是 100755 —— 双击会没反应"
    fi
fi
if [ -f 重装后先运行我.desktop ]; then
    grep -q '^TryExec=' 重装后先运行我.desktop \
        && bad "启动器写了 TryExec —— 该程序不存在时整个入口会消失(找不到就别卡它)" \
        || pass "启动器没写 TryExec(不会因缺终端而整个入口消失)"
    grep -q '重装后先运行我\.sh' 重装后先运行我.desktop \
        && pass "启动器是薄壳(调 重装后先运行我.sh, 逻辑只写一份)" \
        || bad "启动器没调 重装后先运行我.sh —— 同一套逻辑会重复两份"
else
    bad "重装后先运行我.desktop 缺失(重装后没有双击入口)"
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
