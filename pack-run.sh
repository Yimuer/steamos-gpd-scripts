#!/usr/bin/env bash
# ===========================================================================
#  pack-run.sh —— 把 tar.gz 发布包封装成**单文件自安装包** (.run)
# ---------------------------------------------------------------------------
#  【为什么要有它】
#    在 3.10.1 之前, 交付物是一个 tar.gz: 用户要先解压, 而且文档里有 7 处(6 个文件)
#    写着"从 Windows / 网盘 / U 盘拷回来会丢执行位 → 先 chmod +x *.sh *.desktop"
#    (两个 .desktop 注释、README、使用说明.txt、重装流程.md、重装后先运行我.sh)。
#    那条手工步骤的存在说明交付形态不完整: **一个文件、bash 一下就位**才是终点。
#
#  【它解决什么】
#    · 单文件拷到任何机器, `bash steamos-toolbox-<版本>.run` 即可, 不需要执行位
#      (要执行位的是包**里面**那些脚本, 而它们的模式由 pack 显式写进了 tar 元数据)。
#    · 自带 sha256 校验: 网盘截断/传输损坏会在解压前被发现, 而不是跑到一半才炸。
#    · 绝不覆盖用户已有目录(默认拒绝, --force 时把旧的挪到 .bak-时间戳 保留)。
#
#  【设计约束(与项目铁律一致)】
#    · 不自己提权: 全程以当前用户身份写自己的家目录; 需要 root 的事仍由 steamos.sh 分发。
#    · 非交互不挂起: 本脚本不读 stdin; 装完是否启动菜单由"是不是终端"决定。
#    · 只做封装, 不复制逻辑: 成员清单/模式全由 steamos.sh pack 决定, 这里只搬运。
#
#  【用法】
#    bash pack-run.sh <载荷.tar.gz> <输出.run> [版本号]
#    bash pack-run.sh --selftest            (自检: 造一个最小包, 解一遍, 验证 sha)
#
#  【退出码】0 成功 / 2 用法错 / 3 输入缺失或损坏
# ===========================================================================
set -uo pipefail

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'
info() { printf '%s[✓]%s %s\n' "$C_G" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_R" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_RD" "$C_R" "$*" >&2; }
sub()  { printf '    %s\n' "$*"; }

usage() {
    cat <<'EOF'
用法: bash pack-run.sh <载荷.tar.gz> <输出.run> [版本号]
  把 steamos.sh pack 产出的 tar.gz 封成一个单文件自安装包。
  产物用法(给最终用户看的):
    bash steamos-toolbox-<版本>.run              解到 ~/steamos-toolbox 并打开菜单
    bash steamos-toolbox-<版本>.run --list       只列包里的文件
    bash steamos-toolbox-<版本>.run --no-run DIR 解到 DIR, 不启动菜单
    bash steamos-toolbox-<版本>.run --force DIR  旧目录保留为 DIR.bak-<时间戳>
EOF
}

