# 重装后修复脚本 · 注意事项

> 本文档记录「重装 SteamOS 后，脚本出问题需要改/修」时必须注意的点。
> 大部分是这台机器上踩过血泪坑后固化下来的结论，**改脚本前先读一遍，别把修好的东西改回坏的状态**。
>
> 维护对象：`steamos-setup.sh`（主脚本，唯一必需）＋ 一批备用/诊断脚本。
> 更新日期：2026-09-08

---

## 0. 先认清这台机器（最容易搞错的一步）

| 项 | 事实 | 千万别误判成 |
|---|---|---|
| 机型 | **GPD Win 5**（DMI: `GPD` / `G1618-05`） | 不是 Steam Deck |
| CPU | AMD Ryzen AI Max+ 395 w/ Radeon 8060S（Strix Halo） | — |
| 系统 | Valve **SteamOS (holo)** | 不是普通 Arch/CachyOS |
| 用户 | `deck`，家目录 `/home/deck` | — |
| 背键数量 | **只有 2 个**（L4/R4），2026-09-08 用户亲口确认 | 不要按 4 个去扩展守护进程 |

**关键推论**：SteamOS 会带来一堆 Deck 专属包（`jupiter`、`linux-neptune-618`、
`steam-jupiter-stable` 等），用户是 `deck`、有 `/home/deck` —— 这些**都不能**当作
"这是一台 Steam Deck" 的证据。`steamos-setup.sh` 的第 [4] 步（GPD Win5 背键）在这台
机器上是**合法且必需**的步骤，不要因为看到 `deck`/`jupiter` 就以为脚本写错了、去删它。

---

## 1. 脚本结构速览

### 1.1 主脚本 `steamos-setup.sh`（约 1976 行，自包含）

步骤与函数对应关系（改哪步找哪个函数）：

| 参数 | 函数 | 内容 |
|---|---|---|
| `0`（自动） | `prepare()` | 环境准备：sudo 提权、SteamOS 只读解除、pacman-key、补 core/extra 源、环境硬校验 |
| `1`/`cn` | `setup_cn()` | archlinuxcn 源 |
| `2`/`im` | `setup_im()` | **IBus 原生输入法** + 中文引擎（注意：**已不是 fcitx5**） |
| `3`/`wb` | `setup_wb()` | WorkBuddy（AUR 包） |
| `4`/`backkey` | `setup_backkey()` | GPD Win5 背键 + inputplumber（deck 手柄映射） |
| `5`/`decky` | `setup_decky()` | Decky Loader |
| `6`/`games` | `setup_games()` | GE-Proton + 鸣潮/终末地启动辅助 |
| `7`/`dsh` | `setup_dsh()` | DeepSeek Harness（npm CLI） |
| `8`/`clean` | `clean_rootfs()` | rootfs 瘦身（可选） |
| `9`/`tdp` | `setup_tdp()` | TDP 控制（SimpleDeckyTDP，插电/离电分档） |
| `10`/`ntp` | `setup_ntp()` | 换境内 NTP（加速开机，见第 2.7 节） |
| `11`/`gpu` | `setup_gpu()` | **GPU 加速建议**（DLSS/FSR，纯提示无落地，见第 3.1 节） |
| `12`/`selfheal` | `setup_selfheal()` | 升级后自愈服务（user 服务在 /home + sudoers 在 /etc） |
| `13`/`wiliwili` | `setup_wiliwili()` | B站客户端（flatpak `--user`，落 /home） |
| `14`/`localsend` | `setup_localsend()` | **LocalSend 局域网传文件**（官方 AppImage 解到 /home + 放行防火墙 53317） |
| `15`/`mdread` | `setup_mdread()` | **markdown 阅读器 glow**（单个静态二进制 → `~/.local/bin`，不占 rootfs；顺带注册 `.md` 双击打开） |

辅助函数：`url_reachable()`（下载探活）、`homedir()`、`state_*`（断点续传）、
`verify_step()`（落地复核）、`step_label()`、`map_step()`（参数→函数）、`show_status()`、
`adopt_state()`、**`detect_hw()`（统一设备/GPU 检测，见第 3.1 节）**。

### 1.2 其它文件

| 文件 | 定位 | 备注 |
|---|---|---|
| `20-gpd_win5.capmap.yaml` | **主脚本第 4 步的依赖**，自定义能力表（KB→QuickAccess） | 打包必须带上 |
| `20-gpd_win5.deck.yaml` | deck 目标覆盖配置的参考 | 主脚本运行时从 `50-gpd_win5.yaml` 派生，此文件供对照 |
| `install-decky-tdp.sh` | 单独装 TDP 插件（= 主脚本第 9 步） | |
| `setup-win5-backkeys.sh` | 单独配背键（= 主脚本第 4 步），**已内嵌守护进程源码** | |
| `fix-inputplumber-cycle.sh` | 修 systemd 依赖死循环（背键失效的头号元凶） | |
| `diag-gpd-inputs.sh` / `diag-ip.sh` | 输入链路诊断 | |
| `install-decky-loader.sh` / `install-ge-proton.sh` | 单独装 Decky / GE-Proton | |
| `fix-workbuddy-wayland-ime.sh` / `upgrade-workbuddy-aur.sh` | WorkBuddy 输入法修复 / 升级 | |
| `install-workbuddy-home.sh` | **WorkBuddy 迁入 /home（原生无沙箱 + 扛原子升级）** | `--check` 只读自检 / `--sandbox-off` 关命令沙箱；步骤[3]尾部自动调用 |
| `setup-fcitx5-flypy.sh` / `setup-steam-game-mode-ime.sh` | fcitx5 旧方案（已弃用，保留备选） | |
| `set-steam-launchoptions.py` | 写 Steam 启动选项（自动探测 userid） | 主脚本第 6 步会生成更完善的 `steam-launch-games.py` |
| `reset-endfield-sdk.sh` | **终末地黑屏的主修复手段**（清 SDK 本地状态），见 [6h] | 带健康检测 / `--dry-run` / `--force`，改名备份不删除 |
| `diag-black-screen.sh` | 黑屏取证（第 3.5 段是一键判据） | 只读，黑屏时**别关游戏**另开终端跑 |
| `install-dwproton.sh` | 装 DW-Proton —— **后备，本机不需要**（见 [6h]） | 默认 10.0-26；已修好续传 bug |
| `fix-endfield-qt.sh` | 补终末地 Qt WebEngine 运行时资源（见 [6d]） | 幂等，支持 `--dry-run` |
| `switch-compat-tool.py` | 切换 Steam 兼容层（须先彻底退出 Steam） | 支持 `--dry-run`；已修 `pgrep -f steam` 误判 |
| `可选组件安装.sh` | 必装主线之外的增强项菜单（带 ✓ 状态） | 扩展点见 1.3；非 pacman 项用 `MENU_CHECK` |
| `install-app-home.sh` | **单引擎**: `firefox-nightly` / `dsh-desktop` / `wps-office` 三个"下载便携包 → 装 /home 或 /opt"的安装器 | 骨架只写一遍, 各应用一段 profile; `--list` / `--check` / `--force` / `REFETCH=1` |
| `install-workbuddy-home.sh` | WorkBuddy 的 `/home` 自持化 | ⚠️ 不并入引擎: 它不下载产物, 而是让 AUR 装好的 `/opt/WorkBuddy` 在 /home 下自持 |
| `install-harmony-sans-home.sh` | 鸿蒙字体装成系统字体(装 `~/.local/share/fonts`, 扛升级) | 不用 AUR 包(rootfs); fontconfig 落 conf.d/ 不覆盖 fonts.conf |
| `install-nextkde-home.sh` | **NextKde(KOS 桌面外壳)装进 `/home`** | **包装上游 `tools/kosctl`, 不重写构建**; 前置检查 + 记录 KWin 版本(升级后判定插件要不要重编); 会切桌面外壳, 故有显式确认 |
| `verify-upstreams.sh` | **上游依赖体检（只读联网）** | 发布前/重装前跑；区分下载路径与 API 路径；见 §9.1 |
| `tools/shellcheck(.exe)` | 可选：放这就能让 `check.sh` 第 3 节生效 | 当前全脚本 warning = 0，别退回 |

### 1.3 可选组件安装器：新增一个可选项怎么做

`可选组件安装.sh` 是 menu-driven 的独立脚本（`sudo -E` 自提权，**不属** 15 步主线）。
新增条目**只改三处**，不要散落逻辑：

  1. 写 `install_xxx()` —— 逻辑重的话就 call 独立脚本（如 `install_firefox_nightly`
     薄封装 `install-app-home.sh firefox-nightly`），保持"一处实现"。
     若是"下载便携包 → 装 /home 或 /opt"这一类，**优先给 `install-app-home.sh` 加一段 profile**，
     而不是再写一个新脚本（加 profile 只需写"取源/解包/入口/桌面项/额外步骤"那几段）。
2. 注册表各加一行：`MENU_ORDER` / `MENU_NAME` / `MENU_PKGS`。
3. 菜单 `case` 分支加一行。

- **非 pacman 装的项**（如 firefox-nightly 是解包官方便携包到 `/home`）：
  `pkg_installed`（`pacman -Qq`）永远返回假 → 菜单的 ✓ 标记永远不亮。
  这类项额外在 **`MENU_CHECK`** 注册一个判据函数名，菜单会优先用它。
- 脚本以 root 跑，要摸用户目录的判据必须用文件顶部解析出的 `$REAL_HOME`
  （`SUDO_USER` → `getent passwd`），**不要写死 `/home/deck`**。
- 教训：写判据函数时别引用未定义变量（`set -u` 下会静默变空字符串 →
  `[ -x "/.local/..." ]` 恒假，菜单状态就永远不对）。

---

## 2. 铁律（改脚本时绝不可违反）

### 2.1 systemd 依赖绝不能成环 ⚠️ 头号坑

`gpd-win5-backkeys.service` 的 unit **绝不能同时写**：

```
After=multi-user.target
Before=inputplumber.service
WantedBy=multi-user.target
```

三者构成 ordering cycle，systemd 报 `Unable to break cycle` 后**直接丢弃 inputplumber
的启动任务**。症状极具迷惑性：

- 游戏模式手柄退回原始 **Xbox 360**，背键/Home/KB 全部失效；
- 桌面模式手动 `systemctl start inputplumber` 却一切正常。

**正确写法**（现脚本已是这样，别改回去）：

```
After=systemd-modules-load.service   # 只保证 uinput 模块就绪，sysinit 阶段，不成环
RequiresMountsFor=/home              # 守护进程在 /home，必须等 /home 挂载完
Before=inputplumber.service
```

排查入口：`journalctl -u inputplumber -b | grep -i "ordering cycle"`。
`--status` 也会自动查这条日志并告警。

### 2.2 写进度必须「退出码 + 落地复核」双通过

断点续传的进度记录在 `~/.cache/steamos-setup/state`。**光看退出码不够** —— 本脚本
历史上有"命令失败也打 `[✓]`"的毛病，会骗过进度判定、把失败步骤永久记成完成并跳过。

主循环里每步跑完必须再过一遍 `verify_step()`（检查文件/包/systemd unit 是否**真的在**），
两者都过才 `state_mark`。新增步骤时，`verify_step()` 里要补对应的落地判据。

**且「跳过前」同样必须 `verify_step()`**（2026-09-09 补，血泪坑，别退回去）：

旧逻辑是 `state_done` 只看进度文件有没有记录就跳过。但进度文件在 `/home`（升级幸存），
而落地物在 `/etc` `/usr` `/opt`（升级被整块替换）→ **升级后重跑脚本会全部误判为
"已完成"而一个都不恢复**。现在主循环改为：记过完成 → 先 `verify_step` →
过了才跳过，没过就打印 `[重建]` 并自动重跑。

**pacman 类步骤必须「数据库 + 关键文件」双判据**：
`/var/lib/pacman` 在 p7（独立分区，升级幸存），包文件在 `/usr`（p5，被换）。
两者会脱节 —— 数据库说"装了"但文件已被新镜像覆盖。故 `setup_im` 要查
`pacman -Qq ibus` **且** `[ -x /usr/bin/ibus-daemon ]`；`setup_wb` 同理查 `/usr/bin/workbuddy`。

### 2.3 主循环在顶层，不能用 `local`

`for fn in "${FUNCS[@]}"` 这段主循环在**顶层**，不是函数体。里面用 `local` 会直接报
`local: 只能在函数中使用`。主循环里的临时变量要直接用（如 `_sv`）。

### 2.4 `set -u` 下变量必须给初值

主脚本开了 `set -uo pipefail`。凡是 `local X` 后紧跟 `[ -z "$X" ]` 判断的，必须先给
初值 `local X=""`，否则系统没装对应命令时直接 `unbound variable` 崩掉。
已踩坑案例：`setup_dsh()` 里的 `NPM_BIN`/`NODE_BIN`（第 1699 行）。

