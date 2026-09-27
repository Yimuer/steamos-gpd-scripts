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

### 1.1 主脚本 `steamos-setup.sh`（约 3700 行，自包含）

步骤与函数对应关系（改哪步找哪个函数）：

| 参数 | 函数 | 内容 |
|---|---|---|
| `0`（自动） | `prepare()` | 环境准备：sudo 提权、SteamOS 只读解除、pacman-key、补 core/extra 源、环境硬校验 |
| `1`/`cn` | `setup_cn()` | archlinuxcn 源 |
| `2`/`im` | `setup_im()` | **空函数（已禁用）** —— 按 2026-09-24 要求**不改动系统输入法**，避免与 KWin/IBus 打架；`check.sh` 有断言保证它保持为空（旧文档曾写成"IBus 原生输入法"，已纠正） |
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
| `16`/`firefox` | `setup_firefox()` | **Firefox Nightly**（官方 tar.xz 解到 /home，复用 `install-app-home.sh`；可自更新、扛原子升级） |

辅助函数：`url_reachable()`（下载探活）、`homedir()`、`state_*`（断点续传）、
`verify_step()`（落地复核）、`step_label()`、`map_step()`（参数→函数）、`show_status()`、
`adopt_state()`、**`detect_hw()`（统一设备/GPU 检测，见第 3.1 节）**。

### 1.2 其它文件

| 文件 | 定位 | 备注 |
|---|---|---|
| `steamos.sh` | **统一入口（唯一的人机接口）**：菜单 / 清单 / 帮助 / 分发 / 自检 / 打包 | **表驱动**：一张 `REG` 表派生一切；`check.sh` 断言"注册表 ↔ 文件"双向一致。它**不提权、不进 sudoers**。见 §1.5 |
| `steamos.desktop` | 上面的双击入口（薄壳） | 与 `重装后先运行我.desktop` 同款约束：不写 `TryExec`、`Terminal=true`、图标用 `utilities-terminal`（不新增图标依赖） |
| `20-gpd_win5.capmap.yaml` | **主脚本第 4 步的依赖**，自定义能力表（KB→QuickAccess） | 打包必须带上 |
| `20-gpd_win5.deck.yaml` | deck 目标覆盖配置的参考 | 主脚本运行时从 `50-gpd_win5.yaml` 派生，此文件供对照 |
| `install-decky-tdp.sh` | 单独装 TDP 插件（= 主脚本第 9 步） | |
| `setup-win5-backkeys.sh` | 单独配背键（= 主脚本第 4 步），**已内嵌守护进程源码** | |
| `fix-inputplumber-cycle.sh` | 修 systemd 依赖死循环（背键失效的头号元凶） | |
| `diag-gpd-inputs.sh` / `diag-ip.sh` | 输入链路诊断 | |
| `install-decky-loader.sh` / `install-ge-proton.sh` | 单独装 Decky / GE-Proton | |
| `fix-workbuddy-wayland-ime.sh` / `upgrade-workbuddy-aur.sh` | WorkBuddy 输入法修复 / 升级 | |
| `install-workbuddy-home.sh` | **WorkBuddy 迁入 /home（原生无沙箱 + 扛原子升级）** | `--check` 只读自检 / `--sandbox-off` 关命令沙箱；步骤[3]尾部自动调用 |
| `install-deb-portable.sh` | **任意 deb 包便携化：拆包搬进 /home（通用能力，2026-09-27）** | 可视化(kdialog)引导选文件/链接→选主程序；`--check` 升级后体检；`--remove` 卸载。菜单项 `deb-portable` |
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
| `fix-missing-dev-files.sh` | **补 SteamOS 镜像裁掉的开发文件**(头文件/cmake/pkgconfig) —— 编译类任务的前置 | 默认只抽三类开发文件(不碰运行时、不带 locale/doc); 版本不一致**拒绝**装(防部分升级); `--check`/`--apply`/`--dry-run`; 见 §12 |
| `fix-dsh-node-pty.sh` | **修 dsh 桌面版插件安装因 node-pty 编译失败而起不来** | 根因是 AppImage 注入 `PYTHONHOME` 毒害系统 python3（**不是缺 python**）; 解药 = 把产物放进 `prebuilds/linux-x64/` 让 node-gyp 永不参与; `--check` 只读体检; 见 §3.11 |
| `diag-sudo-selfheal.sh` | **自愈免密链路体检（只读，需 root）** | 查 sudoers 有没有 include、哪些文件被 sudo 忽略、规则里的路径是否失配、三条 NOPASSWD 在不在；判定方法见 §11.9 |
| `verify-upstreams.sh` | **上游依赖体检（只读联网）** | 发布前/重装前跑；区分下载路径与 API 路径；见 §9.1 |
| `tools/shellcheck(.exe)` | 可选：放这就能让 `check.sh` 第 3 节生效 | 当前全脚本 warning = 0，别退回 |

### 1.3 可选组件安装器：新增一个可选项怎么做

`可选组件安装.sh` 是 menu-driven 的独立脚本（`sudo -E` 自提权，**不属** 16 步主线）。
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

### 1.4 任意 deb 便携化（通用能力，`install-deb-portable.sh`）

Linux 软件多数只发 `.deb`，直装会进 `/usr` → 原子升级必被冲。这个脚本把**任意** deb
拆包搬进 `/home`，是 WPS / Clash Verge 那套套路的通用化：

```
deb → 取 data.tar.* → 整棵树(通常是 usr/) → ~/.local/opt/<名>
入口 ~/.local/bin/<名> + 桌面项/图标 → ~/.local/share/...
```

**三条硬约束（写进代码，也写进 check.sh 断言）**
1. **保留包内相对结构**：Electron/Tauri 的资源按可执行文件相对位置找，打散成 bin/ + lib/ 会起不来。
2. **判据看真二进制**（`--bin` 指定的路径必须存在），不看"目录在"。
3. **依赖体检不能假绿**：`ldd` 需要可执行位（解出来的文件先补 `+x`）；`ldd` 完全无输出时
   判 `UNKNOWN`（"无法判定"），**不能**报成"依赖齐全"。
   入口 wrapper 会自检这些库，缺了打印可复制的装回命令 —— 绝不"点了没反应"。

**主程序怎么定**：优先用包内 `.desktop` 的 `Exec=`；有多个可执行文件时弹出单选
（kdialog `--radiolist`，无图形时终端编号选择）；也可用 `--bin` 直接指定
（`usr/bin/foo` 与相对树根的 `bin/foo` 两种写法都接受）。

**已知边界**：依赖若在 `/usr`（如 Tauri 的 webkit2gtk），那部分升级仍会被冲 ——
脚本会写明、入口会自检、菜单文案会提示，`--check` 能体检；**没有**做成自动补回，
因为那需要在 sudoers 放行 `pacman`（提权面扩大，属安全取舍，交给用户决定）。

#### 案例：Clash Verge Rev（2026-09-27 新增，用户要求"千万不能被升级冲掉"）
上游 **不发 AppImage**（Linux 只有 deb/rpm），deb 直接装会进 `/usr` → 升级必被冲。
走 WPS 同款路子（拆 deb），但**落点选 /home**（WPS 是因为官方 Relocations 才必须 /opt）：
```
官方 deb → 拆出 data.tar.* → 整棵 usr/ 树搬进 ~/.local/opt/clash-verge/usr
入口 ~/.local/bin/clash-verge + 桌面项/图标 → ~/.local/share/...   （全部扛升级）
```
**两个关键点（踩过才知道）**
1. **必须保留 `usr/` 的相对结构**（`STAGE_REL="tree/usr"`）—— Tauri 的资源是按可执行文件
   相对位置找的，打散成 bin/ + lib/ 会起不来。已实测：拆完直接跑 `usr/bin/clash-verge` 正常。
2. **Tauri 需要 `webkit2gtk-4.1`（WebView），它在 `/usr`** —— 这是本组件**唯一**会被升级冲掉的部分
   （本机原缺；extra-3.9 快照源里有，36MB，版本与系统对齐不会造成部分升级）。
   对策三层：装的时候一并 `pacman -S`；**入口 wrapper 先自检这个 .so**，缺了直接打印可复制的
   装回命令（绝不"点了没反应"）；菜单文案里写明"升级后重跑本项补回"。
   > 没有做成"自动补回"：那需要在 sudoers 里放行 `pacman`（哪怕限定包名也是提权面扩大），
   > 属于安全取舍，要由用户决定，见 CHANGELOG 3.9.8 的待决项。
- 实测：`install-app-home.sh clash-verge` 一次跑通（98MB deb → 283M 落 /home），
  `--check` 就绪，入口自检按设计报缺库并给出命令。上游已加进 `verify-upstreams.sh`。

### 1.5 统一入口 `steamos.sh`（2026-09-27，v3.10.0）

**它解决什么**：30+ 个脚本按"干什么"命名（`doctor` / `diag-` / `fix-` / `install-`），
现场着急时最费时间的不是修，而是"我该跑哪个"。入口把这件事**收敛成一张表**。

**注册表 = 唯一事实来源**（菜单 / 清单 / 帮助 / 分发 / 自检全部由它派生）：

```
命令|文件|默认参数|模式|分组|说明
  · 文件写 `-` → 内建命令(由 steamos.sh 自己实现, 用于自检/打包/包校验)
  · 默认参数   → 自动补上, 用户给的参数追加在后
  · 模式       → ro=只读可无人值守 / root=会自己 sudo / ui=需要人在终端前
```

**新增一条命令只改一行**（在 `REG` 里加一行）。但真正省事的是**断言兜底**：
`check.sh` §2.16 会校验「注册表 ↔ 文件」双向一致 —— 加了脚本忘了登记、登记了但文件改名，
都会当场报红。这是这套设计的关键：**不靠人记得。**

**四条不能违反的设计约束**

1. **只分发，不复制逻辑**：判据/修复都留在原脚本里。入口里写第二份 = 迟早漂移。
2. **自己不提权**：需要 root 的转发给原脚本自己 `sudo`。入口是**用户可写**的，
   写进 `sudoers` 等于放行任意提权 —— `check.sh` 有两条断言钉死（不许出现提权调用 /
   不许被 `NOPASSWD` 引用）。
3. **非交互绝不挂起**：`stdin` 不是终端时，`ro` 项照跑（无人值守体检正需要），
   另外两档**只打印该执行的那条命令**并退 4。项目里踩过 `echo q | bash 可选组件安装.sh`
   永久挂住的坑，不能再让入口成为第二个。
4. **自包含**：不引 `lib/`，可单独拷走（铁律 1）。

**退出码约定**：透传被调脚本；入口自身 `2`=用法/未知命令、`3`=缺文件、`4`=非交互被拦。
（`4` 这一档在无人值守脚本里很好用：既不是"跑成功"，也不会挂住等密码。）

**打包与验证**：`steamos.sh pack` → `dist/steamos-toolbox-<版本>.tar.gz` + `SHA256SUMS`；
`steamos.sh dist-verify` 把它解到临时目录**实跑一遍**（关键文件在位 / 执行位完好 /
没混进版本库元数据与会话产物 / 包内 `selfcheck` 通过）。
> ⚠️ `dist-verify` 刻意**不跑完整 `check.sh`** —— 后者有若干断言依赖 git 台账
> （`git ls-files -s` 查执行位），在"没有 `.git` 的解包目录"里会**假红**。
> 发布包按"自包含"标准验，仓库按"台账"标准验，两者用途不同。
> 另：`tar --exclude` 的模式**不能带 `./` 前缀** —— GNU tar 的规则是"不含 `/` 的模式按基名
> 在任意层级匹配"。写成 `./.workbuddy` 只挡得住顶层，`steamos-nix/` 子目录里的会话产物
> 照样被打进包（这个 bug 就是 `dist-verify` 当场抓到的）。

**与 `重装后先运行我.sh` 的分工**：后者是**重装当天的一次性向导**（顺序跑完再问可选项）；
入口是**日常的万能钥匙**（体检/修复/装单个应用/打包）。两者都只是转发，不复制逻辑。

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