# ── 自检模式: 不依赖外部包, 造一个最小载荷走一遍全流程 ──────────────────────
if [ "${1:-}" = "--selftest" ]; then
    _st="$(mktemp -d "${TMPDIR:-/tmp}/pack-run-selftest-XXXXXX")" || { err "建不了临时目录"; exit 1; }
    # 玩具载荷**镜像真实包结构**(顶层 steamos.sh 可执行 + 一个数据文件):
    #   安装器会硬检查"解出来顶层有没有 steamos.sh", 拿 hello.sh 当载荷会被它正确地拒掉。
    mkdir -p "$_st/src"
    printf '#!/usr/bin/env bash\necho HELLO-FROM-PAYLOAD\n' > "$_st/src/steamos.sh"
    printf 'payload-text\n' > "$_st/src/data.txt"
    tar -cf "$_st/p.tar" --no-recursion --mode='u=rwx,go=rx' -C "$_st/src" steamos.sh \
      && tar -rf "$_st/p.tar" --no-recursion --mode='u=rw,go=r' -C "$_st/src" data.txt \
      && gzip -c "$_st/p.tar" > "$_st/payload.tar.gz" || { err "自检测载荷造失败"; rm -rf "${_st:?}"; exit 1; }
    bash "$0" "$_st/payload.tar.gz" "$_st/out.run" "selftest" || { err "打包失败"; rm -rf "${_st:?}"; exit 1; }
    [ -f "$_st/out.run" ] || { err "没产出 out.run"; rm -rf "${_st:?}"; exit 1; }
    # 1) --list 能列(与载荷自身的清单逐行一致 —— 证明偏移算对了)
    tar -tzf "$_st/payload.tar.gz" > "$_st/want.list"
    bash "$_st/out.run" --list > "$_st/got.list" 2>/dev/null || { err "--list 退出非 0"; rm -rf "${_st:?}"; exit 1; }
    diff -q "$_st/want.list" "$_st/got.list" >/dev/null || { err "--list 内容与载荷不一致"; rm -rf "${_st:?}"; exit 1; }
    # 2) 安装到目标目录 + 执行位正确 + 载荷真能跑
    bash "$_st/out.run" --no-run "$_st/dst" >/dev/null || { err "安装退出非 0"; rm -rf "${_st:?}"; exit 1; }
    [ -x "$_st/dst/steamos.sh" ] || { err "解出来的 steamos.sh 没有执行位"; rm -rf "${_st:?}"; exit 1; }
    "$_st/dst/steamos.sh" | grep -q HELLO-FROM-PAYLOAD || { err "载荷跑不起来"; rm -rf "${_st:?}"; exit 1; }
    # 3) 已存在目标目录时: 默认拒绝, --force 时保留旧的
    if bash "$_st/out.run" --no-run "$_st/dst" >/dev/null 2>&1; then
        err "目录已存在却还肯装 —— 护栏没生效"; rm -rf "${_st:?}"; exit 1
    fi
    printf 'user-precious\n' > "$_st/dst/data.txt"
    bash "$_st/out.run" --no-run --force "$_st/dst" >/dev/null || { err "--force 装不上"; rm -rf "${_st:?}"; exit 1; }
    ls -d "$_st"/dst.bak-* >/dev/null 2>&1 || { err "--force 没有保留旧目录"; rm -rf "${_st:?}"; exit 1; }
    grep -q user-precious "$_st"/dst.bak-*/data.txt 2>/dev/null \
        || { err "旧目录里的用户文件丢了"; rm -rf "${_st:?}"; exit 1; }
    # 4) 载荷被截断时要在解压前就报, 而不是留下半个目录
    #    (用 if 而不是 `[ -e x ] && { ...; }`: 后者会把上一条命令的退出码洗成 0,
    #     自测自己就会假通过 —— 判据不响必须是可见的, 不能静默。)
    head -c $(( $(wc -c < "$_st/out.run") - 400 )) "$_st/out.run" > "$_st/corrupt.run"
    if bash "$_st/corrupt.run" --no-run "$_st/dst2" >/dev/null 2>&1; then
        err "损坏的包居然装成功了"; rm -rf "${_st:?}"; exit 1
    fi
    if [ -e "$_st/dst2" ]; then
        err "失败的安装留下了半个目录"; rm -rf "${_st:?}"; exit 1
    fi
    # 5) 偏移必须是**运行时实算**的: 往头部插 3 行注释后仍要能校验并解压。
    #    (这条防的是"把打包时算出的行数写死进模板" —— 以后谁手改 .run 头部或
    #     模板加了几行, 载荷就会错位; 实算的写法连 .run 整个搬走都照读不误。)
    #     分界用 __PYEOF__ 哨兵(它永远不会被 bash 执行到, 因为上一行已经 exit)。
    _hl="$(awk '/^__PYEOF__$/{print NR; exit}' "$_st/out.run")"
    [ -n "$_hl" ] || { err "找不到 __PYEOF__ 分界行(模板结构变了?)"; rm -rf "${_st:?}"; exit 1; }
    { head -n "$_hl" "$_st/out.run" | sed -e '3i # probe' -e '3i # probe' -e '3i # probe'
      tail -n +"$(( _hl + 1 ))" "$_st/out.run"; } > "$_st/grown.run"
    bash "$_st/grown.run" --check >/dev/null 2>&1 \
        || { err "头部多 3 行后载荷就读不出了 —— 偏移没实算"; rm -rf "${_st:?}"; exit 1; }
    bash "$_st/grown.run" --no-run "$_st/dst3" >/dev/null 2>&1 \
        || { err "头部变长的 .run 装不上"; rm -rf "${_st:?}"; exit 1; }
    [ -x "$_st/dst3/steamos.sh" ] || { err "变长包解出来丢了执行位"; rm -rf "${_st:?}"; exit 1; }
    rm -rf "${_st:?}"
    info "pack-run 自检通过(打包 / --list / 安装 / 执行位 / 拒绝覆盖 / --force 保留 / 损坏检测 / 不留半个目录 / 偏移实算)"
    exit 0
fi