### 2.5 下载要「探活 + 多镜像 + 直连垫底」

境内直连 GitHub 常"能连上但几乎不动"，curl 会一直耗到超时。所有 GitHub 下载必须：
- 先 `url_reachable()` 短超时探活（6s/12s），不通立刻换下一个镜像；
- 镜像数组里**直连 `""` 放在最后垫底**；
- 大文件用 `curl -C -` 续传。

改镜像数组时注意：`ghfast.top`/`gh-proxy.com`/`ghproxy.net` 这些代理会偶尔抽风，
别只留一个源。

### 2.6 大文件别下到 /tmp

SteamOS 的 `/tmp` 是 tmpfs（吃内存）。GE-Proton（约 500MB）、makepkg 的 BUILDDIR
（约 800MB deb）都要挪到 `/home/.cache` 下，否则会吃内存/OOM。

### 2.7 开机慢的头号元凶是 `atomupd` 等 NTP（不是我们脚本）

- SteamOS 开机慢，`systemd-analyze blame` 第一行几乎总是 `atomupd.service`（20s 级）。
- 根因：`atomupd`（原子更新守护）的 `ExecStartPre` 执行
  `timeout 20s systemd-time-wait-sync`，等系统时钟首次 NTP 同步才放行。默认
  `arch.pool.ntp.org` 境内延迟高（实测 400ms+），开机时同步不上就**白等 20 秒**。
- 症状：`journalctl -u atomupd -b` 里看到 `Exit without adjtimex synchronized.`（超时）。
- **修法**：把 NTP 换成境内服务器（`steamos-setup.sh 10` 已自动化），写 drop-in
  `/etc/systemd/timesyncd.conf.d/ntp.conf`（`NTP=ntp.aliyun.com ntp.tencent.com`）。
  系统更新不会覆盖 drop-in，比直接改 `/etc/systemd/timesyncd.conf` 稳。
- **别**去 `systemctl disable atomupd`（SteamOS 更新机制跟它耦合）或改
  `/usr/lib/systemd/system/atomupd.service`（系统更新会覆盖，改了白改）。
- 排障顺序：`systemd-analyze`（分段）→ `systemd-analyze blame`（揪慢服务）→
  `journalctl -u <慢服务> -b`（看卡在哪）。
- 背键 `gpd-win5-backkeys`、Decky `plugin_loader`、`inputplumber` 都是 ms 级，
  **不是**开机慢的来源（`Restart=always` 只要不反复失败就不拖慢）。

---

## 3. 各步骤的坑点备忘

### [2] 输入法 —— 已从 fcitx5 改成 IBus

- 当前方案是 **IBus 原生输入法**（`ibus` + `ibus-libpinyin`/`ibus-rime`/`ibus-pinyin`），
  走 KWin Wayland 原生前端。**不要**再往 fcitx5 上改回去（那是旧方案）。
- 打中文的真正根因是 **KWin 未配 InputMethod**（`kwinrc` 缺 `[Wayland] InputMethod=`），
  不是 WorkBuddy 本身的参数问题。
- `verify_step` 对 `setup_im` 的判据是 `ibus` 已装 **且** 三个中文引擎之一已装。

### [3] WorkBuddy —— rootfs 空间 + AUR + /home 自持化

- `/opt` 在 SteamOS 上是 bind mount 到 `/home` 分区（`/.steamos/offload/opt`），那 818M
  **不占 rootfs**；真正占 rootfs 的是 `/usr` 下的 electron（约 349M）+ 编译最小集（约 229M）。
- **原子升级后 WorkBuddy 的真实命运**（重要，别再当成"整个被冲掉"）：
  | 部件 | 位置 | 升级后 |
  |---|---|---|
  | 主体 `/opt/WorkBuddy` | `/opt` → offload 到 home 分区 | ✅ **幸存** |
  | 入口 `/usr/bin/workbuddy` | rootfs | ❌ 冲掉 |
  | 运行时 系统 `electron` | rootfs `/usr` | ❌ 冲掉 |
  | pacman 记录 | rootfs var | ❌ 冲掉（`pacman -Qq workbuddy` 判"没装"→ 会重装） |
  所以升级后的表象是"主体在、但没运行时没入口"，看起来像没了。
- **对策 = `install-workbuddy-home.sh`**（步骤[3]尾部自动调用）：把入口与运行时搬进
  `/home`，与 `/usr`/pacman 解耦 →
  `~/.local/opt/wb-electron/`（自带运行时）+ `~/.local/bin/workbuddy`（入口）+
  `~/.local/share/applications/workbuddy.desktop`（+ 图标一起搬，否则升级后图标也没）。
  升级后零操作即可启动；缺件时跑 `bash install-workbuddy-home.sh --check` 看报告。
- ⚠️ **别把 `/opt/WorkBuddy` 搬进 `/home`**：AUR PKGBUILD 在 `build()` 里
  `sed -i "s/process.resourcesPath/'\/opt\/WorkBuddy'/g"`，把 app 内的资源路径**硬编码**
  成了字面量 `/opt/WorkBuddy` —— 挪走必崩。而且 `/opt` 本来就在 home 分区，本就不用挪。
  同理 `/usr/local` 也是 offload 的，所以 `/usr/local/bin/workbuddy` 软链做命令行入口也持久。
- **沙箱**是 WorkBuddy 应用自身的设置（`~/.workbuddy/settings.json` 的 `sandbox.enabled`），
  与装在哪无关；`--sandbox-off` 可关。**Flatpak 版才会被 bubblewrap 关住**（碰不到 /etc、
  systemd），所以坚持用 AUR 原生版，不要换 Discover/flatpak。
- 空间预检是**自适应的**：只累加「未安装项 + 200M 缓冲」，不要改回"从零算 768M"的
  硬门槛 —— 那会在二次重跑时被误拦死循环。
- 编译用「最小集」`make gcc binutils pkgconf fakeroot debugedit`（约 229M），
  别改成整组 `base-devel`（约 600M，差 370M 很关键）。
- `electron` 是元包（体积显示 0.00K），真实体积在其依赖的具体 `electronX` 版本包。

### [4] 背键 + inputplumber —— 全链路

链路：物理键 → `hidraw15`(2F24:0137) → 守护进程 → uinput 键盘(F14/F15, event25)
→ inputplumber → `deck` 目标。

- **只有 2 个背键**：守护进程只解码 `byte9=0x69`(L4)、`byte10=0x6A`(R4) 是完整覆盖，别扩展。
- 背键 HID：`HID_ID=0003:00002F24:00000137`；`TARGET_VID=0x2F24` / `TARGET_PID=0x0137`。
- 映射：L4→F14(184)→LeftPaddle1，R4→F15(185)→RightPaddle1。
- uinput 虚拟设备能过 inputplumber 门禁，全靠 udev 规则 `70-gpd-backkeys.rules` 里
  `ENV{ID_BUS}="bluetooth"`（inputplumber 只放行"蓝牙虚拟设备"）。**别删这条规则**。
- 目标手柄是 `deck`（Steam Deck Controller），不是 `xbox-elite`（那会显示成 Xbox 360）。
- 自定义能力表 `gpd_win5_custom` 把 KB 键从「屏幕键盘」改成 QuickAccess（右侧边栏）。
- Home=[Meta+D]、KB=[Meta+Ctrl+O]，走 AT Translated Set 2 keyboard。
- **设备检测**：只有 DMI 是 GPD+Win5 **或** 存在 HID `2F24:0137` 才执行，否则记
  `skipped(非Win5)` 跳过 —— 这是为"换机型重装"设计的，别删掉检测逻辑。

### [5] Decky Loader

- 二进制在 `/home/homebrew`，`/etc` 只留小 unit。
- 下载跳过判据：`PluginLoader` 二进制在 **且** `.loader.version` 文件在才跳过下载
  （不能只看服务是否运行，否则会白白重复下 27MB）。

### [6] 游戏（鸣潮/终末地）—— 启动器黑屏 = WPF `AllowsTransparency` 透明窗口 bug（已解决）

**现象**：鸣潮启动器窗口"黑屏"——只见窗口四边框子、中间透出下层 Steam 界面、无标题栏、
无鼠标交互、无声音。桌面模式 + 游戏模式都一样。重装 SteamOS 后首次装鸣潮。

**根因（确定）**：鸣潮启动器 `launcher_main.exe` 是 **WPF（.NET）程序**，窗口用了
`AllowsTransparency=True`（透明窗口）。Wine/Proton 对 WPF 透明窗口支持有 bug，导致窗口
"透明"——内容画不出、透出下层，看起来就是黑屏。**与 GPU/驱动/Proton 版本/prefix 都无关**。

**修法（社区验证有效，Lutris 官方安装脚本同款思路）**：把启动器版本目录里的
`launcher_main.dll` 中 `AllowsTransparency` 字节串替换成无效值：

```bash
cd ~/Downloads/"Wuthering Waves"/<版本目录>/
cp launcher_main.dll launcher_main.dll.bak
# 用 python3 做二进制替换（不必装 bbe，bbe 在 SteamOS 缺 /lib/cpp 编译不过）
python3 -c '
d = open("launcher_main.dll.bak","rb").read()
old = b"\x12AllowsTransparency"
print("找到", d.count(old), "处")
open("launcher_main.dll","wb").write(d.replace(old, b"\x09IsEnabled\x1bA\x00\x03AAAAA"))
'
```

**已固化进脚本**：`steamos-setup.sh` 第 [6] 步新增 `patch_wuwa_launcher()`，自动探测
`Wuthering Waves/*/launcher_main.dll` 并 patch（幂等，不依赖 bbe）。五种返回值：
- `OK(n)` — 精确匹配到 `\x12AllowsTransparency`，本次替换 n 处，**自动备份 `.orig`**。
- `ALREADY` — 已修过（含新字节串），跳过。
- `AUTO(n,新串)` — 精确串没找到，但**宽松正则自动发现**了一个新的 `Transparen*` 字节串
  并自动 patch，**自动备份 `.orig`**（覆盖厂商改名/改拼写等绝大多数更新情况）。
- `AMBIG(...)` — 发现多个候选字节串，不敢乱改，打印候选列表让你人工挑。
- `MISSING` — 连 `Transparen*` 关键字都没了 → 启动器结构大改，需人工查社区。

**核心机制：三层自动兜底，每次改动都先备份 `.orig`**（可一键还原，所以敢自动）：

1. 精确匹配 `\x12AllowsTransparency`（首选，最安全）。
2. 若失效，宽松正则 `\x12[a-zA-Z]*Transparen[a-zA-Z]*` 自动发现新属性名
   （如 `IsTransparency` / `AllowTransparent`），唯一候选就自动 patch。
3. 多候选则 `AMBIG` 让你挑；彻底没 `Transparen` 才 `MISSING`。

**启动器更新后的正确流程（接近一劳永逸）**：

1. 大版本更新 → 启动器 dll 被还原 → 黑屏复发。
2. 跑 `bash steamos-setup.sh 6` → 脚本自动 patch（90% 是 `OK`，9% 是 `AUTO` 自动适配）。
3. **只有** 厂商把"透明窗口"机制彻底重构（`Transparen` 关键字都删了）才需要查社区，
   那属于极低概率，且社区必然炸锅，看 Lutris 脚本/ProtonDB/贴吧一眼就有新字节串。

**自动备份**：每次 patch 前把原 dll 备份为 `launcher_main.dll.orig`，猜错/想回退直接
`cp launcher_main.dll.orig launcher_main.dll` 即可。

**日常玩法建议**：平时用「本体直启」（Steam 加非 Steam 快捷方式指向
`Wuthering Waves Game/Wuthering Waves.exe`）玩，永不碰启动器、永不黑屏；只在**大版本
更新/需要登录**时开启动器（走 `launcher.exe` 那个快捷方式），此时才依赖本 patch。

**已排除的方向（别重复踩）**：显卡驱动正常；换 Proton 版本无效；改启动选项无效；
删 prefix 重建无效；WebView2 的 `--disable-gpu` 参数是帮倒忙（已从启动选项移除）。

**终末地注意**：终末地启动器是 **QtWebEngine**（`QtWebEngineProcess.exe`），不是 WPF，
黑屏修法不同，别套用本节的 dll patch。

### [6b] 终末地 —— "no Qt platform plugin could be initialized"（已解决，2026-09-09）

**现象**：鹰角启动器能正常打开，点「开始游戏」进入游戏后弹窗
`This application failed to start because no Qt platform plugin could be initialized.`

**根因（实测确定）**：
- 游戏目录 `~/Downloads/Hypergryph Launcher/games/Arknights Endfield/` **自带全套 Qt5 DLL**
  （Qt5Core/Qt5Gui/Qt5Quick/QCefView.dll…），但**整个目录树里没有 `qwindows.dll`**
  （全盘递归搜索为空）→ Qt 加载不到 windows 平台插件。