**查上游最新 tag 一律用公共函数 `gh_latest_tag()`**（已含镜像链与 API/下载路径的区别），
不要在脚本里另写一套 `curl api.github.com`：那既绕过了镜像，也会在 Windows 沙箱里被
证书吊销检查拦下（那种环境需 `--ssl-no-revoke`，**仅手工测试时加，脚本里不许写**）。

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
  ⚠️ **别把 `/usr/local` 当成"同类"**：它属于 `/usr`，**升级会被冲**（2026-09-25 实测纠正）。
  `install-workbuddy-home.sh` 因此是**运行时判断**的：`usrsrc_mount()` 拿到 `/usr/local` 的 SOURCE，
  是独立挂载才放软链，否则跳过并打印原因（`--check` 里能看到）。命令行入口的**正路**是
  `~/.local/bin/workbuddy`（`~/.local/bin` 本来就在 PATH 里）。
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
| `[16]` Firefox Nightly | 全部在 `/home`（`~/.local/opt/firefox-nightly` + 入口/桌面项/图标） | ✅ 幸存 | ⏭ 跳过（官方便携包，装 /home 后自带更新器） |

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
findmnt -no SOURCE --target /usr/local    # ⚠️ 实测与 / **相同** → 它属于 /usr, **不扛升级**
```

| 位置 | 原子升级后 |
|---|---|
| `/home` | ✅ 幸存 |
| `/opt`、`/root`、`/srv`、`/nix` | ✅ **幸存**（bind-mount 到 `/home` 分区 `/home/.steamos/offload/*`） |
| `/var/log`、`/var/tmp`、`/var/cache/pacman`、`/var/lib/{docker,flatpak,…}` | ✅ 也幸存（`var` 下的 offload，较反直觉） |
| `/etc` | ❌ 被冲（overlay，upper 在 `/var`） |
| `/usr`、**`/usr/local`**、`/var`、pacman 数据库 | ❌ 被冲 |

> ⚠️ **2026-09-25 纠正**：本表与 README 曾把 `/usr/local` 列为"幸存"，**是错的** ——
> 实测它是 `/usr` 的一部分（同一 btrfs 子卷），Valve 的 offload 目录里连 `usr/` 都没有。
> 这条错误一路抄进了 6 处文档（含 §13.4 的演进建议），教训：
> **"什么会被冲"这种话必须现查**（`findmnt -no SOURCE --target <路径>` 与 `/` 比），
> 别引用印象；Valve 的清单还会随版本变，所以脚本里该"运行时判断"
> （正面例子：`install-workbuddy-home.sh` 的 `usrsrc_mount()`）。

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
   若 `/usr/local` 是独立挂载(offload)才可在那放软链；**默认不是**（它属于 `/usr`，升级会被冲），
   所以正路是 `~/.local/bin`（本就在 PATH 里）。

### 第二步之二：选哪种发行物（deb / AppImage / 官方 tar）

**优先选"自带运行时"的那一种** —— SteamOS rootfs 上缺的库装起来既吃空间又会被升级冲掉。

判据：把 deb 的 `Depends` 拉出来看（`ar x` 解 deb → `control.tar.*` 里的 `control`），
里面每多一个 `libwebkit*` / `libgtk-*` / `libappindicator*` 这类大件，deb 方案就多一层
"要 pacman 装系统库 + 每次升级重装"的负担。

- 实例（2026-09-24）：`deepseek-harness-desktop` 的 deb `Depends: libappindicator3-1,
  libwebkit2gtk-4.1-0, libgtk-3-0` —— SteamOS 全没有；同版本 AppImage 90M 自带这些运行时
  → **选 AppImage**，解压到 `/home`。
  ⚠️ 该应用还带一个 `resources/version-recommend.json`（写它推荐的内核版本），而上游"已装就
  优先用已装"的逻辑可能让它去用比 `steamos-setup.sh` 顶部 `DSH_VER` 更旧的 dsh 核心 ——
  改 `DSH_VER` 前先想清楚（会连带影响插件兼容，见 §3 的 [3] 一节）。
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

## 3.11 AppImage 便携化的副作用：`PYTHONHOME` 毒害系统 python（2026-09-25 定案）

**症状**（dsh 桌面版 0.17.1 / dsh 0.1.5-rc.3）：插件安装反复失败、桌面版起不来

```
gyp ERR! configure error
gyp ERR! stack Error: Could not find any Python installation to use
[ELIFECYCLE] Command failed with exit code 1.
dsh: pnpm failed in profile directory /home/deck/.dsh/profiles/tauri
```

**别被错误信息骗了**：它**不是**"机器上没装 python"。本机 `/usr/bin/python3`(3.14.6) +
gcc + make 都齐，在普通 Konsole 里用 dsh 自带的 runtime node + 内置 node-gyp
编译 node-pty **一次就成功**（实测 exit 0）。

**真凶是 AppImage 运行时注入的环境变量**。dsh 桌面版是 AppImage，type-2 runtime
（`app/AppRun.wrapped`，二进制里就写着 `PYTHONHOME=%s/usr/`）会**无条件**给整条
进程树 putenv：

```
PYTHONHOME=/tmp/.mount_DeepseXXXX/usr/
PYTHONPATH=/tmp/.mount_DeepseXXXX/usr/share/pyshared/:
LD_LIBRARY_PATH=/tmp/.mount_DeepseXXXX/usr/lib/:...   （同理）
```

而那个 mount 目录里**没有 python 标准库**。于是 dsh 进程树里任何 `/usr/bin/python3`
一启动就：

```
Fatal Python error: Failed to import encodings module
ModuleNotFoundError: No module named 'encodings'
```

退出码 1、**stdout 为空** → node-gyp 探测到的路径是空串 → 报"找不到 Python"。
（因为这两个变量是 runtime 自己 `setenv` 的，**从外部 unset 无效** —— 除非不用
AppImage runtime 启动。）

**取证方法（只读，一眼定案）**：

```bash
PID=$(pgrep -f 'deepseek-harness-desktop$' | head -1)
tr '\0' '\n' < /proc/$PID/environ | grep -E 'PYTHON|LD_LIBRARY'
```

**解药（`fix-dsh-node-pty.sh`，三层，前两层是主力）**：

1. **把编译产物放进 `prebuilds/linux-x64/pty.node`** ← 关键。node-pty 官方**不发
   Linux 预编译包**（`prebuilds/` 里只有 darwin-* 和 win32-*），而它的 install 脚本是
   `node scripts/prebuild.js || node-gyp rebuild`。该目录一旦存在，`prebuild.js`
   直接 `exit 0`，**node-gyp 永不参与** → 以后 dsh 每次启动重跑安装都不再需要 python。
   ⚠️ 编译必须用 **dsh 自己的 runtime node**（`~/.local/share/dsh-tauri/runtime/bin/node`），
   否则 ABI（22.x vs 系统 26.x）对不上，dsh 加载时会崩。
2. **放 `~/.local/bin/python3` 包装器**兜底（万一 prebuilds 被冲、必须现场编译）。
   它清掉"指向不存在的 Python 安装"的 `PYTHONHOME/PYTHONPATH`。
   ⚠️ **坑**：node-gyp 会把探测到的**绝对路径**记下来，之后直接 `exec` 它、不再走
   PATH —— 若包装器回答 `/usr/bin/python3` 就被绕过（实测确认）。所以包装器必须对
   "探测 `sys.executable`"那条命令回答**自身路径**。node-gyp 12 的探测串是
   `sys.stdout.buffer.write(sys.executable.encode('utf-8'))`，11 是 `print(sys.executable)`，
   按"`-c` + 参数里含 `sys.executable`"匹配才两个版本都覆盖。
3. 放行 pnpm v11 的构建脚本拦截（`allowBuilds.node-pty`，见下）。

**顺带纠正一条旧认知**：pnpm v11 的 `.npmrc` 已不读 `onlyBuiltDependencies` 这类设置，
只能写 `pnpm-workspace.yaml` 或全局 `~/.config/pnpm/config.yaml`；键名是 `allowBuilds`。
dsh 自己会往 profile 的 `pnpm-workspace.yaml` 里写 `allowBuilds`，所以那层通常已经过了 ——
**如果日志里已经不再出现 `[ERR_PNPM_IGNORED_BUILDS]`、只剩 gyp 的 python 报错，说明
卡的就是本文这条，别再往 pnpm 配置上找。**

**复发条件**：插件大版本更新会重建 `node_modules` → `prebuilds/linux-x64` 丢失 → 复发。
所以病根没除、只是被绕开；**dsh 大版本升级后跑一次 `bash fix-dsh-node-pty.sh --check`
即可（只读、秒级）**。

**同类风险提醒**：凡是"AppImage 启动的进程里要调用系统 python/node 工具链"的场景，
都可能踩同一个坑（`PYTHONHOME`/`LD_LIBRARY_PATH` 污染）。判断口诀：
**普通终端里能跑、AppImage 里跑不了 → 先查 `/proc/<pid>/environ`。**

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

### 9.5 pre-commit 钩子：文档说"强制"，就得真装（2026-09-25 发现并补上）
`hooks/pre-commit` 一直躺在仓库里（提交前跑 `check.sh`，不过即拒绝提交），但 **`.git/hooks/pre-commit` 并不存在** ——
git 不跟踪 `.git/hooks`，所以每个 clone 都必须自己启用一次：
```bash
git config core.hooksPath hooks    # 指向受版本控制的 hooks/ 目录, 最省事且不会漂移
```
- `check.sh` 第 4 节会检查它是否生效，并打印这条命令（不判失败：全新 clone 没配也正常）。
- 教训同类：**"文档声称的机制"必须有一条能失败的判据去核**（本项目已经栽过 6 次：假绿灯 5 + 这条"写着没装"）。

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
| 6 | **统一入口 `steamos.sh`：一张注册表派生菜单/清单/帮助/分发** | 消除"该跑哪个"的查找成本；加脚本只改一行 | — | **已完成（2026-09-27 v3.10.0）**，见 §1.5。可被断言校验（注册表↔文件双向一致） |
| 3（续） | **主脚本步骤表驱动**（把 #3 落到 `steamos-setup.sh` 内部） | 加一个步骤从"改 9 处"变成"改 1~2 处" | 动主脚本核心分发逻辑；`verify_step` 是函数式判据，可能只能半自动化 | **仍开放**。#6 证明了"表驱动 + 断言兜底"这条路可行，可照此推进 |

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

## 11. 2026-09-25 全量重装实测复盘（GPD Win5 真机跑 15 步 + 可选组件）

当天新装一遍，日志里蹦出 6 条 `[!]`/`[✗]`。逐条查完的结论：**3 条是真故障（已修），
3 条是判据/输出误导（已修，属于"假故障"）**。以后看到同类输出别再重新排查一遍。

### 11.1 假故障①：AUR 构建里一屏 `asar extract ENOENT` —— 无害，别慌
现象：构建 workbuddy 时刷出 15 行 `Unable to extract some files: ENOENT ... arm64-darwin/rg`、
`better-sqlite3/build/Release/better_sqlite3.node` 等，随后 `Node.js v26.5.0` 退出，但
makepkg 照样把包建完、装上去了（装完 766MiB）。
**真相**：`app.asar` 的头表里把跨平台条目标成 `unpacked`，而网易/腾讯发的 deb **只带
x64-linux 那套**，其余平台本来就不存在。asar 一边报 ENOENT 一边 exit 1，PKGBUILD 容错继续。
**怎么判"主体是不是真的完好"**（比看日志靠谱）：看这几个实体在不在 ——
```bash
ls /opt/WorkBuddy/app.asar.unpacked/cli/vendor/ripgrep/x64-linux/rg     # 有
find /opt/WorkBuddy -name 'better_sqlite3.node' -o -name '*.node' | head # prebuilds/linux-x64.node
```
本机实测全在，且 `ps` 里 WorkBuddy 跑的就是 `electron /opt/WorkBuddy/app.asar.unpacked`。
**⚠️ 注意本体布局**：AUR 版把 app.asar **解成目录**用，所以 `/opt/WorkBuddy/` 下**只有
`app.asar.unpacked/`**，没有 `app.asar`。看着"少东西"是正常的（wrapper 直接吃这个目录）。

### 11.2 真故障①：`/usr/include` 被镜像裁掉 → 所有"要编译 C"的 AUR 包必挂
现象：`paru -S wechat-universal-bwrap` 死在
`make: *** [Makefile:9：libuosdevicea.so.unstripped] 错误 1`，往上翻是
`fatal error: string.h：没有那个文件或目录`。
**定性**：`/usr/include` 只剩 18 个条目，glibc 文件清单上 **510 个头文件实体一个不剩**；
`pacman -Q glibc` 却说"已装" → **只装 gcc/make 补不回来**。
修：`ensure_c_headers()`（步骤[3] 工具链之后调用）——
```bash
_sv="$(pacman -Sp --print-format '%v' glibc | head -1)"   # pacman 真会装的那个仓库版本
[ "$(pacman -Q glibc|awk '{print $2}')" = "$_sv" ] && pacman -S --noconfirm glibc linux-api-headers
```
- **必须同版本**：快照源 `core-3.9` 的 glibc = 本机 2.43+r37（已装同版，重装零风险）；
  滚动源 `core` 已经是 **2.44** —— 顺手装了就是把 libc 顶到比系统新，部分升级有炸机风险。
  所以脚本先比版本，不一致就**只警告不动手**。
- **验证过**（不是猜的）：把同版本 glibc 的 `usr/include` 解出来，`gcc -isystem ... -fPIC -shared
  libuosdevicea.c` → `rc=0`，产出正常 ELF。所以 WeChat 那条路只剩"重装头文件"这一步。
- 同理会咬 `可选组件 NextKde`（要编译）—— 修好头文件是它和微信的共同前置。
- 兜底取源（快照源万一没有）：`https://archive.archlinux.org/packages/g/glibc/glibc-<ver>-x86_64.pkg.tar.zst`

### 11.3 真故障②：自愈 user 服务"文件齐了但从没启用"
现象：`[!] 启用 user 服务失败(可能缺 linger...)`，而 `loginctl show-user deck` = `Linger=no`、
`systemctl --user is-enabled steamos-self-heal` = `disabled`。
**根因**：脚本以 root 跑，却用 `su - $REAL_USER -c "systemctl --user enable ..."` —— 从 root 的
su 会话里常常没有 `XDG_RUNTIME_DIR`/bus，连不上该用户的 user manager，再被 `2>/dev/null`
一吞就成了"看着执行了、其实没启用"。实测 `default.target.wants/` 里只有 `gamemoded.service`。
**修法**：`enable` 的本质就是往 WantedBy 目标目录放一个相对软链 —— 直接建链最可靠：
```bash
ln -sfn "../steamos-self-heal.service" "$REAL_HOME/.config/systemd/user/default.target.wants/steamos-self-heal.service"
loginctl enable-linger "$REAL_USER"     # 游戏模式不启 KDE 会话, 没 linger 就不跑
```
并把 `verify_step(setup_selfheal)` 加上 wants 软链判据（**单元文件在 ≠ 单元已启用**）。

### 11.4 假故障②：`LocalSend 落地复核未通过` —— 判据错了，东西是好的
现象：`[✓] 已放行(permanent)` 之后紧跟 `[!] 14 LocalSend 退出正常但落地复核未通过`。
**根因**：SteamOS 出厂 `public` zone 就开了 **1024-65535/tcp+udp**，53317 本来就在范围内。
此时 `firewall-cmd --add-port` 会判 `ALREADY_ENABLED` 而**不写盘**（退出码仍是 0）→
`/etc/firewalld/zones/public.xml` 里**永远找不到字面量 53317**，而旧判据偏偏 grep 它。
后果不只是白报一次：`step[14]` **永远不记进度**（每次重跑都重下 63MB AppImage），
自愈清单那条 `fwport` 还每次开机报一次"缺失"。
**定案判据** `fw_53317_ok()`：显式规则 → `--permanent --list-ports` 含 `1024-65535` → 兜底
`--permanent --query-port=53317/{tcp,udp}`（`--query-*` 会认范围规则）。**主脚本与
`self-heal-after-upgrade.sh` 两处同一套判断，改一处必须同步另一处。**

### 11.5 真故障③：Decky 预置插件一个都没装上（列表写法就错了）
现象：日志只有一条 `[✗] 商店里没有名为 SteamGridDB ProtonDB Badges 的插件`，
而 `~/homebrew/plugins/` 里**只有 SimpleDeckyTDP**。核对商店 API（110 个插件）确认
`SteamGridDB` 与 `ProtonDB Badges` 名字都对（大小写敏感）。
**根因**（老写法 `for _pl in ${DECKY_PLUGINS-"SteamGridDB ProtonDB Badges"}`）：
1. **`ProtonDB Badges` 自带空格** —— 空格分隔的列表根本表达不了这个名字，会被拆成三个词去查商店；
2. `DECKY_PLUGINS=""`（已设置但为空）时 `${VAR-def}` 取的是**空值**而非默认 → 循环 **0 次且一声不吭**
   （实测：`DECKY_PLUGINS=; for p in ${DECKY_PLUGINS-"A B"}; do ...` 什么都不输出）。
**修法**：默认用数组 `_plugins=(SteamGridDB "ProtonDB Badges")`；显式置空 = 跳过并有提示；
自定义改用 **`|`** 分隔：`DECKY_PLUGINS='Decky Localsend|ProtonDB Badges'`。
`check.sh` 的断言也同步改成查数组写法（原来那条 grep 老字符串，会拦住修复）。

### 11.6 root 属主污染：装进 /home 的东西属主是 root → 用户自己再也修不动
实测 `~/.cache/{harmony-sans,glow,localsend,firefox-nightly,dsh-desktop}`、
`~/.local/bin/{glow,firefox-nightly,deepseek-harness-desktop}`、
`~/.local/share/fonts/harmonyos-sans-sc`、`~/.config/fontconfig/conf.d`、`~/.local/opt/steamos-self-heal`
全是 `root:root`。**直接后果**：鸿蒙字体脚本第二次运行时
`mkdir: 无法创建目录 "~/.cache/harmony-sans/.stage.xxx": 权限不够` —— 用户自己也修不动。
**修法**：`fix_home_owner()`（主脚本全量跑完调用）+ `可选组件安装.sh` 的同名收尾，
只扫脚本碰过的路径（不对整个 `/home` 递归 —— 会扫到 Steam 的几十万文件）。
若已污染，手工清一次：`sudo chown -R deck:deck ~/.cache/harmony-sans ~/.local/share/fonts ~/.config/fontconfig`。

### 11.7 假故障③：`最小集未让 base-devel 判定通过`
`pacman -Qq base-devel` 是**整组**查询，最小集必然缺组内成员（autoconf/bison/texinfo…），
于是每台机器都白报一次。改成**逐包**确认 `$BD_MIN` 六件套，缺哪个点名报哪个。

### 11.8 顺带纠正两条老注释（挂载实况变了，别再按老印象写）
- **`/var/cache/pacman` 在 p8（918G 那块）**：`df -h` 实测 → 它**不占 rootfs**，
  清它对 5GB 的 p5 毫无帮助（老注释里"已 offload"是对的）。
- **`/etc` 是 overlay（230M 容量 / 42M 已用）；`/var` 在 p7（230M）**。
- ⚠️ **pacman 数据库不在 `/var/lib/pacman`**：3.9 的 `pacman.conf` 写的是
  `DBPath = /usr/lib/holo/pacmandb/` → **在 rootfs 里，跟 `/usr` 一起被原子升级整块换掉**。
  所以 `verify_step` 注释里"数据库在 p7 幸存、会与文件脱节"的**理由已经过时**（双判据本身保留，仍然是对的）。
- rootfs 实测：装完 15 步后 **`/` 4.1G/5.0G = 93%，仅剩 349M**（`Device unallocated` 只有 1MiB）。
  这次的增量主要是 electron43 + nodejs + 编译工具链（≈470M）。要回收跑 `bash free-rootfs.sh`
  看方案再 `--apply`（本轮未执行）。

### 11.9 ✅ 已解：自愈免密**确实生效**（2026-09-25 20:50 复查），且旧判据本身是错的

当时的疑问：`sudo -n /usr/bin/bash <备份包>/steamos-setup.sh --status` 报"需要密码"，与步骤[12]
"免密已写入并通过 visudo 校验"矛盾。**现在结论**：

- `/etc/sudoers` **确实 include 了 `/etc/sudoers.d`**（`sudo -n -l` 能列出 `sudoers.d/wheel` 等
  Valve 自带文件带来的规则；那些文件若不被 include 就毫无作用）。
- **免密生效的铁证**：先 `sudo -n true` 确认**没有**缓存的 sudo 时间戳（报"需要密码"），
  再跑 `sudo -n bash <MAIN> --after-upgrade` → **成功执行**。既然没有时间戳也能过，就是 NOPASSWD 命中。
  `sudo -n -l` 的输出里能看到最终三条规则：
  ```
  (ALL) NOPASSWD: /home/deck/.local/opt/steamos-self-heal/self-heal-after-upgrade.sh
  (ALL) NOPASSWD: /usr/bin/bash /run/media/.../steamos-setup.sh
  (ALL) NOPASSWD: /usr/bin/bash /run/media/.../steamos-setup.sh *
  (ALL) NOPASSWD: /usr/bin/bash /run/media/.../fix-missing-dev-files.sh      ← v3 新增
  (ALL) NOPASSWD: /usr/bin/bash /run/media/.../fix-missing-dev-files.sh *
  ```
- ⚠️ **旧判据错在哪**：`sudo -n -l <某个命令>` 判不出 NOPASSWD —— 本机有 Valve 的
  `%wheel ALL=(ALL) ALL`（清单里的 `(ALL) ALL`），于是**任何**命令查询都能"匹配"并返回 0，
  sudo 还会把查询的命令原样回显，看着像"允许"。**正确判法只有一条**：拉全量
  `sudo -n -l`（不带命令参数），再按**命令行里的路径**去认那几行 `NOPASSWD`。
  这个判法已固化进 `diag-sudo-selfheal.sh`（只读, `sudo bash diag-sudo-selfheal.sh`）。
- 至于当初那条 `--status` 为什么会要密码：规则用的是**安装时的绝对路径**，备份包挪过位置
  （或探测发生在步骤[12] 写规则之前）就会失配。现在的 diag 脚本会直接把这种失配报出来，
  并给出修法 `sudo bash <MAIN> 12`（按当前路径重写规则）。

---

## 12. SteamOS 把 /usr 的开发文件裁掉了 —— "要编译就报缺"的系统性拦路虎（2026-09-25 实测）

**现象**：凡是走到"要编译"的步骤（NextKde 的 kosctl cmake、要编译 C 的 AUR 包…）必然报缺，
且报的是"文件不存在"而不是"包没装"：
```
Could not find a package configuration file provided by "Qt6"
fatal error: string.h / zlib.h: 没有那个文件或目录
```
同时 `pacman -Q <pkg>` 说"已装"、`pacman -Ql <pkg>` 也老老实实列得出这些文件。

**根因（重要：这不是升级事故，是镜像常态）**
Valve 基础镜像把"开发用"文件摘掉了，**但 pacman 数据库仍保留完整清单** → DB 与磁盘长期不一致。
本机实测（已补过 qt6-base/qt6-declarative 之后的状态，所以实际只会更多）：
- `/usr/include`：DB 里 31088 个文件，**22619 个磁盘上不存在**；
- `.cmake` / `.pc`：8404 条里缺 **3986** 条；
- 单包视角：kwin 缺 315、kio 缺 252、qt6-base 补之前几乎整包缺（它的清单有 4700+ 条）。

**裁掉的边界（实测确认，别多补也别少补）**
| | 内容 |
|---|---|
| ✗ 被裁 | `usr/include/**`、`usr/lib/cmake/**`、`usr/lib/pkgconfig/*.pc`、`usr/share/locale/**`、`usr/share/doc/**` |
| ✓ 保留 | `usr/lib/*.so` **开发符号链接全在**（`libKF6ConfigCore.so`/`libz.so` 都在）、运行时库、`usr/share/ECM`（extra-cmake-modules 完好）、`usr/lib/qt6/mkspecs` |

**修法：`fix-missing-dev-files.sh`**
```bash
bash fix-missing-dev-files.sh                  # 只读体检, 列出缺开发文件的包
sudo bash fix-missing-dev-files.sh --apply     # 默认补 kde/qt6 集合(实测 160 包/9300 文件级)
sudo bash fix-missing-dev-files.sh --apply --set all   # 全系统扫修(更慢更多)
```
默认走"**只从 .pkg.tar.zst 里抽出那三类开发文件写回 /usr**"（`bsdtar -tf` 出成员清单 → `bsdtar -xf -T`）：
不覆盖运行时库、不把 locale/doc 带回来（省掉 ~90% 体积）、不参与 pacman 事务 → 风险≈0。
`--full` 才退化成 `pacman -U --overwrite='*'` 整包重装（连 locale/doc 一起回来）。

**实测结果（2026-09-25 19:30，GPD Win5）**
- `sudo bash fix-missing-dev-files.sh --apply`（默认 kde/qt6 集合）跑完：**160 个包 / 9322 个文件补齐，
  rootfs 只少了 13 MiB**（601→588 MiB）。对比整包重装会带回几百 MB 的 locale/doc —— 这就是选择性抽取的价值。
- 事后 `--set kde` 复检：**没有缺失**；`/usr/include/{zlib.h,X11/Xlib.h,kwin/effect/effect.h}`、
  `KWinConfig.cmake`、`KF6ConfigConfig.cmake` 全部就位 → kosctl 的 `find_package` 链不再报缺。
- 全系统 `--set all`（扫 1255 个包，**19 秒**）：仍有 **507 个包 / 17393 个文件**缺开发文件
  （x264/x265/ffmpeg/zstd/xz/xorgproto/zeromq/udisks2/upower 这些音视频与系统库）。
  对 KDE/Qt 构建无影响；哪天要编 ffmpeg 依赖的 AUR 包再跑 `--set all` 即可。
- ⚠️ **边界：个别包补不了**。`libwireplumber` 本机 0.5.15-1.2 而仓库已 0.5.17-1.1，`wireplumber` 锁着旧版 →
  `pacman -Sp` 直接报"破坏依赖"。这类包**只能等系统整体升级**，脚本会识别并明确跳过（别手贱抄单包 `pacman -U`）。
  注意 `pacman -Sp --print-format` 的**第一行可能是这种 `::` 信息行**，取版本号必须按包名精确匹配，不能用 `head -1`。

**⚠️ 判据教训：dev 文件是"按包"的，但 CMake 是"按文件"找的（2026-09-25 踩）**
补完 libx11 后 `find_package(X11)` 仍报 `missing: X11_X11_INCLUDE_PATH`，而 `/usr/include/X11/Xlib.h` 明明在。
原因：CMake 的 `FindX11.cmake` 第一个查的是 **`X11/X.h`**（`find_path(X11_X11_INCLUDE_PATH X11/X.h)`），
而 `X.h` / `keysym.h` / `Xatom.h` 属于 **`xorgproto`**，不属于 libx11。
`libx11` 的 dev 文件一个不缺、`xorgproto` 却缺 129 个 → 只看"我补过的包全齐"会得出错误结论。
- **教训**：报 `Could NOT find Xxx (missing: ...)` 时，去 `/usr/share/cmake/Modules/FindXxx.cmake` 里
  读出它真正 `find_path` 的**那个文件名**，再 `pacman -F`/`pacman -Ql` 反查属于哪个包 —— 别按包名猜。
- 复现/验证手法（不需要 root，也不动系统）：`pacman -Sp <pkg>` 拿 URL → `curl` 到 /tmp →
  `bsdtar -tf/-xf -T` 抽到临时树 → 用 `CMAKE_INCLUDE_PATH=<临时树>/usr/include cmake …` 验证 find_package 变绿。
  本轮就是这样确认"补 xorgproto 就能过 FindX11"的（`R=FALSE → R=TRUE`）。
- 默认集合已扩成两组：① 通用 C/C++/X11/Wayland 基础；② **CMake Find 模块最常探的库**
  （xorgproto / xz / zstd / bzip2 / libarchive / gmp / nettle / gnutls / krb5 / libcap / pcre /
  python / gettext / double-conversion / lz4 / libdeflate / libpsl / libssh2 / libidn2 / libunistring …）。
  2026-09-25 19:50 实测：新默认集合待补 **29 个包 / 737 个文件 / 下载约 29 MB**（rootfs 代价按 9322 文件≈13 MiB 折算只需个位数 MiB）。

**⚠️ 包文件名不能拼死 `-x86_64`（2026-09-25 19:51 真机第一次跑就踩）**
脚本原本用 `$CACHE/$pkg-$repo-x86_64.pkg.tar.zst` 找缓存文件，于是 **`arch=any` 的包永远"找不到"**：
`xorgproto` 的实际文件名是 `xorgproto-2025.1-1-any.pkg.tar.zst` → 被误报"下载失败"跳过 ——
而它偏偏是 `FindX11` 的必需项，等于白跑一轮。现改为从 `pacman -Sp <pkg>` 解析出的 URL 里
按**包名开头**精确取 basename（URL 里第一行可能是依赖的 URL，也要挑），下完再用
`$CACHE/$pkg-$repo-*.pkg.tar.zst` 兜底。
- 实测本机剩余集合里 `arch=any` 的有 4 个：`xorgproto`、`fwupd-efi`、`gsettings-desktop-schemas`、`ibus-table`
  —— 下次补它们时不会再跳过。
- 自测钩子：`FIXDEV_CACHE=<目录> bash fix-missing-dev-files.sh --apply --dry-run --pkgs xorgproto`
  可拿"替身缓存目录"验证这条路径解析（放一个 `…-any.pkg.tar.zst` 进去，看它是否认出正确文件名）。

### ★ 预检法：不动系统就把整条编译链验穿（比"改一次、贴一次报错"快一个数量级）
把待补包的开发文件抽到一个**临时前缀**，然后让 cmake 同时搜系统与临时树 —— 缺哪个包会一次暴露，
且**整条 configure/编译都能先在本机跑通，再让用户动手**：
```bash
# ① 抽开发文件到 /tmp/devstage（与脚本的 DEV_RE 同一套规则，从 pacman 缓存或 URL 取包）
# ② 用临时前缀配置 + 编译（CMAKE_PREFIX_PATH 走 config 模式, INCLUDE/LIBRARY_PATH 走 find_path/find_library）
cmake -S /home/deck/.local/opt/NextKde -B /tmp/nk-cfg -G Ninja \
      -DCMAKE_BUILD_TYPE=Debug -DCMAKE_INSTALL_PREFIX=/usr \
      -DKOS_BUILD_KWIN_PLUGINS=ON -DBUILD_TESTING=OFF \
      -DCMAKE_PREFIX_PATH=/tmp/devstage/usr \
      -DCMAKE_INCLUDE_PATH=/tmp/devstage/usr/include \
      -DCMAKE_LIBRARY_PATH=/tmp/devstage/usr/lib
ninja -C /tmp/nk-cfg -j6
```
2026-09-25 实测：NextKde 在"系统仅补过 kde 集合 + 临时树里只有 libepoxy"的条件下
**configure 通过 + `ninja` 33/33 全绿（BUILD_RC=0，含 KWin 特效插件与 kos-platform）**。
→ 结论：kde 集合之外，NextKde 真正还缺的**只有 `xorgproto` 与 `libepoxy` 两个包**。
- `libepoxy`：`KWinConfig.cmake:50 → find_dependency(epoxy)` → ECM 的 `Findepoxy.cmake` 要 `epoxy/gl.h`
  → 缺了报 `Could NOT find epoxy (missing: epoxy_INCLUDE_DIRS)`（已加入默认集合）。
- 这套预检法同样适用于任何"CMake 报缺"的第三方项目：**先在临时前缀里把缺的包找齐，
  再让用户在真机上一次性 apply**，能省掉多轮往返。

### ★ 升级后自动恢复链（v3，2026-09-25 定稿）：`self-heal-after-upgrade.sh` + 步骤[12]
原子升级后的自动恢复由三块拼成，缺一块就会"看着恢复了、其实没恢复"：

| 块 | 落点 | 扛升级 | 作用 |
|---|---|---|---|
| 自愈脚本 v3 | `$HOME/.local/opt/steamos-self-heal/self-heal-after-upgrade.sh` | ✅ /home | 开机跑：版本变化检测 + 落点清点 + **开发文件清点** + 自动恢复 |
| user 服务 | `~/.config/systemd/user/steamos-self-heal.service` + `default.target.wants/` 软链 | ✅ /home | 触发（**文件在 ≠ 已启用**，判据要查软链，见 §11.3） |
| 免密规则 | `/etc/sudoers.d/zz-steamos-self-heal` | ❌ /etc | 让上面两块能免密调主脚本；**升级必被冲 → 首次恢复要手动一次** |

- **开发文件清点（v3 新增）**：原子升级同样会摘掉 `/usr` 的 include/cmake/pkgconfig（§12 的根因），
  表现是"以后编译任何东西都莫名报缺头文件"，平时完全无感。v3 用**便宜哨兵**
  （`/usr/lib/cmake/Qt6/Qt6Config.cmake`）探一下，只有"**包在而文件不在**"（`pacman -Qq qt6-base` 成立）
  才叫 `fix-missing-dev-files.sh --set kde` 做全量体检 —— 不装 qt6 的机器不误报，也不在开机路径上白花 20 秒。
  检测到缺失就 `sudo -n bash <补齐器> --apply --set kde` 自动补回来。
- 免密规则必须**同时**放行补齐器（两条：不带参 / 带 `*`），并且步骤[12] 的**判定与落地复核都要认识这条**，
  否则老机器会走 info 分支永远补不上（这次就是踩了这个：只查 `steamos-setup.sh` 的话，
  已装机的规则不会重写）。改动清单：`DEV_ABS` 变量、`DEV_RULES` 条件、heredoc 两行、
  `verify_step(setup_selfheal)` 多一条 `grep -qs 'fix-missing-dev-files'`。
- **排查工具**：`sudo bash diag-sudo-selfheal.sh`（只读）一次查清——include 有没有、
  sudoers.d 里哪些文件被 sudo 忽略（组/他人可写）、规则里的路径是否还对得上当前备份包、
  三条 NOPASSWD 是否都在。**不用它就只能靠猜**（这正是 §11.9 悬了好几天的原因）。
- ⚠️ **判定 NOPASSWD 只能拉全量 `sudo -n -l`**，别用 `sudo -n -l <命令>`：本机有 `%wheel ALL=(ALL) ALL`，
  任何命令查询都会匹配成功并原样回显，看着像允许（实测：连 `/tmp/nonexistent.sh` 都返回 0）。

#### 游戏模式（本机大多数时间）下到底能不能自动唤起？——**能**，但有三个坑，v4 都堵了
实测证据（2026-09-25，全部在本机验过）：
- **会触发**：桌面模式与游戏模式都会走到 user manager 的 `default.target`。
  `systemctl --user list-dependencies default.target` 里直接能看到 `steamos-self-heal.service`；
  Valve 自己的 `gamemoded.service` / `dmemcg-booster-user.service` 同样是 `WantedBy=default.target`
  —— 而游戏模式离不开 gamemode，所以这条链必然被拉起。再加上步骤[12] 的
  `loginctl enable-linger`（不登录图形会话也起 user manager），双保险。
- **定时器真的会被排上**：用户 timer 用 `WantedBy=timers.target`，而 `timers.target` 自己是
  `WantedBy=basic.target`、`default.target` `Requires=basic.target` → 每次 user manager 起来都会拉起它。
  实测 `systemctl --user list-timers`：`NEXT=+19min`、`last trigger` 刚刚。systemd 自带的 user timer
  （tmpfiles-clean / podman-auto-update / drkonqi-*）用的是同一套机制。
- 坑① **开机瞬间没网**：游戏模式一上来就是 gamescope UI，Wi-Fi 常常还在连；主脚本 prepare 要
  `pacman -Sy`/装包，没网必失败。v4 动手前先 `wait_online()`（优先 `nm-online -q -t 5`，
  兜底 HTTP 探上游镜像，最多 120 秒），等不到就**静默交给定时器** —— 不算失败、不写标记、不推进版本戳。
- 坑② **游戏模式没有通知守护**：镜像里只有 plasmashell 提供 `org.freedesktop.Notifications`
  （`ls /usr/share/dbus-1/services | grep -i Notif` 只有 KDE 那条）→ 游戏模式里 `notify-send` 是**哑的**。
  所以失败必须靠①看得见的文件 `~/.local/opt/steamos-self-heal/NEEDS-ATTENTION.txt`
  （内含两条可直接粘的命令）②journal ③定时器持续重试；等切回桌面模式时才会补一次真通知。
- 坑③ **oneshot 只跑一次**：原来失败就等下次开机 → 现在定时器每 20 分钟重试；
  服务在"无事可做"时实测 **0.5 秒**秒退，所以 20 分钟一次的轮询在游戏模式挂着也没有可感开销。

### 撤回 NextKde（2026-09-25 实测：`kosctl uninstall` 在无免密 sudo 的会话里跑不完）
用户决定不装它之后，实操踩到两件事，记下来免得下次再犯：
1. **卸载顺序不能反**：必须**先还原 `plasmashellrc` 的 `[Shell] ShellPackage`，再删外壳包**
   （上游注释写明：键还指着已删的包时，plasmashell 启动会 "starting invalid corona"，
   表现是**没壁纸没面板**）。没有 `~/.local/share/kos/plasma-shell-state` 时上游也是**删键**
   （`kwriteconfig6 --file plasmashellrc --group Shell --key ShellPackage --delete` → 回落 Plasma 默认外壳）。
2. **`kosctl uninstall` 第一步就要 sudo 删 `/usr` 里的 KWin 插件**（读 `kwin-system-files.manifest`），
   在没免密 sudo 的会话里会卡在密码提示、**在还原 ShellPackage 之前就退出**（rc=1）→ 桌面处于
   "键指向 KOS、包还在"的半状态。所以：要么在真机 Konsole 里跑（能输密码），要么手工按
   ①键 ②外壳包 ③user 单元 ④二进制/桌面项/配置 的顺序做，`/usr` 那几个文件最后单独 sudo 删。
3. **查系统残留别设 `-maxdepth`**：`/usr/lib/qt6/plugins/kwin/effects/plugins/*.so` 在第 5 层，
   用 `-maxdepth 4` 会扫成"没有"而漏报；而且其中的 `glass.so` **不带 kos 前缀**，只看文件名认不出来，
   得对着 `kwin-system-files.manifest` 核。KOS 在系统侧一共 5 个文件：
   `kwin/effects/plugins/{glass,kos_context_menu_input,kos_dock_window_animation}.so`、
   `kwin/effects/configs/kwin_glass_config.so`、`qt6/qml/Kos/SurfaceShape/libkos_surface_shape.so`。
4. 卸载不影响正在用的会话：`kosctl install` 只改 `plasmashellrc` 的键，**要等 plasmashell 下次启动才切换**；
   所以删包时当前桌面（若仍是原版 Plasma）完全不受影响，下次登录即回到普通 Plasma。
5. 用户级落地物清单（手工撤回时按这个核）：`~/.local/share/plasma/shells/org.kos.desktop`、
   `~/.config/quickshell/kos`、`~/.local/state/quickshell/kos`、`~/.local/state/quickshell/shell-data-service`
   （Quickshell 的数据服务状态，里面会留 `kos-settings` 字样）、`~/.local/share/kos`、
   `~/.local/share/shared/qml`、`~/.config/plasma-org.kos.desktop-appletsrc`、
   `~/.local/bin/kos-settings`、`~/.local/libexec/kos-{platform,data-service}`、
   `~/.config/systemd/user/kos-{shell,platform,data}.service`、`~/.local/share/applications/{kos-settings,org.kos.Platform}.desktop`、
   `~/.local/opt/NextKde`(源码树 118M)、kwinrc 的 `[Effect-kos_dock_window_animation]` 组。
6. ⚠️ **`kwin-system-files.manifest` 不等于完整文件清单**：它只记了 5 个 `.so`，
   而 `/usr/lib/qt6/qml/Kos/SurfaceShape/` 里还有一个 `qmldir`（`module Kos.SurfaceShape` + `plugin kos_surface_shape`）
   → 只删 manifest 里的东西，`rmdir` 会因"目录非空"失败。**手工撤回时 `rmdir` 别吞 stderr**
   （否则看不出原因），收尾必须 `find <目录>` 确认还剩什么。那个孤儿 `qmldir` 也得删，
   否则 QML 扫到该模块会去找已不存在的插件。

**版本安全闸（这条最要命，别绕过）**
SteamOS 的固定仓库 `*-3.9` 与本机版本对齐（qt6 6.11.1 / KF6 6.28.0 / KWin 6.7.3），
而滚动仓库 `core`/`extra` 已经更新（6.11.2 / 6.30.0 / 6.7.5）→ **`pacman -Sy` 之后再装就是部分升级**，
会拆掉 KDE/KWin 的 ABI。pacman.conf 里 `*-3.9` 排在前面，`pacman -Sp --print-format '%v'` 取到的是
固定快照版本；脚本比对"去 pkgrel 后的版本号"，不一致就拒绝并要求 `--allow-bump`。
> 注意 kwin 本机 `6.7.3-1.5` vs 仓库 `6.7.3-1.6` 只差 pkgrel（Valve 重建），**允许**；
> 差在 `6.7.3` → `6.7.5` 就必须拒。

**手工等价做法**（只补单个包时）：
```bash
sudo steamos-readonly disable        # 重启自动回只读
sudo pacman -Sw <pkg>
sudo pacman -U --overwrite='*' /var/cache/pacman/pkg/<pkg>-<ver>-x86_64.pkg.tar.zst
```
代价是连 locale/doc 一起装回来（体积大得多），所以只在脚本默认模式补不上时才用。

**影响面记住两点**
1. 原子升级后**每次都要重补**（/usr 被整个换掉）—— 跑 `bash fix-missing-dev-files.sh` 看缺什么即可；
2. 任何"要编译"的新需求（AUR 包、桌面插件）先跑一遍这个体检，比 cmake 报错后再猜快得多。

---

## 13. 2026-09-25 健壮性审查（静态全量 + 可行性结论）

**方法**：① 先跑既有质量门（`check.sh`、`verify-upstreams.sh --quick` —— 全绿）；
② 用**只读探索代理**按 11 类脆弱模式扫全部顶层脚本（`2>/dev/null`/`|| true` 吞错、函数外 `local`、
`set -u` 未绑定、未加引号、缺超时、pacman 陷阱、路径假设、`read` 挂起、`mktemp` 续传、trap 覆盖、
eval/mapfile 坑）；③ 主脚本高风险段人工精读；④ 结果固化成新工具 `doctor.sh`。

**可行性结论：没问题** —— 上游地址全部可达、门禁全绿、核心机制（断点续传主循环、准原子替换、
自愈链、开发文件补齐）经得起压力。审查的价值在"假成功/假判据"这一类，不在功能缺失。

### 13.1 已修（按严重度）

| 级别 | 问题 | 修法 |
|---|---|---|
| **P0** | 主脚本装 GE-Proton：`rm -rf 旧版` → `tar -xzf … 2>/dev/null`（错误被吞）→ **无条件打印"安装完成"** → 还删掉 500MB 下载缓存。包损坏/空间不足时就变成"旧没了、新是空壳、还说成功" | 改「暂存 → 校验 `proton` 存在 → `mv` 原子换上去」；**只有成功才清缓存**（失败留着续传） |
| **P0** | `verify_step(setup_games)` 只看"有没有目录" → 解包半失败留下空目录也算达标（**假绿灯**，与上一条叠加） | 改判"真存在 `proton` 文件" |
| **P1** | `systemctl enable … >/dev/null 2>&1` 后不回查 `is-enabled`（背键守护、Decky 两处）→ 又是"文件在 ≠ 已启用" | 回查 `is-enabled`/`is-active` 并分别告警（`§11.3` 的教训复用） |
| **P1** | `pacman -Sy` 失败只 `warn` 就继续 → 后面的装包步骤按**过期包列表**解析依赖（部分升级风险） | 默认**中止**并说清原因；`PKG_ALLOW_STALE=1` 才放行。自愈链不受影响（有 20 分钟重试定时器） |
| **P1** | 没有 `/var/lib/pacman/db.lck` 守卫 → 与后台更新抢锁时每条装包命令都失败，表象像"这个包装不上" | 刷新前查锁：有 `pacman` 进程 → 中止；只有残留锁 → 提示怎么删 |
| **P1** | `install-ge-proton.sh`(509MB) / `install-dwproton.sh`(268MB) 下载缺 `--max-time` → 网络卡死会无限挂 | 补 `--max-time`（+ 保留 `-C -` 续传）；解包同样改"暂存→校验→原子换" |
| **P2** | `check.sh` 里一条断言锚点字面不存在 → **恒真**（又是假绿灯）；执行位检查在没有 `.git` 时被整段跳过；横幅正则遇 tab 缩进会静默不判 | 断言改成"匹配不到就报错"、加非 git 的 `-x` 兜底 |
| **P2** | `可选组件安装.sh` 自提权缺 TTY 守卫 → 非交互（管道/定时/批量）会**永久卡在 sudo 密码**（实测 2.5 分钟无反应） | 加 `[ -t 0 ]` 守卫（给出可复制的运行方式后退出）+ 自提权用**绝对路径** |
| **P2** | `fix_home_owner()` 漏了 `~/.cache/ge-proton`、`Downloads/dwproton-dl`、`~/.local/share/icons` → 这些被 root 写过之后用户清不掉 | 补齐路径清单 |
| **P2** | 零散：`install-app-home.sh` 的 `${prev:?}` 两分支写法不一致、`fix-dsh-node-pty.sh` 缺 `read` 守卫与硬编码 `/home/deck`、`install-decky-tdp.sh` 同类、`upgrade-workbuddy-aur.sh` 的 askpass 可能残留 | 逐个加固（见各文件注释） |

### 13.2 新增的两个"优雅入口"

- **`doctor.sh`** —— 一屏体检：系统与空间 / 必装组件（复用 `--status`）/ 自愈链（复用 `--dry-run`）/
  开发文件 / 免密链路 / 上游（`--net`）。**只读、秒级、无临时文件**，最后给一行结论 + 该跑什么。
  退出码 0=全绿、1=有待处理，可被脚本复用。
- **`self-heal-after-upgrade.sh --dry-run`** —— 只读预演：打印"会修什么"，不调 sudo、不写版本戳/标记。
  `doctor.sh` 的第 3 节就靠它。

### 13.3 判据类的坑（本项目通病，能锁的都锁进 check.sh 了）

- **假绿灯**（已经踩过 5 次）：`tools/shellcheck.exe` 是 Windows PE，Linux 上执行不了却恒判"0 warning"；
  `find` 扫到 `.git/objects/**/*.sh` 这种名字像脚本的 git 对象；断言锚点字面不存在（恒真）；
  "只查单元文件在不在"不查 `is-enabled`；"只看有没有目录"不看里面有没有真东西。
  **统一对策**：判据要"能失败才算判据"——跑一次真命令、核一次落地物、找不到匹配就报错。
- **假红灯**（这次自己踩到，记下来）：`sudo -l` 的输出会**按终端宽度折行**——输出到管道/文件时按 80 列，
  命令与参数被拆到下一行。于是"整条命令行 grep"必然匹配不到，**有免密规则也会被判成"缺失"**。
  对策：先把空白拉平（`tr -s '[:space:]' ' '`），再按路径匹配（`case`，别用正则拼路径）。

### 13.4 已知取舍（明确记录，别当成 bug 反复"修"）

1. **免密规则指向的是"用户可写路径上的脚本"** —— `/etc/sudoers.d/zz-steamos-self-heal` 里写的是
   `deck ALL=(ALL) NOPASSWD: /usr/bin/bash <备份包>/steamos-setup.sh *`。备份包在 /home 或 /run/media，
   **deck 自己能改**；再加上这条 NOPASSWD，就等价于"任何能以 deck 身份执行代码的东西(Game/AUR 脚本、
   被投毒的配置)都能不输密码提权"。不设这条规则则至少要输一次密码。
   - 本项目是**单人掌机**、用户本人就是管理员，故当前接受这个取舍（且它换来"升级后无人值守恢复"）。
   - **更好的做法（2026-09-25 已实施，见 §13.5）**：把需要免密的文件**以 root 身份同步一份到
     `/opt/steamos-backup/`**，sudoers 规则指向那份 root 属主的副本 ——
     `/opt` 实测是 offload（bind 到 home 分区）**扛原子升级**，且 root 属主 → **用户改不动**，
     还能顺带解决"备份包挪位置 → 规则失配"（§11.9 那个坑）。
     （最初想放 `/usr/local`，被实测否掉：它属于 `/usr`，升级会被冲 —— 见 §13 的文档纠正。）
2. **`free-rootfs.sh --aggressive` 是"删系统文件"的操作**（locale/man/doc/壁纸）。它是**显式开关**、
   默认不跑、说明书标了"收益不持久"，本次只把它的失败从"悄悄吞掉"改成"报出来"。
   别"顺手"把它变成默认，也别扩大删除范围。
3. **`pacman -Sy` 失败默认中止**（§13.1 P1）是有意为之：继续跑会让装包步骤按过期列表解析依赖。
   代价是"网络抖一下整轮就停"—— 用 `--allow-stale-db` 放行只做本地文件类步骤。
   自动恢复链不受影响（自愈有 20 分钟重试定时器 + 动 pacman 前先等网络）。
4. **本项目只在 GPD Win5 + SteamOS 实测过**（README「诚实边界」）；其它机型走 `device_profile()` 路由，
   未逐台验证。审查也没有覆盖 `steamos-nix/`（已冻结的探路分支）与 `disabled/`。
5. **开发文件只补"kde/qt6 集合"**（默认）；全系统还有约 507 个包缺开发文件，要用时 `--set all`。
   这是刻意的：默认集合覆盖 CMake 常探的库，全量要多下几百 MB 而多数包一辈子用不到。

---

## 13.5 免密链路改用 `/opt` 下的 root 属主快照（2026-09-25 实施）

**改了什么**：步骤[12] 除了写 sudoers 规则，还会把**备份包的整套顶层文件**以 root 身份同步到
`/opt/steamos-backup/`；规则只放行快照里的 `steamos-setup.sh` 与 `fix-missing-dev-files.sh`，
`self-heal` 的 `main.conf` 也指向快照。

**为什么（三个理由，前两个是这次审查挖出来的）**
1. **提权口子**：旧规则指向"用户可写的脚本"（备份包在 `/home` 或 `/run/media`，deck 自己能改）。
   配上 NOPASSWD，等价于"任何能以 deck 身份执行代码的东西（被投毒的游戏/AUR 脚本/配置）
   都能不输密码拿到 root"。快照是 `root:root`，用户改不动 → 门只剩一个：跑步骤[12] 的 root 自己。
2. **抗挪位**：规则里是绝对路径。备份包一挪位置（`~/Downloads` → `/run/media/...`），
   `sudo -n` 就静默失配 —— 这正是 §11.9"免密到底生不生效"那个悬案的一部分。
   快照路径固定，且 **`/opt` 实测是 offload**（bind 到 home 分区）→ **升级后连快照都不用重建**。
3. **顺带去掉一条没用的规则**：旧规则还放行了自愈脚本本身，但它是**用户身份**跑的、
   根本不需要 sudo（全仓 grep 确认无人用 `sudo` 调它）—— 而它落在用户可写目录，纯属多余的口子。

**代价与对策（必须知道）**
- 快照是"上次跑步骤[12] 时的那套代码"。仓库改了不刷新 → 自动恢复仍然跑旧版本。
  **`doctor.sh` 会比对 `sha256` 并在不一致时提示**"快照与仓库不一致 → 刷新: sudo bash steamos-setup.sh 12"。
  这其实也是个优点：**无人值守的恢复不会执行"半改状态"的仓库代码**。
- 快照同步失败（`/opt` 不可写等）→ 自动退回旧行为（规则指向备份包）并**打印告警**，不会变哑巴。
- 步骤[12] 的落地复核（`verify_step(setup_selfheal)`）现在会查：快照两个关键文件在不在、
  规则是否真的指向 `/opt/steamos-backup`。`check.sh` 也加了 6 条断言锁住这套不变量。

**验证过的（本机实测）**
```
/opt/steamos-backup        44 个文件, root:root, 位于 offload (/dev/nvme0n1p8[/.steamos/offload/opt])
sudo -n -l                 只有 4 条我们的规则, 全部指向 /opt/steamos-backup; 指向备份包/自愈脚本的条目 = 0
sudo -n bash /opt/steamos-backup/steamos-setup.sh --status            ✓ 免密可用
sudo -n bash /opt/steamos-backup/fix-missing-dev-files.sh --help      ✓ 免密可用
self-heal --dry-run        显示会执行 `sudo -n bash /opt/steamos-backup/steamos-setup.sh …`
doctor.sh                  ✓ 免密只放行 root 属主快照 / ✓ 快照属主正确 / ✓ 快照与仓库一致
```

### 同批纠正：背键守护的落点
`setup-win5-backkeys.sh`（备用脚本）原先把守护进程装 `/usr/local/bin`，而 `/usr/local` **不扛升级**。
现改为 `~/.local/opt/gpd-win5-backkeys/`，与主脚本步骤[4] 一致；安装/卸载时顺手清理旧的 `/usr/local` 落点，
并按 `SUDO_USER` 解析真实家目录（`sudo` 下 `$HOME` 是 `/root`，直接用它会把东西装错地方）。

### 13.6 Decky 插件崩在 `Minified React error #130`（2026-09-26 现场）

