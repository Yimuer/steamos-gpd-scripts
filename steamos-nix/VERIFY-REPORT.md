# steamos-nix 可行性 & 健壮性验证报告（第 5 版）

> 更新: 2026-09-16 · 执行环境: Windows 11 本机（静态审计）+ WSL2 docker-desktop 沙盒（动态演练）
> **未登录 SteamOS 真机**，因此 `nix flake check` / `nix build` 这类需要 nix 与网络的步骤没有执行；
> 但本报告把**与 nix 无关的绝大部分逻辑**用真实 Linux 环境跑了一遍。
> 字体与应用的**上游事实**（属性名、版本、license、字体族名）已联网逐项核实，不是推测。

## 0. 本轮改了什么

| 需求 | 实现 |
|---|---|
| 中文字体换成 Harmony Sans | nixpkgs 25.05 **没有** `harmonyos-sans` → 在 `nix/lib.nix` 自建 derivation，`fetchzip` 华为官方 zip，只取 `HarmonyOS_Sans_SC` 6 个字重 |
| 补装 LocalSend | `pkgs.localsend`（MIT，Flutter 源码构建）纳入 `steamos-apps` |
| **WorkBuddy 不要放在沙盒里** | ★ nix 改为只提供**转发器**：优先 exec 系统原生 `/usr/bin/workbuddy`，其次**系统** electron，nix electron 仅最后兜底；全程 `--no-sandbox` + `ELECTRON_DISABLE_SANDBOX=1`（详见 §3.4 与 README §3.4） |
| 上轮 8 项缺陷 | D1–D8 保持修复（回归仍在跑） |
| **输入法统一到 IBus + 小鹤双拼** | ★ SteamOS 自带 ibus；Steam 游戏模式只认 IBus D-Bus 通道，用 fcitx5 得装 AUR 桥接包。新增 `scripts/setup-ibus-xiaohe.sh`，桌面 + gamescope 两个会话共用（详见 §4.5） |
| 本轮新发现 | **D9 / D10 / D11 / D12**（见 §3）—— 都是测试当场抓出来的真 bug |

## 1. 结论速览

| 项 | 结果 |
|---|---|
| 静态可行性（A 组） | **117 / 117 通过**（字体 17 + LocalSend 8 + WorkBuddy 不进沙盒 14 + home-module 契约 5 + **输入法 20 项**） |
| 沙盒健壮性 · desktop 机型 | **73 / 73 通过** |
| 沙盒健壮性 · gpd-win5 机型 | **73 / 73 通过** |
| 修复回归 F 组 | **10 / 10 通过** |
| 本轮新缺陷 | D9 / D10 / D11 / D12 **已修复并转为 PASS** |
| 剩余未覆盖 | 真机 `nix build`（需 nix + 网络）、图形栈下的实际渲染、systemd/udev 早期挂载行为 |

**一句话**：核心机制（内容寻址 store + 一条命令重链 /etc）扎实；机型裁剪生效；
WPS / 微信 / LocalSend / 鸿蒙字体已纳管；**字体作为外部 FOD 已与应用解耦**；
**WorkBuddy 本体已移出 nix，只留一个系统原生优先的转发器**；
**输入法统一到 SteamOS 自带的 IBus + 小鹤双拼，桌面与 gamescope 两个会话共用**，
且**去掉了 fcitx5 那层 AUR 桥接**。
上真机后唯一需要自己跑的是 `nix build` 求值（§5）。

---

## 2. 验证方法

| 组 | 做什么 | 在哪跑 |
|---|---|---|
| A 静态（`.selftest/static-audit.py`） | 语法、路径引用、模板占位符、daemon 忠实性、python 依赖、GC root、免密链、机型裁剪闭环、D1–D8 修复在位、WPS/微信打包契约、**A15 字体契约（17 项）**、**A16 LocalSend 契约（8 项）** | 本机 Windows |
| B 动态（`.selftest/b-harness.sh`） | 激活器**脱插值提取**（`extract-activate.py` → `activate-test.sh`）跑 B1–B10 + B4x；**B11 字体 installPhase**（`extract-font.py` → `font-install-test.sh`）；**B12 fontconfig 渲染**；**B13 WorkBuddy 转发器**（`extract-workbuddy.py` → `workbuddy-test.sh`）；
**B14 输入法**（直接端到端跑 `scripts/setup-ibus-xiaohe.sh` —— 它刻意写成 POSIX sh，
所以在只有 busybox 的沙盒里也能真跑）。两种机型各跑一遍 | WSL2 `docker-desktop`（BusyBox 1.37 / Linux 6.18） |
| F 修复回归（`.selftest/b-fixcheck.sh`） | 对补丁版跑同一套场景 | 同上 |

