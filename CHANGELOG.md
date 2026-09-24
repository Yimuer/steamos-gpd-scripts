# CHANGELOG — steamos-reinstall-backup

遵循语义化版本：`主版本.次版本.修订号`
- 主版本：步骤结构/目标环境变化（不保证旧机器直接复用）
- 次版本：新增步骤或功能
- 修订号：bug 修复与健壮性加固
每次提交后打标签 `vX.Y.Z`；`bash check.sh` 全绿才允许提交（pre-commit 钩子强制）。

## [3.2.0] - 2026-09-24

### 发布前专业审查 + 优化(可行性 / 静态 / 健壮性)

#### 可行性(实测外部依赖, 抓到 3 个真问题)
- **WPS 取源已过时**: 官方现行中文版是 **12.1.2.28080(545MB / 装后 2.07GB)**, 且改成了
  「`Linux2023` 通道 + 时间戳签名」(`?t=<ts>&k=md5(key+uri+ts)`); 原来硬编码的
  11.1.0.11723 静态 URL 只剩 2022 年的旧版本。→ 脚本改为**按官方签名方案构造 URL**,
  老通道降级为兜底; 实测签名 URL 200 / 老通道对 12.x 403。新版本 control 仍是
  `Relocations: /opt/kingsoft` → /opt 设计继续成立。
- **AUR 的 `wps-office-cn`(12.1.2) 与 `wps-office` 都把 office6 重定位到 `/usr/lib`**
  (2GB 进 5G rootfs) → 确认走官方 deb 到 /opt 是唯一可行解。
- **`ghfast.top` / `ghproxy.net` 对 `api.github.com` 一律 403**(它们只代理下载路径)
  → 脚本里的"API 镜像链"删掉死条目, 只留实测可用的 `gh-proxy.com`。
- **archlinuxcn 里已没有任何微信包**(下载 db 逐项确认 4683 个包) → 可选包的微信条目
  在纯仓库环境下必然失败。→ `install_wechat` 增加 **AUR 回退**(yay/paru), 并明确提示
  "这条路装进 /usr, 升级会被冲"。
- 其余端点(各 release API / Mozilla Nightly / LocalSend / dsh AppImage / wiliwili flatpak /
  AUR workbuddy)全部实测可用。

#### 新增 `verify-upstreams.sh` —— 上游依赖体检(只读)
把上面这套人工核查固化成工具: 重装前/发布前跑一次, 一次看清所有外部依赖是否还活着。
会区分「下载路径」与「API 路径」(后者很多镜像不代理), GitHub 资源按脚本真实的
"镜像优先"顺序判定, 避免把"本机直连 github 不通"误报成关键失败。

#### 静态审查(shellcheck 13 warning → **0**)
- **修掉 2 处高危 `rm -rf "$VAR/..."`**(SC2115): `install-decky-tdp.sh` 卸载路径、
  `install-ge-proton.sh` 的 `$TAG` 可为空(会删掉整个 compatibilitytools.d)
  → 全部加 `${VAR:?}` 守卫。
- `install-ge-proton.sh`: 509MB 下载原来落在 `mktemp -d /tmp/...`(/tmp 是 tmpfs 吃内存,
  且随机名让 `-C -` 续传永远失效 —— 与仓库自己记录的教训矛盾)→ 改固定缓存目录。
  同类问题 `install-decky-tdp.sh` 一并改为固定缓存名。
- `install-firefox-nightly-home.sh`: 删无用变量; 图标兜底的 `find | xargs` 改 `-exec {} +`
  (路径含空格会拆错)。
- `check.sh`: `cd` 补 `|| exit`; **shellcheck 检查扩到全部脚本**(原来只查主脚本),
  并真的去 `tools/shellcheck(.exe)` 找(原来只在提示文字里提, 代码里没实现)。
- 零碎: `可选组件安装.sh` 三处 `local x="$(...)"` 拆开(SC2155)、`diag-black-screen.sh`
  无用变量与重定向位置、`install-decky-loader.sh` 的 `ls|grep` 改 glob、
  `steamos-setup.sh` 的 `GAME_DIR` 默认值不再硬编码 `/home/deck`。
- 未用 `--ssl-no-revoke` 之类的平台专属参数, 保持脚本在 SteamOS 上原样可用。

#### 健壮性
- WPS 本体改为**准原子替换 + 回滚**(旧树先 mv 成 `.prev`, 新版校验通过再删; 失败回滚),
  并加**版本标记** → 重跑不再白复制 2GB(升级后最常见的场景其实只需补 /home 侧入口)。