**现场**：游戏模式里 Decky 面板变成整屏报错，报错屏自己写"likely occurred in SteamGridDB"。

**根因（三条证据）**
1. `~/homebrew/settings/loader.json` → `{"branch": 1, "store": 1}`：
   `branch:1` = Decky 本体走 Pre-Release；`store:1` = 插件商店走 **Testing**。
2. 装出来的插件版本带哈希：`decky-steamgriddb 1.7.1-b6bcdd0`、`protondb-decky 1.3.4-809751c`
   —— 这是商店 **Testing 通道的 nightly 制品**（正式版在清单里是纯 semver：`1.7.1`、`1.2.0`）。
3. `~/homebrew/logs/decky-steamgriddb/*.log` 同一天 **22 次 `Unloaded`** = 前端崩→Decky 卸载→重试的死循环。

**关键分辨**：我们仓库的 `install_decky_plugin` 取的是**不带 `testing` 参数**的商店清单 → 装的是正式版；
崩掉的这两个是 Decky 自己的测试通道装上去的。**所以别急着改我们这边的下载逻辑**（`check.sh` 已加断言锁住这一点）。

**工具**：`bash diag-decky.sh`（只读）→ 一次看清通道 / 测试构建 / 崩溃循环；
`--repair [插件名]` 走步骤[5] 用稳定版重装；`--channels-stable` 把 `loader.json` 改回 `branch:0,store:0`（先备份）。
配套给主脚本加了 `--decky-plugins='A|B'` 开关（`=` 形式 + 开关而非环境变量，理由见 §13.5 同款：`shift` 取不准、
`env_reset` 会剥环境变量）。