> B11 / B12 用的是**从 `nix/lib.nix` 与 `install.sh` 里提取出来的真实代码**，
> 不是照抄一份到测试里 —— 改了实现，测试跟着变，不会出现"实现改了测试还绿"的假绿。

复现：

```bash
# A 组
python3 .selftest/static-audit.py

# B 组（Windows 上借 WSL；有 Linux 就直接 sh）
python3 .selftest/extract-activate.py desktop && python3 .selftest/extract-font.py
tar -cf - --exclude=.git . | wsl.exe -d docker-desktop -- /bin/sh -c \
  'rm -rf /tmp/steamos-nix && mkdir -p /tmp/steamos-nix && cd /tmp/steamos-nix && tar -xf - \
   && sh .selftest/b-harness.sh && STEAMOS_NIX_MACHINE=gpd-win5 sh .selftest/b-harness.sh'
```

---

## 3. 本轮新发现的缺陷

| ID | 级别 | 现象 | 根因 | 修复 | 回归断言 |
|---|---|---|---|---|---|
| **D9** 字体目录混入 AppleDouble | P1 | 华为 zip 是 macOS 打的，里面每个 ttf 都伴随一个 `._HarmonyOS_Sans_SC_Regular.ttf`。**它也匹配 `-name '*.ttf'`**，会被当字体 `install` 进 `$out`，fontconfig 扫到 0 字节的假 ttf 会告警甚至让该 family 不可用 | 只按扩展名过滤 | `nix/lib.nix`：`-name '*.ttf' ! -name '._*'` | **B11**（造了 `._*` / `.DS_Store` / `__MACOSX` 干扰项，断言捞出恰好 6 个、干扰文件 0 个）+ A15 |
| **D10** `--emit-fontconfig` 在 ash 下直接退出 | P2 | 沙盒里 `sh install.sh --emit-fontconfig` 输出为空 | `set -euo pipefail` 里 **`pipefail` 是 bash 扩展**，BusyBox ash 不支持 → 脚本在打印任何东西之前就退了 | 把 `emit_fontconfig()` 与分派**移到 `set -euo pipefail` 之前**（纯输出、无副作用，放前面无害） | **B12** + A15（断言函数定义在 `set -euo pipefail` 行之前，用行首匹配避免命中注释） |

> 顺带一个测试自身的坑：A15 里 `install.index("set -euo pipefail")` 一开始命中了**注释里**
> 的同一串文字，产生假 FAIL。已改为 `^set -euo pipefail` 行首匹配。

### D11：home-manager 路径求值会失败（上一轮埋的）

| ID | 级别 | 现象 | 根因 | 修复 | 回归断言 |
|---|---|---|---|---|---|
| **D11** `home-module.nix` 少传 cfg 键 | **P0**（对 home-manager 用户） | 上一轮给 `lib.nix` 加了 `cfg.cjkFont` / `cfg.harmonySansHash`，但 `home-module.nix` 的 `cfg` 没有同步 → `lib.nix` 里 `cfg.cjkFont` 直接取值（没有 `or` 兜底），home-manager 路径**求值阶段就炸** | 加 cfg 键时只改了 `flake.nix`，漏了 `home-module.nix` | `home-module.nix` 补齐 `machine` / `installApps` / `wpsChinese` / `cjkFont` / `harmonySansHash`，并给它们加 `lib.mkOption`（`machine` 与 `cjkFont` 用 `types.enum` 挡非法值） | **A18**（逐个键检查"传值 + 声明"都在位） |

> A18 当场又抓到我补键时**手滑删掉了原有的 `ntpServers = cfg.ntpServers;`** ——
> 这就是自动化的价值，肉眼 diff 很容易漏。

### D12：旧输入法脚本在 Wayland 下无差别强设 GTK/QT_IM_MODULE

