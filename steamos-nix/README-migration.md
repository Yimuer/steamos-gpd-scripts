# SteamOS → Nix 持久化迁移方案 (steamos-nix)

> 目标:把 `steamos-setup.sh` 每次大版本升级后要"重下载+重编译+重打补丁"的易失内容,
> 迁移为 **Nix 管理的、内容寻址的 `/nix/store` 落点**。SteamOS 原子升级只会再冲掉
> `/etc` 里的一层薄符号链接 —— 恢复从"联网重装 12 步"降级为
> **一条离线秒级命令** `sudo ~/.steamos-nix/bin/steamos-nix-activate`,并由
> 幸存于 `/home` 的 user 服务开机自动执行。
>
> **机型自适应**:本方案同时覆盖两类硬件 —— GPD Win 5 掌机(含背键三件套)与
> 9800X3D / 7900XTX 这类**外接键鼠+手柄的台式机**(不含任何手持机专属配置,
> 但包含 WPS / 微信 / 中文字体等桌面生产力套件)。机型由 §0 的探测决定,
> 写进 `machine.nix`,构建期按机型裁剪产物 —— **台式机上不会多出一条无用的
> inputplumber 覆盖,掌机上也不会浪费空间装 WPS**。

## 0. 先做设备检测

nix 是纯函数式求值,**不能**在构建期偷偷读硬件;所以探测在 nix 之外做:

```bash
bash scripts/steamos-nix-detect.sh            # 打印机型画像 + 判定依据
bash scripts/steamos-nix-detect.sh --write    # 把结论写进 machine.nix
STEAMOS_NIX_MACHINE=desktop bash scripts/steamos-nix-detect.sh --write   # 强制指定
bash install.sh --machine desktop             # install.sh 里也会自动探测一遍
```

判定依据依次是:① STEAMOS_NIX_MACHINE 环境变量 → ② DMI `GPD` + `G1618-05`
→ ③ 是否探测到 Win5 背键 HID(`2F24:0137`)→ ④ DMI `Valve` + Jupiter/Galileo
→ ⑤ 有没有内置电池 → 否则按 `desktop`。

| 机型 | 判定 | 构建内容 |
|---|---|---|
| `gpd-win5` | DMI G1618-05 或背键 HID 存在 | 背键守护 unit + udev + inputplumber 覆盖/能力表 **+** NTP + sudoers |
| `steam-deck` | Valve Jupiter/Galileo、或有电池的非 Win5 掌机 | NTP + sudoers(不含 Win5 专属配置) |
| `desktop` | 无电池 / 非掌机 chassis(9800X3D + 7900XTX 这类) | NTP + sudoers **+** WPS / 微信 / LocalSend / 鸿蒙中文字体 |

`machine.nix` 就是一个 `{ machine = "desktop"; }`;可以直接手改。
`install.sh` 每次都会刷新它,并把结论记到 `~/.steamos-nix/machine`。

## 1. 现状分析:哪些内容会被 SteamOS 升级冲掉

依据 `steamos-setup.sh` 的 `verify_step()` 落地判据 + README 的分区结论
(A/B 原子更新整块替换 rootfs;`/home`、`/opt`→offload、`/var/lib/pacman`、**/nix** 幸存):