**经验**：插件崩绝大多数是"**测试通道 nightly + Steam 客户端更新**"的组合，不是插件坏了。
另外报错屏本身有 `Disable <插件>` / `Restart Decky` 按钮 —— **当场止血先点它**，再谈修根因。

---

### 13.7 「文件系统中已存在」= 孤儿文件，**不是**装不上（2026-09-26 定案）

**现场**：一次 `steamos-setup.sh` 跑下来，两处 AUR 安装失败，报错长这样：
```
workbuddy: 文件系统中已存在 /opt/WorkBuddy/app.asar.unpacked/resources/trayTemplate.png
发生错误，没有软件包被更新。
[✗] workbuddy 安装失败

wechat-universal-bwrap: 文件系统中已存在 /opt/wechat-universal/wechat
发生错误，没有软件包被更新。
[✗] AUR 安装未成功(网络/AUR 不可达?)
```

**根因**：`/opt/WorkBuddy/app.asar.unpacked/**` 与 `/opt/wechat-universal/*` 是**孤儿文件** ——
`pacman -Qo <路径>` 明确回"没有软件包拥有"，pacman 本地 DB（`/usr/lib/holo/pacmandb/local/`）
里也没有 `workbuddy` / `wechat-universal-bwrap` 记录。也就是**只有文件、没有台账**。