| ID | 级别 | 现象 | 根因 | 修复 | 回归断言 |
|---|---|---|---|---|---|
| **D12** Wayland 下强设 `GTK_IM_MODULE` / `QT_IM_MODULE` | P1（对"打不出中文"这个症状） | 旧的 `setup-fcitx5-flypy.sh` 往 `~/.config/environment.d/fcitx5.conf` 里无条件写 `GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx`，Wayland 会话也一样 | Wayland 下 **KWin 自己拉起输入法**（`kwinrc [Wayland] InputMethod`），再强设这两个变量会让程序**改走 XWayland 的 IM 模块** —— 结果候选框不跟随，甚至完全发不出中文。IBus 官方也明确要求配置 Wayland 输入法前先 unset 这两个变量 | 新的 `setup-ibus-xiaohe.sh` 按 `$XDG_SESSION_TYPE` 分叉：Wayland **只设 `XMODIFIERS` 并 `unset` 掉 GTK/QT**；X11/XWayland 才设全套。`lib.nix` 里 workbuddy 转发器用同一套判断 | **B14**（四种组合：wayland / wayland+预设值 / x11 / --check）+ **A19**（断言 `unset GTK_IM_MODULE` 与 `= wayland` 分支都在） |

---

---

## 3.4 WorkBuddy：为什么不进 nix（本轮重点）

`/nix/store` 是**只读**的。把 Electron 应用纳管进去，等于关进沙盒：

| 功能 | 为什么在 nix 里会挂 |
|---|---|
| 自动更新 | store 只读，写不了自己的安装目录 |
| dsh / MCP 插件安装 | 插件要写进应用目录（`node_modules/.ignored/...`） |
| native 模块（`.node`） | **nix 的 electron ABI 与 app 自带原生模块对不上** → 加载失败 |
| fcitx5 / Rime 中文输入 | 看不到系统输入法模块路径（`GTK_IM_MODULE` / `XMODIFIERS`） |
| 文件对话框 / 截屏 | 缺 `xdg-desktop-portal` |
| 通知 / 托盘 | 缺系统 dbus |

**改前**（这就是那个"沙盒"）：

```nix
workbuddyElectron = pkgs.electron;    # ← 用 nix 的 electron 去启动 /opt/workbuddy 的 app.asar
```

**改后** —— nix 只提供转发器，本体留在系统里：

```
workbuddy（转发器，在 ~/.nix-profile，升级幸存）
   ├─ ① /usr/bin/workbuddy 存在且是真实文件 → exec 它        ← 正常态，功能完整
   ├─ ② 被原子升级冲掉了 → 用**系统** electron 启动 /opt 的 payload
   └─ ③ 系统 electron 也没有 → 才用 nix electron 兜底（会告警）
```

配套改动：系统路径排在 `runtimePath` **之前**；追加 `/usr/lib` 到 `LD_LIBRARY_PATH`
（给 native `.node` 用，且不覆盖已有值）；输入法不写死，系统已设就尊重、全空才补 fcitx5；
无论走哪条分支都带 `--no-sandbox --disable-setuid-sandbox` + `ELECTRON_DISABLE_SANDBOX=1`。

强制指定：`STEAMOS_NIX_WORKBUDDY=system|nix`。

`install.sh` 的态度也反过来了：**系统里有 `/usr/bin/workbuddy` 是好事，不是冲突**。
原来那两行"nix 版走 ~/.nix-profile、建议移除 AUR 包"的警告已删除。

---

## 3.5 输入法：统一 IBus + 小鹤双拼（本轮重点）

### 为什么是 IBus，不是 fcitx5

| 理由 | 依据 |
|---|---|
| SteamOS 自带 | 不用额外装框架 |
| **游戏模式原生就是 IBus** | 仓库里 `setup-steam-game-mode-ime.sh` 的注释自己就写了：Steam 客户端在 gamescope 下通过 **IBus D-Bus 协议** 跟输入法通信（会话 target 里的 `ibus-gamescope.service`）。用 fcitx5 得装 AUR 桥接包 `fcitx5-steam-ibus-frontend` 去冒充 IBus —— 多一层就多一处坏点 |
| 避免冲突 | 两套框架并存会抢 DBus 名与 GTK/QT IM 模块 |

**联网核实过的外部事实**：