- 抽出公共函数 `gh_latest_tag()`(带镜像兜底), wiliwili 与 LocalSend 两处版本查询改为调用它
  (原来各自写一遍且**都没有镜像兜底**)。

#### 未做(有意留下, 见 SCRIPT-MAINTENANCE §9 的取舍说明)
- 4 个 `install-*-home.sh` 之间有约 120 行/份的重复铺垫(颜色/提权/镜像/入口/桌面项)。
  抽公共库能省约 480 行, 但会破坏"单个脚本可独立拷贝到新机器"这一核心价值, 故暂不动。

## [3.1.0] - 2026-09-24

### 新增: 可选组件 —— WPS Office 中文版装到 /opt + /home
- 新增 `install-wps-office-home.sh`(官方中文版 deb, 304MB)。
- **为什么走官方 deb 不走 AUR 的 wps-office**: 用 range 请求只取 deb 头部解 ar+control
  拿到权威事实 —— 该 deb 自己写着 `Relocations: /opt/kingsoft`、
  `Installed-Size: 1630564 KB`(≈1.55GB)。而 AUR 的 PKGBUILD 在 prepare() 里
  `sed 's|/opt/kingsoft/wps-office|/usr/lib|'` 把它重定位到 `/usr/lib/office6`(rootfs 5G)
  → 必 ENOSPC。按官方布局装才既不占 rootfs 又扛原子升级。
- 权威依赖清单(同一次读取得到): `libc6, libstdc++6, libfreetype6, libcups2,
  libglib2.0-0, libglu1-mesa, libsm6, libxrender1, libfontconfig1, libxext6,
  libxcb1, libbz2-1.0` → 映射为 Arch 名后只补缺的(实测 `glu` 是最可能缺的那个)。
- **只写 /opt 与 ~/.local, 不写 /usr** → 不需要 `steamos-readonly disable`
  (`/opt` 本身就是 rw 的独立挂载)。
- /home 自持化: 官方包装脚本副本 + `WPS_X11` 薄壳入口、桌面项(**Exec 与 TryExec
  都改绝对路径** —— TryExec 找不到会让菜单项直接不显示)、图标(apps/ 与 mimetypes/ 两处)、
  自定义 mime 注册(用户级 `update-mime-database`)。
- 复刻官方 preinst 的进程守卫: 检测到 WPS 在跑就拒绝替换。
- `可选组件安装.sh` 接入 `wps-office` 条目(`MENU_CHECK` 判据 = 入口 + /opt 本体)。
- `check.sh` 断言 2.10: 脚本存在 + 语法 + **本体必须装 /opt/kingsoft** +
  **代码里不得出现 AUR 的 /usr/lib/office6 布局**(注释里提到不算) + Exec/TryExec 改写 + 菜单已接入。

## [3.0.0] - 2026-09-24

### 新增: 步骤[14] LocalSend(局域网传文件) —— 主版本号升级: 步骤结构 13→14
- `setup_localsend()`: 取官方 **AppImage** 解到 `~/.local/opt/localsend/`, 不占 rootfs、
  原子升级幸存。入口与 dsh 桌面版同思路(有 libfuse2 直跑 AppImage, 否则跑解压树)。
- **为什么不取 tar.gz**: 官方 tar.gz 顶层只有 `data/ lib/ localsend_app`(纯 Flutter 便携包),
  没有 .desktop / hicolor 图标, 且 `lib/libflutter_linux_gtk.so`(43M) 动态依赖**系统 gtk3** ——
  SteamOS 上不一定有, 有也是往 rootfs 塞。AppImage 自带 GTK 运行时, 零系统依赖。
- **防火墙是本步不可分割的一半** —— 装好了"搜不到对端"不是装失败:
  LocalSend 用 53317/tcp(传输)+53317/udp(组播发现), SteamOS 默认 `firewalld` 会挡。
  本步幂等放行(`firewall-cmd --permanent --add-port=... + --reload`)。
- **自愈联动(关键)**: 防火墙规则落在 `/etc/firewalld`(原子升级必被冲)。故
  `self-heal-after-upgrade.sh` 的 CHECKS 新增 **`fwport`** 判据类型 + 一条挂到步骤 14 的条目;
  `verify_step(setup_localsend)` 也是**双判据**(程序在 /home + 53317 已放行),
  否则升级后会"程序还在但搜不到对端"却被误判完好而跳过重建。