- 而启动器目录 `~/Downloads/Hypergryph Launcher/<版本>/plugins/platforms/qwindows.dll` 是有的。
- **两边同为 Qt 5.15.8**（`Qt5Core.dll` 仅差 136 字节，构建时间戳差异）→ 可安全直接复用。
- 两边都**没有 `qt.conf`**，靠"应用目录相对路径"解析插件，所以必须落在
  `<游戏目录>/plugins/platforms/`（脚本额外在 `<游戏目录>/platforms/` 放一份兜底）。

**修法**：`fix-endfield-qt.sh`（已并入步骤[6]，也可单独跑）
- 自动挑版本号最大的启动器目录作插件来源；
- 自动扫描 `games/` 下所有含 `Qt5Core.dll` 的目录，缺插件就补；
- 幂等（已存在则跳过），纯新增文件、不动任何原有游戏文件；
- 游戏更新后可能再次丢失 → 重跑 `bash fix-endfield-qt.sh` 即可。

**验证过**：复制后三处 `qwindows.dll` MD5 一致；`Endfield.exe`/`GameAssembly.dll` 时间戳未变。

**若仍报错**：说明不是缺文件而是插件加载失败，在 Steam 启动选项里加
`QT_QPA_PLATFORM_PLUGIN_PATH="Z:\home\deck\Downloads\Hypergryph Launcher\<版本>\plugins\platforms" %command%`。

**另一个独立风险**：游戏目录带 `AntiCheatExpert/`（ACE 反作弊），Proton 下可能另有拦截。
上述 Qt 报错与 ACE 是两回事，先解决 Qt 再看 ACE。

### [6c] 终末地 —— 点「开始游戏」后闪退 = ACE 反作弊，必须换 DW-Proton（2026-09-09）

**现象**：Qt 报错修好后，点开始游戏 → 窗口开一下立刻闪退（CrashSight 只记录到上报，无有用堆栈）。

**根因（社区一致结论）**：终末地自带 **AntiCheatExpert（ACE）**。
ACE 在 **GE-Proton / Proton-CachyOS / 官方 Proton** 下会直接让进程崩溃，典型日志：

```
wine: Call from 00006FFFFFBFD187 to unimplemented function
      ntoskrnl.exe.PsGetProcessExitStatus, aborting
```

**解法：换 DW-Proton**（Dawn Winery 维护，内建 ACE 等反作弊补丁）

- 发布页：https://dawn.wine/dawn-winery/dwproton/releases
- `11.0-7`："Hotfix release fixing launch issues with AK: Endfield"
- `11.0-9`：新增 AK:Endfield 专用 protonfix（缓解加载时大量写盘）
- `11.0-12`：2026-09-09 实测最新
- 安装脚本：`install-dwproton.sh`（自动取最新版 + SHA512 校验 + 修正 vdf 里的工具名）

**装完必做**：彻底退出 Steam 再重开 → 库里右键终末地 → 属性 → 兼容性 → 强制选择 dwproton。
若加载异常缓慢，启动选项加 `UMU_ID=umu-endfield %command%`（dwproton 官方说明）。

> 注意：这类 ACE 游戏的可用性完全依赖上游 Proton 分支，游戏或 ACE 一更新就可能再次失效，
> 届时需要升级 dwproton，不是本脚本能修的。

#### [6c-2] 换 dwproton 后仍闪退 = SDK 配置解析失败（2026-09-09 排查记录）

**现象**：dwproton-11.0-12 生效后（compat_log 确认 `Mapping AppID 2237343548 to dwproton`），
点开始游戏仍闪退。**GE-Proton 与 dwproton 的崩溃堆栈完全相同 → 与 Proton 分支无关**。

**证据链（Player.log + sdklogs，都在 compatdata/2237343548/pfx/.../LocalLow/Hypergryph/Endfield/）**：
1. Unity/Vulkan 初始化正常（RADV STRIX_HALO）—— 不是渲染/驱动问题；
2. `u8sdk_pc.log`：`ParseConfig → Parse config fail`、`appCode is null, try use appid :-1`、
   `SetGameVersion: INVALID_EXTRA_CONFIG1.5.3` —— 启动器传给游戏的 ExtraConfig 解析失败；
3. `Player.log`：`HGSpeedTest ReadWinConfig failed`（加密配置文件不存在）→
   `GetRegion()` 拿不到区域 → `Beyond.GameInitState._DoInit` 里
   `FormatException: Input string was not in a correct format` → `Crash!!!`；
4. `platfrom_process.log`：平台进程 100ms 内 `startProcess → client process exit` 反复循环；
5. 崩溃堆栈里 qt5webenginecore/qtuiframe —— 游戏进程内嵌 QtWebEngine(U8SDK UI 框架)，
   SDK 初始化阶段死掉。
6. 已排除：prefix 的 Geo（`Nation=45/CN`，已设）、ACE（这次没崩在 ntoskrnl）、
   Qt 平台插件（已在 [6b] 修）、启动器版本（1.5.0 就是官方最新）。

**社区情报（dawn.wine dwproton issue #3）**：
- 11+ 版本有回归报告（"runs and crashes without even creating a window"）；
- **10.0-26 被确认能玩**（"game runs fine on 10.0-26"），配合 llauncher；
- ntsync 可解另一类 AFK 崩溃（kernel ≥6.14；本机 neptune-72 内核**自带 ntsync.ko**，
  未加载，`sudo modprobe ntsync` 即可）。

**行动顺序**：
1. `bash install-dwproton.sh 10.0-26` 装实证版本 → Steam 兼容性改选 `dwproton-10.0-26`；
2. 不行再 `sudo modprobe ntsync` 后用 11.0-12 试（dwproton 检测到 /dev/ntsync 会自动启用）；
3. 仍不行：启动选项加 `PROTON_LOG=1 %command%` 抓 `~/steam-*.log` 再分析。

**重要提醒**：终末地的快捷方式是**鹰角启动器**（appid 2237343548），不是游戏本体——
兼容性设置改的是启动器，游戏是它的子进程（同一 prefix）。

#### [6c-3] ⚠️ 结论修正：dwproton 才是崩的那个，改用 GE-Proton11-6（2026-09-09 实测）

上一条 [6c] / [6c-2] 依据社区结论推荐 dwproton，**在本机被证伪**。分析
`~/steam-9609317368610160640.log`（dwproton-10.0-26 + `PROTON_LOG=1`）得到硬证据：

```
Modules: PE 100300000-10099a000  Deferred  ace-base.sys      ← ACE 内核驱动
         PE-Wine  6fffff7b0000-6fffff80e000  ntoskrnl
wine: Call from 00006FFFFFBFD187 to unimplemented function
      ntoskrnl.exe.PsGetProcessExitStatus, aborting
warn:seh:virtual_unwind backtrace: 000000010035C95C: L"ACE-BASE.sys" + 0x5C95C
进程 061c winedevice.exe 崩 → ACE 驱动起不来
→ 随后 PlatformProcess.exe 连续 4 次 0x80000003 断点崩 + UnityCrashHandler64.exe 被拉起
```

即：ACE-BASE.sys 在 wine 的 `winedevice.exe` 里加载，调用的 ntoskrnl 导出
`PsGetProcessExitStatus` 在该 wine 里是 **winebuild 的 unimplemented stub**
（特征字节 `48 83 ec 28 48 8d 0d`，一调用就 abort）。

**逐函数核对（解析 ntoskrnl.exe 导出表 + 反汇编入口字节，不是猜的）**：

| ntoskrnl 导出 | GE-Proton11-6 (wine-11.0 Staging) | dwproton-11.0-12 | dwproton-10.0-26 | Proton Experimental 11.0 |
|---|---|---|---|---|
| `PsGetProcessExitStatus` | **ok** | STUB（崩这儿） | STUB | STUB |
| `PsDereferencePrimaryToken` | **ok** | STUB | STUB | STUB |
| `PsGetProcessPeb` / `ImageFileName` / `SessionId` / `CreateTimeQuadPart` | **ok** | ok | ok | **STUB** |
| `PsReferencePrimaryToken`、`PsGetThreadProcess` | **ok** | ok | ok | **STUB** |
| `KeRegister/DeregisterBugCheckReasonCallback` | **ok** | ok | ok | **STUB** |
| `KeAcquire/ReleaseGuardedMutex` | **ok** | ok | ok | **MISSING** |
| `MmGetVirtualForPhysical` | **ok** | ok | ok | **STUB** |

（其余 200+ 个 ACE 用到的导出，四款全是 stub，属共同短板，不在崩溃路径上。）

**结论**：本机 **GE-Proton11-6 的 ACE 支持最好**（且它就是当前 GE 最新版，2026-08-28）；
Proton Experimental 反而最差。旁证：鸣潮（自带同一套 ACE-BASE.sys）一直跑在 GE-Proton11-6 上。

**正确做法**：Steam → 终末地属性 → 兼容性 → 选 **GE-Proton11-6**。
或用脚本（须先彻底退出 Steam，脚本会检测并拒绝）：
```
python3 ~/Downloads/steamos-reinstall-backup/switch-compat-tool.py --tool GE-Proton11-6-x86_64
```
另外：修好后把启动选项里的 `PROTON_LOG=1` 去掉（一次跑就写了 15MB 日志到 ~/）。

**教训**：排查 ACE/Wine 崩溃不要信"社区说哪款 Proton 能跑"，直接
① 在日志里搜 `unimplemented function`，② 解析该 Proton 的
`files/lib/wine/x86_64-windows/ntoskrnl.exe` 导出表看入口是不是 stub，两分钟出结论。

### [6d] 终末地 —— 换 GE-Proton11-6 后仍闪退：真凶是缺 Qt WebEngine 运行时资源（2026-09-09 定案）

**症状**：按 [6c-3] 换成 GE-Proton11-6 后，加载条走完仍然闪退。

**先纠正 [6c-3] 的一处错误**：事后解析 ACE 驱动的 PE 导入表确认，
`ACE-BASE.sys` / `ACE-CORE.sys`（含 sys2/sysa/sysa2 全部变体）的 ntoskrnl 导入里
**根本没有 `PsGetProcessExitStatus`**（243 / 140 / 118 / 156 / 133 个导入逐一核对，都没有；
`PsDereferencePrimaryToken`、`PsGetProcessPeb`、`MmGetSystemRoutineAddress` 也没有）。
所以日志里 `unimplemented function ntoskrnl.exe.PsGetProcessExitStatus` 的调用方
不是 ACE 驱动的静态导入 —— [6c-3] 那张"逐个导出比对"表的**推导前提不成立**
（结论方向仍可参考，但别当成铁证，更别再拿这张表去下判断）。

**真正的崩溃现场在游戏自己写的日志里**（比 15MB 的 Proton 日志有用得多）：

| 文件 | 关键内容 |
|---|---|
| `<prefix>/.../AppData/Local/Temp/Hypergryph/Endfield/Crashes/Crash_*/Player.log` | 栈：`qt5webenginecore → qt5webenginewidgets → qtuiframe → ucrtbase`；末尾 `FormatException: Input string was not in a correct format.` → `Crash!!!` |
| 同上（往前翻） | `PublicLoadExtraConfig returned null or empty json`；`[HGSpeedTest] ReadWinConfig() failed!` |
| `<prefix>/.../LocalLow/Hypergryph/Endfield/sdklogs/u8sdk_pc.log` | `U8SDKData::ParseConfig → Parse config fail`；`SetGameVersion:INVALID_EXTRA_CONFIG1.5.3`；`appCode is null, try use appid :-1` |
| 同上目录 `platfrom_process.log` | `WebViewSDKSetupGlobalConfig env: globalConfig:` **值为空**；`ICPServerAssist::startProcess` → `client process exit` → 又 start，**反复启停三次** |
| `<游戏目录>/debug.log` | 每次启动刷 4 行 `ERROR:icu_util.cc(251) Couldn't mmap icu data file` |

**链路**：游戏的内嵌网页（登录 / 公告）跑在 **Qt WebEngine（内嵌 Chromium）** 上，
它启动时要 mmap `icudtl.dat`，还要 `qtwebengine_resources*.pak`，这些放在 `<Qt 安装>/resources/`。
**游戏目录只有 DLL**（`Qt5WebEngineCore.dll` 114MB、`QtWebEngineProcess.exe`、`
PlatformProcess.exe`），**没有 `resources/`**；而启动器目录 `1.5.0/resources/` 是齐全的
→ 所以启动器能正常起来、游戏进程起不来。
Chromium 初始化失败 → PlatformProcess.exe 反复崩重启 → 全局配置传不出来 → `appCode` 为空
→ `GetRegion()` 拿到空串 → `int.Parse("")` → `FormatException` → Crash。

