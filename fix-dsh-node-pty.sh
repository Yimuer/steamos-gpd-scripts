#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# fix-dsh-node-pty.sh
# 修复 dsh(DeepSeek Harness 桌面版) 插件安装因 node-pty 失败而 PREINSTALL_FAILED。
#
# ── 根因(2026-09-25 定案, 有实测证据) ─────────────────────────────────────────
# 报错长这样:
#   node_modules/node-pty install: gyp ERR! configure error
#   node_modules/node-pty install: gyp ERR! stack Error: Could not find any Python installation to use
#   dsh: pnpm failed in profile directory ~/.dsh/profiles/tauri
#
# ⚠️ 它**不是**"机器上没装 python"。本机 /usr/bin/python3(3.14) + gcc + make 都齐,
#    在普通终端里用 dsh 的 runtime node 跑 node-gyp 编译 node-pty **完全成功**。
#
# 真凶是 **AppImage 运行时注入的 PYTHONHOME / PYTHONPATH**:
#   dsh 桌面版是 AppImage。type-2 runtime(AppRun.wrapped) 会无条件给整条进程树
#   putenv 这两个变量(二进制里就写着 "PYTHONHOME=%s/usr/"):
#       PYTHONHOME=/tmp/.mount_DeepseXXXX/usr/
#       PYTHONPATH=/tmp/.mount_DeepseXXXX/usr/share/pyshared/:
#   而那个 mount 目录里并没有 python 标准库。于是 dsh 进程树里任何 /usr/bin/python3
#   一启动就:
#       Fatal Python error: Failed to import encodings module
#       ModuleNotFoundError: No module named 'encodings'
#   退出码 1、stdout 为空 -> node-gyp 探测到的路径是空串 -> 判定"没有可用 Python"。
#   取证方法(只读):
#       PID=$(pgrep -f 'deepseek-harness-desktop$' | head -1)
#       tr '\0' '\n' < /proc/$PID/environ | grep -E 'PYTHON'
#   注意: 这两个变量是 runtime 自己 setenv 的, 从外部 unset 无法阻止。
#
# 另有一层: pnpm v11 默认拦截依赖的 build 脚本, 报 [ERR_PNPM_IGNORED_BUILDS],
#   dsh 把它当致命错误直接 abort。必须把 node-pty 加进 allowBuilds 才放行。
#
# ── 本脚本做三件事(前三件缺一不可) ──────────────────────────────────────────
#   [1] 用 dsh 自带的 runtime node + 内置 node-gyp, 把 node-pty 编译一次。
#   [2] 把产物**同时**写到 prebuilds/linux-x64/pty.node —— 这一条是解药的核心。
#       node-pty 官方不发 Linux 预编译包(它的 prebuilds/ 里只有 darwin-* 和 win32-*),
#       而它的 install 脚本是 `node scripts/prebuild.js || node-gyp rebuild`。
#       prebuilds/linux-x64 一旦存在, prebuild.js 直接 exit 0,
#       **node-gyp 永不参与** -> 以后 dsh 每次启动重跑安装都不再需要 python。
#   [3] 放一个 ~/.local/bin/python3 包装器, 清掉"指向不存在的 Python 安装"的
#       PYTHONHOME/PYTHONPATH。这是兜底: 万一 prebuilds 被冲掉(插件大版本更新会
#       重建 node_modules)而必须现场编译, 也能成。
#       ⚠️ 包装器必须对"探测 sys.executable"那条命令回答**自身路径**:
#          node-gyp 会把探测到的绝对路径记下来, 之后直接 exec 它、不再走 PATH,
#          若回答 /usr/bin/python3 就被绕过去了(实测确认过)。见 find-python.js
#          的 argsExecutable(node-gyp 12 与 11 的写法不同, 两种都覆盖)。
#   [4] 放行 pnpm v11 的构建脚本拦截(node-pty -> allowBuilds)。
#
# 用法(在 GPD 真机桌面模式的 Konsole 里跑, 不需要 sudo):
#   bash fix-dsh-node-pty.sh            # 体检 + 修复
#   bash fix-dsh-node-pty.sh --check    # 只体检, 不改任何东西
#
# 说明: 编译只需一次, 产物落在 ~/.dsh(即 /home) 下, SteamOS 原子升级后依然存活;
#       ~/.local/bin/python3 同理。
#
# 若在 dsh 的集成终端里跑本脚本: 脚本开头会 unset 那两个毒变量, 所以本脚本自己的
# 编译不会被它拖累(普通 Konsole 里本来就没有这两个变量)。