- 图标兜底按实测加了一条: 包内无 FHS 图标时用 `data/flutter_assets/assets/img/logo-512.png`。
- 全链路接入(照 [13] 的清单): 头部注释 / show_help 两处 / step_label / verify_step /
  map_step(`14|localsend|ls|传文件|lanshare`) / 两处 FUNCS / check.sh 断言。
- 顺手修正: `[13/13]`→`[13/14]`、`[3/7]`→`[3/14]`(总数变了);
  README 步骤列表原本停在 12(13 那轮漏了), 已补 13/14;
  SCRIPT-MAINTENANCE 的步骤表原本停在 11, 已补 12/13/14 并加进"升级后命运表"。
- `check.sh` 新增断言 2.9: 函数 / map_step / **自愈 fwport 项挂到步骤 14** / 自愈盯住 53317 /
  取的是 AppImage 而非 tar.gz。

## [2.2.0] - 2026-09-24

### 新增: 可选组件 —— DeepSeek Harness 桌面版装进 /home
- 新增 `install-dsh-desktop-home.sh`(上游 dsh-tauri/deepseek-harness-desktop, Tauri 版)。
- **刻意取 AppImage 而非 deb**: 实测官方 v0.17.0 的 deb `Depends: libappindicator3-1,
  libwebkit2gtk-4.1-0, libgtk-3-0` —— SteamOS 全没有, 装进 `/usr` 要几百 MB rootfs
  且原子升级后被冲; AppImage(90M) 自带这些运行时, 解到 `/home` 永久幸存。
- 布局: `~/.local/opt/deepseek-harness-desktop/{AppImage 原文件, app/ 解压树}`;
  入口自动在"FUSE 直跑"(应用内自更新可替换自身)与"解压树兜底"间选择 ——
  后者不需要 `fuse2` 系统包, 等于零系统依赖。
- 版本解析走 GitHub API(直连+镜像), 资产清单里带 size, 缓存完整性按 size 校验;
  下载多镜像择优 + `-C -` 续传(直连实测 1.8KB/s, ghfast ~96KB/s); 原子替换 + `.prev`。
- **内核版本差异会被明确打出**: 包内 `resources/version-recommend.json` 声明
  v0.17.0 需 dsh >= 0.1.5-rc.3, 而本包 step[7] 固定 0.1.2-rc.1,
  且上游"如已装 dsh 则优先用安装版本" → 脚本做语义化版本比较并给出两条处置路径。
- 装前把 `~/.local/bin/dsh` 备份为 `dsh.predshbak`(桌面版可能注册自己的 CLI shim)。
- `可选组件安装.sh` 接入 `dsh-desktop` 条目(薄封装, `MENU_CHECK` 用 AppRun 判据)。
- `check.sh` 断言 2.8: 脚本存在 + 语法 + 安装目标在 `/home` + **取的是 AppImage 资产** + 菜单已接入。
- 文档: README(可选组件段 + 备用脚本段)、SCRIPT-MAINTENANCE(1.2 表 + 3.10 新增
  「选哪种发行物(deb/AppImage/官方 tar)」判据 —— 先把 deb 的 Depends 拉出来看)。


## [2.1.0] - 2026-09-24

### 新增: 可选组件 —— Firefox Nightly 装进 /home (无沙箱 + 扛原子升级)
- 新增 `install-firefox-nightly-home.sh`: 用 Mozilla 官方 tar.xz 解到
  `~/.local/opt/firefox-nightly/`, 与 pacman、`/usr` 解耦 → 原子升级后零操作可用。
  - 不占 rootfs; 反过来可回收系统 `firefox` 的约 290M(`--remove-system`)。
  - 目录在用户可写下 → Nightly 自带更新器能真正自更新(装 `/usr` 时被禁用)。
  - 无 bubblewrap 沙箱(flatpak 版连 `~/下载`、本地服务都受限)。
  - 入口 wrapper 在 `WAYLAND_DISPLAY` 存在时自动 `MOZ_ENABLE_WAYLAND=1`。
  - 原子替换 + `.prev` 回滚位; 版本与语言都没变则跳过重装(`--force` 可强制)。
  - 多源下载: 默认 `archive.mozilla.org`(实测同一文件比官方 cdn 快一两个数量级),
    失败自动回退官方地址; `FFN_MIRROR=` 可自备镜像。
