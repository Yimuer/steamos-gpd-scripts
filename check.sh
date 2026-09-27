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
set -uo pipefail
cd "$(dirname "$0")" || exit 1
FAIL=0
pass() { echo "  [✓] $1"; }
bad()  { echo "  [✗] $1"; FAIL=1; }

# 扫脚本时的统一排除集 —— 判据是"这是不是交付物", 不是"文件在不在"。
#   archive/ disabled/    : 有意保留的历史存档(语法不过也没关系, 它本来就不该跑)
#   .cache/ .workbuddy/ todo/ dist/ tools/ : 运行时/会话/构建产物与第三方二进制
# 2026-09-27 实测教训: 本轮的审计脚本落在 .cache/ 里, 被下面的扫描扫出一条与本仓库
# 代码无关的 shellcheck 红项 —— 排除集漏一项, 门禁就会因为"工具"而不是"产品"变红。
# ⚠️ steamos-nix/ **不在**这个集合里: 第 1 节(语法)照旧扫它 —— 冻结不等于可以损坏,
#    少扫 24 个文件就是少 24 份保障(写这条时差点把它一并排掉, 靠 [✓] 计数从 231
#    掉到 203 才发现)。只有第 3 节 shellcheck 豁免它(冻结分支不追新 lint 结论)。
skip_dir() {
    case "$1" in
        ./archive/*|./disabled/*|./.cache/*|./.workbuddy/*|\
        ./todo/*|./dist/*|./tools/*|*/nix/store/*) return 0 ;;
    esac
    return 1
}

echo "════════ 1) bash -n 语法检查 ════════"
_n_scanned=0
while IFS= read -r f; do
    skip_dir "$f" && continue
    _n_scanned=$((_n_scanned + 1))
    if err="$(bash -n "$f" 2>&1)"; then
        pass "$f"
    else
        bad "$f 语法错误"; echo "$err" | sed 's/^/        /'
    fi
done < <(find . -type f -name "*.sh" -not -path "./.git/*")
# 覆盖面本身要有下限: 排除集写错(比如把整个 steamos-nix 一并排掉)会让"全绿"变成
# "扫得越来越少", 而计数变化没人会去对。与 steamos.sh 注册表"原始行数对账"同一思路。
if [ "$_n_scanned" -lt 40 ]; then
    bad "语法检查只扫了 $_n_scanned 个 .sh(下限 40) —— skip_dir 排除集是不是写宽了?"
else
    pass "语法检查覆盖面 $_n_scanned 个 .sh(≥40)"
fi

echo "════════ 2) 关键不变量断言 ════════"
S=steamos-setup.sh
[ -f "$S" ] && pass "$S 存在" || { bad "$S 缺失"; }

# ─────────────────────────────────────────────────────────────────────────
# 2.0 STEPS 表(必装主线的唯一事实来源) —— 2026-09-27 表驱动改造的守门人
#
#     这一节**不 grep 文案**, 而是把表块整块抽出来、打上桩、真的调用派生出来的
#     map_step / step_label / steps_where, 拿答案对。
#     为什么非要执行: 表驱动的典型故障不是"某个字写错了", 而是"派生出来的行为不对"
#     —— 顺序错一项、别名撞车、某一步悄悄不再进全量列表。这些 grep 全都看不出来,
#     而后果都是"跑全量时静默少装一步"(§13.10.6 那一类)。
#
#     答案表(下面 EXPECT_*)是**独立手抄**的第二份, 故意跟 STEPS 表重复:
#     步骤编号一旦被挪动, 用户手里的 `steamos-setup.sh 12` 语义就变了,
#     这种改动必须逼着"两处一起改"才允许发生。加新步骤时确实要改这里 ——
#     但只需在答案表末尾追加一项, 而原来加一步要在主脚本里改 9 处。
# ─────────────────────────────────────────────────────────────────────────
_h=""          # 派生测试的输出(抽取失败时也要能被后面的交叉核对安全引用)
_tbl="$(sed -n '/# ----8<---- STEPS-TABLE-BEGIN ----/,/# ----8<---- STEPS-TABLE-END ----/p' "$S" 2>/dev/null)"
if ! printf '%s' "$_tbl" | grep -q '^STEPS=('; then
    bad "抽不到 STEPS 表块(标记被改/删? 或表被挪出标记) —— 本节的派生断言全瞎, 先修抽取"
elif ! printf '%s' "$_tbl" | grep -q '^map_step() {'; then
    bad "STEPS 标记块里没有 map_step(被挪出去了?) —— 参数直达失去覆盖, 把它挪回标记块内"
else
    _h="$(
        {
            cat <<'HSTUB'
set -uo pipefail
info(){ :; }
warn(){ :; }
step(){ :; }
err(){ printf 'ERR %s\n' "$*" >&2; }
HSTUB
            printf '%s\n' "$_tbl"
            cat <<'HTEST'
# ── 独立答案表 ──────────────────────────────────────────────────────────
EXPECT_NUMS=(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)
EXPECT_FNS=(setup_cn setup_im setup_wb setup_backkey setup_decky setup_games \
setup_dsh clean_rootfs setup_tdp setup_ntp setup_gpu setup_selfheal \
setup_wiliwili setup_localsend setup_mdread setup_firefox)
# 不带参数跑全量时的执行顺序(步骤[8] rootfs 瘦身**不在**此列 —— 它由步骤[3] 按需触发)
EXPECT_FULL=(setup_cn setup_im setup_wb setup_backkey setup_decky setup_games \
setup_dsh setup_tdp setup_ntp setup_gpu setup_selfheal setup_wiliwili \
setup_localsend setup_mdread setup_firefox)
EXPECT_NOVERIFY=(setup_im clean_rootfs setup_gpu)   # 无落地物, verify 分支恒 return 0(按表序)
NB=0
ok()  { printf 'OK %s\n' "$1"; }
no()  { printf 'BAD %s | 期望[%s] 实得[%s]\n' "$1" "$2" "$3"; NB=$((NB+1)); }
ck()  { [ "$2" = "$3" ] && ok "$1" || no "$1" "$3" "$2"; }

ck "表行数 = ${#EXPECT_NUMS[@]}(与答案表一致)" "${#STEPS[@]}" "${#EXPECT_NUMS[@]}"
ck "步骤总数派生 STEP_TOTAL = 表行数" "$STEP_TOTAL" "${#STEPS[@]}"

# 编号必须连续且与答案表逐项一致(编号被挪动 = 用户手上的命令语义变了)
_i=0
for _r in "${STEPS[@]}"; do
    _i=$((_i+1))
    ck "第 $_i 行的编号 = ${EXPECT_NUMS[$_i-1]}" \
       "$(_step_field "$_r" 1)" "${EXPECT_NUMS[$_i-1]}"
    ck "第 $_i 行的函数 = ${EXPECT_FNS[$_i-1]}" \
       "$(_step_field "$_r" 2)" "${EXPECT_FNS[$_i-1]}"
done

# map_step: 编号 / 每个别名都要能直达; 不认识的一律回空(不能瞎匹配)
for _r in "${STEPS[@]}"; do
    _n="$(_step_field "$_r" 1)"; _f="$(_step_field "$_r" 2)"
    ck "编号 $_n 直达 $_f" "$(map_step "$_n")" "$_f"
    ck "step_no($_f) = $_n" "$(step_no "$_f")" "$_n"
    ck "标题非空($_f)" "$(_step_field "$_r" 3 | grep -c .)" "1"
    case "$(_step_field "$_r" 5)" in y|n) ok "进全量标记合法($_f)";;
                                 *) no "进全量标记非法($_f)" "y 或 n" "$(_step_field "$_r" 5)";; esac
    case "$(_step_field "$_r" 6)" in y|n) ok "有判据标记合法($_f)";;
                                 *) no "有判据标记非法($_f)" "y 或 n" "$(_step_field "$_r" 6)";; esac
    # 别名里混进 glob 或首尾/连续空格, 会让"逐词比较"退化成"按文件名展开", 后果是误命中
    _al="$(_step_field "$_r" 4)"
    if printf '%s' "$_al" | grep -qE '(^ +| +$|  +)'; then
        no "别名格式($_f)" "单个空格分隔、无首尾空格" "$_al"
    else
        case "$_al" in
            *'*'*|*'?'*|*'['*) no "别名含 glob 字符($_f)" "不含 * ? [" "$_al" ;;
                            *) ok "别名格式干净($_f)" ;;
        esac
    fi
    for _a in $(_step_field "$_r" 4); do
        ck "别名 $_a 直达 $_f" "$(map_step "$_a")" "$_f"
    done
done
ck "未知参数回空(不会误当某一步)" "$(map_step nosuchkey)" ""
ck "通配符参数回空(case 会误吃, 逐词比较不会)" "$(map_step '*')" ""
ck "空参数回空" "$(map_step '')" ""

# 全量顺序列表 —— 这条是"跑全量静默少装一步"的直接防线
ck "steps_where 5 y = 全量顺序(15 项)" "$(steps_where 5 y | tr '\n' ' ')" "${EXPECT_FULL[*]} "
ck "不进全量的只有 rootfs 瘦身(别顺手把系统瘦身塞进无人值守)" \
   "$(steps_where 5 n | tr '\n' ' ')" "clean_rootfs "
ck "无落地判据的步骤恰为 3 项(禁用[2]/提示[11]/按需[8])" \
   "$(steps_where 6 n | tr '\n' ' ')" "${EXPECT_NOVERIFY[*]} "

# step_label: 派生格式必须是"编号 标题"; 陌生键回显原值(--status 不能因老进度键崩)
ck "step_label(setup_selfheal) = '12 升级后自愈服务'" \
   "$(step_label setup_selfheal)" "12 升级后自愈服务"
ck "step_label 对陌生键回显原值(不让 --status 崩)" "$(step_label setup_gone_v9)" "setup_gone_v9"

# --help 的步骤清单(2026-09-27 实测它曾停在 15, 步骤[16] 从没进过帮助)
_hl="$(help_step_line)"
ck "help 清单条目数 = 表行数" "$(printf '%s' "$_hl" | grep -o '[0-9]\+/[a-z-]*=' | wc -l | tr -d ' ')" "$STEP_TOTAL"
case "$_hl" in *"16/firefox=Firefox Nightly"*) ok "help 清单含最后一步(16/firefox)" ;;
             *) no "help 清单缺最后一步" "含 16/firefox=…" "$_hl" ;; esac
# 交给 check.sh 后面的静态交叉核对复用(用同一份解析结果, 不再写第二个表解析器)
_xf=""; for _r in "${STEPS[@]}"; do _xf="$_xf$(_step_field "$_r" 2) "; done
printf 'XOUT TOTAL=%s\n' "$STEP_TOTAL"
printf 'XOUT FNS=%s\n' "$_xf"
printf 'XOUT FULL=%s\n' "$(steps_where 5 y | tr '\n' ' ')"
printf 'DONE bad=%d\n' "$NB"
HTEST
        } | bash 2>&1
    )"
    _n_ok="$(printf '%s\n' "$_h" | grep -c '^OK ')"
    _n_bad="$(printf '%s\n' "$_h" | grep -c '^BAD ')"
    _n_err="$(printf '%s\n' "$_h" | grep -c '^ERR ')"
    if [ "$_n_ok" -lt 40 ]; then
        # 断言自己哑了必须报错(§13.10.4 反例②的教训): 表块被改坏时派生测试会
        # 一条都跑不出来, 那时"0 条红"是假绿灯, 比没有断言更危险。
        bad "派生测试只跑出 $_n_ok 条(下限 40) —— 表块或桩坏了, 本节已失效"
        printf '%s\n' "$_h" | head -4 | sed 's/^/        /'
    else
        pass "STEPS 表派生行为可执行(实跑 ${_n_ok} 项断言)"
    fi
    while IFS= read -r _l; do
        case "$_l" in
            BAD\ *) bad "${_l#BAD }" ;;
            ERR\ *) bad "派生代码报错: ${_l#ERR }" ;;
        esac
    done < <(printf '%s\n' "$_h")
    case "$_h" in
        *DONE*)
            if [ "$_n_bad" -eq 0 ] && [ "$_n_err" -eq 0 ]; then
                pass "派生行为全对(全量顺序 15 项 / 别名直达 / help 清单 16 项)"
            else
                bad "派生行为有 ${_n_bad} 红 ${_n_err} 错, 见上"
            fi ;;
        *) bad "派生测试没跑完(输出里没有 DONE 行 —— 中途挂了?)" ;;
    esac
fi

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
# 2.3 Decky 预置插件配置存在(2026-09-25 改为数组: 商店名 "ProtonDB Badges" 自带空格,
#     空格分隔的旧列表会被拆成三个词去查商店, 结果一个都装不上)
grep -q '_plugins=(SteamGridDB "ProtonDB Badges")' "$S" \
    && pass "Decky 预置插件列表正确(SteamGridDB + ProtonDB Badges, 数组形式)" \
    || bad  "Decky 预置插件配置丢失或被改回空格分隔"
grep -q 'install_decky_plugin()' "$S" \
    && pass "install_decky_plugin 助手存在" \
    || bad  "install_decky_plugin 缺失"
# 2.4 断点续传状态机关键节点
#     ("每个步骤函数都在"这条 2026-09-27 起改由 STEPS 表派生, 见 2.0 与 2.15f ——
#      这里原本手抄了 12 个函数名, 本身就是第三份副本, 而且已经漏了 [15][16]。)
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
    # 菜单接入(firefox-nightly 已于 2026-09-25 提为必装步骤[16], 这里不再管它)
    for a in dsh-desktop wps-office; do
        grep -q "install-app-home.sh $a\|bash \"\$s\" $a" 可选组件安装.sh \
            && pass "可选组件菜单已接入 $a" \
            || bad "可选组件菜单未接入 $a"
    done
    grep -q 'MENU_CHECK' 可选组件安装.sh \
        && pass "可选组件菜单支持自定义已装判据(MENU_CHECK)" \
        || bad "MENU_CHECK 机制丢失 —— 非 pacman 项的 ✓ 标记会永远不亮"
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
grep -q 'fwport|14' self-heal-after-upgrade.sh \
    && pass "自愈的 fwport 项已挂到步骤[14](数值对得上)" \
    || bad "自愈的 fwport 项没挂到步骤[14] —— 检测到缺失也不会去重建它(自愈清单是按步骤号挂的)"
grep -q 'fwport' self-heal-after-upgrade.sh \
    && pass "自愈清单含 fwport 判据(端口放行类)" \
    || bad "自愈清单缺 fwport 判据 —— 升级后防火墙规则不会被重建"
grep -q '53317' self-heal-after-upgrade.sh \
    && pass "自愈清单盯住 53317(LocalSend 发现+传输)" \
    || bad "自愈清单没盯 53317"
# 2.9b 防火墙判据不得退回"grep 字面 53317"(2026-09-25 定案)
#     —— SteamOS 出厂 public zone 就开着 1024-65535/tcp+udp, 端口被范围覆盖时
#        firewalld 拒写显式规则(ALREADY_ENABLED), 字面量永远不会出现在配置里。
#        旧判据的实测后果: 步骤[14] 永远"落地复核未通过"→ 永不记进度、每次重跑重装;
#        自愈那条 fwport 每次开机都白报一次缺失。
grep -q 'fw_53317_ok()' "$S" \
    && pass "防火墙判据助手 fw_53317_ok 存在" \
    || bad "fw_53317_ok 缺失 —— 判据会退回 grep 字面量"
grep -q 'fw_53317_ok ;;' "$S" \
    && pass "verify_step(setup_localsend) 走 fw_53317_ok" \
    || bad "verify_step(setup_localsend) 没用 fw_53317_ok(会被出厂范围规则误判)"
grep -q 'query-port=53317' self-heal-after-upgrade.sh \
    && pass "自愈 fwport 带 query-port 兜底(与主脚本同一套判断)" \
    || bad "自愈 fwport 只 grep 字面量 —— 范围规则会被误判成缺失"
# 2.9c C 开发头文件: 镜像裁掉了 /usr/include, 必须在装编译工具链后还原
#     —— 否则任何要编译 C 的 AUR 包都死在 `fatal error: string.h`(wechat/NextKde 都中过)
grep -q 'ensure_c_headers()' "$S" && grep -q '^    ensure_c_headers$' "$S" \
    && pass "C 头文件还原已接入步骤[3]工具链之后" \
    || bad "ensure_c_headers 未定义或未在 setup_wb 里调用"
# 2.9d 自愈服务必须真的"启用"(wants 软链), 文件在 ≠ 服务已启用
grep -q 'default.target.wants/steamos-self-heal.service' "$S" \
    && pass "verify_step(setup_selfheal) 已检查 wants 软链" \
    || bad "自愈只查单元文件存在 —— 2026-09-25 实测就是文件齐但服务 disabled"
# 2.9e root 属主卫生: 安装器退出前必须把 /home 里写的东西还给真用户
#     —— 否则用户自己重跑安装器会 "权限不够"(鸿蒙字体就栽在这), 且无从下手修
grep -q 'fix_home_owner()' "$S" && grep -q '^fix_home_owner$' "$S" \
    && pass "主脚本收尾做属主回收(fix_home_owner)" \
    || bad "缺 fix_home_owner 收尾 —— /home 会留一堆 root 属主文件"
grep -q 'fix_home_owner_opt' 可选组件安装.sh \
    && pass "可选组件安装器也做属主回收" \
    || bad "可选组件安装器没做属主回收"
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
    # monospace 一旦被 prefer, 终端/代码字体会错乱(鸿蒙是比例字体)。
    #  ⚠️ 旧判据拿 `<family>monospace</family>` 当锚点 grep, 而脚本里压根没有这个字面 ——
    #     匹配不到就"通过", 是一条**恒真的假绿灯**(2026-09-25 审查发现)。改成真能失败的形式:
    #     ① 先确认 prefer 块确实存在(否则断言本身无意义) ② 断言 prefer 块里不出现 monospace。
    if awk '/<prefer>/,/<\/prefer>/' install-harmony-sans-home.sh | grep -q '<family>'; then
        awk '/<prefer>/,/<\/prefer>/' install-harmony-sans-home.sh | grep -q 'monospace' \
            && bad "prefer 块里出现了 monospace —— 鸿蒙是比例字体, 会让终端/代码字体错乱" \
            || pass "monospace 未被 prefer 顶替(终端/代码字体不受影响)"
    else
        bad "没找到 <prefer> 块 —— 字体配置结构变了, 这条断言已失效(请更新锚点)"
    fi
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
# 2.13 开发文件补齐器 —— 三条不能退化的约束(SteamOS 会砍 /usr 的开发文件, 见 SCRIPT-MAINTENANCE §12)
if [ -f fix-missing-dev-files.sh ]; then
    pass "fix-missing-dev-files.sh 存在"
    bash -n fix-missing-dev-files.sh 2>/dev/null || bad "fix-missing-dev-files.sh 语法错误"
    # ① 只许补这三类开发文件: 补错了会把 locale/doc(体积大头)一起带回来。
    #    用**真实路径样本**做功能测试(比 grep 匹配字符串可靠, 也不怕正则写法变化):
    #    该被收集的必须命中(含包内成员那种不带前导 / 的形式), 不该的必须不命中。
    dev_re="$(grep -m1 '^DEV_RE=' fix-missing-dev-files.sh | sed 's/^DEV_RE=//')"
    dev_re="${dev_re#\'}"; dev_re="${dev_re%\'}"
    if [ -z "$dev_re" ]; then
        bad "找不到 DEV_RE 定义"
    else
        devre_ok=1
        while IFS=' ' read -r exp path; do
            if printf '%s\n' "$path" | grep -qE "$dev_re"; then got=1; else got=0; fi
            [ "$got" = "$exp" ] || { devre_ok=0; bad "DEV_RE 判错: $path 应=$exp 实=$got"; }
        done <<'DEVRE_SAMPLES'
1 /usr/include/zlib.h
1 /usr/lib/cmake/Qt6/Qt6Config.cmake
1 /usr/lib/pkgconfig/Qt6Core.pc
1 usr/include/qt6/QtCore/qglobal.h
0 /usr/share/locale/zh_CN/foo.mo
0 /usr/share/doc/pkg/README
0 usr/share/locale/zh_CN/foo.mo
DEVRE_SAMPLES
        [ "$devre_ok" = 1 ] && pass "DEV_RE 只收开发文件(include/cmake/pkgconfig), 不含 locale/doc"
    fi
    # ② 版本安全闸: 本机与仓库版本不一致必须拒绝(混装 = 部分升级, 会拆 KDE/KWin 的 ABI)
    grep -q 'base_inst' fix-missing-dev-files.sh && grep -q 'ALLOW_BUMP' fix-missing-dev-files.sh \
        && pass "有版本安全闸(不一致默认拒绝, 需 --allow-bump 才放行)" \
        || bad "缺版本安全闸 —— pacman -Sy 后会把滚动仓库的新版本装进来"
    # ③ 默认路径不许走整包重装(pacman -U 只在 --full 分支)
    grep -q -- '--overwrite' fix-missing-dev-files.sh \
        && grep -q 'FULL' fix-missing-dev-files.sh \
        && pass "整包重装(pacman -U --overwrite)只在 --full 分支" \
        || bad "默认路径疑似走整包重装"
    grep -q 'bsdtar -tf' fix-missing-dev-files.sh \
        && pass "默认走「只抽开发文件」(bsdtar 成员清单 → 选择性解包)" \
        || bad "默认路径没走选择性抽取"
else
    bad "fix-missing-dev-files.sh 缺失(编译类任务仍会卡在缺头文件/cmake)"
fi
# 2.13b 自愈链必须把「开发文件」也纳入自动恢复(否则升级后编译又莫名报缺)
if [ -f self-heal-after-upgrade.sh ]; then
    pass "self-heal-after-upgrade.sh 存在"
    bash -n self-heal-after-upgrade.sh 2>/dev/null || bad "self-heal-after-upgrade.sh 语法错误"
    # 统一体检入口: 只读、不许有写操作(它是医生, 别自己动手)
    if [ -f doctor.sh ]; then
        pass "doctor.sh 存在(一屏体检)"
        bash -n doctor.sh 2>/dev/null || bad "doctor.sh 语法错误"
        # doctor 是"医生", 自己不许动手: 先剥掉注释与引号里的文字(帮助文案里会提到
        # `systemctl --user start` 这类字样), 再看剩下的是不是真的在命令位上调用了写操作。
        code="$(sed 's/#.*$//' doctor.sh | sed 's/"[^"]*"//g; s/'"'"'[^'"'"']*'"'"'//g')"
        if printf '%s' "$code" | grep -qE '(^|[;&|(])[[:space:]]*(rm|mv|cp|install|pacman|systemctl|sudo)[[:space:]]'; then
            bad "doctor.sh 里有写操作 —— 它必须是只读的"
        else
            pass "doctor.sh 只读(不改系统、只查询)"
        fi
        grep -q 'tr -s' doctor.sh \
            && pass "doctor.sh 拉平了 sudo -l 的折行(否则免密会被误报为缺失)" \
            || bad "doctor.sh 没处理 sudo -l 折行 —— 会误报免密缺失"
    else
        bad "缺 doctor.sh(没有一个统一的一屏体检入口)"
    fi
    grep -q 'fix-missing-dev-files.sh' self-heal-after-upgrade.sh \
        && pass "自愈链已纳入开发文件补齐器" \
        || bad "自愈链没接开发文件补齐器 —— 升级后 /usr 开发文件不会自动补"
    grep -q 'Qt6Config.cmake' self-heal-after-upgrade.sh \
        && pass "开发文件用'便宜哨兵'探测(不在才做 20 秒全量体检)" \
        || bad "缺哨兵判断 —— 每次开机都会白跑一遍全量体检"
    grep -q 'pacman -Qq qt6-base' self-heal-after-upgrade.sh \
        && pass "哨兵判据要求'包在而文件不在'(不装 qt6 的机器不会误报)" \
        || bad "哨兵判据不全 —— 没装 qt6 的机器会每次开机误报开发文件缺失"
    # 游戏模式(本机大多数时间)下的三个约束: 等网络 / 重试定时器 / 失败标记
    grep -q 'wait_online' self-heal-after-upgrade.sh \
        && pass "动 pacman 之前会等网络(游戏模式开机时 Wi-Fi 常没就绪)" \
        || bad "没有等网络 —— 游戏模式下自愈会因没网而失败"
    grep -q 'NEEDS-ATTENTION' self-heal-after-upgrade.sh \
        && pass "失败会写看得见的标记文件(游戏模式没有通知守护, notify-send 是哑的)" \
        || bad "没有失败标记 —— 游戏模式下用户永远不知道自愈没做成"
    grep -q 'steamos-self-heal.timer' steamos-setup.sh \
        && pass "步骤[12] 会部署重试定时器(oneshot 失败后不等到下次开机)" \
        || bad "缺重试定时器 —— 一次失败就要等下次开机"
        grep -q 'timers.target.wants' steamos-setup.sh \
        && pass "定时器按 timers.target.wants 建软链启用(文件在 ≠ 已启用)" \
        || bad "定时器没被真正启用"
    # 2.13c 审查修掉的"假成功/静默继续"类, 逐条锁住(2026-09-25 §13)
    grep -q 'STAGE=' steamos-setup.sh && grep -q '\[ -f "$STAGE/$TAG/proton" \]' steamos-setup.sh \
        && pass "GE-Proton 解包走「暂存 → 校验 proton → 原子换」" \
        || bad "GE-Proton 安装又退回'先删旧版再解包、无条件报成功'了"
    grep -q 'name proton -type f' steamos-setup.sh \
        && pass "verify_step(setup_games) 判的是'真有 proton 文件'" \
        || bad "verify_step(setup_games) 又只看目录了 —— 解包半失败也会判达标"
    grep -q 'db\.lck' steamos-setup.sh \
        && pass "prepare 有 pacman 锁守卫(抢锁时给出可执行办法)" \
        || bad "缺 /var/lib/pacman/db.lck 守卫"
    grep -q 'PKG_ALLOW_STALE' steamos-setup.sh && grep -q -- '--allow-stale-db' steamos-setup.sh \
        && pass "源刷新失败默认中止, 且给了 --allow-stale-db 开关(不靠会被 sudo 剥掉的环境变量)" \
        || bad "源刷新失败仍会静默继续(部分升级风险)"
    [ "$(grep -c 'is-enabled --quiet' steamos-setup.sh)" -ge 2 ] \
        && pass "systemctl enable 之后回查 is-enabled(文件在 ≠ 已启用)" \
        || bad "enable 之后没回查 —— 背键/Decky 会在下次开机静默失效"
    grep -q '\[ ! -t 0 \]' 可选组件安装.sh \
        && pass "可选组件菜单有 TTY 守卫(非交互不再卡在 sudo 密码)" \
        || bad "可选组件菜单缺 TTY 守卫 —— 管道/定时调用会永久挂起"
    grep -q -- '--dry-run' self-heal-after-upgrade.sh \
        && pass "自愈脚本支持 --dry-run(只读预演, doctor.sh 依赖它)" \
        || bad "自愈脚本没有 --dry-run —— 排障时无法只读预演"
    [ -f diag-sudo-selfheal.sh ] \
        && pass "diag-sudo-selfheal.sh 存在(排查免密为何失效)" \
        || bad "缺 diag-sudo-selfheal.sh —— 免密失效时无从查起"
    # 主脚本里: 免密规则要放行补齐器, 且落地复核要能发现"旧规则缺新条目"
    # 免密快照方案(2026-09-25): 规则必须指向 /opt 下的 root 属主快照, 不许指向用户可写路径
    grep -q 'SNAP_DIR="/opt/steamos-backup"' steamos-setup.sh \
        && pass "步骤[12] 定义免密快照(/opt 是 offload → 扛升级)" \
        || bad "步骤[12] 没有 /opt 免密快照 —— 免密会指向用户可写路径(提权口子)"
    grep -q 'install -m 0644 -o root -g root' steamos-setup.sh \
        && pass "快照以 root 属主安装(用户改不动)" \
        || bad "快照不是 root 属主 —— 用户能改 = 规则等于送 root"
    grep -q 'NOPASSWD: /usr/bin/bash \$RULE_MAIN' steamos-setup.sh \
        && pass "免密规则用 \$RULE_MAIN(快照优先, 失败才退回备份包)" \
        || bad "免密规则没走快照路径"
    grep -q 'NOPASSWD: \$SH_SCRIPT' steamos-setup.sh \
        && bad "仍在放行自愈脚本本身 —— 它落在用户可写目录, 不需要也不该有 sudo" \
        || pass "不再放行自愈脚本(它是用户身份跑的, 去掉一个提权口子)"
    grep -q '/opt/steamos-backup/steamos-setup.sh' steamos-setup.sh \
        && pass "verify_step(setup_selfheal) 会复核快照与规则指向" \
        || bad "落地复核没查快照 —— 快照没了也判达标"
    grep -q 'sha256sum' doctor.sh && grep -q '快照与仓库' doctor.sh \
        && pass "doctor.sh 会比对'仓库 vs 快照'并在不一致时提示刷新" \
        || bad "doctor.sh 没做快照漂移检测 —— 仓库改了而自动恢复仍跑旧代码没人知道"
    grep -q '免密只放行 root 属主快照' doctor.sh \
        && pass "doctor.sh 有反向判据(规则里不该再出现用户可写脚本)" \
        || bad "doctor.sh 缺反向判据 —— 提权口子回来也不会报警"
    grep -q 'fix-missing-dev-files' steamos-setup.sh \
        && pass "步骤[12] 判定/复核认识开发文件条目(旧规则会被重写)" \
        || bad "步骤[12] 判据没算开发文件条目 —— 老机器永远补不上"
    # 自愈脚本的秒退路径也必须清过期标记(否则系统修好后 doctor.sh 永远报红;
    # 2026-09-26 实测: 收尾的 rm -f "$MARK" 只有一条, 秒退绕过了它)
    [ "$(grep -c 'rm -f "\$MARK"' self-heal-after-upgrade.sh)" -ge 2 ] 2>/dev/null \
        && pass "自愈脚本秒退路径也清 NEEDS-ATTENTION 标记(不只收尾一处)" \
        || bad "自愈标记只在收尾清一次 —— 秒退路径会留下永不消失的过期标记"
    # 2.13d Decky: 插件崩了要能自查自修(2026-09-26 现场: nightly 构建崩在 React #130)
    if [ -f diag-decky.sh ]; then
        pass "diag-decky.sh 存在(Decky 插件体检)"
        bash -n diag-decky.sh 2>/dev/null || bad "diag-decky.sh 语法错误"
        grep -q -- '--channels-stable' diag-decky.sh && grep -q -- '--repair' diag-decky.sh \
            && pass "能一键修: --repair(重装稳定版) / --channels-stable(关掉测试通道)" \
            || bad "diag-decky.sh 缺修复入口"
    else
        bad "缺 diag-decky.sh —— Decky 插件崩了只能一屏屏猜"
    fi
    grep -q -- '--decky-plugins=' steamos-setup.sh \
        && pass "主脚本支持 --decky-plugins=(修复单个插件用; 开关式, 不被 sudo env_reset 剥掉)" \
        || bad "缺 --decky-plugins= 开关 —— diag-decky --repair 没法免密跑"
    # 我们自己装插件必须走**不带 testing 参数**的商店清单(拿纯 semver 稳定版)
    if grep -q 'plugins.deckbrew.xyz/plugins' steamos-setup.sh && ! grep -q 'testing=1' steamos-setup.sh; then
        pass "插件安装走稳定清单(不带 testing 参数)"
    else
        bad "插件安装可能拿到测试构建"
    fi
    grep -q '\$REAL_HOME/homebrew' steamos-setup.sh \
        && pass "fix_home_owner 覆盖 ~/homebrew(否则 Decky 目录被 root 写过用户清不掉)" \
        || bad "fix_home_owner 漏了 ~/homebrew"
    # 2.13e 孤儿文件兜底(2026-09-26 现场: 升级后 /opt 里文件幸存、DB 被冲 → "文件系统中已存在")
    #   要点: ① 必须能识别这类报错; ② 覆盖前必须确认路径**无包拥有**(否则会盖掉真冲突);
    #         ③ 不许出现"无脑 --overwrite='*'"式的全局开关。
    grep -q 'PACMAN_CONFLICT_RE' steamos-setup.sh \
        && pass "能识别 pacman「文件系统中已存在」(孤儿文件, 不是包损坏)" \
        || bad "缺孤儿文件识别 —— 升级后再装 workbuddy/微信必失败且原因看不出"
    grep -q 'aur_conflict_retry' steamos-setup.sh \
        && pass "有带 --overwrite 的重试路径(aur_conflict_retry)" \
        || bad "缺 aur_conflict_retry"
    # 覆盖前用 pacman -Qo 逐个确认"无主", 有主就拒(防止把真冲突硬盖过去)
    grep -q 'pacman -Qo "\$_p"' steamos-setup.sh \
        && pass "覆盖前用 pacman -Qo 确认孤儿(有主的路径拒绝覆盖)" \
        || bad "aur_conflict_retry 没做'有无包拥有'的确认 —— 可能掩盖真冲突"
    # WB_LOG 必须是文件路径(⚠️ homedir() 对整个参数 mkdir -p, 传文件名会建出同名目录
    # → tee 写不进 → 冲突重试拿不到日志; 2026-09-26 11:23 实测踩过)
    if grep -q 'homedir .cache/steamos-setup-wb-install' steamos-setup.sh; then
        bad "WB_LOG 经 homedir 传文件名 —— 日志路径会被建成目录"
    else
        pass "WB_LOG 不经 homedir 建(homedir 只能收目录参数)"
    fi
    grep -q 'WB_LOG="\$REAL_HOME/.cache/steamos-setup-wb-install.log"' steamos-setup.sh \
        && pass "WB_LOG 直指文件路径(重试日志能落盘)" \
        || bad "WB_LOG 文件路径丢了 —— 冲突重试将拿不到日志"
    # 锁也要进 step[3] 失败原因清单(别让用户往网络/包上猜)
    grep -q '这次失败是\*\*锁\*\*' steamos-setup.sh \
        && pass "workbuddy 失败原因清单含锁(命中时第⓪条直接说明)" \
        || bad "step[3] 失败原因没提锁 —— 撞锁场景会被往别处带"
    # 预检直通: 孤儿现场要一轮装成, 别让用户连输三次 sudo 密码(2026-09-26 现场)
    grep -q '孤儿现场(升级幸存、DB 被冲)' steamos-setup.sh \
        && pass "step[3] 有孤儿预检(命中直接带 --overwrite, 不白跑注定失败的轮次)" \
        || bad "step[3] 缺孤儿预检 —— 孤儿现场要多输两次密码"
    grep -q 'WB_OV' steamos-setup.sh \
        && pass "预检结果经 WB_OV 数组传入 yay/paru(空数组也安全)" \
        || bad "预检没接进安装命令"
    # 微信那条独立路径也要有兜底(可选组件安装.sh 与主脚本不共享函数)
    grep -q 'overwrite' 可选组件安装.sh \
        && pass "可选组件安装.sh 的微信段也处理了孤儿文件" \
        || bad "可选组件安装.sh 微信段没处理「文件系统中已存在」"
    # 微信段也要有 RPC 本地包兜底(与 workbuddy 同款; 2026-09-26 靠它实战救回微信)
    grep -q 'cache/paru/clone/wechat-universal-bwrap' 可选组件安装.sh \
        && pass "微信段有 RPC 本地构建包兜底(缓存里有包就不依赖 AUR 网络)" \
        || bad "微信段缺 RPC 兜底 —— AUR 间歇断网时无法用本地缓存装回"
    # 2.13g Clash Verge(2026-09-27 新增可选组件): 重点在"本体必须扛升级"
    grep -q 'clash-verge' 可选组件安装.sh \
        && pass "可选组件菜单有 Clash Verge" \
        || bad "菜单缺 clash-verge"
    grep -q '\[clash-verge\]="clashverge_installed"' 可选组件安装.sh \
        && pass "Clash Verge 注册了 MENU_CHECK(非 pacman 装, 否则菜单 ✓ 永远不亮)" \
        || bad "clash-verge 没注册 MENU_CHECK"
    grep -q 'clash-verge) install_clash_verge ;;' 可选组件安装.sh \
        && pass "菜单选择已接到安装函数(带连字符的 key 走 install_clash_verge)" \
        || bad "菜单选了 clash-verge 会落进'尚未实现'"
    # 本体必须落 /home(不是 /usr) —— 这是用户"千万不能被升级冲掉"的硬要求
    grep -qE 'clash-verge\).*|STAGE_REL="tree/usr"; DEST_DIR="\$VENDOR_DIR/usr"' install-app-home.sh \
        && grep -q 'VENDOR_DIR="\$LOCAL/opt/clash-verge"' install-app-home.sh \
        && pass "Clash Verge 本体落 ~/.local/opt(升级幸存, 不进 /usr)" \
        || bad "Clash Verge 落点不在 /home —— 升级会被冲"
    # 解包判据要"真能启动的文件", 不是"目录在"(GE-Proton 假绿灯同款教训)
    grep -q 'usr/bin/clash-verge' install-app-home.sh \
        && pass "解包校验看真二进制(usr/bin/clash-verge), 不是看目录" \
        || bad "解包判据太松 —— 空目录也会算成功"
    # 缺依赖时要给可复制的命令, 不能"点了没反应"
    grep -q 'libwebkit2gtk-4.1.so.0' install-app-home.sh \
        && pass "入口会自检 Tauri WebView 缺库并给出装回命令(不哑失败)" \
        || bad "缺 webkit 时会静默失败 —— 用户只会看到'点了没反应'"
    # 唯一会进 /usr 的部分必须在文案里写明(不藏着)
    grep -q 'WebView' 可选组件安装.sh \
        && pass "菜单文案写明 WebView 依赖在 /usr(升级后重跑本项补回)" \
        || bad "没写明 /usr 依赖 —— 用户会以为全扛升级"
    # 2.13h 通用 deb 便携化(2026-09-27 新增: 任意 deb → /home, 用户要求的"固化能力")
    [ -f install-deb-portable.sh ] \
        && pass "install-deb-portable.sh 存在(任意 deb 便携化)" \
        || bad "缺 install-deb-portable.sh"
    grep -q 'OPTROOT="\$LOCAL/opt"' install-deb-portable.sh \
        && pass "deb 便携化落点 ~/.local/opt(不进 /usr, 扛升级)" \
        || bad "deb 便携化落点不在 /home —— 升级会被冲"
    grep -q 'tree_root="tree/usr"' install-deb-portable.sh \
        && pass "保留包内相对结构(usr/ 不打散 —— Tauri/Electron 资源靠相对位置找)" \
        || bad "会重组目录结构 —— Electron/Tauri 类应用会起不来"
    grep -q 'not found' install-deb-portable.sh \
        && pass "用 ldd 体检缺失动态库(不靠猜)" \
        || bad "没做缺库体检 —— 用户只会看到'点了没反应'"
    grep -q 'UNKNOWN' install-deb-portable.sh \
        && pass "ldd 无输出时判'无法判定'而不是假绿'齐全'(防假绿灯)" \
        || bad "ldd 判据会假绿 —— 缺执行位/非 ELF 时会误报依赖齐全"
    grep -q 'bash install-deb-portable.sh --check\|--check)' install-deb-portable.sh \
        && pass "提供 --check(升级后体检已装应用与缺库)" \
        || bad "缺升级后体检入口"
    grep -q 'deb-portable) install_deb_portable ;;' 可选组件安装.sh \
        && pass "菜单已接入 deb 便携化" \
        || bad "菜单选 deb-portable 会落进'尚未实现'"
    # 2.13i 升级后自动补回便携化应用的依赖(2026-09-27, 用户拍板要做)
    [ -f fix-opt-deps.sh ] \
        && pass "fix-opt-deps.sh 存在(升级后自动补回 webkit 等依赖)" \
        || bad "缺 fix-opt-deps.sh —— 升级后应用会打不开"
    # ★ 安全红线: 不能放行 pacman 本身(那等于免密装任意包)
    if grep -qE 'NOPASSWD:[[:space:]]*/usr/bin/pacman' steamos-setup.sh; then
        bad "sudoers 放行了 pacman —— 任何能以 deck 执行代码的东西都能免密装任意包"
    else
        pass "sudoers 未放行 pacman(只放行专用脚本, 提权面可控)"
    fi
    grep -q 'RULE_DEPS' steamos-setup.sh \
        && pass "步骤[12] 会写第三条免密规则(专用补依赖脚本)" \
        || bad "步骤[12] 没写补依赖的免密规则 —— 自动补回不会生效"
    # 包名必须写死在 root 属主脚本里, 绝不能读用户可写清单
    grep -qE 'OPT_DEPS=\(webkit2gtk-4.1' fix-opt-deps.sh \
        && pass "补依赖的包名写死在脚本里(不读用户可写清单)" \
        || bad "包名来源可疑 —— 若来自用户可写文件就等于开放免密装包"
    grep -q '忽略参数' fix-opt-deps.sh \
        && pass "不接受命令行传包名(挡住 sudo 免密装任意包)" \
        || bad "补依赖脚本接受 argv 包名 —— 那是提权口子"
    grep -q 'fix-opt-deps' self-heal-after-upgrade.sh \
        && pass "自愈链会调用补依赖(升级后无人值守补回)" \
        || bad "自愈链没接补依赖 —— 只在手动跑时才补"
    # 不允许"无脑全局 --overwrite": 应只在确实判定为孤儿时才出现
    if grep -qE '^\s*pacman -S[^#]*--overwrite' steamos-setup.sh; then
        bad "有无条件 --overwrite 的 pacman 调用 —— 会掩盖真实的包间冲突"
    else
        pass "没有无条件的 --overwrite(只在判定孤儿后才用)"
    fi
    # 2.13f 锁守卫(2026-09-26 现场: 撞锁被误报成"源的问题", 且守卫因路径写死从没生效)
    #   ① 不许写死 /var/lib/pacman/db.lck —— 本机 DB 真身在 /usr/lib/holo/pacmandb
    grep -q 'usr/lib/holo/pacmandb' steamos-setup.sh \
        && pass "锁守卫运行时探测 DB 目录(holo/pacmandb, 不写死 /var/lib/pacman)" \
        || bad "锁守卫写死了 DB 路径 —— 本机 /var/lib/pacman 不存在, 守卫永不生效"
    #   ② 必须能区分"锁"与"源": 撞锁不能报成源的问题
    grep -q '无法锁定数据库|unable to lock' steamos-setup.sh \
        && pass "pacman -Sy 失败会区分「锁」与「源」(不再一律归咎于源)" \
        || bad "pacman -Sy 失败一律归咎于源 —— 会把用户带向错误排查方向"
    #   ③ 撞锁要能等(持锁者常是我们自己的自愈链, 它下完包会放手)
    grep -q 'PACMAN_LOCK_WAIT' steamos-setup.sh \
        && pass "撞锁会等待重试(PACMAN_LOCK_WAIT 可调, 默认 180s)" \
        || bad "撞锁直接退出 —— 自愈链持锁时用户手动跑必失败"
    #   ④ 持有者匹配不许用 -f 全命令行(会把 gpg-agent 这种"路径含 pacman"的也算进来)
    if grep -qE "pgrep -a -f '\(\\|/\)\(pacman" steamos-setup.sh; then
        bad "持有者匹配用 -f 全命令行 —— 会把 gpg-agent 等误列为持有者"
    else
        pass "持有者匹配只认可执行名(不误抓 gpg-agent 之类)"
    fi
    #   ⑤ 步骤[12] 必须免刷新: 它是"修锁的钥匙", 不能反过来被 pacman 锁挡住
    #     (2026-09-26 实测: 补齐器持锁 → 步骤[12] 死在环境准备 → 免密永远建不起来)
    [ "$(grep -c 'PREPARE_NO_REFRESH' steamos-setup.sh)" -ge 2 ] 2>/dev/null \
        && pass "步骤[12] 免刷新(PREPARE_NO_REFRESH: prepare 认它, setup_selfheal 设它)" \
        || bad "步骤[12] 仍陪跑 pacman -Sy —— 修锁的人会被锁挡在门外"
    grep -q 'PREPARE_NO_REFRESH=1' steamos-setup.sh \
        && pass "setup_selfheal 已设 PREPARE_NO_REFRESH=1" \
        || bad "setup_selfheal 没设免刷新开关"
    # /usr/local 属于 /usr, **不扛原子升级**(2026-09-25 实测纠正; 曾在 6 处文档里写错) ——
    # 所以任何"持久物"都不许往那放。这条断言专治"顺手又写回去"。
    if grep -qE '^DAEMON_DST="/usr/local|install -m [0-9]+ [^|]*>/usr/local|install -m [0-9]+ "[^"]*" /usr/local' \
            steamos-setup.sh setup-win5-backkeys.sh 2>/dev/null; then
        bad "有脚本把持久物装进 /usr/local —— 那属于 /usr, 升级会被冲"
    else
        pass "没有脚本把持久物装进 /usr/local(背键守护已改 ~/.local/opt)"
    fi
else
    bad "self-heal-after-upgrade.sh 缺失(升级后不会自动恢复)"
fi
# 2.14 启动器: 执行位 + 薄壳约束
#      —— "双击没反应"最常见的原因就是执行位丢了(.desktop 必须可执行 Dolphin 才肯跑),
#         而 TryExec 写终端会让没装该终端的机器上整个入口消失。
#      执行位有两处可查: git 索引(跨平台, 含已暂存未提交的条目) 与 文件系统。
#      文件系统这处在 Windows/NTFS 上**必然假红**: chmod 是空操作, Git Bash 的 -x 只看
#      shebang/扩展名(2026-09-27 在 Windows 副本实测) → 查磁盘位前先探环境。
fs_can_x() {   # 探针: 本机文件系统表示得了执行位吗(全程不碰仓库, 结果缓存)
    [ -n "${_FS_CAN_X:-}" ] && return "$_FS_CAN_X"
    local t; t="$(mktemp "${TMPDIR:-/tmp}/.exec-probe.XXXXXX")" || return 0
    chmod +x "$t" 2>/dev/null
    if [ -x "$t" ]; then _FS_CAN_X=0; else _FS_CAN_X=1; fi
    rm -f "$t"
    return "$_FS_CAN_X"
}
if [ -d .git ]; then
    # 关键文件必须还在(缺失断言, 原来就有)
    for f in steamos-setup.sh 可选组件安装.sh 重装后先运行我.sh; do
        [ -f "$f" ] || bad "$f 缺失"
    done
    # 索引里**全部**已跟踪 .sh/.desktop/hooks/* 都必须 100755 —— 不再只点名几个:
    # Windows 上 git add 一律记 100644, 只查点名清单会让其它脚本从 Windows 提交时
    # 静默落成 644(8977c11「整仓没执行位」事故的复发通道, 2026-09-27 审查补)。
    # hooks/* 也要查: pre-commit 不是可执行的话 git 会静默跳过, 等于本脚本这道门没了
    # (真抓到: hooks/pre-commit 曾以 100644 在索引里躺到 3.10.1 才被发现)。
    # git ls-files -s 读的是索引, 已暂存未提交也能查到 → pre-commit 阶段就拦得住。
    _n755=0; _nbad=0
    while IFS= read -r _line; do
        _mode="${_line%% *}"
        _f="$(printf '%s' "$_line" | cut -f2-)"
        if [ "$_mode" = "100755" ]; then
            _n755=$((_n755 + 1))
        else
            _nbad=$((_nbad + 1))
            bad "$_f 在 git 里不是 100755 —— 修: git update-index --chmod=+x \"$_f\""
        fi
    done < <(git ls-files -s -- '*.sh' '*.desktop' 'hooks/*' 2>/dev/null)
    [ "$_nbad" -eq 0 ] && pass "git 索引里 $_n755 个 .sh/.desktop/hooks 全部 100755(可执行)"
    unset _n755 _nbad _mode _f _line
else
    # 不是 git 仓库(典型: 从网盘/Windows 拷回来的备份包) —— 这时更要查!
    # "拷回来双击没反应 / 脚本跑不起来"的根因就是**文件系统上的执行位**丢了,
    # 旧写法在这种情况下整段跳过 → 恰恰漏掉了最容易出事的那条路(2026-09-25 审查补)。
    # 但 Windows/NTFS 上磁盘位查不了(chmod 空操作 → 必然假红) → 先探环境再判。
    for f in steamos-setup.sh 可选组件安装.sh 重装后先运行我.sh 重装后先运行我.desktop; do
        [ -f "$f" ] || { bad "$f 缺失"; continue; }
        if [ -x "$f" ]; then
            pass "$f 有执行位"
        elif ! fs_can_x; then
            pass "$f 执行位本机验证不了(Windows/NTFS 存不了) —— 拷回 Linux 后跑 bash check.sh 复核"
        else
            bad "$f 没有执行位 —— 修: chmod +x \"$f\""
        fi
    done
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
# 2.14 步骤[15] markdown 阅读器(glow)
grep -q '^setup_mdread() {' "$S" \
    && pass "步骤[15] setup_mdread 存在" \
    || bad "步骤[15] setup_mdread 缺失"
# (map_step / FUNCS 的点名断言已于 2026-09-27 并入 STEPS 表派生测试: 见 2.0 与 2.15f。
#  旧断言靠 grep 字面量 '15|mdread' 与 'setup_localsend setup_mdread', 表驱动后那些
#  字面量本就不存在了 —— 留着它们只会假红, 删掉才是对的。)
grep -q 'BIN="\$REAL_HOME/.local/bin/glow"' "$S" \
    && pass "glow 装进 /home(不占 rootfs、扛原子升级)" \
    || bad "glow 落点被改 —— 那就不如直接用 Arch 包了, 但那个进 rootfs 会被升级冲掉"
# 桌面项两条规矩(与启动器同源: Terminal=true 别硬写终端; 不写 TryExec)
grep -q 'glow-markdown.desktop' "$S" \
    && pass "glow 注册了 .md 文件关联(双击可看)" \
    || bad "没注册 .md 关联 —— 那就只是个命令行工具, 不算'阅读器'"
# 2.15a 严格模式一致性(2026-09-27): 未定义变量静默变空, 在装包/删目录处后果最大。
#   本项目标准是 `set -uo pipefail`(也接受 `set -euo pipefail`)。
#   2026-09-27 第二轮把判据**从"有 -u"提到"有 -u 且有 pipefail"**: 本站自己的
#   check.sh 当时就只有 `set -u` —— 判据宽一档, 自己就成了漏网的那个。
_no_u=0
while IFS= read -r _f; do
    grep -qE '^set -.*u.*pipefail' "$_f" 2>/dev/null || { bad "缺 set -uo pipefail: $_f"; _no_u=1; }
done < <(find . -maxdepth 1 -name '*.sh' -not -path './.git/*' 2>/dev/null)
[ "$_no_u" -eq 0 ] && pass "全部脚本都开了 set -uo pipefail(未定义变量不静默、管道失败会被发现)"
# 2.15b 过期快照自检(2026-09-26 最贵的一次教训: 跑了旧快照 → 修好的 bug 原样复现)
grep -q 'warn_stale_snapshot' "$S" \
    && pass "跑快照那份时会自检是否落后于仓库(并指路仓库那份)" \
    || bad "缺过期快照自检 —— 会再出现'修好的 bug 又复现'的排查黑洞"
grep -q '.snapmeta' "$S" \
    && pass "步骤[12] 同步时盖来源戳(.snapmeta: 源路径 + 主脚本 sha256)" \
    || bad "快照没盖来源戳 —— 无法判断是否过期"
# 2.15c 自愈清点要覆盖"装在 /opt 的 AUR 包"(微信那类'凭空消失'过去无人告知)
grep -q 'orphanpkg' self-heal-after-upgrade.sh \
    && pass "自愈清点覆盖 /opt 类 AUR 包(目录在+台账没了会被告知)" \
    || bad "自愈清点不含 /opt 类包 —— 微信那类消失会静默发生"
grep -q '\[ "\$step" = "-" \]' self-heal-after-upgrade.sh \
    && pass "报告-only 项不会被当成可自动修复的步骤(步骤写 '-')" \
    || bad "报告-only 项会被塞进自动修复步骤表 —— 会拿 '-' 去跑 steamos-setup.sh"
# 2.15d 免密规则"生成"与"落地判据"必须同步(2026-09-27 真机现场踩到)
#   症状: 跑 `sudo bash steamos-setup.sh 12`, 却只得到
#         "[跳过] 12 升级后自愈服务 —— 已完成于 2026-09-26" ——
#   根因: 新增第三条免密规则(补依赖 fix-opt-deps.sh)时只改了**规则生成**,
#         verify_step 里的**落地判据**没跟着加 → 永远判定"已完成", 缺的规则补不上,
#         自愈链就此瘸腿(而且不报错, 只是静默不干活)。
#   判据: 从 setup_selfheal 里 `SNAP_*="$SNAP_DIR/xxx"` 的赋值抽出脚本名,
#         逐个确认它也出现在 verify_step 的 setup_selfheal 分支里。
#         这样"以后再加第四条规则"时会自动被这条断言逼着改两处。
_sh_arm="$(sed -n '/^        setup_selfheal) /,/;;/p' "$S" 2>/dev/null)"
if [ -z "$_sh_arm" ]; then
    bad "取不到 verify_step 的 setup_selfheal 分支 —— 判据失效(写法变了?), 请更新正则"
else
    _rules="$(grep -oE 'SNAP_[A-Z]+="\$SNAP_DIR/[^"]+"' "$S" 2>/dev/null | sed 's|.*/||; s|"||g')"
    _n_rule="$(printf '%s\n' "$_rules" | grep -c .)"
    if [ "$_n_rule" -lt 3 ]; then
        bad "只解析出 $_n_rule 条免密规则脚本(应 ≥3) —— 判据失效, 请检查 SNAP_* 赋值写法"
    else
        _sh_miss=""
        # 只数"分支里提到这个名字"是不够的 —— 分支里还有 `[ -f .../fix-opt-deps.sh ]`
        # 这种**文件存在性**检查也含同一个名字, 于是"漏掉 sudoers 判据"会被假通过
        # (第一版反例正是这么被骗过去的)。所以必须盯住**真正的那个动作**:
        # 一行 grep, 且这行里出现该脚本名。
        _glines="$(printf '%s\n' "$_sh_arm" | grep -E 'grep[[:space:]]+-qs' || true)"
        while IFS= read -r _r; do
            [ -n "$_r" ] || continue
            _stem="${_r%.sh}"
            case "$_glines" in
                *"$_stem"*) ;;
                *) _sh_miss="$_sh_miss $(basename "$_r")" ;;
            esac
        done <<< "$_rules"
        [ -z "$_sh_miss" ] \
            && pass "步骤[12] 落地判据覆盖全部 $_n_rule 条免密规则(少了就会静默跳过)" \
            || bad "步骤[12] 落地判据漏了免密规则:$_sh_miss —— 缺它会永远判'已完成'而跳过"
    fi