set -uo pipefail

MODE="apply"
case "${1:-}" in
  --check) MODE="check" ;;
  -h|--help)
    sed -n '3,10p' "$0"
    exit 0
    ;;
  "") ;;
  *)
    echo "未知参数: $1 (可用: --check)" >&2
    exit 64
    ;;
esac

# ── 0. 先清掉 AppImage 注入的毒变量(在 dsh 集成终端里跑时它们一定在) ─────────
unset PYTHONHOME PYTHONPATH

DSH_SHARE="${HOME}/.local/share/dsh-tauri"
PROFILE="${HOME}/.dsh/profiles/tauri"
NODEPTY_DIR="${PROFILE}/node_modules/node-pty"
DSH_RUNTIME_NODE="${DSH_SHARE}/runtime/bin/node"
ARTIFACT="${NODEPTY_DIR}/build/Release/pty.node"
PREBUILD_DIR="${NODEPTY_DIR}/prebuilds/linux-x64"
PREBUILD="${PREBUILD_DIR}/pty.node"
PY_WRAPPER="${HOME}/.local/bin/python3"
PNPM_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/pnpm/config.yaml"

OK=0
BAD=0
note_ok()  { echo "[OK]   $*"; OK=$((OK + 1)); }
note_bad() { echo "[待修] $*"; BAD=$((BAD + 1)); }

echo "== 体检 =="

# --- 1. 找系统 python3(编译 node-pty 需要) ---
PYTHON_BIN=""
if [ -x "$PY_WRAPPER" ] && grep -q "fix-dsh-node-pty.sh" "$PY_WRAPPER" 2>/dev/null; then
  PYTHON_BIN="$PY_WRAPPER"
elif [ -x /usr/bin/python3 ]; then
  PYTHON_BIN=/usr/bin/python3
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python)"
fi
if [ -n "$PYTHON_BIN" ]; then
  note_ok "Python: $PYTHON_BIN -> $("$PYTHON_BIN" --version 2>&1)"
else
  note_bad "系统里没有任何可用的 python3/python"
fi

# --- 2. 编译器 ---
HAVE_CC=0
for c in gcc cc; do
  if command -v "$c" >/dev/null 2>&1; then
    HAVE_CC=1; note_ok "C 编译器: $(command -v "$c")"; break
  fi
done
[ "$HAVE_CC" -eq 0 ] && note_bad "没有 gcc/cc（编译 node-pty 必需）"
if command -v make >/dev/null 2>&1; then note_ok "make 存在"; else note_bad "没有 make"; fi

# --- 3. dsh 的 runtime node（编译目标 ABI 必须与它一致，不能用系统 node） ---
if [ -x "$DSH_RUNTIME_NODE" ]; then
  note_ok "dsh runtime node: $("$DSH_RUNTIME_NODE" --version 2>&1)"
else
  note_bad "找不到 $DSH_RUNTIME_NODE（先启动一次 dsh 桌面版让它自解压）"
fi

# --- 4. 找 node-gyp（路径随 dsh 版本变，动态找，别写死） ---
NODE_GYP=""
for c in \
  "${DSH_SHARE}/dependencies/pnpm/dist/node_modules/node-gyp/bin/node-gyp.js" \
  "${DSH_SHARE}/runtime/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js"