- `可选组件安装.sh` 扩展: 注册表新增 **`MENU_CHECK`**(自定义"是否已装"判据),
  非 pacman 安装的项(解包官方便携包)菜单 ✓ 标记才能正确显示;
  接入 `firefox-nightly` 条目(薄封装上述脚本, 保持"一处实现");
  脚本顶部补 `REAL_USER/REAL_HOME` 解析(root 跑时能定位真用户家目录)。
- `check.sh` 新增断言 2.7: 脚本存在 + 语法 + **安装目标必须在 `/home` 下** +
  菜单已接入 + `MENU_CHECK` 机制未丢。
- 文档: README(新增【可选组件】段 + 备用脚本段 + rootfs 回收口径)、
  SCRIPT-MAINTENANCE(1.2 表 + 新增 **1.3 可选组件怎么加** + 删 firefox 口径)。
- 顺带修正 README 里与 1.4.x 同源的一处错误结论:
  "`/etc /usr /opt` 全被覆盖, 只有 `/home` 幸存" —— 实为 `/opt`、`/usr/local`、
  `/root`、`/srv` 是 bind-mount 到 `/home` 分区(`/home/.steamos/offload/*`), **同样幸存**。


## [2.0.0] - 2026-09-24

### 新增: 步骤[13] wiliwili(B站第三方客户端, 必装) —— 主版本号升级: 步骤结构 12→13
- 官方 x86_64 Linux 仅发 flatpak 单文件包 → flatpak --user 安装, 落在 /home
  原子升级不冲; bundle 运行时依赖走 flathub 用户远端(境内首次较慢, 一次性)
- 下载走 gh 镜像优先(ghfast/gh-proxy/ghproxy/直连), API 失败兜底 v1.6.0
- root 环境下以真实用户身份执行 flatpak --user(避免装进 root 家目录)
- verify: 按 ~/.local/share/flatpak/app 目录名判(不依赖具体 app-id)
- 步骤全链路接入: step_label/verify_step/map_step(13|wiliwili|bili)/
  两处 FUNCS/help/头部注释/check.sh 断言清单

## [1.4.1] - 2026-09-24

### 新增: 开机慢诊断工具
- `诊断-开机慢.sh`: 只读诊断(耗时关键链路/NTP/网络等待服务/atomupd/
  开机超时日志/Steam服务器连通性/DNS), 报告落盘供远程分析;
  针对境内网络开机转圈半天的场景

## [1.4.0] - 2026-09-24

### 新增: 必装/可选分离 —— 可选组件安装器
- 新增 `可选组件安装.sh`: 必装主线(steamos-setup.sh 十二步)之外的增强项菜单,
  首个条目: 微信(官方原生版沙盒封装 wechat-universal-bwrap, 自动补中文字体
  noto-fonts-cjk; 包名逐个探测以适配 archlinuxcn 上游变化)
- 两个启动器(重装后先运行我 .desktop/备用.sh)在必装跑完后询问
  "是否安装可选组件(微信等)?", 确认后拉起可选安装器
- 扩展点: 新增可选项只需 ①install_xxx() ②注册表(MENU_ORDER/NAME/PKGS)
  ③case 分支, 三处各一行, 与 profile_extra 同哲学

## [1.3.1] - 2026-09-24

### 修正(健壮性)
- 设备画像掌机证据链注释纠偏: GPD Win5 电池可拆卸, 拔电池运行时电池判据失效
  —— 明确 ①背键 HID ②DMI 掌机品牌 为硬证据(判定逻辑本就如此, 仅文档纠偏),
  电池存在只作未知品牌便携设备的兜底信号

## [1.3.0] - 2026-09-24

### 新增: 设备画像层(装前检测 + 多机型适配空间)
- 主脚本启动/prepare 时自动归类设备画像(`--device` 可免root单独复查):
  - `amd-handheld-gpdwin5`  AMD核显掌机·GPD Win5(主目标, 全功能)
  - `amd-handheld`          其它AMD核显掌机(电池/掌机品牌判据)
  - `amd-desktop`           AMD 台式主机(独显或APU/迷你主机)
  - `intel-handheld`        Intel核显掌机(如 MSI Claw) → 引导 Bazzite
  - `intel-nvidia-desktop`  Intel+NVIDIA 台式主机 → 引导 Bazzite
  - `unknown`               其它组合 → 各步骤按判据自动取舍