**修复**：`bash fix-endfield-qt.sh`（该脚本已从"只补 plugins"扩展为补齐
`plugins` / `resources` / `translations` / `res` 四项，幂等 + `--dry-run`）。
两边同为 Qt 5.15.8（`Qt5WebEngineCore.dll` 仅差 136 字节，是构建时间戳差异），资源可直接复用。
本次实测补齐：`resources/icudtl.dat` + 4 个 pak、`translations` 30 项、`res/config/app.data`。

**排查这类闪退的正确顺序**（省时间，别再走弯路）：
1. 先读**游戏自己写的日志**（上表三个路径），别一上来就加 `PROTON_LOG=1` 抓 15MB；
2. 看崩溃栈落在哪个模块再归因 —— 栈里是 `qt5webenginecore` 就不是反作弊的锅；
3. 拿"能跑的进程"（启动器）和"崩的进程"（游戏）的目录做文件清单对比，缺什么一目了然。
   本轮和上一轮的 `qwindows.dll`、以及鸣潮的 WPF 补丁，本质都是同一类病：**只发 DLL 不发运行时资源**。

### [6e] 终末地 —— 不再闪退，但「同意协议后黑屏、无声音」（2026-09-09）

**进展确认**：补完 Qt WebEngine 资源后，崩溃确实消失了。硬证据 —— 游戏目录下的
`<游戏>/debug.log` 在 18:17 最后一次写 `Couldn't mmap icu data file`，**18:31 那次运行再没写入**；
`u8core_ui_pc.log` 首次出现 `init QWebEngine` 成功；`platfrom_process.log` 不再反复启停。
⇒ [6d] 的修复是有效的，黑屏是**新问题**，不要回滚。

**当前卡点（已定位到具体文件）**：SDK 的账号配置从未落地。

- `U8SDK.dll` 里（**宽字符串**，必须 `strings -e l` 才看得到）硬编码了三个读取路径：
  `/U8Data/config/config.bin`、`/U8Data/config/config.gryph`、`/U8Data/config/u8ExtraConfig.bin`
- 全盘搜索：这三个文件**一个都不存在**，三个候选根目录
  （`LocalLow/Hypergryph/Endfield/U8Data`、`<游戏>/U8Data`、`LocalLow/Hypergryph/U8Data`）**全部缺失**。
- 后果链（与 [6d] 同一条链，只是这次没崩而是卡住）：
  `U8SDKData::ParseConfig` → `Parse config fail` → `appCode is null, try use appid :-1`
  → `PublicLoadExtraConfig returned null or empty json` → `GetRegion()` 空
  → `int.Parse("")` → `FormatException`（在 `Beyond.GameInitState._DoInit`）
  → 初始化中断 → **黑屏 + 无声音**（音频此刻还没起来，所以"没声音"是伴随症状，不是独立故障）。
- 相关：`games.log` 里 `clm user not login` 出现 23 次 —— **启动器层面账号未登录**。
  U8Data 那批配置只有在账号登录后才会由启动器/下载 SDK 落地（U8SDK.dll 里只有读取路径，没有写入逻辑）。

**另一个必须排除的可能：首次 shader/PSO 预热。**
`Player.log` 有 `HGPsoRecordManager::Init enablePsoWarmup:1` 且 `Vulkan PSO: cache data not found`，
`vulkan_pso_cache.bin` 只写了 2944 字节（≈空）。RADV 上首次编译 pipeline 可能要 5~15 分钟，
期间就是纯黑屏。日志里 `FormatException` 之后紧接着是 `Setting up 8 worker threads for Enlighten`
（Unity 光照系统起来），说明**进程并没有死**，它在继续初始化。

**怎么一眼区分这两种情况**：黑屏时 `bash diag-endfield.sh`（别关游戏），看进程 CPU——
- `Endfield.exe` CPU 高（几十%~上百%）= 在编译 shader/解压资源 → **耐心等 10 分钟**；
- CPU 接近 0 = 真卡在 SDK 初始化 → 走下面第 1 条（先登录账号）。

**处理顺序**
1. 先在**启动器**里登录账号（不是 Steam）。登录后启动器才会下发/落地 SDK 配置，再点开始游戏。
2. 想排除全屏/分辨率因素，可临时在启动选项加窗口化参数：
   `-screen-fullscreen 0 -screen-width 1280 -screen-height 720 %command%`
   （注册表 `HKCU\Software\Hypergryph\Endfield` 里记的是 1920x1080 全屏，本机屏幕也是 1920x1080，
   这项属于低概率，但成本为零。）
3. 仍黑屏 → 保持黑屏状态跑 `bash diag-endfield.sh`，把生成的 `~/endfield-diag-*.txt` 发出来。

**新工具**：`diag-endfield.sh` —— 只读取证，一次收集进程/CPU、窗口几何、U8Data 是否存在、
登录次数、Player.log（自动过滤 vulkan 噪音）、4 个 SDK 日志、debug.log、最近崩溃目录。

### [6f] 黑屏/无声音 = SDK extra config 拿不到 appCode（2026-09-09 定案）

> ⚠️ **本节的现象描述准确，但归因已被 [6h] 证伪。**
> 「缺 `U8Data/config/*.bin`」不是病因 —— 修好后这三个文件依然零命中。
> 真病因是 `sdkdata/` 里的空壳文件，解法见 [6h]。**别照本节挖 U8Data 了。**

**结论链（全部有日志实证，不是推测）**：

```
U8SDKData::ParseConfig fail            (u8sdk_pc.log:88)   ← U8Data/config/*.bin 从未生成
  → appCode is null, try use appid :-1  (u8sdk_pc.log)
  → PublicLoadExtraConfig returned null or empty json   (Player.log) ← [Critical]
  → Skip GlobalOptions.InitExtraConfig
  → [HGSpeedTest] ReadWinConfig() failed!
  → FormatException: Input string was not in a correct format.
      at Beyond.GameInitState+<_DoInit>d__5.MoveNext()
  → 初始化中断 → 黑屏 + 无音频（音频在更后面的状态才初始化）
```

**判定「黑屏但进程活着」的关键指标**（Player.log 尾部 Unity 退出时的内存统计）：

- `[ALLOC_GFX_MAIN] Peak Allocated memory` 只有 **81.1 KB** → 什么都没画，确认是初始化中断，
  **不是** shader 编译、也不是渲染问题（正常进游戏应是 MB 级）。
- 整个 `Player.log` **搜不到任何 audio 行** → 音频从未初始化，印证卡在 GameInitState。
- 进程 CPU 高（47s CPU / 38s wall）只是 Unity 空转渲染循环，不代表在编译 shader。

**已排除**（别再往这些方向查）：

| 嫌疑 | 结论 |
|---|---|
| ~~Proton 版本 / ACE 反作弊~~ | ⚠️ **此项已于 [6g] 推翻**：当时只凭"GE-Proton11-6 下 ACE 未报错"就排除，证据不足。社区共识是鹰角系游戏必须 DW-Proton，且"启动器半可用、游戏起不来"与本机症状一致 → **改回 DW-Proton** |
| Qt WebEngine 资源 | 已修好且生效：`debug.log` 18:17 后不再写 `Couldn't mmap icu data file` |
| 启动器未登录 | **已排除**：18:57:01 `OnLoginResult bSuccess:true`（游戏 18:57:03 才启动） |
| MachineGuid / DPAPI | 存在且合法 `a35c48ce-f7a0-4a69-a506-1bf2a1bd9949` |
| 代理 / 网络 | `game-config.hypergryph.com` 可达(HTTP 400/404 有响应)，Wine `ProxyEnable=0` |
| 分辨率 / 缩放 | 1920x1080，注册表也是 1920x1080 全屏 |

**关键事实（供下次直接引用）**：

- 启动器**知道**游戏的 appCode：`ReadGameConfig ... strAppCode:6LL0KJuqHBVz33WK,
  strChannel:1, strSubChannel:1, strRegion:cn, strGameVer:1.5.3`，且 `bGameConfigFileValid:true`。
  但**游戏进程**拿到的是 null —— 配置没从启动器传到游戏。
- U8SDK.dll 硬编码读取（**必须 `strings -e l` 宽字符**才搜得到）：
  `/U8Data/config/config.bin`、`config.gryph`、`u8ExtraConfig.bin`；
  hgsdk.dll/U8CoreUI.dll 另有 `sdk_hgsdk_config.bin|gryph`、`sdk_glsdk_config.bin|gryph`。
  全盘搜 `*.gryph` / `sdk_*config*.bin` **零命中**，三处候选根目录全缺失。
- `U8Data` **不在**下载索引 `Endfield_Data/Persistent/index_main.json` 里 → 不是装漏了，
  是运行时生成，而生成从未成功。
- extra config 疑似走远程下发：`global-metadata.dat` 里有
  `https://game-config.hypergryph.com/api/remote_config/v2/canary` 和 `_extra_config.json`。
- `WinConfigParser` 的解密流程（来自 IL2CPP 元数据）：
  `ExtractPublicKeyFromPem → VerifySignature → AES-CBC DecryptConfig`，
  报错 `ParseEncryptionFile() encrytion file not exist` —— 它在找的加密文件不存在
  （注意：元数据里**没有** `config.ini` 这个字符串，所以游戏找的不是游戏目录那个 256B 的 config.ini）。
- 游戏目录 `config.ini` 是 256 字节高熵数据（= RSA-2048 密文），**启动器**能读；
  `Player.log` 里 `WinConfigParser` 找不到文件 → 强烈怀疑**路径/CWD 解析问题**。

**下一步（按性价比排序）**：

0. **先换 DW-Proton（优先级已提到最高，见下面 [6g]）** —— 社区三处独立来源一致指出
   鹰角系游戏必须 DW-Proton，GE-Proton 的表现正是"启动器半可用、游戏起不来"。
   这一步成本最低、可逆，先做再做下面的。
1. 黑屏时跑 `bash ~/Downloads/steamos-reinstall-backup/diag-endfield.sh`，
   重点看新增的 **3b 段：Endfield.exe 的 cwd** 是否等于游戏目录。
   若 cwd 是启动器目录，就解释了为什么相对路径的加密配置文件读不到。
2. 启动器里「游戏设置 → 修复客户端 / 检查游戏完整性」。
3. 清 SDK 状态重来：删除 `LocalLow/Hypergryph/Endfield/` 下 `sdkdata/`、`sdk_data_*/` 后重开。
4. 若都不行 → 属上游（鹰角 SDK / 远程配置）问题，脚本层面无解，等官方修复或重装客户端。

### [6g] 换兼容层：GE-Proton11-6 → **DW-Proton**（2026-09-09，推翻 [6f] 里"Proton 无关"的判断）

> 🚫 **本节结论已被 [6h] 实机证伪，不要照做。**
> 终末地在 **GE-Proton11-6** 下已正常进入游戏。dwproton 不是必需的。
> 本节保留仅供溯源（记录当时为什么走了弯路）。**兼容层请保持 GE-Proton11-6。**

**为什么改主意**（已证明是错的，留作教训）：[6f] 里"Proton 版本无关"只凭"GE-Proton11-6 下 ACE 没报错"就排除，
证据太弱。查了社区三处**互相独立**的来源，结论一致且和我们症状严丝合缝：

| 来源 | 原话/要点 |
|---|---|
| rhea.dev《Installing Windows games on Linux — Arknights: Endfield》(2026-01) | "I usually run things through GE-Proton, however this is the rare case when that has disappointed me. While the game installed fine for me and **the launcher was semi functional, it wouldn't actually start the game**. So this time around, it's gonna be **dwproton**" |
| 巴哈姆特《關於如何在linux上游玩終末地》 | 装 **dwproton**（ProtonPlus 或手动放 `compatibilitytools.d/`）；并给出直启法：把 Target 改成 `{游戏路径}/games/EndField Game/Endfield.exe` |
| justalo.li《Linux 环境运行鹰角网络游戏方案》(2026-08) | 用 **DW-Proton 11.0-11**；并指出 Launcher.exe 有时需经容器内 cmd 间接启动 |

- 另一个旁证：**LLauncher**（社区原生 Linux 启动器，`github.com/AugustLigh/LLauncher`）
  内置"下载并管理 **DWProton**"，说明该圈子的默认答案就是 DW-Proton。
- 它的 `src-tauri/src/game/launcher/linux.rs` 还有两点可借鉴：
  `cd` 进游戏目录后再 `proton run Z:\...\Endfield.exe`（**印证 [6f] 的 CWD 嫌疑**），
  并默认加 `-vulkan` 走原生 Vulkan 渲染器。

**本机现状**：`compatibilitytools.d/` 里 **dwproton-10.0-26 和 dwproton-11.0-12 都已装好**
（含 `proton` + `toolmanifest.vdf`，完整），无需重新下载。当前 2237343548 用的是
`GE-Proton11-6-x86_64`。