| 步骤 | 落点 | 位置 | 大版本升级后 | nix 迁移后 |
|---|---|---|---|---|
| 1 | archlinuxcn 仓库段 | `/etc/pacman.conf` | ❌ 被冲 | 不再需要(nix 供包);装 AUR 时仍需步骤1 |
| 2 | ibus + 引擎二进制 | `/usr`(pacman) | ❌ 被冲 | ⚠️ 保留 pacman(深度系统会话集成),仅配置层归 nix |
| 2 | 输入法方案(小鹤双拼) | `~/.config/ibus/rime` | ✅ 幸存 | ✅ `setup-ibus-xiaohe.sh` 写入,见 §3.5 |
| 2 | dconf/kwinrc 输入配置 | `/home` | ✅ 幸存 | home-manager 可选接管 |
| 3 | WorkBuddy 本体 | `/opt`(offload→home) + `/usr` | ✅ 幸存 | ⚠️ **不进 nix** —— 本体留在系统里,见 §3.4 |
| 3 | electron 依赖 + `/usr/bin/workbuddy` 包装补丁(IME flags) | `/usr` | ❌ 被冲(旧方案每次重打 sed) | ✅ nix 只提供**转发器**:优先 exec 系统 wrapper,全挂了才退到 electron |
| 4 **(仅 Win5)** | 背键守护单元 | `/etc/systemd/system/gpd-win5-backkeys.service` | ❌ 被冲 | ✅ 仅 gpd-win5 机型才生成 |
| 4 **(仅 Win5)** | 守护进程 py | `/home/.local/opt/...` | ✅ 幸存 | ✅ vendor 进 nix(逐字校验一致,见 §6) |
| 4 **(仅 Win5)** | udev 规则 / inputplumber 覆盖 / 能力表 | `/etc/...` | ❌ 被冲 | ✅ 仅 gpd-win5 机型才 symlink |
| 4 | inputplumber 本体 | pacman | ❌ 被冲 | ⚠️ 保留 pacman(系统级输入服务) |
| 5 | Decky 二进制/插件 | `/home/homebrew` | ✅ 幸存 | 不动 |
| 5 | plugin_loader.service | `/etc/systemd/system` | ❌ 被冲 | ⚠️ Decky 自管;兜底重跑 `install-decky-loader.sh` |
| 6 | Proton 兼容层/前缀/快捷方式 | `~/.local/share/Steam` | ✅ 幸存 | 辅助脚本进 nix tools |
| 7 | dsh | `~/.local`(npm) | npm 前缀幸存,但依赖系统 node | ✅ nix `dsh`(buildNpmPackage 钉版本) |
| 9 | SimpleDeckyTDP | `/home/homebrew/plugins` | ✅ 幸存 | 掌机专属,不动 |
| 10 | NTP drop-in | `/etc/systemd/timesyncd.conf.d/ntp.conf` | ❌ 被冲 | ✅ 全机型通用的 2 个落点之一 |
| 12 | 自愈 user 单元 + 脚本 | `~/.config/systemd/user` + `~/.local/opt` | ✅ 幸存 | ✅ 由 nix 渲染安装,只引用稳定路径 |
| 12 | sudoers 免密 | `/etc/sudoers.d/steamos-nix` | ❌ 被冲 | ✅ 全机型通用的 2 个落点之一(visudo 校验后落盘) |
| — | 20+ 诊断/修复/安装脚本 | 重装即没了 | ❌ 依赖 U 盘备份 | ✅ `steamos-tools` 进 profile |
| — | WPS / 微信 / LocalSend | pacman 或 Flatpak | ❌ 系统更新后残留 | ✅ nix profile(见 §3) |
| — | 鸿蒙中文字体 | `~/.local/share/fonts` | ❌ 每次手动拷 | ✅ `steamos-cjk-fonts` + fontconfig 指向 store(见 §3.2) |

**结论**:nix 化后,这些落点的**内容**全部在持久 `/nix/store`,升级后缺失的只是 `/etc`
符号链接层,`steamos-nix-activate` 离线秒级重建;user 服务开机自动跑,人工只剩**首次** sudo 引导一次。

明确保留给 pacman 的两处(诚实边界):`ibus` 与 `inputplumber` 的**系统服务二进制** ——
它们与桌面会话/游戏模式深度集成,强行搬到 nix 收益低风险高;但它们的**配置**
(inputplumber yaml、kwin/ibus 配置所在 /home)已全部持久或归 nix。

## 2. 目录结构