| 项 | 结论 |
|---|---|
| IBus + Rime 的组合 | ArchWiki：IBus 用 `ibus-rime`；Rime 配置目录为 `~/.config/ibus/rime` |
| 小鹤双拼的 schema id | `double_pinyin_flypy`，由 Arch **extra** 仓库的 `rime-double-pinyin` 提供（`/usr/share/rime-data/double_pinyin_flypy.schema.yaml`） |
| 重新部署的方式 | `rm ~/.config/ibus/rime/default.yaml && ibus-daemon -drx` —— **不删 `default.yaml` 不会重算** |
| KDE Wayland 的输入法选择 | 存在 `~/.config/kwinrc`，键为 `[Wayland] InputMethod`，值是 `/usr/share/applications/` 下带 `X-KDE-Wayland-VirtualKeyboard=true` 的 desktop 文件（实测名 `org.freedesktop.IBus.Panel.Wayland.Gtk3.desktop`）→ **用探测而不是硬编码** |
| ⚠️ Wayland 下的环境变量 | IBus 官方建议：配置 Wayland 输入法前必须 **unset** `QT_IM_MODULE` / `GTK_IM_MODULE`，只留 `XMODIFIERS`。强设会让程序走 XWayland 的 IM 模块 → 候选框不跟随 |

### 两个会话怎么覆盖

| 会话 | 机制 | 落点 |
|---|---|---|
| KDE 桌面（Plasma Wayland） | KWin 拉起输入法 | `~/.config/kwinrc` 的 `[Wayland] InputMethod` + `~/.config/plasma-workspace/env/90-steamos-nix-ime.sh` |
| 游戏模式（gamescope） | Steam 走 IBus D-Bus，只要守护进程在 | `~/.config/systemd/user/ibus-daemon.service`，`WantedBy=graphical-session.target gamescope-session.target`，靠 `EnvironmentFile=-%t/gamescope-environment` 拿 DISPLAY |

两者**共用同一个 `ibus-daemon` 和同一份 Rime 配置** —— 小鹤双拼两边一致，不需要分别配置。

`nix` 的边界不变：ibus 服务二进制仍归 pacman（深度系统会话集成），**nix 只管配置层**
（脚本在 store 里，落点在 `/home`）。这与 README 里"诚实边界"那条一致。

### fcitx5 退场

- `scripts/setup-fcitx5-flypy.sh` → 已废弃，直接运行会退出并指向新脚本。
- `scripts/setup-steam-game-mode-ime.sh` → 重写为只做检查，不再装 AUR 桥接包。
- `setup-ibus-xiaohe.sh` 会主动扫描 fcitx5 残留（environment.d / autostart / config 目录 /
  旧 unit / 运行中进程），给出清理命令但**不擅自删除**。

---

## 4. HarmonyOS Sans：事实核查结论

**nixpkgs 25.05 里没有这个包**，这是本轮最主要的外部确认：

| 核查项 | 结论 |
|---|---|
| `pkgs/by-name/ha/harmonyos-sans` @ nixos-25.05 | **HTTP 404**（不存在） |
| `pkgs/by-name/lo/localsend` @ nixos-25.05 | **存在**（`package.nix` + `pubspec.lock.json` + `update.sh`） |
| 社区版本 | 只有 NUR / 第三方 overlay（`nur-combined/repos/guanran928/pkgs/harmonyos-sans`） |

因此自建 derivation，并对上游做了实测：

| 项 | 实测值 |
|---|---|
| 下载地址 | `https://developer.huawei.com/images/download/general/HarmonyOS-Sans.zip` |
| 可达性 | **HTTP 200**，`application/zip`，**52,165,952 字节** |
| zip sha256 | `fb02c86e358cd9aad8d4dfa957ee502381e7ee2e94499a9133add4324b6ce69a` |
| 顶层目录 | `HarmonyOS Sans/`（**名字里有空格**）+ `__MACOSX/` |
| 子族 | `HarmonyOS_Sans_SC` / `_TC` / `_(多语种)` / `_Italic` / `_Condensed` / `_Naskh_Arabic`… |
| 取用 | `HarmonyOS_Sans_SC/` 的 6 个字重：Thin / Light / Regular / Medium / Bold / Black |
| **字体族名（从 ttf name 表读出）** | `HarmonyOS Sans SC`（postscript `HarmonyOS_Sans_SC`）<br>`HarmonyOS Sans`（多语种版）<br>`HarmonyOS Sans TC` |
| license | `unfree` —— 华为授权可随产品嵌入、**不可单独再分发** |

