# 适配 GPD 的 SteamOS 脚本

> **更适合中国宝宝和各路 win 掌机的 steamos 出路**

**仓库地址**：https://github.com/Yimuer/steamos-gpd-scripts　·　**许可**：GPL-3.0

把「SteamOS / Win 掌机重装系统后，要从零配一遍」这件事，变成**跑几条命令**。

本项目在 **GPD Win5（Ryzen AI Max+ 395 / Radeon 8060S）** 上逐环实测，
所有脚本都围绕一个核心约束设计：**SteamOS 的 A/B 原子升级会怎样把你的劳动成果吃掉。**

---

## 一、核心思路：搞清楚「什么会被冲掉」

SteamOS 大版本升级会整块替换 rootfs。踩过之后才知道，被冲与否**不是**凭直觉：

| 位置 | 原子升级后 | 说明 |
|---|---|---|
| `/home` | ✅ 幸存 | 游戏、前缀、配置都在这里 |
| `/opt`、`/root`、`/srv`、`/nix` | ✅ **幸存** | 它们是 bind-mount 到 `/home` 分区（`/home/.steamos/offload/*`）的 |
| `/etc` | ❌ 被冲 | overlay，upper 在 `/var` |
| `/usr`、`/var`、pacman 数据库 | ❌ 被冲 | 包管理器装的软件全在这里 |
| ~~`/usr/local`~~ | ❌ **被冲** | **2026-09-25 实测纠正**：它属于 `/usr`（同一 btrfs 子卷），**不在 Valve 的 offload 清单里**。以前这里把它错列为"幸存" |
| `/var/log`、`/var/tmp`、`/var/cache/pacman`、`/var/lib/{docker,flatpak}` | ✅ 幸存 | 这几个 `var` 下的目录**也是 offload**（意外但实测如此，pacman 包缓存就住在这里） |

> ⚠️ **这张表请以实机为准，别凭印象**（曾经因为想当然，把 `/usr/local` 错写成"扛升级"，一路抄进了 6 处文档）。
> 一条命令自查：`findmnt -no SOURCE --target <路径>` —— 与 `findmnt -no SOURCE --target /` **不同**才算 offload。
> Valve 的清单还可能随版本变，所以脚本里凡是要"放东西抗升级"的地方都**运行时判断**
> （例：`install-workbuddy-home.sh` 的 `usrsrc_mount()`，不是 offload 就跳过并说明）。

于是本项目的两条铁律：

1. **能用官方便携包的，一律装进 `/home` 或 `/opt`**，入口 / 桌面项 / 图标放 `~/.local`，
   彻底和 `pacman`、`/usr` 解耦 —— 升级后**零操作**可用。
2. **必须写 `/etc` 的东西（背键 unit、NTP、防火墙规则等），全部登记进自愈清单**，
   由 `/home` 里的一个 user 服务在每次开机时自动检测并重建。

> 反过来说：**为了装一个可选应用去 `pacman` 塞一堆系统库，等于把它绑死在会被冲的 rootfs 上。**
> 所以本项目选发行物时，会先把 deb 的 `Depends` 拉出来看，大件系统库越多越要选自带运行时的便携包。

---

## 二、快速开始

**交付物是一个文件**：`steamos-toolbox-<版本>.run`（由 `bash steamos.sh pack` 打出）。
拷到任何 Linux（含 SteamOS）机器上，`bash` 它一下就位——不需要先 `chmod`，不需要手工解压：

```bash
bash steamos-toolbox-3.11.0.run        # 校验载荷 → 解到 ~/steamos-toolbox → 打开菜单
bash steamos-toolbox-3.11.0.run --list # 只想看看包里有什么
bash steamos-toolbox-3.11.0.run --check # 只校验完整性（网盘截断会在这里暴露）
```

开发/取最新代码用 git clone，入口同样是那一个（菜单按「体检 / 重装 / 应用 / 修复 / 诊断 / 维护」分组，
每项都标了性质 `只读` / `sudo` / `交互`）：

```bash
git clone https://github.com/Yimuer/steamos-gpd-scripts.git
cd steamos-gpd-scripts

bash steamos.sh                 # 交互菜单（推荐入口；也可双击 steamos.desktop）
bash steamos.sh list            # 只想要一份清单
bash steamos.sh help            # 用法
```

常用的那几条（都能从菜单进，也可以直接敲）：

```bash
bash steamos.sh doctor          # 这台机器现在健康吗（只读，秒级）
bash steamos.sh status          # 16 步各自的落地状态
sudo bash steamos-setup.sh 3    # 分步安装（便于定位错误；等价于菜单里的 setup）
sudo bash steamos-setup.sh      # 或一次全量跑完 16 步
sudo bash steamos-setup.sh --after-upgrade   # 大版本升级后：只重建被冲掉的
```