**为什么偏偏是 `/opt` 出这事**：`/opt` 是 offload（bind 到 /home 分区）。AUR 包把主体装进 `/opt`
（`workbuddy` 的 PKGBUILD 硬编码 `/opt/WorkBuddy`；`wechat` 的装 `/opt/${_pkgname}`），
于是**原子升级整块换 rootfs 时，`/opt` 里的文件幸存、`/usr` 里的入口+运行时+DB 记录被冲掉**
—— 结果就是"文件在、台账没了"。之后再装同一个包，pacman 看到文件已存在就拒绝覆盖。

**诊断（三条命令，别猜）**
```bash
pacman -Qo /opt/WorkBuddy/app.asar.unpacked/resources/trayTemplate.png   # 没有软件包拥有 → 孤儿
ls /usr/lib/holo/pacmandb/local/ | grep -i workbuddy                     # 空 → DB 里没记录
ls -la /opt/WorkBuddy /opt/wechat-universal                              # 文件确实在
```

**修法（三选一，按推荐度）**
1. **让 AUR 助手自己覆盖（推荐）**：`yay`/`paru` 交互时会问
   `Package … already exists in filesystem. Overwrite?` → 答 `y`。
   本仓库脚本用 `--noconfirm`，所以**必须显式告诉助手**：`--overwrite='*'`
   （yay/paru 都支持透传给 pacman）。本项目已在主脚本 workbuddy 段与微信段接上：
   先普通装一次，检测到 `文件系统中已存在`/`exists in filesystem` 就**带 `--overwrite` 重试一次**，
   并在日志里说清"这是覆盖孤儿文件，不是重装"。