- 不支持机型(支持度=bazzite)在 prepare 阶段弹确认门禁(交互确认/非交互跳过,
  `SKIP_DEVICE_GATE=1` 可关闭)
- 新增 `profile_extra()` 机型适配挂载点: 未来给新机型做适配只加 case 分支,
  不污染各步骤逻辑(步骤只认 IS_WIN5/GPU_IS_APU 等底层判据)
- `--status` 与 prepare 横幅均显示画像与支持度

## [1.2.1] - 2026-09-24

### 新增
- 启动器定制图标(steamos-runme): 手写 SVG(橙红渐变+白色运行三角), 首次双击
  自动装入用户图标主题(hicolor), 之后永久显示且不随备份包移动失效
- 【重装流程.md】: 一页纸重装全流程(准备→重装→桌面→重建→验收→升级→排错)
- README.txt 顶部加入口指引

## [1.2.0] - 2026-09-24

### 新增: 重装后一键启动器(中文名, 双击即用)
- `重装后先运行我.desktop`: 双击弹出 konsole 自动 cd 到备份包目录并运行
  steamos-setup.sh 全量(自动提权/断点续传), 结束后窗口保留显示退出码;
  自动兜底 ~/Downloads/steamos-reinstall-backup
- `重装后先运行我-备用.sh`: 备用启动器(.desktop 提示不受信任时用,
  Dolphin 选"在终端中运行"效果相同)
- 首次使用若桌面提示"不受信任": 右键 → 属性 → 应用/信任 该启动器
## [1.1.0] - 2026-09-24

### 新增: SteamOS 升级自愈钩子 v2
- self-heal-after-upgrade.sh 重写: 每次开机对比系统版本号, 检测到原子更新
  (rootfs 被整块替换)后自动清点被冲掉的内容, 报告落盘
  (~/.local/opt/steamos-self-heal/last-report.txt) 并弹桌面通知
- sudoers 幸存时全自动恢复(主脚本 --after-upgrade, 落地复核只补缺失项);
  sudoers 也被冲掉时通知一条手动命令(诚实边界: /etc 侧免密文件升级必被冲)
- 清点范围新增 Decky Loader 系统单元(plugin_loader.service)
- 部署时固化主脚本路径到 main.conf —— 修复旧版自愈脚本部署后找不到主脚本、
  自动恢复从未真正生效的隐藏 bug
- sudoers 规则补主脚本调用(旧规则只放行自愈脚本自身, 脚本内 sudo -n 永远失败)

### 修复
- verify_step 的 dsh 判据与 2026-09-09 的 ~/.local 安装布局脱节, 导致步骤[7]
  永远落地复核未通过; 现在新旧布局都认

### 优雅化
- 删除主脚本内嵌的自愈脚本副本(双份漂移根源), 缺文件时明确报错

## [1.0.0] - 2026-09-24

基线版本（对应 steamos-setup.sh 十二步状态机 + 全部外围脚本）。

### 约束
- 【重要】不再改动原系统(SteamOS)输入法的任何内容：
  - 主脚本步骤[2] setup_im 改为空函数，原实现存档 `disabled/setup_im.disabled.sh`
  - 三个历史输入法脚本归档至 `disabled/`（不执行）
  - WorkBuddy 应用自身的 IME 启动参数自愈（步骤[12]）保留
- 历史事故防线：`: <<'EOF'` 块禁用手法禁止使用（check.sh 断言 2.5 强制）

### 新增
- 第[5]步 Decky Loader 装完后自动安装预置插件：SteamGridDB + ProtonDB Badges
  （走 Decky 官方商店分发；`DECKY_PLUGINS` 可自定义/置空跳过）
- `check.sh` 项目自检脚本（bash -n 全量 + 关键不变量断言，只读免 root）
- `hooks/pre-commit`：git 提交前自动跑 check.sh，不通过则拒绝提交
- `archive/`：0909 原版与 lean 精简版历史存档

### 修复（shellcheck warning 级清零）
- 递归删除路径加 `${VAR:?}` 非空护栏（ToolsDir/Tag）
- 5 处 `local x="$(...)"` 声明与赋值分离，避免返回值被掩盖
- 移除未使用变量：`m` / `MAIN_ABS` / `WB_MARK`
- `ls|grep` 改 glob 循环（show_status 已装插件列表）
- steamos-nix/scripts/setup-ibus-xiaohe.sh：`-f` 通配符误用（SC2144）改为循环判定