> 拿到的若是**整个目录**（git clone，或手工解开 tar.gz），从 Windows / 网盘 / U 盘拷回来会丢执行位，
> 要先 `chmod +x *.sh *.desktop`，否则双击没反应。**用 `.run` 就不用管这条** —— 执行位写在包内的
> tar 元数据里，安装器解出来会自己补齐（这是 `.run` 存在的主要理由）。

**断点续传**：中断后重跑同一条命令会跳过已完成步骤。进度记在
`~/.cache/steamos-setup/state`；`--reset` 清进度，`--force` 强制重跑（别用 `FORCE=1 sudo …` 前缀，环境变量会被 sudo 的 env_reset 剥掉）。

---

## 三、必装主线（16 步）

| 步 | 内容 |
|---|---|
| 1 | `archlinuxcn` 源 |
| 2 | 系统输入法（**已禁用** —— 不改动系统输入法，避免与 KWin/IBus 打架） |
| 3 | WorkBuddy（AUR 包 + 自动自持化到 `/home`） |
| 4 | GPD Win5 背键 → inputplumber（仅 Win5，其它机型跳过） |
| 5 | Decky Loader + 预置插件 |
| 6 | 游戏兼容层（GE-Proton）与鸣潮 / 终末地辅助 |
| 7 | DeepSeek Harness（`dsh` CLI，走 npm 国内镜像） |
| 8 | rootfs 瘦身（可选） |
| 9 | TDP 控制（SimpleDeckyTDP，插电 / 离电分档） |
| 10 | 换境内 NTP（解决开机白等 20 秒） |
| 11 | GPU 加速建议（DLSS / FSR / XeSS，按显卡提示） |
| 12 | **升级后自愈服务**（开机自动重建被升级冲掉的 `/etc` 配置） |
| 13 | wiliwili（B 站客户端，flatpak 用户级） |
| 14 | LocalSend（局域网传文件；**附带放行防火墙 53317**） |
| 15 | markdown 阅读器 glow（**单个静态二进制** → `~/.local/bin`；顺带注册 `.md` 双击打开） |
| 16 | Firefox Nightly（官方 `tar.xz` 解到 `/home`；**自带更新器能自更新**、扛原子升级） |

## 四、可选组件（`bash 可选组件安装.sh`，或菜单里的 `apps`）

菜单会带 ✓ 标出哪些已装。**新增一个可选项只改三处**（`install_xxx()` + 注册表 + case 分支）。

| 组件 | 做法 | 为什么这么做 |
|---|---|---|
| 微信 | 仓库包，没有就退到 AUR | SteamOS 缺 CJK 字体，会顺带补上 |
| Clash Verge Rev | 官方 **deb** 拆包 → `~/.local/opt/clash-verge`（**保留包内 `usr/` 结构**） | 上游**不发 AppImage**；直装 deb 会进 `/usr`、升级被冲。唯一会被冲的是 Tauri 的 `webkit2gtk-4.1`（在 `/usr`）→ 已接进自愈链自动补回 |
| 任意 deb 便携化 `install-deb-portable.sh` | 自己给 URL 或本地 `.deb` → 拆包 → `~/.local/opt/<名>` | 把上面那套特例**通用化**：图形引导选文件/链接与主程序，`--check` 升级后体检、`--remove` 卸载 |
| DeepSeek Harness 桌面版 | 官方 **AppImage** 解到 `/home` | deb 依赖 `libwebkit2gtk-4.1-0` 等一堆 SteamOS 没有的系统库 |
| WPS Office 中文版 | 官方 **deb** → `/opt/kingsoft` | 该 deb 自己声明 `Relocations: /opt/kingsoft`；**AUR 两版都把它重定位到 `/usr/lib`，2GB 进 5G rootfs 必炸** |
| 鸿蒙字体 HarmonyOS Sans | 官方 zip → `~/.local/share/fonts` + fontconfig 的 `conf.d/` | AUR 那套装进 `/usr/share/fonts`（rootfs，升级被冲）；官方直链带时间戳签名会过期，所以脚本不写死地址，改用 `HARMONY_ZIP` / `HARMONY_URL` |
| NextKde 桌面外壳（KOS） | 源码 clone 到 `~/.local/opt/NextKde`，然后交给**上游官方安装器** `tools/kosctl` 编译安装 | 它自带安装器，重写构建只会与上游脱节。⚠️ 三件事脚本会先讲明白再要你确认：编译依赖进 **rootfs**（升级被冲）、会**切换桌面外壳**（改 `plasmashellrc`，壁纸会重置）、KWin 插件与 KWin 版本耦合（脚本记录构建时版本，`--check` 能判定要不要重编）。**2026-09-25 用户已决定不装** |