fi
# 2.15e 免密规则的"参数形态"必须与**调用方式**匹配(2026-09-27 真机探针确证)
#   实测(用当前规则集直接探了一次): sudoers 里**不带 `*`** 的规则, 同一个命令**带参数会被拒**
#   —— 报 "sudo: 需要密码"(退 1); 不带参数才放行。带 `*` 才允许任意参数。
#   含义: "调用方传参 + 规则没 `*`" = 无人值守自愈链上**静默失败**(和今天那个跳过同类)。
#   当前事实: 自愈链调补依赖器是 `sudo -n bash "$DEPS_TOOL"`(不传参)
#   → 规则刻意**不带** `*`(最小提权面)。两边谁变了, 这条断言都会响。
_deps_call="$(grep -E 'sudo -n bash ["$]*DEPS_TOOL' self-heal-after-upgrade.sh 2>/dev/null \
              | grep -v 'dry-run\|echo ' | head -1)"
if [ -z "$_deps_call" ]; then
    bad "找不到自愈链对补依赖器的调用 —— 判据失效(写法变了?), 请更新正则"
else
    # 去掉重定向与 then/if 之类, 剩下的就是"参数"
    _deps_tail="$(printf '%s' "$_deps_call" | sed 's/.*DEPS_TOOL"//; s/>>[^ ]*//g; s/2>&1//g; s/;//g; s/then//g; s/elif//g; s/if//g; s/[[:space:]]//g')"
    if grep -qE 'NOPASSWD: /usr/bin/bash \$RULE_DEPS \*' "$S" 2>/dev/null; then _star=1; else _star=0; fi
    if [ -z "$_deps_tail" ]; then
        [ "$_star" -eq 1 ] \
            && bad "补依赖器的免密规则带了 * 变体, 但调用不传参 —— 提权面被无谓放大" \
            || pass "免密规则参数形态与调用一致(补依赖器不传参 → 规则不带 *, 最小提权面)"
    else
        [ "$_star" -eq 1 ] \
            && pass "补依赖器调用带参数($_deps_tail) 且规则有 * 变体 → 免密可用" \
            || bad "补依赖器调用带参数($_deps_tail) 但规则没有 * 变体 → 无人值守时会被拒(静默失败)"
    fi