**怎么换**（必须先彻底退出 Steam，否则 Steam 退出时会把 config.vdf 改回去）：

```bash
# 1) Steam 菜单 -> 退出（不是关窗口）
# 2)
python3 ~/Downloads/steamos-reinstall-backup/switch-compat-tool.py --tool dwproton-11.0-12-x86_64
# 3) 重开 Steam，直接启动游戏
```

- 换兼容层**不会重建 prefix**，游戏文件、下载进度、登录态都在。
- 想看会改什么：`--dry-run`；想回退：`--tool GE-Proton11-6-x86_64`。

**顺手修的脚本 bug**：`switch-compat-tool.py` 的 `steam_running()` 原来用 `pgrep -f steam`，
在 SteamOS 上会被 `steamos-manager` / `steamdeck.local` / `steamos-devkit-service` 命中，
**永远返回"Steam 正在运行"，脚本一次都用不了**。已改为只匹配
`steam.sh` / `steamrt64/steam` / `steamwebhelper` / `ubuntu12_32/steam`。

**若换完仍黑屏**（按序试）：

1. 直启游戏本体，绕开启动器（巴哈姆特指南验证过可行）：
   Steam → 添加非 Steam 游戏 → 浏览 → 选
   `/home/deck/Downloads/Hypergryph Launcher/games/Arknights Endfield/Endfield.exe`
   → 兼容层同样选 DW-Proton → 启动。
   （登录态在 `LocalLow/Hypergryph/Endfield/sdk_data_*/mmkv.default`，启动器已登录过，有机会直接进。）
2. cmd 间接启动法（justalo.li）：Target 改成容器内 `cmd.exe`，
   Launch Options 填 `/c start "" "C:\Program Files\Hypergryph Launcher\Launcher.exe"`。
3. 再回到 [6f] 的 2/3（修复客户端、清 sdkdata）。

### [6h] ✅ 终末地 & 鸣潮 全部跑通 —— 定案（2026-09-09 22:43 实机验证）

**最终可用配置（别再动了）**

| 项 | 值 |
|---|---|
| 兼容层 | **GE-Proton11-6**（不要再换 dwproton，理由见下） |
| 终末地 prefix | **2620397720**（旧笔记里的 2237343548 是错的，已更正） |
| 启动选项 | **空**，不需要任何特殊变量 |

**真正的修复动作只有一个：清空 SDK 本地状态**

```bash
bash ~/Downloads/steamos-reinstall-backup/reset-endfield-sdk.sh
# 然后：打开鹰角启动器 → 点「修复客户端」→ 再启动游戏
```

脚本把 `sdkdata/`、`sdk_data_*/`、旧日志**改名备份**（不是删），下次启动由启动器重新下发。

**修复前后的硬指标对照**（全部实测，不是推测）

| 指标 | 修复前 | 修复后 |
|---|---|---|
| `u8sdk_pc.log` 的 `SetGameVersion` | `INVALID_EXTRA_CONFIG1.5.3` | **`prod_obt1.5.3`** |
| `globalConfig` | 空串（len=156 无内容） | `{"env":"prod","region":"cn","channel":1,...}` |
| `ParseConfig` | `fail`（u8sdkdata.cpp:88） | `leave`（line 253，正常返回） |
| `Player.log` | `FormatException @ GameInitState._DoInit` | 无 |
| GFX 峰值内存 | 81.1 KB（什么都没画） | **334.1 MB** |
| `vulkan_pso_cache.bin` | 2944 字节（≈空） | 42 MB |

> **`SetGameVersion` 的前缀是最快判据**：`prod_*` = 健康，`INVALID_EXTRA_CONFIG*` = 坏。
> 已内置到 `diag-black-screen.sh` 第 3.5 段和 `reset-endfield-sdk.sh` 的自我保护里。

#### ⚠️ 两条已被证伪的旧结论（头号「往回改」陷阱）

**1. [6f] 的「缺 `U8Data/config/*.bin` 导致 ParseConfig 失败」—— 错的。**

修好后复查：`U8Data/config/config.bin`、`config.gryph`、`u8ExtraConfig.bin`
**依然全盘零命中**，而游戏正常进了。说明 U8Data 缺失是常态，不是病因。

真病因是 `sdkdata/`、`sdk_data_*/` 里躺着**从备份恢复过来的空壳文件**
（每个 4096 字节、内容全 0）—— `ParseConfig` 能读到文件，却解不出任何内容。
清掉让它重新生成即可。

**2. [6g] 的「鹰角系游戏必须换 DW-Proton」—— 错的。**

这是同一个问题的**第三次**反复（[6c] 换 dw → [6c-3] 换回 GE → [6g] 又换 dw）。
[6c-3] 早已用 **ntoskrnl 导出表逐函数核对**证明 GE-Proton11-6 的 ACE 支持最好，
[6g] 却仅凭社区帖子又改回 dwproton。实机证明 **GE-Proton11-6 才是正解**。

> **教训（写死在这，别再犯）**：社区结论只能当线索。本机判定兼容层的硬证据是
> ① 日志里搜 `unimplemented function`；② 解析该 Proton 的
> `files/lib/wine/x86_64-windows/ntoskrnl.exe` 导出表看入口是不是 stub。
> 两分钟出结论，比任何帖子都可靠。

dwproton（10.0-26 / 11.0-12）保留在 `compatibilitytools.d/` 里做后备，
**但不要主动切过去**。

#### 鸣潮：黑屏有声音 = 在编译 shader，等着就行

- 刚重装的系统 shader 缓存是空的，UE4 首次 PSO 编译十几分钟很正常。**别退，等着。**
- 判据：`bash diag-black-screen.sh` 第 2 段，主进程 CPU 高 = 在干活。
- 鸣潮 `Client.log` 是**加密的**（可打印字符 0%），grep 全是乱码 ——
  别在这文件上浪费时间，diag 脚本已自动识别并跳过。
- **已证伪**：不是 `SteamDeck=1`。本机进程环境里没有该变量，
  `DesiredScreenWidth=1280x720` 是 UE4 引擎自身默认值，不是 Deck 配置。
  所以**不要**加 `SteamDeck=0`。

#### 新增工具（本次会话产出）

| 脚本 | 用途 |
|---|---|
| `reset-endfield-sdk.sh` | 清 SDK 状态。带**健康检测**（SDK 已好就拒绝执行）、`--dry-run`、`--force`、跳过 `*.bak-*` 防套娃 |
| `diag-black-screen.sh` | 黑屏取证。第 3.5 段是本次总结的**一键判据**，另含 GPU/CPU/窗口/PSO 缓存/内存峰值 |

### [2b] 输入法输出繁体 = `trad-switch` 热键误触（2026-09-09）

**现象**：打字变繁体，而且会反复发生（"怎么又变繁体了"）。

**根因**：`ibus-libpinyin` 的 gschema 里有 `trad-switch`（简/繁切换），
**默认值是 `<Control><Shift>f`** —— 打字/快捷键组合时极易误触，且状态会被记住。

**解法**：`fix-ibus-simplified.sh`（以 deck 身份跑，不要 sudo）
1. 切到 `libpinyin` 智能拼音（老引擎 `ibus-pinyin` **没有 gschema**，锁不住设置）
2. `init-chinese=true` + `init-simplified-chinese=true`（强制简体）
3. **`trad-switch` 置空** → 彻底解绑热键，杜绝复发（这才是根治）

schema 路径：`/com/github/libpinyin/ibus-libpinyin/libpinyin/`

**附属经验**：沙箱/受限环境写脚本要注意两点 —— `$HOME` 可能 unbound（用 `${HOME:-}` 兜底）；
`mapfile < <(...)` 依赖 `/dev/fd`，没有时改用临时文件。

**Proton 版本建议**：社区推荐稳定版（Proton 9.0-x / GE-Proton 稳定版），
避免 Proton Experimental 太新导致兼容问题。

### [9] TDP —— 插电/离电分档

- 官方 QAM 性能面板**只对 Steam Deck 给 TDP 滑块**，GPD Win5 不在列表，必须靠
  Decky 插件 **SimpleDeckyTDP**（自带 ryzenadj，4W~120W）。
- 配置在 `~/homebrew/settings/SimpleDeckyTDP/settings.json`：
  - `advanced.acPowerProfiles = true`（打开 AC Profiles 开关）
  - `tdpProfiles["default"].tdp` = 离电档（默认 40W）
  - `tdpProfiles["default-ac-power"].tdp` = 插电档（默认 75W）
  - `enableTdpProfiles = false`（用全局 default）
- 可配置档位：`TDP_AC`（默认 75）/ `TDP_DC`（默认 40），`sudo bash steamos-setup.sh 9`。
- 写配置用 python `setdefault`（幂等，不覆盖用户已改的值）。
- 设备检测：仅 AMD/Intel APU；**AMD 桌面独显（非 APU）和 NVIDIA 独显都 `skipped`**（见第 3.1 节
  的 `detect_hw`）。`TDP_FORCE=1` 强跑。

### [11] GPU 建议 + 多机型兼容（DLSS/FSR）⚠️ 新增

**`detect_hw()` 统一检测设备**（脚本加载时执行一次，供 `--status` / `setup_gpu` / `setup_tdp` 用）：
- `GPU_VENDOR` = amd / nvidia / intel；`GPU_IS_APU` = 1(核显/APU) / 0(独显)；`IS_WIN5` = 是否 GPD Win5。
- **检测顺序必须是 NVIDIA → Intel → AMD**。AMD 正则只用 `advanced micro devices|\[amd|radeon`，
  **不能用 `ati`**——`ati` 会误命中 Intel 核显描述的 `"compatible"`/`"Integrated"` 里的 `"ati"`。
  （这是实测踩过的坑，Intel 核显一度被误判成 AMD。）
- Win5 判据：DMI(GPD + G1618-05/Win5) 或背键 HID `2F24:0137`。`setup_backkey` 内**另有一套**
  局部检测（`local IS_WIN5`，带 WIN5_FORCE 强制），与全局 `IS_WIN5` 不冲突、行为一致，别删。

**多机型兼容结论（2026-09-08 核实）**：

| 机型 | GPU | 官方 SteamOS | 脚本行为 |
|---|---|---|---|
| GPD Win5 | 8060S(RDNA3.5) | ✅ 已是 | 背键[4]+TDP[9] 全走 |
| 台式 9800X3D+7900XTX | RX 7900XTX(RDNA3) | ✅ SteamOS 3.8 支持 | 背键[4]跳过、TDP[9]跳过(独显非APU) |
| ITX iU+N卡 | NVIDIA | ❌ 不支持 | 引导走 Bazzite + DLSS 4.5 |
| 游戏本 iU+N卡 | NVIDIA | ❌ 不支持 | 引导走 Bazzite + DLSS 4.5 |
| Panther Lake 核显本 | Arc B3xx(Xe3) | ❌ 不支持(仅AMD) | 引导走 Bazzite + XeSS 硬件加速 |

**DLSS / FSR / XeSS 事实（别给错结论）**：
- **NVIDIA DLSS 4.5**（2026-01 CES 发布）：N 卡专属，Linux 靠 Proton + NVIDIA 驱动 +
  `dlss-updater`(3.3.0 起支持 Linux) 或 dxvk-nvapi preset override。RTX 40/50 系才有帧生成。
- **AMD FSR 4**：RDNA4 硬件专属(绑 FP8 AI 单元)；RDNA3(7900XTX)/RDNA3.5(8060S) 当前**不支持**，
  AMD 明确「FSR4 暂不计划支持 RDNA3.5 核显」；2026-07 起才把 FSR4 移植到 RDNA3/3.5(跑 INT8，
  画质/性能打折)，SteamOS 跟进时间未知。**别给 8060S 塞 PROTON_FSR4_UPGRADE 之类变量(无效)**。
- **Intel XeSS**：Xe3(Panther Lake, Arc B370/B380/B390 核显)有 XMX 硬件单元，XeSS/XeSS3/多帧
  生成是**硬件加速**，不是软件回退；老 Intel 核显/独显才可能回退软件模式。
  Linux 支持：kernel 6.18+/Mesa 25.3+ + 最新 linux-firmware(Intel GuC 固件)。
- **官方 SteamOS 不支持 N 卡**（Valve 官方硬约束，N 卡支持最早 2026 底/2027）。
  N 卡机器做"SteamOS 主机"只能走 **Bazzite**（社区 Fedora 游戏发行版，N 卡+DLSS 开箱即用，
  但包管理是 rpm-ostree，本脚本的 pacman 步骤不适用）。Panther Lake 核显本同理走 Bazzite。

### [10] NTP —— 换境内服务器加速开机

- 目的：解决 `atomupd` 开机等 NTP 校时最多 20 秒的慢（详见第 2.7 节）。
- 落点：drop-in `/etc/systemd/timesyncd.conf.d/ntp.conf`，内容
  `NTP=ntp.aliyun.com ntp.tencent.com` + `FallbackNTP=... time.cloud.tencent.com`。