> Firefox Nightly 已从可选项**提为必装步骤[16]**（见下一节）。

---

## 五、自检、打包与上游体检

```bash
bash steamos.sh                 # 交互菜单（所有命令都能从这里进）
bash doctor.sh                  # 一屏体检：这台机器现在健康吗？(只读, 不需要 root)
bash doctor.sh --net            # 再加联网的上游依赖体检
bash check.sh                   # 改任何脚本后必跑：语法 + 不变量断言(只读免 root)
bash steamos.sh selfcheck       # 入口自检：注册表↔文件一致 / 跑的是哪一份 / 快照新旧
bash verify-upstreams.sh        # 发布前/重装前跑：一次探完所有外部依赖是否还在
bash steamos.sh pack            # 打发布包：dist/steamos-toolbox-<版本>.tar.gz (+SHA256SUMS)
bash steamos.sh dist-verify     # 把发布包解到临时目录实跑一遍，验证它真的自包含
```

- **`steamos.sh`** 是统一入口：一张注册表派生菜单 / 清单 / 帮助 / 分发。
  每条命令标注性质 —— `只读`（不改任何东西）、`sudo`（会提权，要密码）、
  `交互`（需要你在终端前）。**stdin 不是终端时（管道/定时任务），后两类只打印该跑的命令，不会挂起。**
  它自己**不提权**、也不进 `sudoers`（用户可写的脚本不能放行提权），这条有断言钉死。
- **`doctor.sh`** 把散在各脚本里的健康检查串成一条：系统与空间 / 必装组件 / 升级后自愈链
  （服务·定时器·落点）/ 开发文件 / **免密链路** / 上游（`--net`）。
  只读、秒级、**无临时文件**，最后给一行结论 + 该跑哪条命令；退出码 `0`=全绿、`1`=有待处理。
  平时想确认"升级后自愈还在正常工作"就跑它。
- **提交前强制自检**：仓库自带 `hooks/pre-commit`（提交前跑 `check.sh`，不过就拒绝提交）。
  `core.hooksPath` 是**每个 clone 各自**的设置，所以新克隆要执行一次：
  ```bash
  git config core.hooksPath hooks     # 之后每次 git commit 都会先跑 check.sh
  ```
  没启用的话 `check.sh` 会明确告警（以前文档写着"钩子强制"，其实没装 —— 2026-09-25 发现并补上）。
- `check.sh` 会做 **shellcheck（warning 级 = 0）**、断言各步骤的落地物、断言
  「安装目标必须在 `/home` 或 `/opt`」这类容易被改错的不变量。
  > 想启用 shellcheck：放一个 `shellcheck(.exe)` 到 `tools/` 即可 —— 注意**必须是本机架构**的，
  > Windows 的 `.exe` 在 Linux 上执行不了（以前这会让这一节变成"恒绿"的假绿灯，已修）。
- `verify-upstreams.sh` 探 release API、下载地址、镜像、仓库包。
  它区分「下载路径」与「API 路径」—— 实测 `ghfast.top` / `ghproxy.net`
  **不代理 `api.github.com`**，只有 `gh-proxy.com` 两者都行。

---

## 六、诚实边界

- **只在 GPD Win5 + SteamOS 上实测过**。其它机型由 `/etc` 里的 `device_profile()`
  路由（AMD 掌机 / AMD 台式 / Intel 掌机 / N 卡机器），未逐台验证。
- 部分步骤需要联网；下载默认**镜像优先**（境内直连 GitHub 常不通）。
- 需要 root 的步骤会自己提权；`/etc` 只读的环境会先拦下确认。
- 脚本里的上游地址、版本号都是「外部事实」，**随时可能过期** —— 所以有了
  `verify-upstreams.sh`。发现哪个地址失效，欢迎提 issue。

## 七、目录说明

**入口（平时只用这两个）**

```
steamos.sh                统一入口: 菜单 / 子命令 / 自检 / 打包(表驱动, 只分发不复制逻辑)
steamos.desktop           它俩的双击入口(薄壳, 与 重装后先运行我.desktop 同款约束)
重装后先运行我.sh         重装当天的向导: 顺序跑完 16 步 → 再问要不要装可选组件
steamos-setup.sh          主脚本(唯一必需, 自包含; 步骤 1~16)
```

**其余按用途分**（`bash steamos.sh list` 能看到全部 44 条命令）