> 族名是**解析 ttf 的 `name` 表**得到的，不是照抄文档。fontconfig 的 `<prefer>` 必须写
> `HarmonyOS Sans SC`，写成 `HarmonyOS Sans` 会命中不到 SC 变体。

**FOD hash 的风险与对策（本轮最重要的设计决定）**：

`fetchzip` 是 fixed-output derivation，hash 必须与解包结果逐字节一致。
`flake.nix` 里填的是社区记录值 `sha256-c10AIlce3WSqzKI9cq9LoobRJHgbqnzBo/d958Acz/A=`
（与 NUR 表达式同 URL、同 `stripRoot = false`，理论上可复用），但**无法离线验证**。
所以做了三层兜底：

1. **解耦** —— `steamos-apps` 里**故意不含字体**，字体是独立 attr。hash 不对 → 只字体失败，
   WPS / 微信 / LocalSend 照装（A15 有断言钉死这个不变量）。
2. **降级** —— `install.sh` 单独构建字体，失败只 `warn`，并在检测到 `hash mismatch` 时
   打印可执行的两遍法指引；`verify.sh` 里字体构建失败也只 `note` 不计 FAIL。
3. **开关** —— `cfg.cjkFont = "harmony-sans" | "noto" | "none"`，改 `"noto"` 立刻绕开
   外部 FOD（用 Noto CJK + 文泉驿）。

---

## 5. LocalSend：事实核查结论

| 项 | nixpkgs 25.05 实测值 |
|---|---|
| 属性 | `pkgs.localsend`（`pkgs/by-name/lo/localsend`） |
| 版本 | 1.17.0 |
| license | **MIT**（不是 Apache，**不 unfree**） |
| 打包 | `flutter324.buildFlutterApplication`，GitHub tag 拉源码 |
| `mainProgram` | **`localsend_app`**（不是 `localsend`；那是 darwin 版的 bin） |
| 桌面入口 | 自带 `LocalSend.desktop`（`Exec=localsend_app %U`，icon `localsend`）+ hicolor 32/128/256/512 图标 → `install.sh` 的 `.desktop` 循环自动接管 |
| 网络 | **53317/tcp**（传输）+ **53317/udp**（组播发现）。SteamOS `firewalld` 默认拦截，表现为"能打开但搜不到对端" |
| x11 变体 | `localsend_app-x11`，用 `GDK_BACKEND=x11`（GTK/Flutter 语义，不是 Qt 的 `QT_QPA_PLATFORM`） |

放端口：

```bash
sudo firewall-cmd --permanent --add-port=53317/tcp --add-port=53317/udp && sudo firewall-cmd --reload
```

---

## 6. 机型裁剪：生效证据（本轮复测）

| 机型 | /etc 落点 | 符号链接 | 背键 unit | inputplumber |
|---|---|---|---|---|
| `desktop` | **2**（ntp.conf + sudoers） | 1（sudoers 是 0440 副本） | 不存在 ✅ | 不存在 ✅ |
| `gpd-win5` | **6** | 5 | 存在 ✅ | 存在 ✅ |

9800X3D + 7900XTX 的台式机没有内置电池，会稳定落到 `desktop`
（判定链：`STEAMOS_NIX_MACHINE` → DMI `GPD`+`G1618-05` → 背键 HID `2F24:0137` → DMI `Valve` → 电池 → desktop）。

---

## 7. 通过项明细（节选）

**静态 79 项全绿**，本轮新增的重点：

- ★ `steamos-apps` 的 `paths = [ wps-office wechat localsend ]` —— **不含字体**（解耦不变量）
- ★ `installPhase` 有 `! -name '._*'`（D9 回归）
- ★ `emit_fontconfig()` 定义在 `set -euo pipefail` **之前**（D10 回归）
- 字体族名三处一致：`lib.nix` 的 `cjkFontFamily` / `install.sh` 的映射 / B12 的期望值
- `prefer` 只覆盖 `sans-serif` + `serif`，**不污染 `monospace`**
- `cfg.harmonySansHash` 填的是真 hash（非 `fakeSha256`）
- `mkX11VariantFor` 参数化了 env：WPS/微信走 `QT_QPA_PLATFORM=xcb`，LocalSend 走 `GDK_BACKEND=x11`