- 可配置：`NTP_SERVERS='ntp.example.com'`（空格分隔，默认阿里+腾讯）。
- 幂等：`verify_step` 判据 = drop-in 存在 **且** 含 `aliyun|tencent`。已配则跳过。
- 还原：`sudo rm -f /etc/systemd/timesyncd.conf.d/ntp.conf && sudo systemctl restart systemd-timesyncd`。
- ⚠️ **事实修正（2026-09-09 实测）**：脚本原注释说"系统更新不会覆盖此 drop-in"是**错的**。
  SteamOS 3.8→3.9 原子升级把整个 `/etc` 都换了，连 `timesyncd.conf.d` drop-in 也没放过。
  所以 NTP 同样是"升级即丢"的一类，已纳入步骤[12]自愈覆盖范围。

### [12] 升级后自愈服务（self-heal，2026-09-09 新增）

- 背景：SteamOS 大版本升级（3.8→3.9）整块替换 rootfs 镜像，把脚本写进 `/etc` 的系统级
  修改（背键 unit/udev/inputplumber 配置/NTP drop-in/WorkBuddy wrapper）全部冲掉，
  只有 `/home` 里的东西幸存。用户只能事后发现。
- 方案：`setup_selfheal` 部署一个 **systemd user 服务**（`~/.config/systemd/user/steamos-self-heal.service`，
  放 `/home` 本身能扛升级）+ 自愈脚本 `~/.local/opt/steamos-self-heal/self-heal-after-upgrade.sh`。
  开机自动检测 6 个落点，缺哪个就用 `sudo -n` 调主脚本对应步骤（FORCE=1）重建。
- 检测落点 → 修复步骤：背键 unit/udev/inputplumber 覆盖配置/能力表 → 步骤4；
  境内 NTP → 步骤10；WorkBuddy IME → 步骤3。
- **关键设计**：自愈脚本零重复逻辑，完全复用主脚本的幂等安装（不做第二次实现，避免漂移）。
- **已知限制（写清楚，别指望它万能）**：sudoers 免密文件在 `/etc/sudoers.d/`（系统分区），
  升级也会被冲 → 升级后自愈服务第一次触发时 sudo 会失效，重建动作降级为"下次再试"。
  彻底恢复需重跑 `sudo bash steamos-setup.sh 12`（重装 sudoers）。这是无法绕过的硬约束
  （systemd 不认 /home 下的 sudoers）。可配 `sudo loginctl enable-linger deck` 让无头也跑。

---

## 3.9 SteamOS 大版本升级后怎么恢复（2026-09-09 定稿）

### 一句话答案

**重跑一条命令即可，但必须满足两个前提：有网、rootfs 有足够空间。**

```bash
cd ~/Downloads/steamos-reinstall-backup
sudo bash steamos-setup.sh --after-upgrade     # 等价 sudo bash steamos-setup.sh restore
```

**语义是「恢复」不是「装机」**：只补**曾经装过、现在被升级冲掉**的步骤。
state 里没记录的（从没装过的，比如 dsh）不会趁机新装 —— 否则一次"恢复"会冒出你
从来没要过的东西。**新装机请直接跑全量**（不带 `--after-upgrade`），
或加 `FORCE=1` 强制全跑。

### 为什么以前"重跑没用"（已修，别退回去）

进度文件在 `~/.cache/steamos-setup/state`（`/home` 分区，升级**幸存**），
而落地物在 `/etc` `/usr` `/opt`（升级被**整块替换**）。旧逻辑 `state_done` 只查进度文件
就跳过 → 升级后重跑会看到"全都已完成"→ **一个都不恢复**。

现在主循环改为**跳过前先 `verify_step()` 复核落地物**：还在才跳过，没了就打
`[重建]` 并自动重跑。同时新增 `detect_os_upgrade()` 比对 `VERSION_ID`，
版本变了会主动告诉你"检测到系统版本变化 X → Y，正在重建"。

### 升级后各步骤的真实命运（实测推演 + 判据核对）

| 步骤 | 落地物在哪 | 升级后 | 重跑行为 |
|---|---|---|---|
| `[1]` archlinuxcn 源 | `/etc/pacman.conf` | 被冲 | 🔧 重建 |
| `[2]` IBus 输入法 | pacman → `/usr` | 包没了 | 🔧 重装（占 rootfs ~146M） |
| `[3]` WorkBuddy | 主体 `/opt`（p8）+ 入口/运行时在 `/home`（自持化后） | ✅ 幸存 | ⏭ 跳过（自持化前会被冲，需 🔧 重装；见 1.x [3] 节） |
| `[4]` 背键 + inputplumber | `/etc` unit/udev/devices.d | 被冲 | 🔧 重建 |
| `[5]` Decky Loader | 主体 `/home`（幸存）+ `/etc` unit（被冲） | 部分 | 🔧 重建 unit |
| `[6]` 游戏 / Proton | `/home` | ✅ 幸存 | ⏭ 跳过 |
| `[7]` dsh | 2026-09-09 起装 `~/.local`（**✅ 幸存**）；旧的 `/usr/bin/dsh` 软链被冲 | 部分 | 🔧 仅当你**装过**才重建。新版会检测到 `~/.local/bin/dsh` 仍在 → 跳过重装，只补软链，**不会再吃 281M** |
| `[9]` TDP 插件 | `/home/homebrew/plugins` | ✅ 幸存 | ⏭ 跳过 |
| `[10]` 境内 NTP | `/etc/systemd/timesyncd.conf.d/` | 被冲 | 🔧 重建 |
| `[11]` GPU 建议 | 纯提示 | — | ⏭ 跳过 |
| `[12]` 自愈服务 | 服务在 `/home`，sudoers 在 `/etc` | 部分 | 🔧 重建 sudoers |
| `[13]` wiliwili | flatpak `--user` → `/home` | ✅ 幸存 | ⏭ 跳过 |
| `[14]` LocalSend | 程序在 `/home`（`~/.local/opt/localsend`）；**防火墙规则在 `/etc/firewalld`** | 部分 | 🔧 重建（`verify_step` 双判据会把"程序在但搜不到对端"识别为待重建；也挂进了自愈清单） |
| `[15]` glow | 二进制与 `.desktop` 都在 `/home`（`~/.local/bin` + `~/.local/share/applications`） | ✅ 幸存 | ⏭ 跳过（**选它就是因为它只依赖 glibc** —— 那些 GUI 阅读器要把 Qt/GTK 装进 rootfs，升级必被冲） |

**幸存不需要管的**：游戏本体、Proton（GE/DW）、Steam 前缀 `compatdata`、
Decky 插件与其配置、非 Steam 快捷方式、dconf 输入法配置、脚本进度文件。

### 两个硬前提（不满足就恢复不了，先解决它）

1. **网络**：pacman 重装需要联网下载。离线环境装不回 IBus / WorkBuddy / dsh。
2. **rootfs 空间**：新镜像通常比旧的更大，升级后 rootfs 往往更紧张。
   重装 IBus 等约需 200～300MB。低于 600MB 时 `restore` 会主动告警，先跑：
   ```bash
   sudo bash free-rootfs.sh --apply          # btrfs 元数据平衡 +334M，无损
   ```
   详见 **7.5 节**。

### 自愈服务 vs 手动重跑的关系

- 自愈服务（步骤[12]）只能补 **`/etc` 下的配置项**（背键 unit / udev / inputplumber / NTP），
  它**装不了 pacman 包**（那需要下载 + rootfs 空间，不适合开机静默做）。
- 且它依赖的 sudoers 文件本身也在 `/etc`，升级必被冲 → 升级后第一次触发会失效。
- **所以：大版本升级后，务必手动跑一次 `--after-upgrade`。** 自愈服务只负责日常小修小补。

### 健壮性验证清单（2026-09-09 已测）

| 项 | 结果 |
|---|---|
| 主循环四态判定（未装过 / 不适用 / 已完好 / 装过但缺失） | ✅ 四种分支行为均正确 |
| 升级恢复模式 vs 普通全量模式对照 | ✅ dsh 在前者跳过、后者执行 |
| `prepare` 未加 sudo 时 `exec sudo` 是否丢 `--after-upgrade` | ✅ 已修，改用 `ORIG_ARGS` 快照透传 |
| `set -u` 下空数组 `${ORIG_ARGS[@]}` 展开 | ✅ bash 5.3 安全（SteamOS 自带 5.x） |
| `__osversion` 内部键是否污染 `--status` 输出 | ✅ 被 `setup_*\|clean_rootfs` 过滤，未显示 |
| `setup_games` 只认 GE-Proton 导致 dwproton-only 机器误重建 | ✅ 已改为"任一兼容层目录"即达标 |
| restore 子集与全量列表漂移（曾漏 `setup_dsh`） | ✅ 已取消独立子集，直接走全量 |
| `bash -n` 语法校验 | ✅ 通过 |

**辅助脚本健壮性（2026-09-09 22:50 复测，20 个 .sh + 2 个 .py 全过 `bash -n`/`py_compile`）**

| 脚本 | 测出的缺陷 | 处置 |
|---|---|---|
| `reset-endfield-sdk.sh` | ① SDK 已修好后重复执行会清掉正常配置 | ✅ 加健康检测（`SetGameVersion` 前缀判定），默认拒绝，`--force` 才放行 |
| 同上 | ② 会把自己的备份再备份 → `.bak-xxx.bak-yyy` 套娃 | ✅ glob 跳过 `*.bak-*` |
| 同上 | ③ **非交互终端下 `read` 永久挂起**（P0，会让定时任务/管道调用死掉） | ✅ 加 `-t 0` 判断，非 TTY 直接报错退出；交互式也加 `-t 30` 超时；dry-run 只警告 |
| 同上 | ④ 进程检测排在健康检测之前，健康时也会先弹询问 | ✅ 调整顺序，健康直接 exit 0 |
| `diag-black-screen.sh` | ⑤ 终末地 prefix 硬编码 `2620397720` | ✅ 改为遍历 compatdata 自动探测 |
| 同上 | ⑥ 把加密的鸣潮 `Client.log` 整段贴出（25 行乱码噪音） | ✅ 自动检测可打印字符比例，<80% 判定二进制并跳过 |
| 同上 | ⑦ 二进制检测用了 `grep -P`，本机 grep 无 PCRE，**静默失效** | ✅ 改用 `LC_ALL=C tr -dc '[:print:]'`，POSIX 可靠（**教训：别用 grep -P**） |
| 同上 | ⑧ GPU 峰值内存用字符串排序 → `9.5 MB` 排在 `73.2 MB` 后，结果严重偏低 | ✅ 改 `awk` 归一到 MB 后 `sort -g`，实测从 73.2 MB 修正为 334.1 MB |
| `install-dwproton.sh` | ⑨ 下载用 `mktemp` 临时目录，`-C -` 续传形同虚设，268MB 包在 76% 被 HTTP/2 reset 后全废 | ✅ 改固定目录 `~/Downloads/dwproton-dl/` + `--http1.1` + 6 次重试续传 |
| 同上 | ⑩ 默认版本是 11.0-12，而上游说 >10.0-26 跑不起来 | ✅ 默认改为 10.0-26（注：本机最终不需要 dwproton，见 [6h]） |

---

## 3.10 通用套路：把应用改成「/home 自持」（2026-09-24 定案）

已用于 **WorkBuddy**（`install-workbuddy-home.sh`）与 **Firefox Nightly**
（`install-app-home.sh firefox-nightly`）。以后再有"某某应用一升级就没了"照这个来。

### 第一步：先分清哪些会被冲（别凭印象）

```bash
findmnt -no SOURCE --target /opt          # 与 / 的 SOURCE 不同 → 是 offload, 幸存
findmnt -no SOURCE --target /usr/local
```

| 位置 | 原子升级后 |
|---|---|
| `/home` | ✅ 幸存 |
| `/opt`、`/usr/local`、`/root`、`/srv` | ✅ **幸存**（bind-mount 到 `/home` 分区 `/home/.steamos/offload/*`） |
| `/etc` | ❌ 被冲（overlay，upper 在 `/var`） |
| `/usr`、`/var`、pacman 数据库 | ❌ 被冲 |

⚠️ **最常见的误判**：以为"装到 `/opt` 就没事"或"`/opt` 也会被冲"。两者都错 ——
要看的是它的**入口和运行时**在哪：`/usr/bin/<app>` + `/usr` 里的依赖照样会没，
所以表象常是"主体还在、但打不开"。

### 第二步：四条搬运原则

1. **程序本体** → `/home`。但**若上游把安装路径硬编码进程序内部**（WorkBuddy 的
   `process.resourcesPath` 被 PKGBUILD 改成字面量 `/opt/WorkBuddy`），就**别挪**——
   `/opt` 本来就幸存，留在原地风险最低。