```
体检: doctor.sh · check.sh · verify-upstreams.sh · 诊断-开机慢.sh
诊断: diag-black-screen / diag-decky / diag-endfield / diag-gpd-inputs / diag-ip / diag-sudo-selfheal
修复: fix-inputplumber-cycle · fix-missing-dev-files · fix-opt-deps · fix-dsh-node-pty
      fix-endfield-qt · fix-workbuddy-wayland-ime · reset-endfield-sdk
安装: 可选组件安装.sh(菜单) · install-app-home.sh(单引擎) · install-deb-portable.sh(任意 deb)
      install-workbuddy-home.sh · install-harmony-sans-home.sh · install-nextkde-home.sh
      install-decky-loader.sh · install-decky-tdp.sh · install-ge-proton.sh · install-dwproton.sh
      setup-win5-backkeys.sh · free-rootfs.sh
维护: self-heal-after-upgrade.sh(开机自愈) · upgrade-workbuddy-aur.sh
      switch-compat-tool.py · set-steam-launchoptions.py · 20-gpd_win5.*.yaml
```

**文档与元数据**

```
VERSION                  版本号(与 CHANGELOG 最新条目一致, check.sh 有断言)
使用说明.txt             详细用法(完整版; 本文件是它的精简版)
SCRIPT-MAINTENANCE.md    维护手册: 每个坑的来龙去脉、改脚本前必读
CHANGELOG.md             版本记录
steamos-nix/             探路分支(已冻结, 主线不依赖; 详见下节)
```

## 八、关于 `steamos-nix/`（探路分支，已冻结）

这是 2026-09-15~16 做的**另一条技术路线的试验**：用 nix（`flake.nix` + `nix/lib.nix`）把整个用户态环境
搬进持久化的 `/nix/store`，想彻底躲过 SteamOS 的原子升级 —— 升级后只缺 `/etc` 那层符号链接，
`steamos-nix-activate` 离线秒级重建即可。

**后来没有采用**，原因说出来挺有意思：做 nix 的那次调查**自己产出了让它变得不必要的结论**。
调查发现 `/opt`、`/root`、`/srv`、`/nix` 同样 bind-mount 到 home 分区（就是本文件 §一 那张表；
当时还多写了 `/usr/local`——**2026-09-25 实测证明它属于 `/usr`，不扛升级**），
绝大部分东西本来就幸存。于是主线用「官方便携包 → `/home` 或 `/opt` + 入口放 `~/.local`
+ 必须写 `/etc` 的登记自愈」就达到了"升级后零操作"；而 nix 的代价一个都没少 ——
要先装 nix、每个包都得重写 nix 表达式、还要和 pacman **双包管理并存**。
**痛点被主线自己的发现消解了，nix 的收益消失大半，代价却还在。**

它不是"没做完的半成品"，而是一次**成功的探路**，产出已经被主线吸收：

| nix 分支的产出 | 主线怎么用 |
|---|---|
| "什么会被冲掉"那张分区表 | 本文件 **§一 核心思路** 就是从它提炼的 |
| 鸿蒙字体打包踩的坑（zip 目录带空格、`__MACOSX`/`._*` 苹果垃圾、SC/TC 分辨、fontconfig 只给 sans/serif 写 prefer 不动 monospace） | 做可选组件「鸿蒙字体」时**原样复用**，没有它就会再踩一遍 |
| WPS / 微信 / LocalSend 的打包方法、selftest 的写法 | 参考价值 |

**状态**：冻结，**主线从不调用它**（本仓库的主 README 以外，主线脚本与它零耦合）。
⚠️ 它 `scripts/` 下的脚本与主目录重复是**故意的** —— nix 的 `src` 是参与哈希的固定源树，
`steamos-tools` 会把每个 `.sh`/`.py` 装进自己的 `$out/bin`。**不要去重**，详见 `steamos-nix/README.md`。

## 九、许可

**GPL-3.0**（见 [LICENSE](LICENSE)）—— 2026-09-25 由 MIT 改为 GPL-3.0。

```
适配 GPD 的 SteamOS 脚本
Copyright (C) 2026 Yimuer

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
more details.
```

对使用者意味着什么：

- ✅ 自己用、自己改、自己跑 —— **没有任何义务**（GPL 的义务只在"分发"时才触发）
- ✅ 装 NextKde 这类 GPL 程序、或让本脚本去安装它们 —— 不影响本项目的许可
- ⚠️ 如果你**Fork 后改了再发布**，那份衍生作品**必须同样用 GPL-3.0 开源**，并保留署名
- ⚠️ 想**借用本项目的代码**去闭源发布 —— 不允许（这正是 GPL 与 MIT 的关键区别）
- ⚠️ 反过来：本项目**不会**被第三方 GPL 代码"传染"—— 因为本仓库不复制任何 GPL 源码，
  只是安装/调用它们（单纯聚合，不构成衍生作品）

---
