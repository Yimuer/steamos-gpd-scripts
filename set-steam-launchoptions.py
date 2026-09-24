#!/usr/bin/env python3
"""给 Steam 非 Steam 快捷方式写入启动选项(干净无副作用, 不塞 FSR4 变量)。

自动探测 Steam userid 与游戏快捷方式(按名称匹配), 不再写死旧机器 ID。
用法: python3 set-steam-launchoptions.py [--dry-run]

说明: 鸣潮/终末地启动器是 WPF(.NET)程序, 不需要任何 FSR 变量;
      FSR4 是 RDNA4 专属, 对 8060S(RDNA3.5) 完全无效, 别再塞 PROTON_FSR4_UPGRADE。
      上采样交给游戏内原生 FSR + SteamOS 系统级 FSR(QAM 面板)。

注意: 此脚本是独立备用版; 重装后推荐直接用 steamos-setup.sh 步骤6
生成的 ~/.local/bin/steam-launch-games.py(逻辑一致)。
"""
import sys
import glob
import os
import shutil

try:
    import vdf
except ImportError:
    print("缺少 python-vdf, 请: sudo pacman -S python-vdf")
    sys.exit(1)

OPT = '%command%'

# 匹配名称里含以下任一词的快捷方式
NAME_KEYS = ("鸣潮", "鹰角", "终末地", "Wuthering", "Hypergryph")

dry = "--dry-run" in sys.argv

# 自动探测 localconfig.vdf
cands = glob.glob(os.path.expanduser("~/.local/share/Steam/userdata/*/config/localconfig.vdf"))
cands += glob.glob(os.path.expanduser("~/.steam/steam/userdata/*/config/localconfig.vdf"))
if not cands:
    print("未找到 Steam localconfig.vdf, 请先启动一次 Steam")
    sys.exit(1)
LC = cands[0]

with open(LC) as _f:
    d = vdf.load(_f)
apps = d["UserLocalConfigStore"]["Software"]["Valve"]["Steam"]["apps"]

changed = []
for appid, node in apps.items():
    name = str(node.get("name", ""))
    if any(k in name for k in NAME_KEYS):
        cur = node.get("LaunchOptions")
        if cur == OPT:
            print(f"  {appid} ({name}): 已是目标值，无需改动")
        else:
            node["LaunchOptions"] = OPT
            changed.append(f"{appid} ({name})")

if not changed:
    print("没有找到要写入的游戏快捷方式（请先在 Steam 添加非Steam游戏）")
    sys.exit(0)

if dry:
    print(f"[干跑] 将写入: {', '.join(changed)}")
else:
    shutil.copy(LC, LC + ".bak")
    with open(LC, "w") as f:
        vdf.dump(d, f, pretty=True)
    print(f"已写入并备份原文件: {', '.join(changed)}")
    print("重启 Steam 生效")