fi
# 2.15 步骤[16] Firefox Nightly(2026-09-25 从可选组件提为必装)
grep -q '^setup_firefox() {' "$S" \
    && pass "步骤[16] setup_firefox 存在" \
    || bad "步骤[16] setup_firefox 缺失"
grep -q 'firefox-nightly/firefox/firefox' "$S" \
    && pass "Firefox Nightly 装进 /home(不占 rootfs、扛原子升级)" \
    || bad "firefox 落点被改 —— 装 /usr 会进 rootfs 且更新器被禁"
grep -q '"\$FF_INST" firefox-nightly' "$S" \
    && pass "步骤[16] 复用 install-app-home.sh 单引擎(不另写一套下载/解包)" \
    || bad "firefox 没走 install-app-home.sh —— 有第二套下载逻辑会漂移"
# ── 2.15f 步骤表的静态交叉核对(与 2.0 的派生测试配对) ──────────────────────
#    2.0 证明「表派生出来的行为对」; 这一节证明「表点到的东西真的存在,
#    而且文档里写死的步数没漂」。防的正是 §13.10.6 那一类事故: 一侧改了、
#    另一侧没改, 两侧各自都"自洽", 只有放在一起比才现形。
_x_total="$(printf '%s\n' "$_h" | sed -n 's/^XOUT TOTAL=//p')"
_x_fns="$(printf '%s\n' "$_h" | sed -n 's/^XOUT FNS=//p')"
if [ -z "$_x_total" ] || [ -z "$_x_fns" ]; then
    bad "拿不到表清单(2.0 的派生测试没跑完) —— 本节已失效, 先修上面"