**沙盒 73+73 项全绿**，本轮新增：

| 用例 | 覆盖 |
|---|---|
| **B11** 字体 installPhase | 源目录**带空格**；造了 `._*.ttf` / `.DS_Store` / `__MACOSX/` / `HarmonyOS_Sans_TC` 诱饵；断言恰好捞出 6 个、干扰 0 个、权限 0644、只捞 SC；**负例**：SC 目录消失时必须报错退出而不是静默装空包 |
| **B12** fontconfig 渲染 | `<dir>` 指向 store 真路径；族名 `HarmonyOS Sans SC`；根标签配对且唯一；恰好 2 组 alias；不含 `monospace`；`cjkFont=noto` → Noto 兜底；`cjkFont=none` → 不写 alias |
| **B14** 输入法端到端（20 项） | **直接跑 `scripts/setup-ibus-xiaohe.sh` 本体**（它是 POSIX sh，busybox 也能跑）。覆盖：Rime 配置含 `double_pinyin_flypy` 且为默认、`default.yaml` 被删以触发重部署；环境变量四种组合（wayland 只设 `XMODIFIERS` 且清掉 GTK/QT、wayland 下预设值也被清、x11 设全套）；kwinrc 是**替换**旧 `InputMethod` 而非追加重复段、且其它段未被破坏；unit 同时挂两个 target、读 `gamescope-environment`、有 `StartLimitBurst`、启的是 `ibus-daemon` 而非 fcitx5 桥接；重复执行幂等；`--check` 只读；root 直跑被拒绝 |
| **B13** WorkBuddy 转发器（13 项） | 有系统 wrapper → **exec 它且一个 electron 都不启动**、参数透传；`STEAMOS_NIX_WORKBUDDY=nix` → 跳过系统 wrapper、用**系统** electron、带 `--no-sandbox --disable-setuid-sandbox`、`ELECTRON_DISABLE_SANDBOX=1`、追加系统库路径、IME flags 仍在；系统 electron 缺失 → nix electron 兜底且同样禁 sandbox；无 payload → 报错退出并提示安装 |

原有 33 项（空 /etc 重建、幂等 md5 零变化、半损精确补回、store 换代与回滚、链接直指 store、
store 被 GC 时报错且不破坏既有落点、悬空链接自愈、无写权限非零退出、含空格路径）**仍全绿**。

---

## 8. 上机要执行的命令