2. **入口 wrapper** → `~/.local/bin/<app>`。**绝不写回 `/usr/bin`**（那正是会被冲的地方）。
3. **桌面项 + 图标** → `~/.local/share/{applications,icons}`。
   **图标一定要跟着搬** —— `/usr/share/icons` 在 rootfs 上，升级后图标会一起消失，
   菜单里只剩个没图的空壳。
4. **运行时依赖**（electron、自带的浏览器内核等）→ 也放 `~/.local`，
   不要依赖 `/usr` 里的 pacman 包。`:~/.local/bin` 若不在 PATH，桌面项写绝对路径即可；
   也可在 `/usr/local/bin` 放软链（该目录同样 offload，扛升级）。

### 第二步之二：选哪种发行物（deb / AppImage / 官方 tar）

**优先选"自带运行时"的那一种** —— SteamOS rootfs 上缺的库装起来既吃空间又会被升级冲掉。

判据：把 deb 的 `Depends` 拉出来看（`ar x` 解 deb → `control.tar.*` 里的 `control`），
里面每多一个 `libwebkit*` / `libgtk-*` / `libappindicator*` 这类大件，deb 方案就多一层
"要 pacman 装系统库 + 每次升级重装"的负担。

- 实例（2026-09-24）：`deepseek-harness-desktop` 的 deb `Depends: libappindicator3-1,
  libwebkit2gtk-4.1-0, libgtk-3-0` —— SteamOS 全没有；同版本 AppImage 90M 自带这些运行时
  → **选 AppImage**，解压到 `/home`。
- **第三种情况：deb 自己就认 `/opt`**。用 range 请求只取 deb 头部（`control.tar.*`
  排在 `data.tar.*` 前面，所以取前 3MB 就够）解出 `control`，看两行：
  `Relocations:` 与 `Installed-Size:`。WPS 的官方 deb 写的是 `Relocations: /opt/kingsoft`
  + 1.55GB → 按官方布局装到 `/opt` 最省事（`/opt` 是 home 分区的 bind mount）。
  **别学 AUR 把它重定位到 `/usr/lib`** —— 1.55GB 进 5G rootfs 必炸。
  顺手还能拿到权威的 `Depends`，比抄 AUR 手工维护的清单可靠。
- AppImage 落地方式：`chmod +x` 后先试**直接跑**（这样应用内自更新能替换它自己），
  同时 `./X.AppImage --appimage-extract` 留一份解压树；入口里判断 `libfuse.so.2`
  是否可用（`ldconfig -p`），不可用就走解压树 —— **完全不依赖 `fuse2` 这个系统包**。
  `--appimage-extract` 是 AppImage runtime 自带能力，不需要 FUSE。
- tar/xz 类（如 Firefox）：直接解压到 `/home`，注意大文件下载别用 `mktemp`。
- 通用禁忌：**不要为了装一个可选应用去 pacman 装一堆系统库** —— 那等于把这应用绑死在
  会被冲的 rootfs 上，前功尽弃。

### 第三步：脚本骨架（三个范例都是这套）

- 默认动作 = 安装/更新（幂等）；`--check` = 只读自检，**升级后先跑这个**；
- 版本（+语言/变体）没变就跳过重装，`--force` 兜底；
- 大文件下载：**固定缓存目录** + `-C -` 续传 + `--http1.1`（**别用 `mktemp`，续传会失效**）；
  多源择优、失败自动回退（本机实测：同一文件 `archive.mozilla.org` 比官方 cdn 快一两个数量级）；
- 原子替换 + 留一份 `.prev` 回滚位；替换前用 `pgrep` 确认进程没在跑；
- 以 root 跑时先解析 `REAL_USER`/`REAL_HOME`（`SUDO_USER` → `getent passwd`），
  **不要写死 `/home/deck`**；
- 判据不要引用未定义变量：`set -u` 下它静默变空串，`[ -x "/.local/..." ]` 恒假；
- `findmnt` 读不到时**别让两个空值相等就判过**（假阳性），要显式要求非空。

### 第四步：收尾三件事（缺一就容易烂掉）

1. 接进 `可选组件安装.sh`：`MENU_ORDER`/`MENU_NAME`/`MENU_PKGS` 三处 + `case` 分支；
   非 pacman 装的项还要在 `MENU_CHECK` 注册"是否已装"判据，否则菜单 ✓ 永远不亮。
2. `check.sh` 加断言 —— **必须断言"安装目标在 `/home` 下"**，否则将来有人改个路径就白做了。
3. README + 本文件登记（含 rootfs 回收口径的变化）。

---

## 4. 这台机器的物理事实（别再误判）

- **外置电池设计**：电池拆下时 `/sys/class/power_supply/` 只有 `ACAD`、没有 `BAT*`
  是**正常现象**，不是驱动问题。装回外置电池后才会出现 BAT*。
- 判断「离电」用 `ACAD/online`（1=插电，0=拔掉），不依赖电池设备。
- rootfs `/dev/nvme0n1p4` 只有 **5.0G**，长期紧张（剩余约 718M，btrfs unallocated 仅 1MiB）。
- `/opt` 和 `/home` offload 在 `/dev/nvme0n1p8`（918G，几乎全空）→ 大件往 /home、/opt 放。
- **禁删**：`/usr/lib/firmware`、`/usr/lib32`（Proton）、`/usr/lib/steam`、`noto-fonts-cjk`（中文）。
- 可回收候选：`firefox`(262M)、`plasma-workspace-wallpapers`(140M)。
- 安全启动已关闭；TDP 拖不动时给内核加 `iomem=relaxed`（SteamOS 用 systemd-boot）。

---

## 5. 修复脚本的标准流程

1. **先备份**：大改前 `cp -a steamos-setup.sh steamos-setup.sh.bak.$(date +%m%d-%H%M)`。
2. **改完必跑**：`bash -n steamos-setup.sh`（以及所有改动的 .sh）。
3. **Python/YAML 校验**：`python3 -m py_compile *.py`；yaml 用
   `python3 -c "import yaml; yaml.safe_load(open('xxx.yaml'))"`。
4. **沙箱里验证非破坏路径**：`--help`、`--status`、`--adopt`（只检测不安装）。
5. **真机回归**：系统级步骤（/etc 写、systemd、udev、下载安装）一律回真机 Konsole 用
   `sudo bash steamos-setup.sh N` 实测 —— WorkBuddy 会话是受限沙箱，**测不出真实结果**。
6. **验证断点续传**：跑完看 `--status` 的进度表；`FORCE=1` 验证强跑路径。

---

## 6. 打包 / 备份规范

- **必须带上的文件**（主脚本的硬依赖）：`steamos-setup.sh` + `20-gpd_win5.capmap.yaml`
  + `20-gpd_win5.deck.yaml`。缺了 capmap.yaml，主脚本第 4 步会走"从上游 gpd4 派生"的兜底。
- **排除**：所有 `*.bak.*`（历史备份）、`steamos-setup.sh.txt`（中间产物）、`.workbuddy/`（记忆目录）。
- 打包命令参考：
  ```bash
  tar -czf steamos-reinstall-backup-$(date +%Y%m%d-%H%M%S).tar.gz \
    --exclude='*.bak.*' --exclude='steamos-setup.sh.txt' --exclude='.workbuddy' \
    使用说明.txt SCRIPT-MAINTENANCE.md steamos-setup.sh *.yaml *.sh *.py
  ```
- 打包后**解压复验**：语法再过一遍 + 确认 capmap.yaml 在包内。

---

## 7. 容易犯的「往回改」清单（改脚本前自查）

- [ ] 有没有把 IBus 改回 fcitx5？（应保持 IBus）
- [ ] 有没有在 unit 里加回 `After=multi-user.target`？（会成环，禁）
- [ ] 有没有删掉 udev 规则里的 `ID_BUS=bluetooth`？（背键会失效）
- [ ] 有没有把目标手柄 `deck` 改回 `xbox-elite`？（会退回 Xbox 360）
- [ ] 有没有把「自适应空间预检」改回「768M 硬门槛」？（二次重跑死循环）
- [ ] 有没有把编译最小集改回整组 base-devel？（白多占 370M）
- [ ] 有没有删掉第 4 步的设备检测？（换机型会装错）
- [ ] 有没有重新引入硬编码 `/home/deck` 或 `/home/deck/下载/workbuddy`？（换机/换路径就废）
- [ ] 有没有破坏 `verify_step()` 的落地复核？（失败会被记成完成）
- [ ] 有没有把终末地的兼容层换成 dwproton？（应保持 **GE-Proton11-6**，见 [6h]）
- [ ] 有没有又去挖 `U8Data/config/*.bin`？（已证伪，它缺失是常态，见 [6h]）
- [ ] 有没有给鸣潮加 `SteamDeck=0`？（本机没有 `SteamDeck=1`，1280x720 是 UE4 默认值）
- [ ] 有没有删掉 `reset-endfield-sdk.sh` 的健康检测？（会让修好的机器被重复清空）
- [ ] 有没有在脚本里用 `grep -P`？（本机 grep 未编译 PCRE，会静默失效，改用 `tr -dc`）

---

## 7.5 rootfs 空间告急怎么办（2026-09-09 实测）

**rootfs 只有 5.0G（`/dev/nvme0n1p5`），官方 3.9 镜像本身就吃 ~4.2G，属于结构性紧张。**

### 别走弯路：以下常规清理对 rootfs 完全无效

| 常见招数 | 为什么无效 |
|---|---|
| `pacman -Scc` 清缓存 | `/var/cache/pacman` 已 offload 到 p8 |
| `journalctl --vacuum` 清日志 | `/var/log` 已 offload 到 p8 |
| 清 systemd coredump / docker / flatpak | 全在 p8 |
| 删 WorkBuddy | 它的 776M **全在 `/opt`**，也 offload 到 p8，删了不释放 rootfs |
| 删旧内核 | 只有 1 个内核（166M），无从删起 |

p8（918G）常年有 400G+ 空闲，**问题从来不在 p8，只在 p5 的 5G**。

### 🥇 新发现的最大单点：把 dsh 搬出 rootfs（2026-09-09）

`/usr/lib/node_modules/@deepseek-ai/dsh` 占 **281M**，而它：

- **没有任何 pacman 包拥有**（`pacman -Qo` 报错）→ 是 npm 全局装进去的；
- 是主脚本步骤 [7] `setup_dsh` 特意装到 `/usr` 的（注释写"与 pacman 的 nodejs 布局一致"）；
- 但 rootfs 只有 5G，**281M 相当于 5.6%**，属于明显的位置错配。

**搬到 `~/.local/lib/node_modules/` 后功能完全不变** —— `/usr/bin/dsh` 原本就是指向
`../lib/node_modules/@deepseek-ai/dsh/lib/bin.js` 的相对软链，重建为绝对路径即可，
rootfs 只剩一个几字节的软链。

`free-rootfs.sh --apply` 已内置该迁移（步骤 ⓪，默认执行），带回滚：软链重建失败会搬回去。

> ✅ **2026-09-09 已从根上修掉**（不再只是建议）：
> `setup_dsh()` 的安装命令由 `npm install -g --prefix /usr` 改为
> **`--prefix "$REAL_HOME/.local"`** —— 新装直接落在 /home(p8)，不再吃 rootfs，
> 且 SteamOS 原子升级后本体仍在（/home 幸存）。附带三点加固：
>
> 1. **不重复装**：若 `/usr/bin/dsh` 已存在且版本正确，只提示"建议跑 free-rootfs.sh 迁移"，
>    不会在 ~/.local 再装一份（否则两份 281M）。
> 2. **以 root 跑时** npm 落地的文件属主是 root → 补 `chown -R $REAL_USER`。
> 3. **补 `~/.local/bin/dsh` 软链**（幂等）。这条很关键：`/usr/bin/dsh` 不属任何 pacman 包，
>    **升级整块换 rootfs 后会被抹掉**；而 `~/.local/bin` 在 /home 存活，且 `~/.bashrc`
>    第 8 行已 source `~/.local/bin/env`（把该目录 prepend 进 PATH）→ 升级后 `dsh` 照样能用。
>    `free-rootfs.sh` 步骤⓪ 迁移成功后也会补这个软链。

### 真正有效的几招（见 `free-rootfs.sh`）

0. **迁移 dsh 到 /home**：281M，零功能损失（见上）。
1. **btrfs 元数据平衡**（零数据风险）：`Metadata,DUP` 分配 493M 但实占仅 191M，
   `btrfs balance start -musage=30/60/90 /` 可回收 **~300M**。
2. **删无依赖包**：`gcc` 212M（无任何包依赖）、孤儿包（asar/debugedit/fakeroot/pkgconf）。
  3. **删 firefox** 290M（无依赖。若已用 `install-app-home.sh firefox-nightly` 把
   Firefox Nightly 装进 `/home`，删掉**不损失浏览器**；否则会失去自带浏览器，需用户确认）。