do
  if [ -f "$c" ]; then NODE_GYP="$c"; break; fi
done
if [ -z "$NODE_GYP" ] && [ -d "$DSH_SHARE" ]; then
  while IFS= read -r c; do
    [ -n "$c" ] && { NODE_GYP="$c"; break; }
  done < <(find "$DSH_SHARE" -maxdepth 8 -type f -path '*node-gyp/bin/node-gyp.js' 2>/dev/null)
fi
if [ -n "$NODE_GYP" ] && [ -x "$DSH_RUNTIME_NODE" ]; then
  note_ok "node-gyp: $NODE_GYP (v$("$DSH_RUNTIME_NODE" -e "console.log(require('${NODE_GYP%/bin/node-gyp.js}/package.json').version)" 2>/dev/null))"
elif [ -n "$NODE_GYP" ]; then
  note_ok "node-gyp: $NODE_GYP"
else
  note_bad "找不到 node-gyp（dsh 未完整安装？）"
fi

# --- 5. node-pty 与产物状态 ---
NEED_BUILD=0
if [ ! -d "$NODEPTY_DIR" ]; then
  note_bad "找不到 $NODEPTY_DIR —— node-pty 还没被拉下来"
  echo "        先启动一次 dsh 桌面版（让它跑一次 pnpm 把包装好），再跑本脚本。"
  echo
  echo "结论: 无法继续（缺 node-pty 源码）。"
  exit 1
fi
note_ok "node-pty 源码: $NODEPTY_DIR"

if [ -f "$ARTIFACT" ]; then
  note_ok "已有编译产物 build/Release/pty.node"
else
  note_bad "build/Release/pty.node 不存在 -> 需要编译"
  NEED_BUILD=1
fi
if [ -f "$PREBUILD" ]; then
  note_ok "已有预编译产物 prebuilds/linux-x64/pty.node（node-gyp 不会被调用）"
else
  note_bad "prebuilds/linux-x64/pty.node 不存在 -> dsh 每次都会去调 node-gyp"
  NEED_BUILD=1
fi

if [ "$MODE" = "check" ]; then
  echo
  if [ "$BAD" -eq 0 ]; then
    echo "结论: 全绿（$OK 项就绪）。"
    exit 0
  fi
  echo "结论: 有 $BAD 项待修，跑一次本脚本（不带 --check）即可。"
  exit 1
fi

# ── 6. [兜底层] 写 python3 包装器 ────────────────────────────────────────────
# 万一 prebuilds 被冲掉必须现场编译时, 让 node-gyp 能真的用上 python。
if [ -f "$PY_WRAPPER" ] && ! grep -q "fix-dsh-node-pty.sh" "$PY_WRAPPER" 2>/dev/null; then
  BAK="${PY_WRAPPER}.bak.$(date +%m%d-%H%M%S)"
  cp -f "$PY_WRAPPER" "$BAK"
  echo "[提示] $PY_WRAPPER 原本已存在且不是本脚本生成的，已备份到 $BAK"
fi