else
    _nb=0
    for _fn in $_x_fns; do
        grep -q "^$_fn() {" "$S" || { bad "表里有 $_fn, 但主脚本里没有它的函数体"; _nb=$((_nb+1)); }
    done
    [ "$_nb" -eq 0 ] && pass "表点的 $_x_total 个步骤函数全部有函数体"

    # 每个步骤都必须在 verify_step 里有分支 —— 无落地物的也要**显式**写 return 0,
    # 不能靠 case 末尾的 `*) return 0` 兜底(那等于"没判据也算完成", 是假达标)。
    _vb="$(sed -n '/^verify_step() {/,/^}/p' "$S" 2>/dev/null)"
    if [ -z "$_vb" ]; then
        bad "抽不到 verify_step 函数体 —— 判据覆盖率断言自己失效了(被改名/缩进变了?)"
    else
        _nv=0
        for _fn in $_x_fns; do
            printf '%s\n' "$_vb" | grep -Eq "^ +$_fn\)" \
                || { bad "verify_step 里没有 $_fn 分支 —— 会掉到 *) return 0 = 假达标"; _nv=$((_nv+1)); }
        done
        [ "$_nv" -eq 0 ] && pass "verify_step 覆盖全部 $_x_total 步(无落地物的也显式写了 return 0)"
    fi

    # 横幅: 编号与总数由表派生, 不许再出现手写的 [N/M](历史上 /7 /9 /12 /14 并存过)
    #  模式提到变量里: `"$(grep -E '...含双引号...' "$S")"` 这种嵌套引号会被 bash 的
    #  双引号内命令替换预解析提前闭合(实测报 "looking for matching '", 2026-09-27)。
    #  ⚠️ 模式**不能带结尾的 `\"`**: 真实横幅是 `step "[11/16] GPU 加速建议(...)"`,
    #     `]` 后面是文字不是引号。带上它就永远匹配不到 —— 2026-09-27 反例探针
    #     (把 banner 改回手写横幅)当场验出这条假绿灯, 别改回去。
    _bann_pat='step "\[[0-9]+/[0-9]+\]'
    _lit="$(grep -cE "$_bann_pat" "$S")"
    _nb2="$(grep -cE '^ *banner [a-z_]+ ' "$S")"
    if [ "$_lit" != "0" ]; then
        bad "主脚本残留 $_lit 处手写 step \"[N/M]\" 横幅 —— 编号该交回 banner 派生"
    elif [ "$_nb2" != "$_x_total" ]; then
        bad "banner 调用数($_nb2)≠ 步骤数($_x_total) —— 有一步打不出横幅, 或多出野横幅"
    else
        pass "步骤横幅全部由表派生($_nb2 处 banner, 零手写编号)"
    fi

    # 文档里写死的步数 = 人判断"到底跑完没有"的依据, 漂了会误导(历史上漂过 12→14→16)
    _doc_pat='(必装|走完|看必装|顺序跑完|跑完) [0-9]+ 步|[0-9]+ 步, 断点续传|必装主线（[0-9]+ 步）'
    _doc_n="$(
        {
            grep -rhoE "$_doc_pat" README.md 使用说明.txt 重装流程.md steamos.sh \
                      重装后先运行我.sh 2>/dev/null | grep -oE '[0-9]+'
            # "步骤 1~16" 是区间写法, 步数在波浪号后面 —— 只取上界, 别把 1 也算进去
            grep -rhoE '步骤 1~[0-9]+' README.md 使用说明.txt 2>/dev/null | sed -n 's/^步骤 1~//p'
        } | sort -u | tr -d '\n'
    )"
    if [ -z "$_doc_n" ]; then
        bad "一条'N 步'都没扫到 —— 本断言的写法已过时, 它现在等于没检查"
    elif [ "$_doc_n" != "$_x_total" ]; then
        bad "文档里的步数[$_doc_n]与表的[$_x_total]不一致(grep -rn '[0-9]* 步' 自查)"
    else
        pass "文档里写死的步数全部 = $_x_total(与表一致)"
    fi
    _rn="$(grep -c '^| [0-9]\+ |' README.md)"
    if [ "$_rn" = "$_x_total" ]; then
        pass "README 必装主线表 $_rn 行 = 表步数(没有漏登记或多余行)"
    else
        bad "README 主线表 $_rn 行 ≠ 表步数 $_x_total —— 加/删步骤忘了同步 README"
    fi
    # 维护手册 §1.1 的导读表 + 它声明的主脚本行数(数字声明最容易漂, 用容差而不是相等:
    #   那里写的是"约 N 行", 要求逐字相等会让人懒得更新)
    _mr="$(grep -c '^| `[0-9]\+`/`' SCRIPT-MAINTENANCE.md)"
    if [ "$_mr" = "$_x_total" ]; then
        pass "维护手册 §1.1 导读表 $_mr 行 = 表步数"
    else
        bad "维护手册 §1.1 导读表 $_mr 行 ≠ 表步数 $_x_total —— 同步一下那张表"
    fi
    _decl="$(sed -n 's/^### 1\.1 主脚本.*（约 \([0-9]\+\) 行.*/\1/p' SCRIPT-MAINTENANCE.md | head -1)"
    # 用 wc -l 而不是 grep -c . —— 后者数的是**非空行**, 会少报 200 行(写这条时踩到)
    _real="$(wc -l < "$S" | tr -d ' ')"
    if [ -z "$_decl" ]; then
        bad "从 §1.1 标题里抽不出'约 N 行' —— 本断言已失效(标题格式变了?)"
    elif [ "$_decl" -lt $((_real * 9 / 10)) ] || [ "$_decl" -gt $((_real * 11 / 10)) ]; then
        bad "维护手册说主脚本约 $_decl 行, 实测 $_real 行(差超 10%) —— 改一下那个数字"
    else
        pass "维护手册说约 $_decl 行, 实测 $_real 行(在 ±10% 内)"
    fi
