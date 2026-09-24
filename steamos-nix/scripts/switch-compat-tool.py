#!/usr/bin/env python3
"""切换某个非 Steam 游戏使用的 Proton 兼容层(改 Steam 全局 config.vdf)。

背景 / 结论(2026-09-09 修订, 推翻上一版):
  【当前推荐: DW-Proton】鹰角(Hypergryph / GRYPHLINE)系游戏在 Linux 上的
  社区共识是 DW-Proton, 而不是 GE-Proton。三个独立来源一致:
    - rhea.dev《Installing Windows games on Linux - Arknights: Endfield》:
      "GE-Proton ... the game installed fine for me and the launcher was semi
       functional, it wouldn't actually start the game" -> 换 dwproton 解决
    - 巴哈姆特《關於如何在linux上游玩終末地》: 明示装 dwproton
    - justalo.li《Linux 环境运行鹰角网络游戏方案》: 用 DW-Proton 11.0-11
  这与本机症状完全吻合: 启动器能装游戏/能登录/能拉起进程, 但
  U8SDKData::ParseConfig fail -> appCode is null -> 同意协议后黑屏无声音。
  详见 SCRIPT-MAINTENANCE.md 的 [6g]。

  【已证伪, 别再用】上一版靠"逐函数核对 ntoskrnl.exe 导出表"得出
  "必须 GE-Proton11-6" 的结论是错的: 后来逐个变体核对 ACE-BASE/CORE.sys
  (含 sys2/sysa/sysa2) 的导入表, 里面根本没有 PsGetProcessExitStatus,
  整个推理前提不成立。真凶是游戏目录缺 Qt WebEngine 运行时资源(见 [6d])。

用法:
  1) 彻底退出 Steam(不是关窗口, 是 Steam -> 退出; Steam 退出时会重写 config.vdf)
  2) python3 switch-compat-tool.py --tool dwproton-11.0-12-x86_64
     (不带 --tool 则列出可用兼容层)
  python3 switch-compat-tool.py --dry-run   先看会改什么
  python3 switch-compat-tool.py --list      只看现状

注意: 只改 CompatToolMapping, 不动 LaunchOptions, 不动 prefix(换兼容层
      不会重建 prefix, 游戏文件与登录态都保留)。
"""
import os
import sys
import glob
import shutil
import subprocess

try:
    import vdf
except ImportError:
    sys.exit("缺少 python-vdf, 请: sudo pacman -S python-vdf")

HOME = os.path.expanduser("~")
STEAM = os.path.join(HOME, ".local/share/Steam")
CFG = os.path.join(STEAM, "config/config.vdf")
TOOLS_DIR = os.path.join(STEAM, "compatibilitytools.d")

# 要匹配的游戏名关键词(在 shortcuts.vdf 的 AppName 里)
NAME_KEYS = ("终末地", "Endfield", "鹰角", "Hypergryph")

dry = "--dry-run" in sys.argv
just_list = "--list" in sys.argv

tool = None
if "--tool" in sys.argv:
    i = sys.argv.index("--tool")
    if i + 1 < len(sys.argv):
        tool = sys.argv[i + 1]
if tool and not tool.endswith("-x86_64"):
    tool = tool + "-x86_64"


def steam_running():
    """只认真正的 Steam 客户端。

    2026-09-09 修的 bug: 原来用 `pgrep -f steam`, 在 SteamOS 上永远命中
    steamos-manager / steamdeck.local / steamos-devkit-service 这些系统进程,
    结果脚本永远报"Steam 正在运行"、一次都没法用。
    改为只匹配 Steam 客户端自己的可执行文件。
    """
    pats = ("steam.sh", "steamrt64/steam", "steamwebhelper", "ubuntu12_32/steam")
    try:
        out = subprocess.run(["pgrep", "-u", str(os.getuid()), "-af", "steam"],
                             capture_output=True, text=True).stdout
    except Exception:
        return False
    for line in out.splitlines():
        if any(p in line for p in pats):
            return True
    return False


# ---- 列出可用兼容层 ----
avail = []
for d in sorted(glob.glob(os.path.join(TOOLS_DIR, "*"))):
    if os.path.isdir(d):
        avail.append(os.path.basename(d))
for d in sorted(glob.glob(os.path.join(STEAM, "steamapps/common/Proton*"))):
    if os.path.isdir(d):
        avail.append(os.path.basename(d))

d = vdf.load(open(CFG))
mapping = (d.get("InstallConfigStore", {})
            .get("Software", {})
            .get("Valve", {})
            .get("Steam", {})
            .get("CompatToolMapping", {}))

# ---- 找目标 appid(从 shortcuts.vdf 反查) ----
targets = []
for f in glob.glob(os.path.join(STEAM, "userdata/*/config/shortcuts.vdf")):
    try:
        sc = vdf.binary_load(open(f, "rb"))["shortcuts"]
    except Exception:
        continue
    for _i, s in sc.items():
        name = str(s.get("AppName", ""))
        if any(k in name for k in NAME_KEYS):
            exe = str(s.get("Exe", "")).strip('"')
            # shortcuts.vdf 里存的是有符号 32 位, Steam 内部用无符号
            aid = s.get("appid")
            if aid is None:
                continue
            appid = aid & 0xffffffff
            targets.append((str(appid), name, exe))

if not targets:
    sys.exit("没在 shortcuts.vdf 里找到终末地快捷方式(请先在 Steam 里加为非 Steam 游戏)")

print("当前 CompatToolMapping:")
for k, v in mapping.items():
    print(f"  {k}: {v.get('name')}")

print("\n目标快捷方式:")
for aid, name, exe in targets:
    cur = mapping.get(aid, {}).get("name", "(未设置, 走全局默认)")
    print(f"  {aid}  {name}\n      exe={exe}\n      当前={cur}")

if just_list:
    print("\n已安装兼容层:")
    for a in avail:
        print("  -", a)
    sys.exit(0)

if not tool:
    print("\n已安装兼容层:")
    for a in avail:
        print("  -", a)
    print("\n推荐(鹰角系游戏社区共识): --tool dwproton-11.0-12-x86_64")
    print("回退: --tool GE-Proton11-6-x86_64")
    sys.exit(0)

if tool not in avail:
    sys.exit(f"找不到兼容层 '{tool}'. 可用: {', '.join(avail)}")

if steam_running():
    sys.exit("检测到 Steam 正在运行。请先彻底退出 Steam(菜单->退出), 否则改动会被覆盖。")

changed = []
for aid, name, _exe in targets:
    node = mapping.setdefault(aid, {})
    if node.get("name") == tool:
        print(f"  {aid} ({name}): 已是 {tool}, 跳过")
        continue
    mapping[aid] = {"name": tool, "config": "", "priority": "250"}
    changed.append(f"{aid} ({name}) -> {tool}")

if not changed:
    print("没有需要改动的地方")
    sys.exit(0)

if dry:
    print(f"[干跑] 将把 {', '.join(changed)}")
else:
    shutil.copy(CFG, CFG + ".bak")
    with open(CFG, "w") as f:
        vdf.dump(d, f, pretty=True)
    print(f"已写入并备份 {CFG}.bak: {', '.join(changed)}")
    print("重新打开 Steam 生效。换兼容层不会重建 prefix, 游戏文件和登录态都保留。")
    print("首次以新兼容层启动会重建 ACE / VC runtime 组件, 可能较慢, 属正常。")