[ "$#" -ge 2 ] || { usage; exit 2; }
PAYLOAD="$1"; OUT="$2"; VER="${3:-unknown}"
[ -f "$PAYLOAD" ] || { err "载荷不存在: $PAYLOAD"; exit 3; }
[ -s "$PAYLOAD" ] || { err "载荷是空文件: $PAYLOAD"; exit 3; }
tar -tzf "$PAYLOAD" >/dev/null 2>&1 || { err "载荷不是合法的 gzip tar: $PAYLOAD"; exit 3; }

SHA="$(sha256sum "$PAYLOAD" 2>/dev/null | cut -d' ' -f1)"
[ -n "$SHA" ] || { err "算不出 sha256(没有 sha256sum?)"; exit 3; }
SIZE="$(wc -c < "$PAYLOAD" | tr -d ' ')"
NFILES="$(tar -tzf "$PAYLOAD" | grep -c .)"

HDR="$(mktemp "${TMPDIR:-/tmp}/pack-run-hdr-XXXXXX")" || { err "建不了临时文件"; exit 1; }
trap 'rm -f "${HDR:?}"' EXIT

# ---- 自安装器的头部(它自己就是一个完整的 bash 脚本) --------------------------
#      写在这里用带引号的 heredoc: 内部的 $ 都不在本脚本展开, 只把 @@TOKEN@@ 换掉。
cat > "$HDR" <<'HEADER_EOF'
#!/usr/bin/env bash
# ===========================================================================
#  @@NAME@@ —— SteamOS 工具箱单文件自安装包
# ---------------------------------------------------------------------------
#  这是"一个文件就是整个交付物": 拷到任何 Linux(含 SteamOS)机器上,
#      bash @@NAME@@
#  就会把工具箱包解到 ~/steamos-toolbox 并打开统一入口菜单。
#
#  · 不需要先 chmod +x —— 要执行位的是包**里面**的脚本, 它们的模式写在 tar 元数据里。
#    (这正是它替代"从 Windows/网盘拷回来先 chmod +x *.sh *.desktop"那条手工步骤的原因)
#  · 自带 sha256 校验, 网盘截断/传输损坏会在解压**之前**被发现。
#  · 全程不提权: 只写你自己的家目录; 需要 root 的动作仍由包里的脚本自己 sudo。
#  · 已存在的目标目录默认拒绝覆盖; --force 时旧目录保留为 <目录>.bak-<时间戳>。
#
#  用法:
#    bash @@NAME@@                    解到 ~/steamos-toolbox, 然后开菜单
#    bash @@NAME@@ --list             只列包里的文件(不解压)
#    bash @@NAME@@ --check            只校验载荷完整性
#    bash @@NAME@@ --no-run [目录]    解到指定目录, 不启动菜单
#    bash @@NAME@@ --force [目录]     覆盖安装(旧目录保留为 .bak-时间戳)
#    bash @@NAME@@ --help
#  退出码: 0 成功 / 2 用法错 / 3 载荷损坏 / 4 目标已存在(未给 --force)
# ===========================================================================
set -uo pipefail