4. ~~**zstd 重压缩**（高级）：rootfs 默认未启用压缩~~
   **❌ 2026-09-09 实测证伪，别再跑。** 抽样 `/usr` 下 10 个 >5M 的文件，
   **10/10 都带 `btrfs.compression="zstd"` xattr** → rootfs **早就全局启用 zstd 压缩**了
   （`findmnt` 挂载选项里看不到，要看文件 xattr：`getfattr -m btrfs.compression -d <file>`）。
   所以 `defrag -r -czstd:3 /usr` 收益接近 0，反而有实打实的风险：
   **defrag 会打断 reflink / 硬链接共享**，让多份副本各自独立占空间 → 空间可能不降反升。
   `free-rootfs.sh` 已内置检测：发现已压缩会自动跳过并说明。
5. **`--aggressive`**：精简 `/usr/share/locale`（294M → 约 40M，只留 zh_CN/en/C）
   + 删 `/usr/share/wallpapers`（86M）。

> **执行顺序**（2026-09-09 修订）：先 `sudo bash free-rootfs.sh --apply`，
> 之后**只在余量 <600M 时**才追加 `--aggressive`。`--compress` 已不必再跑（见第 4 条）。
>
> **2026-09-09 实测战绩**：246M(95%) → **997M(80%)**，释放 751M。构成：
> dsh 迁移 281M + 元数据平衡 ~300M + 孤儿包 + gcc。
> 到此 **80% 已比官方镜像（装完约 84%）还宽裕**，满足大版本升级的 600M 门槛 → 建议停手。
> `--aggressive` 的 ~320M 是删 pacman 包内文件换来的，**原子升级整块换 rootfs 后会被覆盖回去，
> 收益不持久**，且会让 `pacman -Qkk` 报文件缺失 —— 除非余量告急，否则不划算。

### 可删 vs 禁删（按实际落点核实过，不是猜的）

- ✅ 可删：`gcc`(182M)、`firefox`(290M)、`opencv`+`spectacle`(110M，失 KDE 截图)、孤儿包、
  `@deepseek-ai/dsh`(281M，**建议迁移而非删除**，见上)、`/usr/share/locale` 非中英文部分、
  `/usr/share/wallpapers`(86M)
- ⚠️ 谨慎：`/usr/share/icons`(339M)、`/usr/share/ibus`(146M)、`/usr/lib/guile`(48M)
  —— 收益有限且可能是桌面依赖，默认不动
- ⛔ 禁删：`steam-jupiter-stable`(408M)、`linux-firmware-neptune`(374M)、
  `noto-fonts-cjk`(298M，中文)、`linux-neptune-72`(146M)、`llvm-libs`/`lib32-llvm-libs`(游戏图形依赖)
- ⚠️ 删不得：`electron43`(332M) ← `electron` ← **workbuddy**。它在 `/usr` 占 rootfs，
  但删了 WorkBuddy 就起不来；`noto-fonts`(106M) 被 steam/plasma 依赖。

### 前置动作

清理前必须 `sudo steamos-readonly disable`（SteamOS rootfs 默认只读）。

---

## 8. 一句话总结

这台是 **GPD Win5 + SteamOS**，脚本已把背键映射、inputplumber 目标、TDP 分档、断点续传
全部调好并逐环实测过。改脚本最怕的是"把修好的坑改回去"——尤其 systemd 依赖成环、
输入法方案回退、硬编码路径这三类。**改前读第 2、7 节，改后必跑 `bash -n`，真机回归。**

---

## 9. 发布前审查（2026-09-24）与外部依赖体检

### 9.1 先跑这个：`verify-upstreams.sh`

所有外部地址都是"外部事实"，上游随时会变（改名 / 下线 / 加签名 / 换路径）。
**发布前、重装前、隔一段时间**各跑一次：

```bash
bash verify-upstreams.sh            # 全查(需联网)
bash verify-upstreams.sh --quick    # 跳过 archlinuxcn 大文件
```

它把本项目依赖的东西集中探一遍：各 repo 的 release API、**镜像前缀**、
每个应用的下载地址、AUR 包、archlinuxcn 包。退出码 0 = 关键项全通。

**两个设计要点（别改回去）**：
1. **区分"下载路径"与"API 路径"**。实测（2026-09-24）：`ghfast.top` 与 `ghproxy.net`
   **对 `api.github.com` 一律 403** —— 它们只代理下载路径。所以 API 镜像链里只能留
   `gh-proxy.com`，把前者列进去只会白等超时。
2. **GitHub 资源按脚本真实的"镜像优先"顺序判定**。本机（Windows 沙箱）直连 github.com
   不通是常态，若把"直连失败"当关键失败，工具在开发机上会天天误报。要按
   `gh-proxy → ghfast → ghproxy.net → 直连` 的顺序，命中即通过。

### 9.2 本次审查的三个实质发现（都已修）

| 发现 | 事实（实测） | 处置 |
|---|---|---|
| **WPS 取源过时** | 官方现行中文版 **12.1.2.28080**（545MB / 装后 2.07GB），且改成「`Linux2023` 通道 + 时间戳签名」`?t=<ts>&k=md5(key+uri+ts)`；老静态 URL 只剩 2022 年的 11.1.0 | 脚本改为按官方签名方案构造 URL，老通道降级兜底。新版本 control 仍是 `Relocations: /opt/kingsoft` → /opt 设计不变 |
| **AUR 两版 WPS 都进 rootfs** | `wps-office` 与 `wps-office-cn` 的 PKGBUILD 都 `sed /opt/kingsoft/wps-office → /usr/lib`，2GB 进 5G rootfs | 确认"官方 deb → /opt"是唯一可行解；`check.sh` 加了"代码里不得出现 `/usr/lib/office6`"断言（注释里提到不算） |
| **微信条目必然失败** | 下 archlinuxcn 的 db 逐项确认（4683 个包）**没有任何微信包** | `install_wechat` 增加 AUR 回退（yay/paru），并明确提示"这条路装进 /usr，升级会被冲" |

### 9.3 静态审查基线

- **`shellcheck -S warning` 对全部脚本 = 0 条**。装法：把 `shellcheck(.exe)` 放 `tools/`，
  `check.sh` 第 3 节会自动用它（并把范围从"只查主脚本"扩到全部）。
- 已修的**高危**项：`rm -rf "$VAR/..."` 在变量为空时会变成 `rm -rf "/"` ——
  `install-decky-tdp.sh` 卸载路径与 `install-ge-proton.sh` 的 `$TAG` 都中过，现已加 `${VAR:?}`。
  **新写 `rm -rf` 时如果路径拼了变量，一律加 `:?`。**
- 大文件下载**不要用 `mktemp`**：随机目录名会让 `-C -` 续传永久失效（仓库里踩过两次，
  `install-ge-proton.sh` 还额外把 509MB 下到了 tmpfs 的 `/tmp`）。用固定缓存目录。
- `find ... | xargs` 遇空格/换行文件名会拆错 → 用 `find ... -exec cmd {} +`。

### 9.4 有意留下的取舍：不做公共库

4 个 `install-*-home.sh` 之间有约 120 行/份的重复铺垫（颜色、提权、镜像、入口生成、
桌面项/图标搬运）。抽一个 `lib/` 能省约 480 行，但**会破坏"单个脚本能独立拷贝到新机器"
这一核心价值**（本包的设计前提就是"解压到 Downloads 就能跑，不依赖旧机器任何文件"）。
故选择保留重复，用**断言**来防漂移：新脚本的落地路径、判据、菜单挂接都有 `check.sh` 断言兜底。
若哪天决定改走公共库，先确认"单脚本可独立拷贝"不再是需求。

---

## 10. 架构现状与优化路线图（2026-09-25 全项目回顾）

### 10.1 现状量化（实测数字，不是印象）

| 项 | 数字 |
|---|---|
| 主脚本 `steamos-setup.sh` | **3029 行** |
| `steamos-nix/scripts/steamos-setup.sh` | 2660 行，与主脚本约 80% 相同 —— **但它是 nix 的固定源树，不能删**（见下） |
| `steamos-nix/scripts/` 下与主目录同名的脚本 | 17 个（整个 `steamos-nix/` 共 78 文件）—— **同上，属 nix derivation 的输入** |
| 4 个 `install-*-home.sh` | 各 441~489 行，共用同一套骨架（`info/ok/warn/err/sub`、`main`、`do_install`、`do_check`、`run_root` 各 4 份） |
| `archive/` | 两个历史版本存档（2625 + 1287 行）—— **有意保留** |
| `__pycache__` / `*.pyc` | 已被 `.gitignore` 挡住，仓库里 0 个 ✔ |

### 10.2 候选优化（按 收益/风险 排序）

| # | 做什么 | 收益 | 代价 / 风险 | 建议 |
|---|---|---|---|---|
| 1 | ~~把 `steamos-nix/` 整体迁到独立仓库~~ | — | — | **用户决定：不迁**（2026-09-25）。保留在原地，好处是探路产出（分区表、字体打包踩坑）留在同一个仓库里可随时对照 |
| 1b | 保留现状 + 写清它的定位与"别去重" | 零风险；读者知道它是什么 | 仓库体积不变 | **已做**（`steamos-nix/README.md` + 主 README §八 + 本文件 §10.3b） |
| 2 | ~~4 个 `install-*-home.sh` 合并为「单引擎 + profile」~~ | — | — | **已完成（2026-09-25 v3.5.0）**：新增 `install-app-home.sh`，覆盖 firefox / dsh / wps 三个；净减 719 行。⚠️ **workbuddy 刻意不并入**（它不下载产物，属另一物种），理由写在引擎头部 |
| 3 | **步骤表驱动**：一张 `STEPS` 表定义「函数名 / 编号 / 关键词 / 标题 / 落地判据」，让 `step_label`、`map_step`、`FUNCS`、help 全部由表派生 | 加一个步骤从**改 9 处**变成**改 1~2 处**，不会再漏接注册点（历史上 README 步骤列表、本节的步骤表都曾漏更新） | 动主脚本的核心分发逻辑；`verify_step` 是函数式判据，可能只能半自动化 | 收益高，风险中等 |
| 4 | ~~两份 README 归一~~ **已完成（2026-09-25）**：`README.txt` → `使用说明.txt`，顶部加一句"详细版用法，概览看 README.md"；README.md / 本文件 / 重装流程.md 的指向同步更新 | 消除"两份说明书"的漂移 | — | **结案** |
| 5 | 自愈清单 `CHECKS` 与步骤落地物是**两处重复的知识**（已有 `check.sh` 断言兜底） | 理论可派生 | 抽象成本大于收益 | **建议不做**，保持断言 |

### 10.3 已决定不做（记录理由，免得反复讨论）

- **不做 `lib/` 公共库**：会破坏"单脚本可独立拷贝"，见 §9.4。
  注意：若做了 #2 单引擎，就**不需要** `lib/` 了 —— 重复被彻底消除，这是更优的解法。
- **不硬拆主脚本**（3029 行）："唯一必需 + 自包含"是设计前提，拆开就得带一堆文件。
  要降复杂度请走 #3 表驱动，而不是拆文件。

### 10.3b 一个**纠正**：`steamos-nix/scripts/` 不是"可删的重复副本"

第一版路线图（10.2 的 #1）曾建议"删掉 17 个重复脚本 + 那份 2660 行副本"，**这个判断是错的**，已在动手前查证纠正：

`nix/lib.nix` 的 `steamos-tools` derivation 是这么写的：

```nix
# ── 1. steamos-tools: every .sh/.py in scripts/, deps injected ──
for f in "$src"/scripts/*.sh; do ... install -m 0755 "$f" "$out/bin/$b"
for f in "$src"/scripts/*.py; do ...
```

即 **nix 会把 `scripts/` 下每个脚本都装进它自己的 `$out/bin`**；而 nix 的 `src` 是**参与哈希的固定源树**
（可复现构建的前提），所以这条线必须自带一份"当时那一版"的脚本，不能指向主目录。

删任何一个都会连带影响：① `steamos-tools` 少部署对应工具；② `verify.sh`（它检查 `steamos-setup.sh` 等是否存在）；
③ `.selftest/static-audit.py`（直接读取 `scripts/steamos-setup.sh`）。

**教训**：看到"重复"先查清楚是不是哪条构建链的输入，再决定能不能删。
这条已写进 `steamos-nix/README.md`，防止以后再犯。

### 10.4 已处理的杂项

- `okww-readme.md`（147 行）—— 是**另一个项目**（ok-ww，鸣潮自动化程序）的 README 全文，
  从首个提交就在、无人引用、带着人家的 logo / badge / 链接。仓库公开后放这个不合适，
  **已删除**（可恢复：`git checkout 2ad0e9a -- okww-readme.md`）。