2. **先清孤儿再装**：`rm -rf` 掉那几个目录（**前提：确认没有别的包/用户数据在里面**）。
   对 `/opt/WorkBuddy` 要当心 —— 里面可能还有 `~/.workbuddy` 之外的本地数据（设置、缓存）。
3. **手工等价**：`sudo pacman -U --overwrite='*' <缓存的 .pkg.tar.zst>`（见 §12 的同类做法）。

> ⚠️ **不要**把 `--overwrite='*'` 当成万能开关塞进所有 pacman 调用 —— 它会掩盖真实的包间冲突
> （两个包争同一个文件那种）。只在**明确判定为孤儿**（`pacman -Qo` 无主）时才用。

**同一个坑的判定捷径**：只要是"**装在 `/opt` + 靠 AUR 装 + 刚做完整块升级**"，
出现 `文件系统中已存在` 基本就是这条，不用往"包损坏"上想。

#### 附：`AUR RPC unexpected EOF`（同一次现场的另一件事）
```
错误： error sending request for url (https://aur.archlinux.org/rpc): error trying to connect: unexpected EOF
```
这是 **AUR 的 RPC 接口（`aur.archlinux.org`，HTTPS）连不通**，与本项目脚本无关。
实测 `curl --max-time 10 https://aur.archlinux.org/rpc?...` → `000`（连 TCP/TLS 都没成）。
`aur.archlinux.org` 与 `github.com` **不是同一件事**：git 协议可能通、网页可能通，
但 `aur.archlinux.org` 被 DNS 污染/被墙/代理规则漏掉都会长这样。
**排查顺序**：`curl -v https://aur.archlinux.org/rpc` 看卡在哪一步（DNS？TLS？）→ 换 DNS 或补代理规则。
脚本侧只能"把话说准"（现在报的是"AUR 不可达"而不是泛泛的"安装失败"），网络本身得用户侧解决。

---

### 13.8 「无法锁定数据库」被误报成「源的问题」（2026-09-26 现场，两个真 bug）