```
steamos-nix/
├── flake.nix                  # 唯一入口; tunables 集中在 cfg; allowUnfree 在此放行
├── machine.nix                # ★ 机型开关(由 §0 的 detect 脚本写入)
├── nix/
│   ├── lib.nix                # 包定义: tools / etc / activate / workbuddy / dsh /
│   │                          #          daemon / wps-office / wechat / localsend /
│   │                          #          harmonyos-sans / cjk-fonts / apps
│   └── home-module.nix        # 可选 home-manager 模块(非必需路径)
├── config/                    # vendor 的配置真身(由 nix 内容寻址进 store)
│   ├── inputplumber/{devices.d,capability_maps.d}/20-gpd_win5.yaml   # 仅 Win5
│   ├── udev/rules.d/70-gpd-backkeys.rules                            # 仅 Win5
│   ├── systemd/gpd-win5-backkeys.service.in                          # 仅 Win5
│   ├── systemd/user/steamos-nix-heal.service  # 开机自愈(只引用稳定路径)
│   ├── python/gpd-win5-backkeys.py
│   ├── ntp/ntp.conf.in                       # 全机型
│   └── sudoers.d/steamos-nix.in              # 全机型
├── scripts/                   # 全部维护脚本 → steamos-tools(wrapProgram 注入依赖)
│   ├── steamos-nix-detect.sh                 # ★ 机型探测
│   └── ...
├── bootstrap-nix.sh           # 一次性:装 nix + 探测 /nix 持久性 + 开 flakes
├── install.sh                 # 首次安装/日常升级/换机: detect→build→profile→指针→激活
├── verify.sh                  # 真机组验证(需 nix + root 沙盒)
├── VERIFY-REPORT.md           # ★ 本机静态 + WSL 沙盒验证报告(离线可读)
└── README-migration.md        # 本文
```

离线可复核的自检脚本在 `.selftest/`:
`static-audit.py`(静态)、`b-harness.sh`(沙盒动态)、`b-fixcheck.sh`(修复回归),
以及三个"从实现里提取真身"的提取器
`extract-activate.py` / `extract-font.py` / `extract-workbuddy.py`
(测试跟着实现走,不会出现"实现改了测试还绿"的假绿)。

## 3. 桌面套件:WPS Office / 微信 / LocalSend(台式机默认安装)

| 软件 | nixpkgs 属性 | 打包方式 | license | 可执行文件 | 说明 |
|---|---|---|---|---|---|
| WPS Office | `pkgs.wpsoffice`(本仓库 `useChineseVersion = true`) | deb 解包 + `autoPatchelfHook` | `unfreeRedistributable` | `wps` `wpp` `et` `wpspdf` | 专有,需 `allowUnfree` |
| 微信 | `pkgs.wechat` | AppImage 解包 + `wrapAppImage` | `unfree` | `wechat` | 专有,需 `allowUnfree` |
| LocalSend | `pkgs.localsend` | Flutter 源码构建(`flutter324`) | **MIT**(不 unfree) | `localsend_app` | 局域网传文件,AirDrop 替代品 |