```bash
# 1) 机型判定（9800X3D 台式机应显示 desktop）
bash scripts/steamos-nix-detect.sh

# 2) 安装（用 deck 用户，不要 sudo —— 脚本有门禁）
bash install.sh

# 3) 字体 hash（最可能需要你手动补一次）
nix build .#steamos-cjk-fonts     # 若报 hash mismatch, 把 "got:" 的串填回 flake.nix 的 cfg.harmonySansHash
fc-match "HarmonyOS Sans SC"      # 应解析到 /nix/store/...-harmonyos-sans-sc/...
fc-match sans-serif:lang=zh-cn    # 应命中 HarmonyOS Sans SC

# 4) GC root 必须在（这条最关键）
nix store gc --print-roots | grep steamos-etc

# 5) 真机组验证
bash verify.sh

# 6) 应用
wps              # 或 wpp / et / wpspdf；Wayland 下异常换 wps-x11
wechat           # 或 wechat-x11
localsend_app    # 需要先放行 53317/tcp+udp

# 7) WorkBuddy：确认走的是系统原生版，而不是被塞进 nix
ls -l /usr/bin/workbuddy                # 应存在且是真实文件 → 转发器会直接 exec 它
command -v workbuddy                    # 应是 nix 转发器（~/.nix-profile/bin/workbuddy）
yay -S workbuddy                        # 若 /usr/bin/workbuddy 不存在，先装回系统原生版

# 8) 输入法：IBus + 小鹤双拼（桌面 + 游戏模式）
sudo pacman -S ibus-rime librime rime-double-pinyin
sh scripts/setup-ibus-xiaohe.sh --install
sh scripts/setup-ibus-xiaohe.sh --check   # 体检，应全绿
#  注销重登后：Super+Space 切中英；Ctrl+` 或 F4 开方案选单（小鹤双拼应在第一项）
#  游戏模式：STEAM+X 呼出键盘 → 左下角切到中文
```

## 9. 残余风险

| 风险 | 级别 | 说明 | 对策 |
|---|---|---|---|
| **字体 FOD hash 不匹配** | 中 | 无法离线验证 nix 解包后的 NAR hash | 解耦 + 降级 + `cfg.cjkFont="noto"` 三条兜底（§4） |
| 上游 zip 下线 / 结构变化 | 低 | 华为改地址或改目录结构 | `installPhase` 捞不到 ttf 会**报错退出**（B11 负例覆盖），不会静默装空包；改 `cfg.cjkFont="noto"` 绕开 |
| 华为字体授权 | — | 可嵌入、**不可单独再分发** | 只在本机下载进自己的 store；**不要推公共 binary cache**，不要拷 `$out` 给他人（已写进 README §8） |
| LocalSend 搜不到对端 | 低 | firewalld 默认拦 53317 | README §3.1 + `verify.sh` 会主动检测并提示 |
| WorkBuddy 退到 nix electron 兜底 | 低 | `/usr/bin/workbuddy` 与系统 electron 都没了（刚做过原子升级且没装 AUR 包） | 转发器会打印降级告警；`install.sh` 提示 `yay -S workbuddy`；`verify.sh` C 组会 note |
| WorkBuddy 中文仍打不出 | 低 | 输入法没配好 / IME 环境变量被别处覆盖 | 转发器只在 `GTK_IM_MODULE`/`QT_IM_MODULE`/`XMODIFIERS` **全空**时才补 IBus，不抢已有配置；Wayland 下只补 `XMODIFIERS`；先跑 `setup-ibus-xiaohe.sh --check` |
| 游戏模式搜不到中文候选 | 中 | `ibus-daemon` 没在跑，或残留的 `fcitx5-steam-ibus.service` 在抢 DBus 名 | `systemctl --user status ibus-daemon.service`；`setup-steam-game-mode-ime.sh` 会检测旧 fcitx5 unit 并提示停掉 |
| Wayland 下候选框不跟随 | 中 | 别处（如旧 fcitx5 配置）仍在 export `GTK_IM_MODULE`/`QT_IM_MODULE` | 新 env 片段在 Wayland 下会主动 `unset` 这两个；检查 `~/.config/environment.d/*.conf` 里的遗留 |
| `rime-double-pinyin` 装不上 | 低 | SteamOS 仓库里可能没有 | 备选：`ibus-libpinyin` 也内置小鹤双拼，但配置走 gsettings，不如 Rime 好版本化；或开 archlinuxcn |
| WPS/微信首次必联网 | 低 | `hydraPlatforms = []`，本机直连上游 CDN | 挂代理；或换 `cfg` 关掉 apps |
| 属性改名/下线 | 低 | 换 channel 后 `wpsoffice`/`wechat`/`localsend` 可能变 | 全部 `pkgs.X or null` + `filterAttrs` 过滤，不会让 `nix flake show` 整体失败 |

## 10. 本次未覆盖

| 未覆盖 | 原因 | 建议 |
|---|---|---|
| `nix flake show` / `nix build` 能否求值 | 本机无 nix | 上机跑 `verify.sh` |
| 字体 FOD 的真实 hash | 需要 nix 解包后算 NAR hash | 见 §8 第 3 步两遍法 |
| WPS/微信/LocalSend 能否真的启动（Qt/GTK/字体/IME） | 沙盒无图形栈 | 上机跑，异常换 `-x11` 变体 |
| WorkBuddy 自更新 / dsh 插件安装 / 中文输入是否真的恢复 | 沙盒无图形栈、无 fcitx5 | 上机确认 `/usr/bin/workbuddy` 存在（`yay -S workbuddy`），再试中文输入与插件安装 |
| 游戏模式（gamescope）里小鹤双拼能否真的打出中文 | 沙盒无 Steam、无 gamescope | 上机切到游戏模式，STEAM+X 呼出键盘实测；`systemctl --user status ibus-daemon.service` |
| kwinrc 写入后 KDE 是否真的拉起 IBus | 沙盒无 KWin | 上机「系统设置 → 键盘 → 虚拟键盘」应显示已选中 IBus Wayland |
| systemd/udev 早期是否读得到 store 直链 | WSL 无 systemd | 上机 `reboot` 后 `systemctl status` / `udevadm info`（Win5） |