**现场**：用户手动跑 `sudo bash steamos-setup.sh 3`，输出：
```
• 刷新仓库(pacman -Sy)...
[!] pacman -Sy 刷新失败 —— 多半还是源的问题, 关键错误如下:
错误：未能同步所有数据库（无法锁定数据库）
```
**用户的第一反应必然是"源坏了"** —— 但真正的原因跟源毫无关系。

**真凶（追父进程链才看清）**
```
37784 pacman -Sw --noconfirm breeze
 └─ 36284 bash /opt/steamos-backup/fix-missing-dev-files.sh --apply   ← 另一个实例正在补 KDE 开发文件
    └─ 36283 sudo bash …
       └─ 用户自己的 Konsole 会话（10:28 手动跑的）
```
即：**用户手动跑步骤[3] 的同时，另一个补开发文件的进程正在下载 `breeze` 等包（一个就几十 MB），
一直握着 pacman 锁** → 撞锁 → 报"无法锁定数据库"。用户亲眼看到 `.part` 文件在涨才知道是在正常下载。

**我们的脚本里有两个真 bug（都不是"源"的问题）**

| # | bug | 后果 | 修法 |
|---|---|---|---|
| ① | 锁路径**写死** `/var/lib/pacman/db.lck` | 本机 DB 真身在 `/usr/lib/holo/pacmandb/`（`/var/lib/pacman` 根本不存在）→ **这个守卫从没生效过**，每次都直接落到 `pacman -Sy` 失败 | 改为运行时探测：优先 `/usr/lib/holo/pacmandb`，退回 `/var/lib/pacman` |
| ② | 持有者匹配用 `pgrep -a -f '(^|/)(pacman\|yay\|paru)\b'` | `-f` 匹配整条命令行 → 把 `gpg-agent --homedir /etc/pacman.d/gnupg` 这种"路径里含 pacman"的进程也列成"持有者"（实测踩过），越列越糊涂 | 改用 `pgrep -x pacman -a`（只认可执行名）+ 另用 `pgrep -f 'fix-missing-dev-files\.sh'` 单独识别自愈链 |

**顺带加的能力：等锁，别一撞就退**
最可能的持锁者恰恰是**我们自己的自愈链/补齐器**，它下完包会自己放手。所以不再"一撞就退出"，而是：
- 先打印**持有者是谁**（`pgrep -x pacman -a`），若判定是自愈链就明说"它下完包会自己放手，干等一会儿通常就过了"；
- 最多等 **180 秒**（`PACMAN_LOCK_WAIT=秒数` 可调），每 30 秒报一次进度；
- 等到了继续跑；等不到才退出，并给出"想多等"的命令。
- `pacman -Sy` 失败后**再复核一次**错误文本：若含 `无法锁定数据库|unable to lock`，明确报"这是**锁**、不是源"，
  避免再次把用户带偏。

**教训（这条通用）**：报错文案本身就是产品的一部分。当守卫**失效**时，用户看到的是下一层的
误报信息，而误报信息会把人引向**完全错误的排查方向**（这次是"源"）。所以：
> 凡是"拦截失败后落到下层错误"的地方，下层那段的文案必须能区分上层那几类原因。

### 13.8b ⚠️ 免密规则随 `/etc` 被冲 → 自愈链在"恢复免密之前"永远起不来（死循环）
同一个现场的另一条，**比上面更硬**：
```
sudo[29383]: deck : a password is required ; COMMAND=/usr/bin/bash /opt/steamos-backup/steamos-setup.sh 3
[自愈] 步骤 3 未执行(需免密 sudo, 见 steamos-setup.sh 12)
```
`/etc/sudoers.d/zz-steamos-self-heal` **不存在**了（`cat` 报"没有那个文件或目录"），
`sudo -n -l` 里只剩 Valve 出厂的两条 NOPASSWD（`steamos-prepare-oobe-test`、`steamos-chroot`），
**我们的一条都没有**。

**这是预期内的**：`/etc/sudoers.d/` 在 rootfs 里，原子升级连 `/etc` 一起冲掉（见 §3）。
但它造成一个**自指的死循环**：
> 自愈链要恢复系统，**依赖免密**；而恢复免密这件事本身**要跑步骤[12]**，步骤[12] 要 root
> → 免密没了 → 自愈链每 20 分钟重试一次，**每次都失败**，且永远无法自举。

**所以升级后的正确顺序只能是（这点必须让用户知道）**
```bash
sudo bash /opt/steamos-backup/steamos-setup.sh 12   # ← 唯一必须人工输密码的一步(自举)
sudo bash /opt/steamos-backup/steamos-setup.sh --after-upgrade
```
**任何"全自动恢复"的承诺都越不过这一步** —— 自愈链能处理的是"免密还在"的局部损坏。
排查工具 `sudo bash /opt/steamos-backup/diag-sudo-selfheal.sh` 就是为了让人一眼看出
"是规则丢了、还是快照丢了、还是路径对不上"。

#### 13.8b+ 同现场的第三层悖论：修锁的钥匙被锁挡在门外（已修）
用户真按上面跑了 `…/steamos-setup.sh 12`，**还是失败** —— 死在环境准备的 `pacman -Sy`
（还是那个锁）。这暴露出更荒诞的一层：
> 步骤[12] 的工作是**重建免密规则/快照/服务软链，全是文件操作、不装包、与 pacman 无关**；
> 它却陪跑 `pacman -Sy`，于是"**修锁的人被锁挡在门外**"。补齐器持锁多久，免密就多久建不起来。

**修法（3.9.6）**：`prepare()` 认 `PREPARE_NO_REFRESH=1` —— 跳过锁守卫与 `-Sy`，直达正题；
`setup_selfheal()` 设它。只读解除/密钥环/镜像表这些快速且无锁的准备工作照跑。
`check.sh` 钉了两条断言（开关必须存在 + setup_selfheal 必须设置）。

**顺带两个口径修正**
1. **免密已失效时，第一步该跑【仓库那份】的步骤[12]**，不是快照那份：
   反正要人工输密码、无提权口子；而仓库那份的步骤[12] 会**顺手把过期快照同步成最新**
   （新锁守卫/免刷新逻辑一并进快照）。"只能用快照那份"的告诫只适用于**免密还活着**的场景
   （用快照刷快照 = 把提权口子开回来，守卫会拒绝）。doctor.sh 的建议已改为优先仓库路径。
2. 撞锁等待超时的提示里要点明："只想恢复免密 → 步骤[12] 不受锁影响，现在就能跑"。

**当前未决**：2026-09-26 现场这次，用户尚未成功跑步骤[12]（旧快照版死在锁上），
快照/免密仍是旧状态，自愈服务持续失败并在 `~/.local/opt/steamos-self-heal/NEEDS-ATTENTION.txt` 留了标记。
**下次重装/升级后，仓库版的步骤[12] 是第一个要跑的东西。**
（2026-09-26 12:32 已用 `12 --force` 成功收尾；当天的完整结局见每日记忆。）

---

## 13.9 2026-09-27 全项目复审（方法 + 扫描结论 + 三项优化）

**方法**：① 跑既有门禁；② 按 §13 的 11 类脆弱模式做**静态全量扫描**；
③ 针对 2026-09-26 两次最贵的现场教训做定向优化（优化的方向是**消除不一致/补盲区**，不是加新机制）。

**扫描结论（先看没问题的，避免重复劳动）**
| 项 | 结果 |
|---|---|
| 能删根的 `rm -rf "$VAR/..."` 形态 | **0 处**（24 处 `rm -rf` 全是整变量或 `-exec {} +`） |
| 下载 `--max-time` | 全覆盖（含 3600s 大包） |
| 交互 `read` 挂起 | 全部带 `-t` 超时 |
| 下载缓存用 mktemp | 无（都固定路径，保 `-C -` 续传） |
| `verify-upstreams.sh` | 关键项全通 |

**三项优化**
1. **严格模式统一**：3 个脚本此前没开 `set -u`（`可选组件安装.sh` / `诊断-开机慢.sh` /
   **`self-heal-after-upgrade.sh`** —— 后者是无人值守跑的，变量打错名字没人看得见）。
   已对齐项目标准 `set -uo pipefail`，并**逐一实跑验证**（自愈 `--dry-run`、可选组件非交互、开机慢诊断）。
2. **过期快照自检**（对应 §13.8b 的"快照永远落后于仓库"）：步骤[12] 同步时盖 `.snapmeta`
   （源路径 + 主脚本 sha256 + 时间）；之后凡**从快照目录启动**，自动比对并警告 + 指路仓库那份。
   > 设计取舍：只在"跑的是快照"时发声，从仓库跑时静默 —— 免密无人值守场景不受影响。
3. **自愈清点覆盖"装在 /opt 的 AUR 包"**（微信 2026-09-26 凭空消失且无人告知）：
   新增 `orphanpkg` 判据（目录在 + 台账没了 = 孤儿），**只报告不自动装** ——
   可选组件不该由自愈替用户决定装不装；步骤字段写 `-` 表示不进自动修复表（否则会拿 `-` 去跑主脚本）。
   包名走 CHECKS 的**第 5 字段**，判据保持通用。

`check.sh` 新增 6 条断言（共 **195 条**全绿）。

**两条通用经验**
- **"跑错副本"是一类独立的故障源**：症状是"刚修好的 bug 原样复现"，极难往这个方向想。
  凡是"同一份代码有多个副本"的设计（快照/缓存/已安装副本），都要有**版本可见性**（盖章 + 启动自检）。
- **"消失"比"报错"更需要主动告知**：升级冲掉台账时，程序不会报错、只会从菜单里不见。
  所以清点清单该覆盖"幸存文件 + 缺失台账"这种不一致态，而不只是检查"文件在不在"。

---

## 13.10 2026-09-27 第二次复审：把散脚本封装成一个应用（可行性 + 健壮性验证）

**诉求**：回顾整个项目 → 优雅地优化 → 详细的可行性分析与健壮性验证 → 封装成一个完整的可执行项目应用。

### 13.10.1 方法（沿用 §13 的路子，但换了个问法）

§13 那次问的是"哪里会坏"；这次问的是**"人会怎么用错 / 用什么会腐化"**。所以做了三步：
① 跑既有门禁建立基线（`check.sh` 217 条全绿 + `doctor.sh`）；
② **一致性扫描**：把文档/注释/元数据里"会过期的事实"逐类扫一遍（步骤数、行数、版本号、
脚本清单、悬空引用）；
③ 交付一个统一入口，并给它**装上自动化护栏**（人记不住的东西交给断言）。

### 13.10.2 扫描结论（修了 6 处"不报错、只是慢慢错"的漂移）

| 位置 | 原来 | 实际 | 危害 |
|---|---|---|---|
| `VERSION` | `3.7.0` | `3.9.10` | 半年前就停了；现在它是入口横幅与**发布包名**的来源 |
| `重装后先运行我.sh` 头注释 | "15 步" | 16 步 | 用户按错的步数预期判断"是不是跑完了" |
| `可选组件安装.sh` 头注释 | "十二步主线" | 16 步 | 同上 |
| `SCRIPT-MAINTENANCE` §1.1 | "约 1976 行" | 3734 行 | 维护者据此估复杂度会错 |
| `SCRIPT-MAINTENANCE` §1.1 步骤 2 | "IBus 原生输入法" | **已禁用（空函数）** | 与 `README` 直接矛盾，改错的地方就在这 |
| `fix-workbuddy-wayland-ime.sh` | 指向 `check-wayland-ime.sh` | **该脚本从未存在** | 读者去找一个不存在的东西 |

后三类是同一类病：**同一事实写了两份**。能自动比对的（版本号）已加断言；其余靠"指向唯一来源"解决。

### 13.10.3 可行性分析（结论：低风险 —— 因为零侵入）