> **为什么不选 `wechat-uos`**:nixpkgs 上的版本目前存在构建失败
> (nixpkgs issue #458010 —— 上游 deb 下载返回 403)。官方 AppImage 版 `wechat` 可用,
> 这也是本仓库的选择。后续若 uos 版恢复,改一行即可。

### 3.1 LocalSend 需要放行防火墙

LocalSend 用 **53317/tcp** 传输 + **53317/udp** 做组播发现。SteamOS 默认 `firewalld`
会挡掉,表现为"能打开但搜不到对端":

```bash
sudo firewall-cmd --permanent --add-port=53317/tcp --add-port=53317/udp
sudo firewall-cmd --reload
```

桌面入口由 `install.sh` 自动链进 `~/.local/share/applications/`(包名自带
`LocalSend.desktop` 与 hicolor 图标)。

### 3.2 中文字体:HarmonyOS Sans SC

nixpkgs 25.05 **没有** `harmonyos-sans`(`pkgs/by-name/ha/harmonyos-sans` 返回 404;
社区版本只存在于 NUR / 第三方 overlay)。所以本仓库**自建 derivation**:

| 项 | 值 |
|---|---|
| 来源 | `https://developer.huawei.com/images/download/general/HarmonyOS-Sans.zip`(已实测 HTTP 200, 52MB) |
| 取出 | 只取 `HarmonyOS Sans/HarmonyOS_Sans_SC/*.ttf` —— 6 个字重(Thin/Light/Regular/Medium/Bold/Black) |
| family 名 | `HarmonyOS Sans SC`(已从 ttf name 表实测;postscript `HarmonyOS_Sans_SC`) |
| license | `unfree` —— 华为授权是"可随产品嵌入、**不可单独再分发**",别把 `$out` 推到公共 binary cache |
| 开关 | `flake.nix` 里 `cfg.cjkFont = "harmony-sans"` \| `"noto"` \| `"none"` |

**hash 是 FOD,可能需要你填一次真值。** `fetchzip` 属于 fixed-output derivation,
hash 必须与解包结果逐字节一致;`flake.nix` 里填的是社区记录值,若你的 nix 解包器
或上游 zip 与之不同,构建会失败并打印 `got: sha256-...` —— 两遍法修一次即可:

```bash
cd steamos-nix
nix build .#steamos-cjk-fonts          # 故意失败一次, 看 "got:" 后面的串
#   把 got: 的整串 sha256-... 填回 flake.nix 的 cfg.harmonySansHash
bash install.sh                        # 再跑一次
```

想立刻绕开就改 `cfg.cjkFont = "noto"`(用 Noto CJK + 文泉驿兜底,不需要外部 FOD)。

> **关键设计:字体与应用解耦。** `steamos-apps` 里**不含**字体,字体是独立 attr,
> `install.sh` 单独构建、失败只降级告警。**因此字体 hash 对不上不会导致
> WPS / 微信 / LocalSend 装不上** —— 只是中文暂时是豆腐块。

### 3.3 其它配套

- **桌面入口** —— `install.sh` 把 `~/.nix-profile/share/applications/*.desktop`
  软链到 `~/.local/share/applications/`(在 /home,升级幸存)。
- **字体接入** —— 不复制字体,而是往 `~/.config/fontconfig/conf.d/10-steamos-nix-fonts.conf`
  写 `<dir>`(指向 store 路径)+ `<prefer>`(把 sans-serif / serif 的首选族钉到鸿蒙)。
  只用 `<dir>` 的话 fontconfig 只是"多一个候选",中文仍可能被别的字体抢走。
  `monospace` **不**写 prefer —— 拿比例字体顶替等宽会让终端/代码字体错乱。
  换代时 install.sh 会整条重写。
- **Wayland 兜底** —— 每包额外提供 `wps-x11` / `wechat-x11`(Qt:`QT_QPA_PLATFORM=xcb`)
  与 `localsend_app-x11`(GTK/Flutter:`GDK_BACKEND=x11`)。
  KDE Plasma Wayland 下偶尔出现缩放/输入法不跟随,用它切一下。
  IME 模块名没有写死(fcitx5 与 ibus 都可能);需要时用 `STEAMOS_NIX_IME` 注入。

安装/关闭:

```bash
bash install.sh                    # desktop 机型默认带 --with-apps
bash install.sh --without-apps     # 只要维护脚本,不要 WPS/微信/LocalSend/字体
bash install.sh --with-apps        # 掌机上也强制装(不推荐:浪费盘)
```

### 3.4 WorkBuddy:本体**不进 nix**（重要）

WorkBuddy 是 Electron 应用。`/nix/store` 是**只读**的，把它纳管进去等于关进沙盒，
下面这些会直接废掉：

| 功能 | 为什么在 nix 里会挂 |
|---|---|
| 自动更新 | store 只读，写不了自己的安装目录 |
| dsh / MCP 插件安装 | 插件要写进应用目录（`node_modules/.ignored/...`） |
| native 模块（`.node`） | nix 的 electron ABI 与 app 自带原生模块对不上 → 加载失败 |
| fcitx5 / Rime 中文输入 | 看不到系统的输入法模块路径（`GTK_IM_MODULE` 等） |
| 文件对话框 / 截屏 | 缺 `xdg-desktop-portal` |
| 通知 / 托盘 | 缺系统 dbus |

所以策略是 **nix 只提供一个转发器，本体必须留在系统里**：

```
workbuddy（转发器，在 ~/.nix-profile，升级幸存）
   │
   ├─ ① /usr/bin/workbuddy 存在且是真实文件 → exec 它   ← 正常态，功能完整
   │
   ├─ ② 被原子升级冲掉了 → 用**系统** electron 启动 /opt/workbuddy 的 payload
   │
   └─ ③ 系统 electron 也没有 → 才用 nix electron 兜底（会告警：功能可能受限）
```

无论走哪条路，转发器都会 `--no-sandbox --disable-setuid-sandbox` +
`ELECTRON_DISABLE_SANDBOX=1` —— Electron/Chromium 的沙盒一律关掉，要的是完整系统访问。

强制指定：`STEAMOS_NIX_WORKBUDDY=system|nix nix run ...`（平时不用管）。

> **所以系统里有 `/usr/bin/workbuddy` 是好事，不是冲突。** `install.sh` 检测到它会
> 明确告诉你"nix 转发器会直接调用它"；只有它不见了才会提示 `yay -S workbuddy` 装回。

### 3.5 输入法：统一 IBus + 小鹤双拼（桌面 + 游戏模式）

SteamOS **自带 IBus**，所以输入法框架就用它 —— 不再装 fcitx5。

| 理由 | 说明 |
|---|---|
| SteamOS 自带 | 不用额外装框架 |
| **游戏模式原生就是 IBus** | Steam 客户端在 gamescope 下**只认 IBus D-Bus 协议**（会话 target 里的 `ibus-gamescope.service` 就是这个通道）。用 fcitx5 得额外装 AUR 桥接包 `fcitx5-steam-ibus-frontend` 去冒充 IBus —— 多一层就多一处坏点 |
| 避免冲突 | 两套框架并存会抢 DBus 名与 GTK/QT IM 模块，是"候选框乱飞 / 输入发不出"的常见源 |

输入方案是 **Rime 的小鹤双拼**（`double_pinyin_flypy`）—— 跟之前 fcitx5 上用的是同一套
方案文件，词库和用户习惯不用迁移。

**两个会话怎么覆盖：**

| 会话 | 机制 |
|---|---|
| KDE 桌面（Plasma Wayland） | KWin 负责拉起输入法 → 必须配 `~/.config/kwinrc` 的 `[Wayland] InputMethod`；环境变量走 `~/.config/plasma-workspace/env/` |
| 游戏模式（gamescope） | Steam 走 IBus D-Bus，只要 `ibus-daemon` 在用户会话里跑着就行 → 用 systemd user unit 常驻，**两个会话共用同一个守护进程**和同一份 Rime 配置 |

> ⚠️ **最关键的一个坑**：Wayland 会话下**不能** export `GTK_IM_MODULE` / `QT_IM_MODULE`。
> KWin 自己管输入法，再强设会让程序改走 XWayland 的 IM 模块 —— 结果就是候选框不跟随、
> 甚至完全打不出中文。**只设 `XMODIFIERS=@im=ibus`**（IBus 官方也是这么建议的）。
> X11 / XWayland 会话下才需要全套。脚本会按 `$XDG_SESSION_TYPE` 自动切换。

依赖（SteamOS 自带 ibus，这两个通常要补）：

```bash
sudo pacman -S ibus-rime librime rime-double-pinyin
#   ibus-rime        Rime 引擎的 IBus 前端
#   rime-double-pinyin  提供 /usr/share/rime-data/double_pinyin_flypy.schema.yaml（小鹤双拼）
```

配置 / 体检：

```bash
sh scripts/setup-ibus-xiaohe.sh            # 配置（幂等，可重复跑）
sh scripts/setup-ibus-xiaohe.sh --install  # 顺带用 pacman 补装依赖
sh scripts/setup-ibus-xiaohe.sh --check    # 只读体检，不写任何东西
bash scripts/setup-steam-game-mode-ime.sh  # 游戏模式复查（现在只做检查，不再装桥接包）
```

配置落在 `~/.config/ibus/rime/`（Rime 配置）、`~/.config/plasma-workspace/env/`（环境变量）、
`~/.config/systemd/user/ibus-daemon.service`（常驻）—— 全在 `/home`，升级幸存。
`install.sh` 第 4.5 步会自动跑一遍。

常用：`Super+Space` 切中英，`Ctrl+\`` 或 `F4` 开方案选单。

**fcitx5 退场**：`scripts/setup-fcitx5-flypy.sh` 已废弃（直接退出，防止误用）。
`setup-ibus-xiaohe.sh` 会主动检测 fcitx5 残留并给出清理命令
（`sudo pacman -Rns fcitx5 fcitx5-rime fcitx5-steam-ibus-frontend`）。

验证中文是否真的生效:

```bash
fc-match "HarmonyOS Sans SC"       # 应解析到 /nix/store/...-harmonyos-sans-sc/...
fc-match sans-serif:lang=zh-cn     # 应命中 HarmonyOS Sans SC
```

## 4. 使用

```bash
# 全新机器 / 迁移首日:
bash bootstrap-nix.sh                 # 装 nix(单用户, profile 在 /home)
bash scripts/steamos-nix-detect.sh    # 看一眼机型判定对不对
cd steamos-nix && bash install.sh     # detect→build→profile→指针→激活(sudo 一次)
bash verify.sh                        # 真机组验证(需要 nix)

# 日常改配置: 编辑 flake/cfg 或 config/* → bash install.sh
# SteamOS 大版本升级后: 什么都不用做(自愈服务开机重建); 或手动一条:
sudo ~/.steamos-nix/bin/steamos-nix-activate

# 查看状态/体检(不改系统):
steamos-nix-activate --check                                   # rc=0 无缺失; rc=1 有待链项
steamos-nix-activate --prefix /tmp/sim --state ~/.steamos-nix  # 沙盒演练
```

dsh 的 npm hash 引导(一次性,需联网):`nix build .#dsh` 会报错并打印实际 hash →
填回 `flake.nix` 的 `dshTarballHash`/`dshNpmDepsHash`,之后 `bash install.sh --with-dsh`。

回滚:`install.sh` 每次把上代 etc 树记入 `~/.steamos-nix/etc-previous`;
`ln -sfn $(readlink ~/.steamos-nix/etc-previous) ~/.steamos-nix/etc-current && sudo steamos-nix-activate`
即回旧配置。nix 层整体回滚:`nix profile rollback`。

## 5. 境内镜像加速

- **nix 二进制缓存**:`bootstrap-nix.sh` 会在 `~/.config/nix/nix.conf`(在 `/home`, 持久)
  幂等写入 USTC/TUNA substituter(`https://mirrors.ustc.edu.cn/nix-channels/store`、
  `https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store`、`https://cache.nixos.org/`)。
  换源:`NIX_SUBSTITUTER='...' bash bootstrap-nix.sh`。
- **nix 安装器本体**:`NIX_TARBALL_URL=https://ghfast.top/...` 走 GitHub 代理前缀。
- **flake 输入**:`github:NixOS/nixpkgs/nixos-25.05` 首次解析要走一次 GitHub。
  不通就挂 `https_proxy`,或 `nix flake update --override-flake nixpkgs <本地克隆>`。
- **WPS/微信的上游地址**:分别在 `wpscdn.cn` 与腾讯 CDN。它们是 `meta.hydraPlatforms = []`
  (Hydra 不代构建),所以**首次一定在本机取包**;网络不通时换源或走 HTTPS 代理即可。
- 工具层原有国内源保持不动:npm→npmmirror、GitHub Release→ghfast/gh-proxy、pacman→tuna/ustc、
  NTP→阿里/腾讯、WorkBuddy→AUR 镜像源。

## 6. 可行性验证

完整报告见 **[`VERIFY-REPORT.md`](./VERIFY-REPORT.md)**(静态审计 + WSL2 真实 Linux 沙盒演练)。

已复核并成立的部分:

- **结构一致性**:lib.nix 引用与 `config/` 实际路径逐一对得上;3 个 `.in` 模板的
  `@占位符@` 与构建期替换键完全闭合;6 个 Win5 落点(4 个 Win5 专属 + 2 个通用)。
- **daemon 忠实性**:vendored `gpd-win5-backkeys.py` 自 `import glob` 起与
  `steamos-setup.sh` 内嵌版**逐字节一致**(4177B / md5 `1f92df4a` 双份相同);
  vendored 版额外自带 shebang + 归属说明(393B header)。
- **脚本可执行性**:`steamos-tools` 对每个脚本 `wrapProgram --prefix PATH` 注入运行时依赖
  (含 python3+vdf+**pyyaml**);`systemctl`/`pacman` 等**故意不注入**,留给宿主 systemd。
- **免密链**:sudoers 是单命令宽参数形式(`NOPASSWD: <绝对路径>` 允许 `--state/--quiet`),
  与 heal unit 的 `ExecStart` 用的是同一个稳定路径。
- **shell / python 语法**:24 个 `.sh` 通过 `bash -n`;3 个 `.py` 通过 `py_compile`。
- **字体族名实测**:直接从华为 zip 里的 ttf 解析 `name` 表,确认
  `HarmonyOS Sans SC` / `HarmonyOS Sans` / `HarmonyOS Sans TC` 三个族名,
  fontconfig 的 `<prefer>` 用的是实测值而非文档抄写。
- **上游可达性实测**:华为字体 zip 拉取为 HTTP 200 / 52,165,952 字节;
  nixpkgs 25.05 的 `pkgs/by-name/ha/harmonyos-sans` 为 404、`lo/localsend` 存在。

## 7. 健壮性验证

`VERIFY-REPORT.md` 记录了在真实 Linux 沙盒里跑的场景,**当前全部通过**
(桌面机型 73/73、Win5 机型 73/73、修复回归 10/10):

| 场景 | 结果 |
|---|---|
| 空 `/etc` → 一次激活重建全部落点(sudoers 0440 副本,其余为 store 符号链接) | ✅ |
| 重复执行 → 文件集合与内容 **md5 零变化**;`--check` rc=0 | ✅ 幂等 |
| 半损(删 udev + 整个 inputplumber 目录)→ `--check` 精确列出缺失 → 激活精确补回 | ✅ |
| store 换代 / 回滚锚点 | ✅ |
| 所有链接解析后落在 `/nix/store` 内 | ✅ |
| **store 被 GC 掉** → 报错退出 + 给出修复指引 + **不破坏既有落点** | ✅ |
| 目标悬空链接 → 能识别、能自愈 | ✅ |
| 无写权限 → 非零退出(自愈单元可识别失败并重试) | ✅ |
| 字体 installPhase: 源目录**带空格** + `._*.ttf`/`.DS_Store`/`__MACOSX` 干扰 → 只捞出 6 个真 ttf | ✅ |
| 字体 installPhase 负例: 上游结构变化 → **报错退出**,不静默装空包 | ✅ |
| fontconfig 渲染: 族名/标签配对/alias 数量/`monospace` 不被污染 | ✅ |
| WorkBuddy 转发器: 有系统 wrapper 就 exec 它、**一个 electron 都不启动** | ✅ |
| WorkBuddy 转发器: 强制 nix 模式 → 用**系统** electron、且 `--no-sandbox` + `ELECTRON_DISABLE_SANDBOX=1` | ✅ |
| WorkBuddy 转发器: 系统 electron 也缺 → 才用 nix electron 兜底(同样禁 sandbox) | ✅ |
| 输入法端到端: Rime 配置含小鹤双拼、`default.yaml` 被删触发重部署 | ✅ |
| 输入法环境变量: **Wayland 只设 XMODIFIERS 并清掉 GTK/QT**(X11 才设全套) | ✅ |
| 输入法 kwinrc: 替换旧的 `InputMethod` 且**不追加重复段**、不破坏其它段 | ✅ |
| 输入法 unit: 同时挂桌面会话与 `gamescope-session.target`、读 gamescope 的 DISPLAY | ✅ |
| 输入法: 重复执行幂等;`--check` 只读不写文件;root 直跑被拒绝 | ✅ |

剩余 2 项在报告里已记录根因并给出补丁,补丁版本已通过回归测试的 10/10(见 `.selftest/`):

1. 链接 target 一度绕经 `~/.steamos-nix/etc-current`(指向 /home 的软链)而非 store 真路径
   → systemd/udev 在 /home 挂载前会读到 ENOENT。**已在 `nix/lib.nix` 修复**:
   `ln -sfn "$(readlink -f "$src_file")" "$tgt"`。副作用(已知):换代后必须重跑一次 activate,
   这一步由 install.sh 第 5 步与开机自愈覆盖。
2. 遍历用 `for x in $(find …)` 会把含空格的路径分词。**已修复**为 `while IFS= read -r`(临时文件 + trap 清理)。

第 3 轮(加字体和 LocalSend)又当场抓出并修掉 2 项:

3. **D9** —— 华为 zip 里 `._HarmonyOS_Sans_SC_Regular.ttf` 这类 AppleDouble 文件**也匹配
   `*.ttf`**,会被当字体装进 store → 已加 `! -name '._*'`,B11 用例守住。
4. **D10** —— `set -o pipefail` 是 bash 扩展,BusyBox ash 不支持,导致内部模式
   `--emit-fontconfig` 在沙盒里直接退出 → 渲染函数已移到 `set -euo pipefail` 之前。

## 8. 安全说明

- sudoers 只免密放行**一条命令**(激活器),且激活器只做"从 /nix/store 重链 /etc + reload"。
- 免密路径在 `/home` 下(稳定指针),信任模型与旧方案 `self-heal` 相同(单用户掌机/个人主机);
  若介意,可把 sudoers 改指 store 路径并放弃开机自愈的"免密"部分,只手动跑。
- **不要用 root 跑 `install.sh`** —— STATE 会漂到 `/root/.steamos-nix`,
  与 sudoers/heal unit 里的 deck 路径不一致,自愈会静默失效。脚本已有门禁主动拒绝。
- WPS / 微信是专有闭源二进制;本仓库只负责它们的取得与纳管,不修改其内部。
  LocalSend 是 MIT 开源(Flutter 源码构建),无此顾虑。
- **HarmonyOS Sans 是 `unfree` 且授权禁止单独再分发** —— 本仓库只在**你自己机器上**
  从华为官方地址下载、进你自己的 `/nix/store`;不要把它推到任何公共 binary cache,
  也不要把 `$out` 拷给他人。不想要就改 `cfg.cjkFont = "noto"`。
- 不导入任何旧 `.reg`/不触碰 OneDrive 已知文件夹 —— 本方案不写 `/home` 用户数据区以外的任何东西。