mkdir -p "$(dirname "$PY_WRAPPER")"
cat > "$PY_WRAPPER" <<'PYEOF'
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# python3 包装器 —— 由 fix-dsh-node-pty.sh 生成, 可重复覆盖。
#
# 背景(根因): DeepSeek Harness 桌面版是 AppImage。AppImage 运行时(type-2)会无条件
#   给整条进程树 putenv 这两个变量(见 AppRun.wrapped 内嵌的 "PYTHONHOME=%s/usr/"):
#       PYTHONHOME=/tmp/.mount_DeepseXXX/usr/
#       PYTHONPATH=/tmp/.mount_DeepseXXX/usr/share/pyshared/:
#   于是继承这套环境的 /usr/bin/python3 一启动就找不到标准库:
#       Fatal Python error: Failed to import encodings module
#       ModuleNotFoundError: No module named 'encodings'
#   退出码 1 且 stdout 为空。node-gyp 探测 python 时拿到空结果, 于是报
#       gyp ERR! stack Error: Could not find any Python installation to use
#   -> node-pty 编译失败 -> dsh 插件安装 PREINSTALL_FAILED, 桌面版起不来。
#
# 本文件做两件事:
#   1) 透传时清掉"指向不存在的 Python 安装"的 PYTHONHOME/PYTHONPATH。
#   2) node-gyp 探测 sys.executable 时回答"我自己"。
#      #2 是必须的: node-gyp 会把这个绝对路径记下来, 之后版本检查和实际编译都
#      直接 exec 该绝对路径、不再走 PATH —— 若回答 /usr/bin/python3, 包装器就被
#      绕过去了(实测确实如此)。回答自身后 node-gyp 全程经由本包装器执行,
#      毒变量在每一跳都被清掉。
#
# 安全: 除上述精确匹配的一条命令外, 其余参数一律原样透传给系统 python3, 对
#       conda/venv 等正常用法透明; 且只有 PYTHONHOME 指向"无标准库的目录"时才清。
# 位置: ~/.local/bin 在 dsh 的 PATH 里排第一位且在 /usr/bin 之前; 位于 /home
#       分区, SteamOS 原子升级后依然存活。

# --- 1. 清理"有毒"的 PYTHONHOME/PYTHONPATH ---
if [ -n "${PYTHONHOME:-}" ]; then
  _ok=0
  for _d in "$PYTHONHOME"/lib/python3.*/encodings; do
    if [ -d "$_d" ]; then _ok=1; break; fi
  done
  if [ "$_ok" -ne 1 ]; then
    unset PYTHONHOME
    unset PYTHONPATH
  fi
  unset _ok _d
fi