| 关注点 | 结论 | 依据 |
|---|---|---|
| 会不会破坏免密自举链 | **不会** | 入口**不提权、不进 sudoers**；需要 root 的转发给原脚本原有的路径。另加两条断言钉死 |
| 会不会影响步骤[12] 的快照同步 | **不用改一行** | `sync_snapshot()` 本来就是"顶层所有文件一起搬"，新文件自动被带上（`chmod 0755` 也自动适用于 `*.sh`） |
| 会不会影响断点续传状态机 | **不会** | 入口不碰 `~/.cache/steamos-setup/state`，只转发 |
| 会不会与"单脚本可独立拷贝"（铁律 1）冲突 | **不冲突** | 入口本身自包含、可单独拷走；没有引入 `lib/` |
| 新增维护负担 | **一处**：加脚本要在注册表加一行 | 而这一条有断言兜底 —— 忘了会报红 |
| 会不会让"跑错副本"变严重 | **不会，反而更可见** | `selfcheck` 会说明"你跑的是仓库那份还是快照那份"，并比对 sha256 |

### 13.10.4 健壮性验证（全部实跑，含反例）

| 验证项 | 手段 | 结果 |
|---|---|---|
| 语法 | `bash -n` 全部脚本 | 通过 |
| 静态 | `shellcheck -S warning`（含新入口） | 0 warning |
| 门禁 | `check.sh` | **233 条全绿**（218 → +15） |
| **免密规则"生成↔判定"同步** | 真机跑步骤[12] 得到"[跳过] 已完成" | 已修判据 + 加交叉断言（见下），反例验证会报警 ✔ |
| **免密规则的参数形态** | 用当前规则集直接探 `sudo -n bash <脚本> --参数` | 确证"不带 `*` 只放行原样调用" → 加双向断言（见下） |
| 未知命令 | `bash steamos.sh nosuchcmd` | 退 2，并指路 `list` / `doctor` |
| 缺文件 | 临时移走 `fix-opt-deps.sh` | 退 3；`selfcheck` 同时报"注册了但文件不在" |
| 退出码透传 | `steamos.sh status` | 退 0（子脚本的码原样带出） |
| 非交互不挂起 | `steamos.sh setup </dev/null`、`apps </dev/null` | 打印该跑的命令，退 4，**不挂起** |
| 非交互只读项 | `steamos.sh status </dev/null` | 照跑（无人值守体检可用） |
| 交互菜单 | **伪终端**(pty) 真发按键：`42`→执行→回车→`q` | 渲染、执行、回菜单、退出码 0 全部正常 |
| 符号链接调用 | 软链到 `/tmp/linktest/toolbox` 再调用 | `HERE` 正确解析到**真实包目录**（解链后 cd），功能正常 |
| 发布包自包含 | `pack` → 解到 `/tmp` → 包内 `selfcheck` | 全绿（628K，无 git 依赖） |
| **反例①** 新脚本未登记 | 造一个 `zz-probe.sh` | 断言报警"这些脚本没登记进 steamos.sh" ✔ |
| **反例②** 注册表行引号没闭合 | 伪造一行 | 报警"行数对不上(45/44)"+ "内建命令没有实现函数: zzbogus" ✔ |

> 反例②是**顺手补掉一个自己的盲区**：第一版用带引号的正则去抽注册表行，
> 于是一行"引号没闭合"的坏行**匹配不上、被后面所有检查静默忽略**。
> 现在改成"原始行数 vs 可解析行数"对账（带下限，防整表删空时 0=0 通过）。
> 又一次印证 §13 那条规矩：**判据失效本身必须报错，否则它比没有还危险。**

### 13.10.5 三个自己踩的坑

1. **`GROUPS` 是 bash 特殊变量**（当前用户的组 ID 列表），`GROUPS=(health setup …)`
   的赋值被**无声吞掉** → 菜单分组直接变成 `1000/998/973` 这种组号。改名 `CMD_GROUPS`。
   *教训：给 shell 脚本起变量名前，先想一下它是不是 shell 自留的名字。*
2. **`tar --exclude` 的作用域**：不含 `/` 的模式按"基名"在**任意层级**匹配；写成 `./.workbuddy`
   只挡得住顶层，`steamos-nix/` 子目录里的会话产物照样进包 —— 被 `dist-verify` 当场抓到。
3. **断言选择器要能看见坏数据**：见 §13.10.4 的反例②。凡是"先按格式抽出数据、再校验数据"的
   断言，都要额外对一次**总量**，否则格式坏掉的那条会从眼皮底下溜走。

### 13.10.6 复查时**用户真跑一次**抓到的第 4 个坑（最有价值的一个）

我按上面的清单验证完、宣布"全绿"之后，用户照我给的命令跑了一次步骤[12]，结果是：

```
$ sudo bash steamos-setup.sh 12
[✓] [跳过] 12 升级后自愈服务 —— 已完成于 2026-09-26 12:32:23  (--force 可强制重跑)
```

**看起来一切正常，其实什么都没做。** 免密快照停在上一天的版本，新加的第三条免密规则
（`fix-opt-deps.sh`）也没补上 —— 自愈链就此瘸腿，而且**全程不报错**。

**根因**：`setup_selfheal` 里"**生成**免密规则"与 `verify_step` 里"**判定**规则在不在"
是**两处**。v3.9.10 加第三条规则时只改了生成那处。
> 同一类坑 2026-09-25 已经踩过一次（受害者是"开发文件补齐器"那条规则），
> 当时还在 `verify_step` 旁边写了注释提醒自己 —— **第二次照样复发**。

**修**：
1. `verify_step setup_selfheal` 补上第三条的判据（快照里文件在不在 + sudoers 里有没有）。
2. `check.sh` 加**交叉核对断言**：从 `SNAP_*="$SNAP_DIR/xxx"` 抽出全部规则脚本名，逐个
   要求在 `verify_step` 里出现**在一行 `grep` 判据上** —— 以后再加第四条规则，会被断言逼着改两处。

**这条断言自己也踩了一次假绿灯**：第一版写的是"分支里提到这个名字就算过"，
结果被同一分支里 `[ -f /opt/steamos-backup/fix-opt-deps.sh ]` 这种
**文件存在性**检查骗了过去（反例验证时才暴露）。改成"必须出现在 `grep` 行上"才作数。
> 又一次印证：**判据要盯住"真正的那个动作"，而不是"提到过没有"。**

**方法上的教训（比这个 bug 本身更值钱）**：
静态扫描 + 自造反例，**抓不到"两处知识不同步"这类 bug** —— 因为它两侧各自都"自洽"，
只有**真跑一遍、看它到底做了什么**才会现形。我给的"修好了"结论之所以快了半步，
就是因为验证停在"读代码 + 造反例"，而用户那一步是"执行真实路径"。
**能真跑的，别只读代码。**

### 13.10.7 确证 sudoers 的参数语义（不查文档，直接探）

修上面那个 bug 时顺手确证了一条**一直被假设、没人验过**的规则（**用现有规则集直接试**）：

```
$ sudo -n bash /opt/steamos-backup/fix-opt-deps.sh --任意参数
sudo: 需要密码                      ← 被拒(退 1)
$ sudo -n bash /opt/steamos-backup/fix-opt-deps.sh
[✓] 依赖齐全: webkit2gtk-4.1 libayatana-appindicator    ← 放行(退 0)
```

**结论**：`NOPASSWD: /usr/bin/bash <脚本>`（不带 `*`）**只放行"原样调用"**；一旦带参数就会被拒，
必须另写一条 `... <脚本> *`。这就是为什么主脚本与开发文件补齐器各有 `*` 变体，
而补依赖器没有 —— **因为自愈链调它时不传参，这是刻意的"最小提权面"**。

**加的双向断言**（`check.sh` 2.15e）：把"调用方式"和"规则形态"绑在一起校验 ——
- 调用改成传参、规则却还是没 `*` → 报"无人值守时会被拒(静默失败)"；
- 规则无谓加上 `*`、调用并不传参 → 报"提权面被无谓放大"。
两边各做了一次反例验证。

> 顺带一个副产品：那次探针同时**确证了 Clash Verge 的依赖是齐的**
> （`webkit2gtk-4.1` + `libayatana-appindicator` 都在），也就是"便携化应用 + `/usr` 依赖"
> 这条链现在是健康的 —— 属于"顺便验了另一件该验的事"。

### 13.10.8 边界（诚实记下）

- 注册表里的"模式"（`ro` / `root` / `ui`）是**我按各脚本的实际行为判定的**，不是脚本自己声明的。
  加新脚本时若判错：标 `ro` 而实际需要密码 → 无人值守时会挂住（这是**唯一**有实际后果的一档）。
  兜底做法：不确定就标 `ui`（默认最保守）。
- `pack` 打的是**工作区当前内容**（不是最后一次 commit）—— 发布前先跑 `check.sh`，它才是台账标准。
- 入口的菜单没有做"命令参数输入"（比如给 `setup` 传编号）：菜单里只跑默认形态。
  要带参数直接在命令行用：`bash steamos.sh setup 3`。

### 13.10.9 同日第三次复审（Windows 副本）：执行位的跨平台真相 + 两处护栏加固

上一轮复审在 SteamOS 真机上做；这一轮在 **Windows 副本**（OneDrive 同步目录，Git Bash）上做，
结果 `check.sh` 一跑就抓到一个真机上**不可能出现**的红项：`steamos.desktop 没有执行位`。
顺藤摸瓜，补齐了"执行位"这个判据在跨平台场景下的完整真相：

**三个实测出来的平台事实（都拿探针验过，不是猜）**

1. Windows/NTFS 上 Git Bash 的 `chmod +x` 是**空操作**（探针：临时文件 chmod 后 `-x` 仍为假）。
2. Git Bash 的 `-x` 测试是**内容嗅探**：有 shebang 的 `.sh` 显示可执行，无 shebang 的
   `.desktop` 永远不可执行 → 在 Windows 上拿磁盘位判 `.desktop` **必然假红**。
3. Windows 上 `git add` 一律记 `100644` → 新脚本/启动器从 Windows 提交会静默丢执行位，
   正是 8977c11「整仓没执行位 → 双击没反应」事故的**复发通道**。

**加固一：check.sh 的执行位判据改为「索引优先 + 环境探针」**
- 已入 git（含已暂存）→ 查 `git ls-files -s` 的索引模式（跨平台，Windows 上同样有效），
  且从"点名 4 个文件"**扩到全部已跟踪 `.sh`/`.desktop`**（当前 62 个全 100755）。
- 未入 git → 先跑 `fs_can_x` 探针：本机表示不了执行位就**明示跳过**（"提交后由索引断言兜底"），
  不再假红；表示得了（Linux）才拿磁盘位判，行为与原来一致。
- 反例验证：`git add steamos.desktop`（Windows 记 100644）→ check.sh 两处同时报警并给出
  `git update-index --chmod=+x` 修法；修复后转绿 ✔

**加固二：dist-verify 新增「tar 元数据执行位」判据**
- 动机：在 Windows 上 `pack` 时，`.desktop` 会被按 644 存进包 → 到 Linux 双击没反应；
  而解包后在 Windows 上做 `-x` 又必然假红。**唯一两边都信的判据是 tar 里存的模式**。
- 反例验证：在 Windows 上真打了一次包 → 两个 `.desktop`（及 `disabled/` 一个存档脚本）
  全是 644 → dist-verify 退出 1 并精确点名 ✔；换回 Linux 造的好包 → 全绿 ✔

**加固三（同日稍后实施）：pack 改为平台免疫 —— 上面"只能在 Linux 造"的限制已解除。**
与其把"别在 Windows 上打包"写成纪律，不如让打包器**不依赖文件系统位**：成员分两趟显式
`--mode` 写包（执行位集合 = 名字规则 ∪ git 索引 100755，其余 644；`--no-recursion` 防子树
按 FS 位二次塞入）。任何平台打出的包模式都正确，dist-verify 的元数据判据负责兜底验证。
3.10.1 的发布包就是在 Windows 上造的，dist-verify 全绿；文件清单与 3.10.0 的 Linux 造包
逐一比对一致（数据文件从"碰巧全 755"回归正常的 644，更干净）。

**结论**：`pack` / `check.sh` / `selfcheck` / `dist-verify` 在 Windows 与 Linux 上**行为一致、
全部可信**。跨平台时唯一要记得的手工动作是从 Windows 提交新脚本后
`git update-index --chmod=+x`（忘了也没关系：pre-commit 的索引断言会拦下并教你怎么修）。