PAYLOAD_SHA="@@SHA@@"
PAYLOAD_SIZE=@@SIZE@@
TOOLBOX_VERSION="@@VERSION@@"
TOOLBOX_NAME="@@NAME@@"
# 载荷从哪儿开始: **运行时**找 __PYEOF__ 哨兵行, 它的下一行就是载荷。
#   为什么不写死打包时算好的行数: 那样只要头部被加/删一行(以后谁注释模板、
#   或某个工具动了文件头), 偏移就错, 而症状是"解压失败" —— 极难往这上面想。
#   2026-09-27 自测第 5 项(往头部插 3 行再装)专治这条: 第一版写死偏移, 当场被它抓住。
DEFAULT_DIR="$HOME/steamos-toolbox"

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'; C_B=$'\033[1m'
info() { printf '%s[✓]%s %s\n' "$C_G" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_R" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$C_RD" "$C_R" "$*" >&2; }
sub()  { printf '    %s\n' "$*"; }

# 定位"真实的自己": 必须解开符号链接(BASH_SOURCE 给的是软链路径时会找错载荷)
_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
    _d="$(cd -P "$(dirname "$_self")" 2>/dev/null && pwd)"
    _self="$(readlink "$_self")"
    case "$_self" in /*) ;; *) _self="$_d/$_self" ;; esac
done
SELF="$(cd -P "$(dirname "$_self")" 2>/dev/null && pwd)/$(basename "$_self")"
unset _self _d

# 管道调用(`cat x.run | bash`)时 SELF 是 stdin, 拿不到后面的载荷 —— 明确拒绝
if [ ! -f "$SELF" ] || [ ! -r "$SELF" ]; then
    err "认不出自己所在的文件(被管道调用了? SELF=$SELF)"
    sub "请用文件路径调用:  bash /完整路径/$TOOLBOX_NAME"
    exit 2
fi

# 载荷起点 = 哨兵行的下一行。运行时才算(理由见文件头 PAYLOAD 注释)。
payload() {
    local _off
    _off="$(awk '/^__PYEOF__$/{print NR+1; exit}' "$SELF")"
    if [ -z "$_off" ]; then
        err "在这个文件里找不到 __PYEOF__ 分界行 —— 它不是完整的单文件包(头部被截过?)"
        return 1
    fi
    tail -n +"$_off" "$SELF"
}

usage() {
    sed -n '/^#  用法:/,/^#  退出码/p' "$SELF" | sed 's/^# \{0,2\}//'
    echo
    echo "当前包: $TOOLBOX_NAME (工具箱 $TOOLBOX_VERSION, 载荷 $PAYLOAD_SIZE 字节)"
}

# --list: 只列清单, 不落任何盘
do_list() { payload | tar -tz 2>/dev/null; }

# --check: 校验载荷(大小 + sha256)。解压前先跑它。
do_check() {
    local got size
    size="$(payload | wc -c | tr -d ' ')"
    if [ "$size" != "$PAYLOAD_SIZE" ]; then
        err "载荷大小对不上: 记录 $PAYLOAD_SIZE, 实得 $size —— 这个包被截断或改过"
        return 3
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        warn "本机没有 sha256sum, 只做了大小校验"
        return 0
    fi
    got="$(payload | sha256sum | cut -d' ' -f1)"
    if [ "$got" != "$PAYLOAD_SHA" ]; then
        err "载荷 sha256 对不上(下载/拷贝过程中坏了)"
        sub "记录: $PAYLOAD_SHA"
        sub "实得: $got"
        sub "重下一份, 或从 git 仓库 clone: 见包内 README.md"
        return 3
    fi
    info "载荷完整(sha256 一致, $PAYLOAD_SIZE 字节)"
    return 0
}

MODE=install; DEST=""; FORCE=0; RUN=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help|help) usage; exit 0 ;;
        --list)         MODE=list ;;
        --check)        MODE=check ;;
        --no-run)       RUN=0 ;;
        --force)        FORCE=1 ;;
        --dir=*)        DEST="${1#--dir=}" ;;
        -*)             err "未知选项: $1"; usage; exit 2 ;;
        *)              DEST="$1" ;;
    esac
    shift
done

case "$MODE" in
    list)  do_list; exit $? ;;
    check) do_check; exit $? ;;
esac

[ -n "$DEST" ] || DEST="$DEFAULT_DIR"
case "$DEST" in
    "~"|"~/"*) DEST="$HOME/${DEST#\~/}" ;;
esac
if ! mkdir -p "$(dirname "$DEST")" 2>/dev/null; then
    err "建不了父目录: $(dirname "$DEST")(要写到别的分区请先换目录参数)"
    exit 2
fi
DEST_ABS="$(cd "$(dirname "$DEST")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$DEST")")" || {
    err "定位不了目标目录: $DEST"; exit 2; }
DEST="$DEST_ABS"

printf '%s══ SteamOS 工具箱 %s (单文件包) ══%s\n' "$C_B" "$TOOLBOX_VERSION" "$C_R"
sub "包:   $SELF"
sub "目标: $DEST"
do_check || exit $?

if [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
    if [ "$FORCE" -ne 1 ]; then
        err "目标目录已存在且非空: $DEST"
        sub "已装过的话直接跑就行:  bash $DEST/steamos.sh"
        sub "确认要重装:  bash $(basename "$SELF") --force $DEST   (旧目录保留为 $DEST.bak-<时间戳>)"
        exit 4
    fi
    bak="$DEST.bak-$(date '+%Y%m%d-%H%M%S')"
    mv "$DEST" "$bak" || { err "旧目录挪不开: $DEST"; exit 2; }
    warn "旧目录已保留为: $bak   (没删任何东西; 确认不需要了自己挪走)"
fi

# 先解到同分区的临时目录, 成功才改名到位 —— 失败时不会留下半个安装
TMPDEST="$DEST.installing-$$"
cleanup() { [ -n "${TMPDEST:-}" ] && [ -d "$TMPDEST" ] && rm -rf "${TMPDEST:?}"; return 0; }
trap cleanup EXIT INT TERM
mkdir -p "$TMPDEST" || { err "建不了临时目录: $TMPDEST"; exit 2; }
if ! payload | tar -xz -C "$TMPDEST"; then
    err "解压失败(包已损坏?) —— 没有安装任何东西, 目标目录没被动过"
    exit 3
fi

# 执行位: tar 元数据里已经带着(pack 显式写过模式), 这里再补一次是**保险**——
# 免得哪天换个解压器/文件系统把模式吞了, 又变成"双击没反应"那种查半天的现场。
chmod +x "$TMPDEST"/*.sh "$TMPDEST"/*.desktop 2>/dev/null || true
[ -f "$TMPDEST/steamos.sh" ] || { err "包里没有 steamos.sh —— 这不是完整的工具箱包"; exit 3; }
printf 'FROM=pack-run\nVER=%s\nINSTALLED=%s\nSRC=%s\n' \
    "$TOOLBOX_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')" "$SELF" \
    > "$TMPDEST/.installed-from" || warn "安装标记没写成(不影响使用)"

if ! mv "$TMPDEST" "$DEST"; then
    err "落位失败: mv $TMPDEST -> $DEST"
    exit 2
fi
trap - EXIT INT TERM
NFILES_RUN="$(find "$DEST" -type f 2>/dev/null | grep -c .)"
info "安装完成: $DEST ($NFILES_RUN 个文件, 工具箱 $TOOLBOX_VERSION)"
sub "以后直接用:  bash $DEST/steamos.sh        (菜单)"
sub "体检:        bash $DEST/steamos.sh doctor (只读, 秒级)"
sub "重装向导:    bash $DEST/steamos.sh wizard (需 sudo)"
if [ "$RUN" -eq 1 ] && [ -t 0 ]; then
    printf '\n进入菜单(非交互环境不会走到这里)...\n'
    exec bash "$DEST/steamos.sh"
elif [ "$RUN" -eq 1 ]; then
    warn "stdin 不是终端 -> 不开菜单(非交互不挂起); 要菜单请执行: bash $DEST/steamos.sh"
fi
exit 0
__PYEOF__
HEADER_EOF

# ---- 把占位符换成真实值 -----------------------------------------------------
#      载荷偏移不用算了: 头部用 __PYEOF__ 哨兵在运行时自己定位。
BASE="$(basename "$OUT")"
sed -e "s|@@SHA@@|$SHA|g" \
    -e "s|@@SIZE@@|$SIZE|g" \
    -e "s|@@VERSION@@|$VER|g" \
    -e "s|@@NAME@@|$BASE|g" \
    "$HDR" > "$OUT" || { err "写头部失败: $OUT"; exit 1; }
# 漏替换的占位符会变成一个"看起来正常但永远装不上"的包 —— 当场拦住
if grep -q '@@' "$OUT"; then
    err "头部还有没替换掉的 @@占位符@@, 中止:"
    grep -n '@@' "$OUT" | head -3 | sed 's/^/    /'
    rm -f "$OUT"; exit 1
fi
grep -q '^__PYEOF__$' "$OUT" || { err "头部没有 __PYEOF__ 分界行(模板被改坏了?)"; rm -f "$OUT"; exit 1; }
# 头部必须仍是合法 bash —— 语法不过就当场失败, 不要留下打不开的包
bash -n "$OUT" || { err "生成的 .run 头部语法不过(占位符替换出了什么?)"; rm -f "$OUT"; exit 1; }

cat "$OUT" > "$OUT.tmp" && cat "$PAYLOAD" >> "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT" \
    || { err "拼装载荷失败"; rm -f "$OUT" "$OUT.tmp"; exit 1; }
chmod 0755 "$OUT" 2>/dev/null || true

# 打完立刻自查一遍(--check 会读偏移并核 sha): 偏移错就在这一刻暴露
if ! bash "$OUT" --check >/dev/null; then
    err "生成的 .run 自检没过(载荷偏移或 sha 写错了) —— 别用这个包"
    exit 1
fi
LIST_N="$(bash "$OUT" --list 2>/dev/null | grep -c .)"
[ "$LIST_N" -eq "$NFILES" ] || { err "生成的 .run 列出的条目数($LIST_N)与载荷($NFILES)不一致"; exit 1; }

info "单文件包已生成: $OUT"
sub "体积 $(du -h "$OUT" 2>/dev/null | cut -f1) · 内含 $NFILES 个文件 · sha256 ${SHA:0:16}…"
sub "用法: bash $OUT            (解到 ~/steamos-toolbox 并开菜单)"
sub "验证: bash $OUT --check    (只校验, 不解压)"