fi
# 2.16 统一入口 steamos.sh(2026-09-27): 菜单/清单/帮助/分发全部由**一张注册表**派生,
#      所以核心不变量就是"注册表 ↔ 文件"双向一致。这两种漂移都真实发生过:
#        · 加了脚本没登记 → 它躺在目录里, 却没有任何入口指向它(人找不到 = 等于不存在)
#        · 登记了但文件被改名/删掉 → 菜单里点下去只报"缺文件"
#      外加两条安全红线: 入口自己不许提权、不许被写进 sudoers。
E=steamos.sh
if [ -f "$E" ]; then
    pass "$E 存在(统一入口)"
    # 注册表**行数**先对一次: 用带引号的模式去抽行时, 一行"引号没闭合"的注册表
    #   根本匹配不上 → 它会被后面所有检查**静默忽略**(第一版就是这样漏的)。
    #   判据失效本身必须报错, 所以这里拿"原始行数 vs 可解析行数"比, 并带一个下限
    #   (否则把整张表删空也会 0=0 通过)。
    _raw="$(grep -cE '^  "' "$E")"
    _ok="$(grep -oE '^  "[^"]+"' "$E" | wc -l)"
    if [ "$_raw" -eq "$_ok" ] && [ "$_raw" -ge 30 ]; then
        pass "注册表 $_raw 行全部可解析"
    else
        bad "注册表行数对不上(原始 $_raw / 可解析 $_ok) —— 有行格式坏了(引号没闭合?), 或表被删空"
    fi
    # 注册表每行必须正好 6 段: key|文件|默认参数|模式|分组|说明
    _badrow="$(grep -oE '^  "[^"]+"' "$E" | awk -F'|' 'NF!=6' | head -3)"
    [ -z "$_badrow" ] \
        && pass "注册表字段数一致(每行 6 段)" \
        || bad "注册表有格式不对的行(应为 key|文件|默认参数|模式|分组|说明): $_badrow"
    # 正向: 注册表点名的文件都得在
    _miss=""
    while IFS= read -r _f; do
        [ "$_f" = "-" ] && continue
        [ -f "$_f" ] || _miss="$_miss $_f"
    done < <(grep -oE '^  "[^"]+"' "$E" | cut -d'|' -f2)
    [ -z "$_miss" ] \
        && pass "注册表点到的脚本都在" \
        || bad "注册表点了不存在的文件:$_miss"
    # 反向: 根目录每个 .sh/.py 都必须被登记 —— **新脚本不许被遗忘**
    _unreg=""
    while IFS= read -r _f; do
        _f="${_f#./}"
        [ "$_f" = "$E" ] && continue
        grep -qF "|$_f|" "$E" || _unreg="$_unreg $_f"
    done < <(find . -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null)
    [ -z "$_unreg" ] \
        && pass "根目录全部脚本都已登记进入口(没有'存在但没人找得到'的脚本)" \
        || bad "这些脚本没登记进 $E:$_unreg"
    # 内建命令(注册表里文件写 '-')必须有实现函数, 否则点下去是 command not found
    #   取 key 用 `sed 's/^  "//'` 剥掉行首标记而不是靠引号匹配 —— 这样即使某行
    #   引号没闭合, 它照样会被本断言看见(前面的行数断言也会同时报警)。
    _nofn=""
    while IFS= read -r _k; do
        grep -q "^builtin_${_k//-/_}() {" "$E" || _nofn="$_nofn $_k"
    done < <(grep -E '^  "' "$E" | sed 's/^  "//' | awk -F'|' '$2=="-" {print $1}')
    [ -z "$_nofn" ] \
        && pass "内建命令都有实现函数(自检/打包/包校验)" \
        || bad "内建命令没有实现函数:$_nofn"
    # 安全红线①: 入口是**用户可写**的, 绝不能自己提权(否则等于放行任意代码)
    if grep -qE '^[[:space:]]*(exec )?sudo ' "$E"; then
        bad "$E 里出现提权调用 —— 用户可写的脚本绝不能提权"
    else
        pass "$E 不提权(需要 root 的仍由各脚本自己 sudo)"
    fi
    # 安全红线②: 它更不能被写进 sudoers(免密只放行 root 属主快照里的固定脚本)
    grep -qE 'NOPASSWD:.*steamos\.sh' steamos-setup.sh 2>/dev/null \
        && bad "免密规则里出现了 $E —— 那等于把提权口子开回来" \
        || pass "免密规则不涉及 $E(入口不在提权面内)"
    # 发布包目录必须被 gitignore: 否则 628K 的 tar 会跟着提交进版本库
    grep -q '^dist/' .gitignore 2>/dev/null \
        && pass "dist/ 已被 gitignore(发布包不会进版本库)" \
        || bad "dist/ 没进 .gitignore —— 发布包会被提交"
else
    bad "$E 缺失(没有统一入口)"
fi

# 2.16b 入口的桌面启动项(与 重装后先运行我.desktop 同款约束)
if [ -f steamos.desktop ]; then
    grep -q '^TryExec=' steamos.desktop \
        && bad "steamos.desktop 写了 TryExec —— 缺该程序时入口会整个消失" \
        || pass "steamos.desktop 没写 TryExec(不会因缺终端而消失)"
    grep -q 'steamos\.sh' steamos.desktop \
        && pass "steamos.desktop 是薄壳(调 steamos.sh, 逻辑只写一份)" \
        || bad "steamos.desktop 没调 steamos.sh —— 会出现第二套入口逻辑"
    # 执行位: 已入 git(含已暂存)的必须是 100755(历史 bug: 仓库里文件全没执行位 → 双击没反应);
    #   还没进索引的新文件只能看磁盘位, 但 Windows/NTFS 存不了执行位(chmod 空操作,
    #   2026-09-27 实测) → 先探环境: 表示不了就明示, 提交后由上面的索引断言兜底。
    _mode="$(git ls-files -s -- steamos.desktop 2>/dev/null | awk '{print $1}')"
    if [ -n "$_mode" ]; then
        [ "$_mode" = "100755" ] \
            && pass "steamos.desktop 在 git 里可执行(100755)" \
            || bad "steamos.desktop 在 git 里不是 100755 —— 修: git update-index --chmod=+x steamos.desktop"
    elif [ -x steamos.desktop ]; then
        pass "steamos.desktop 有执行位(尚未入 git, 看的是磁盘位)"
    elif ! fs_can_x; then
        pass "steamos.desktop 尚未入 git 且本机存不了执行位(Windows/NTFS) —— 提交后由 git 100755 断言兜底"
    else
        bad "steamos.desktop 没有执行位 —— 修: chmod +x steamos.desktop"
    fi
    unset _mode
else
    bad "steamos.desktop 缺失(工具箱没有双击入口)"
fi

# 2.16c VERSION 文件必须与 CHANGELOG 最新版本号一致
#   以前 VERSION 停在 3.7.0 而 CHANGELOG 已经到 3.9.10, 没人发现 ——
#   现在 VERSION 是入口横幅与发布包名的来源, 再漂就会打错包名。
_v_file="$(cat VERSION 2>/dev/null | tr -d '[:space:]')"
_v_log="$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md 2>/dev/null | sed 's/## \[//;s/\]//')"
if [ -n "$_v_file" ] && [ -n "$_v_log" ]; then
    [ "$_v_file" = "$_v_log" ] \
        && pass "VERSION(${_v_file}) 与 CHANGELOG 最新版本一致" \
        || bad "VERSION 是 $_v_file, CHANGELOG 最新是 $_v_log —— 发版时两处要一起改"
else
    bad "读不到版本号(VERSION 或 CHANGELOG 缺) —— 判据失效本身就该报错"
fi

echo "════════ 3) shellcheck (可选, 未安装则跳过) ════════"
# 找 shellcheck: 先在 PATH 里找, 再找本目录 tools/ 下的(shellcheck 或 shellcheck.exe)
SC=""
for c in shellcheck ./tools/shellcheck ./tools/shellcheck.exe; do
    # 必须**真的能跑**才算数: tools/shellcheck.exe 是 Windows PE, 在 Linux 上
    # `command -v` 找得到却执行不了 —— 旧写法会让本节"0 warning"变成假绿灯。
    if command -v "$c" >/dev/null 2>&1 && "$c" --version >/dev/null 2>&1; then SC="$c"; break; fi
done
if [ -n "$SC" ]; then
    n=0; _screp=""
    while IFS= read -r f; do
        skip_dir "$f" && continue
        case "$f" in ./steamos-nix/*) continue ;; esac   # 冻结分支豁免 lint(语法仍扫, 见 skip_dir)
        hits="$("$SC" -S warning -f gcc "$f" 2>/dev/null | grep 'SC[0-9]')"
        c="$(printf '%s\n' "$hits" | grep -c 'SC[0-9]')"
        if [ "$c" -gt 0 ]; then
            n=$((n + c))
            _screp="$_screp$hits
"
        fi
    done < <(find . -type f -name "*.sh" -not -path "./.git/*")
    # 以前只报"发现 N 个", 不给是哪几个 —— 2026-09-27 复现时就只能手工把
    # 整个循环再跑一遍。红项必须自带指路。
    if [ "$n" -eq 0 ]; then
        pass "shellcheck warning 级 = 0 (全部脚本)"
    else
        bad "shellcheck 发现 $n 个 warning 级问题"
        printf '%s' "$_screp" | sed '/^$/d; s/^/        /'
    fi
else
    echo "  [i] 没有**能跑**的 shellcheck —— 放一个本机架构的到 tools/shellcheck 即可启用;"
    echo "      tools/shellcheck.exe 是 Windows 二进制, Linux 上跑不了(跳过 ≠ 通过);"
    echo "      当前全部脚本的 warning 级已清零, 装上后应保持 0"
fi

# ── 4) 提交钩子是否真的生效(文档声称"pre-commit 强制", 得真装才有意义) ──────
echo "════════ 4) pre-commit 钩子 ════════"
if [ -d .git ]; then
    hp="$(git config --get core.hooksPath 2>/dev/null || true)"
    if [ "$hp" = "hooks" ] && [ -x hooks/pre-commit ]; then
        pass "pre-commit 已启用(每次提交前跑本脚本)"
    else
        # 不判失败: 新克隆没配也正常 —— 但这种"文档说强制、实际没装"的差距必须说出来
        echo "  [i] pre-commit 未启用 —— 文档说'提交前强制自检', 但 core.hooksPath 没指向 hooks/"
        echo "      启用(每个 clone 一次): git config core.hooksPath hooks"
        echo "      当前 core.hooksPath: ${hp:-(未设)}"
    fi
else
    echo "  [i] 不是 git 仓库(备份包), 跳过"
fi

echo
[ "$FAIL" -eq 0 ] && { echo "════ 全部通过 ════"; exit 0; } || { echo "════ 存在失败项, 请修复后重跑 ════════"; exit 1; }