# --- 2. node-gyp 的 sys.executable 探测: 回答自身 ---
#     见 <node-gyp>/lib/find-python.js 的 argsExecutable, 各版本写法不同:
#       12.x: -c "import sys; sys.stdout.buffer.write(sys.executable.encode('utf-8'));"
#       11.x: -c "import sys; print(sys.executable)"
#     故按"参数是 -c 且脚本里出现 sys.executable"来判定。
if [ "$#" -eq 2 ] && [ "$1" = "-c" ]; then
  case "$2" in
    *sys.executable*)
      case "${0:-}" in
        */*) printf '%s\n' "$0" ;;
        *)   printf '%s\n' "${HOME:-/home/deck}/.local/bin/python3" ;;
      esac
      exit 0
      ;;
  esac
fi

# --- 3. 透传给真正的系统 python3 ---
for _p in /usr/bin/python3 /usr/bin/python /usr/local/bin/python3; do
  if [ -x "$_p" ]; then
    exec "$_p" "$@"
  fi
done

echo "python3 wrapper: 系统里找不到可用的 python3" >&2
exit 127
PYEOF
chmod 755 "$PY_WRAPPER"
if [ -x "$PY_WRAPPER" ] && "$PY_WRAPPER" -c 'import sys' >/dev/null 2>&1; then
  echo "[OK]   已就绪 python3 包装器: $PY_WRAPPER"
else
  echo "[失败] python3 包装器写入后无法执行: $PY_WRAPPER"
  exit 2
fi

# ── 7. 需要就先装依赖(需 sudo, 二次确认) ────────────────────────────────────
if [ "$NEED_BUILD" -eq 1 ] && { [ -z "$PYTHON_BIN" ] || [ "$HAVE_CC" -eq 0 ] || ! command -v make >/dev/null 2>&1; }; then
  echo
  echo "⚠️ 需要安装 python 和/或编译工具(base-devel)，会临时写入 rootfs"
  echo "   (升级后 python 可能丢失，但已编译的 node-pty 产物在 /home 下永久存活)。"

  PKGS=(python)
  if [ "$HAVE_CC" -eq 0 ] || ! command -v make >/dev/null 2>&1; then
    PKGS+=(base-devel)
  fi

  if [ ! -t 0 ]; then
    echo "本步骤需要 sudo 安装依赖, 但当前不是交互终端, 无法确认。"
    echo "请手动执行以下命令后重跑本脚本:"
    echo
    echo "  sudo steamos-readonly disable"
    echo "  sudo pacman-key --init"
    echo "  sudo pacman-key --populate archlinux holo"
    echo "  sudo pacman -S --needed ${PKGS[*]}"
    echo "  sudo steamos-readonly enable"
    exit 3
  fi

  read -r -t 30 -p "是否现在安装? [y/N] " ans || ans="n"
  case "$ans" in
    y|Y) ;;
    *) echo "已取消。请手动安装 python3(+base-devel)后重跑本脚本。"; exit 3 ;;
  esac

  sudo steamos-readonly disable
  sudo pacman-key --init 2>/dev/null || true
  sudo pacman-key --populate archlinux holo 2>/dev/null || true
  sudo pacman -S --needed "${PKGS[@]}"
  sudo steamos-readonly enable

  if [ -z "$PYTHON_BIN" ]; then
    [ -x /usr/bin/python3 ] && PYTHON_BIN=/usr/bin/python3
  fi
fi

# ── 8. 编译(仅当需要) ───────────────────────────────────────────────────────
if [ "$NEED_BUILD" -eq 1 ]; then
  if [ ! -x "$DSH_RUNTIME_NODE" ]; then
    echo "[失败] 找不到 dsh runtime node: $DSH_RUNTIME_NODE"; exit 4
  fi
  if [ -z "$NODE_GYP" ] || [ ! -f "$NODE_GYP" ]; then
    echo "[失败] 找不到 dsh 内置 node-gyp"; exit 5
  fi
  if [ -z "$PYTHON_BIN" ]; then
    echo "[失败] 找不到可用的 python3，无法编译。"; exit 6
  fi

  echo
  echo "== 编译 node-pty =="
  echo "   node:   $DSH_RUNTIME_NODE ($("$DSH_RUNTIME_NODE" --version 2>&1))"
  echo "   gyp:    $NODE_GYP"
  echo "   python: $PYTHON_BIN"
  # 只清"有毒"的那两个变量; PYTHON 显式给上, node-gyp 认这个变量
  export PYTHON="$PYTHON_BIN"
  unset PYTHONHOME PYTHONPATH
  (
    cd "$NODEPTY_DIR" || exit 7
    "$DSH_RUNTIME_NODE" "$NODE_GYP" rebuild
  )
  RC=$?
  if [ "$RC" -ne 0 ]; then
    echo "[失败] node-gyp rebuild 退出码 $RC"; exit 7
  fi
  if [ ! -f "$ARTIFACT" ]; then
    echo "[失败] rebuild 报 ok 但 $ARTIFACT 仍未出现"; exit 8
  fi
  echo "[OK]   编译成功: $ARTIFACT"
fi

# ── 9. [解药核心] 同步到 prebuilds/linux-x64 ────────────────────────────────
# 有它, node-pty 的 install 脚本 (`node scripts/prebuild.js || node-gyp rebuild`)
# 会走前半段直接 exit 0, node-gyp 根本不被调用 -> 不再需要 python。
if [ -f "$ARTIFACT" ]; then
  mkdir -p "$PREBUILD_DIR"
  if [ -f "$PREBUILD" ] && cmp -s "$ARTIFACT" "$PREBUILD"; then
    echo "[OK]   prebuilds/linux-x64/pty.node 已是最新（与 build/Release 一致）"
  else
    cp -f "$ARTIFACT" "$PREBUILD"
    echo "[OK]   已同步到 prebuilds/linux-x64/pty.node（dsh 今后不再调用 node-gyp）"
  fi
fi

# ── 10. 放行 pnpm v11 的构建脚本拦截 ────────────────────────────────────────
mkdir -p "$(dirname "$PNPM_CFG")"
if [ -f "$PNPM_CFG" ] && grep -q "node-pty" "$PNPM_CFG" 2>/dev/null; then
  echo "[OK]   $PNPM_CFG 已含 node-pty 的 allowBuilds 条目"
else
  [ -f "$PNPM_CFG" ] && printf '\n' >> "$PNPM_CFG"
  cat >> "$PNPM_CFG" <<'YAML'

# 允许 dsh(tauri) 的 node-pty 原生模块通过 pnpm v11 构建脚本拦截 (fix-dsh-node-pty.sh)
allowBuilds:
  node-pty: true
YAML
  echo "[OK]   已写入 $PNPM_CFG: allowBuilds.node-pty=true"
fi
# profile 自己的 pnpm-workspace.yaml 由 dsh 维护, 通常已带 allowBuilds, 只提醒不代改
if ! grep -q "node-pty" "${PROFILE}/pnpm-workspace.yaml" 2>/dev/null; then
  echo "[提示] ${PROFILE}/pnpm-workspace.yaml 里没有 node-pty 的 allowBuilds,"
  echo "       若 dsh 仍报 [ERR_PNPM_IGNORED_BUILDS], 手动加:"
  echo "         allowBuilds:"
  echo "           node-pty: true"
fi

# ── 11. 双判据落地复核(不看"文件在不在", 看"真的能用") ──────────────────────
echo
echo "== 复核 =="
FAIL=0

# 判据 1: node-pty 的 install 脚本必须走 prebuild 分支(exit 0 = 不会调 node-gyp)
if [ -f "$ARTIFACT" ] && [ -x "$DSH_RUNTIME_NODE" ]; then
  if ( cd "$NODEPTY_DIR" && "$DSH_RUNTIME_NODE" scripts/prebuild.js >/dev/null 2>&1 ); then
    echo "[OK]   判据1: node-pty 安装脚本走 prebuild 分支（node-gyp 不会被调用）"
  else
    echo "[失败] 判据1: node-pty 安装脚本仍会落到 node-gyp 分支"
    FAIL=1
  fi
else
  echo "[跳过] 判据1: 缺产物或 node runtime"
  FAIL=1
fi

# 判据 2: 用 dsh 的 runtime node 真的 require 一次原生模块
if [ -x "$DSH_RUNTIME_NODE" ] && [ -f "$ARTIFACT" ]; then
  if "$DSH_RUNTIME_NODE" -e "require('$NODEPTY_DIR')" >/dev/null 2>&1; then
    echo "[OK]   判据2: node-pty 原生模块可被 $("$DSH_RUNTIME_NODE" --version 2>&1) 加载"
  else
    echo "[失败] 判据2: node-pty 原生模块加载失败（ABI 不匹配？重跑本脚本）"
    FAIL=1
  fi
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "== 未通过 =="
  echo "把上面 [失败] 那行连同 'gyp ERR!' 日志发出来再排查。"
  exit 9
fi

echo "== 完成 =="
echo "1) node-pty 原生模块已就绪, 且已放进 prebuilds/linux-x64（node-gyp 不再被调用）"
echo "2) pnpm v11 构建拦截已放行（node-pty -> allowBuilds）"
echo "3) python3 包装器已就位（万一需要重编译也能过）"
echo
echo "现在**完全退出并重新打开** DeepSeek Harness 桌面版, 它会重试之前失败的插件安装并成功。"
echo "若重开后仍报 [ERR_PNPM_IGNORED_BUILDS] / Ignored build scripts, 用环境变量强开一次:"
echo "  pnpm_config_dangerously_allow_all_builds=true ~/.local/opt/deepseek-harness-desktop/Deepseek.Harness.Desktop.AppImage"
echo "  (一次性强开后产物已落盘, 之后正常启动即可)"
echo
echo "体检随时可跑: bash $0 --check"
