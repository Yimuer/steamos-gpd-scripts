# CHANGELOG — steamos-reinstall-backup

遵循语义化版本：`主版本.次版本.修订号`
- 主版本：步骤结构/目标环境变化（不保证旧机器直接复用）
- 次版本：新增步骤或功能
- 修订号：bug 修复与健壮性加固
每次提交后打标签 `vX.Y.Z`；`bash check.sh` 全绿才允许提交（pre-commit 钩子强制）。

## [3.11.0] - 2026-09-27（主脚本步骤表驱动 + 单文件自安装包）

**这一轮问的问题**：前两轮（§13.9 / §13.10）已经把散脚本收敛成统一入口，交付物仍是
"一个目录 + 5 处'先 chmod +x'的手工前置"，而路线图里最后一件大事 #3（步骤表驱动）还开着。
所以本轮只做两件事：**把步骤知识从 7 份副本收成一张表**，**把交付物从一个目录收成一个文件**。

### 新增：`STEPS` 表驱动（结案路线图 #3，主脚本）

- 主脚本新增 `STEPS` 表（`编号|函数名|标题|别名|进全量|有判据`），派生出
  `step_label()`、`map_step()`、全量 `FUNCS` 列表、`--adopt` 列表、`--help` 步骤清单、
  以及 16 处步骤横幅里的 `[n/N]`（`banner <函数> "文字"`）。
  **加/删一步从"改 9 处"变成"改表 1 行"**（+ 手册/README 各同步一行，这两处有断言会提醒）。
- 两个刻意保住的差异：① 步骤[8] `clean_rootfs` **不进全量列表**（它是步骤[3] 按需触发的
  子步骤，误并入等于无人值守时擅自瘦身系统分区）；② `verify_step()` **不表化** ——
  那里的注释是实测踩坑记录，抽象它等于压扁历史知识，改为**由断言逼着**每步必须有分支
  （无落地物的三步也要显式 `return 0`，不许掉进 `*) return 0` 假达标）。
- 顺手修掉一个真 bug：`show_help()` 的步骤清单是手抄的，**停在 15 —— 步骤[16] Firefox
  从来没进过 `--help`**。派生之后自动包含。

### 新增：`pack-run.sh` —— 单文件自安装包 `.run`（交付物的主形态）

- `bash steamos.sh pack` 现在同时产出 `dist/*.tar.gz` 与 `dist/*.run`（后者是主形态）：
  `bash steamos-toolbox-<版本>.run` → 校验 sha256+字节数 → 解到 `~/steamos-toolbox` →
  补执行位 → 开菜单。**"先 chmod +x"这条手工前置随之消失**（执行位写在包内 tar 元数据里）。
- 护栏：目标目录非空默认拒绝（退 4）；`--force` 时旧目录 `mv` 成 `.bak-<时间戳>` 而非删除；
  先解到临时目录、成功才 `mv` 到位（失败不留半个安装）；全程不提权；非交互不开菜单；
  载荷偏移由 `__PYEOF__` 哨兵**运行时**定位（不写死行数）。
- `bash steamos.sh pack-run` 跑它自带的 9 项自测；`dist-verify` 新增第 6 节：真的调用
  `.run` 装到临时目录、在装出来的副本里跑 `selfcheck`、成员清单与 tar.gz 逐行比对。

### 质量：断言层换代（`check.sh` 230 → 231 项，其中新增的派生测试实跑 194 项）

- **新增"实跑派生"测试**：把 `STEPS` 表块（`# ----8<---- STEPS-TABLE-BEGIN/END ----`）
  抽出来、打桩、**真的调用** `map_step / step_label / steps_where`，对一份**独立手抄的答案表**
  （编号连续性、别名直达、全量顺序 15 项逐字一致、未知/通配/空参数一律回空、help 清单 16 项）。
  表块抽不到或跑不满 40 项时报红而不是静默通过。
- 新增 5 组交叉核对：表 ↔ 步骤函数体 ↔ `verify_step` 分支 ↔ `banner` 派生 ↔
  文档步数（README 主线表、手册 §1.1 导读表、手册声明的行数 ±10%）。
- 删掉 4 组已被派生测试取代的旧 grep 断言（点名 `14|localsend` / `15|mdread` /
  `setup_localsend setup_mdread` 等字面量），以及 2.4 里手抄的 12 个函数名
  （那份副本本身已经漏了步骤[15][16] —— 它就是它要检查的那类病）。

### 修复（本轮审计发现）

- `.gitignore` 漏了 `.cache/`（`harmony-sans` 下载缓存污染 `git status`）。
- **7 处**"从 Windows/网盘拷回来先 `chmod +x *.sh *.desktop`"（6 个文件：README / 使用说明.txt /
  重装流程.md ×2 / 重装后先运行我.sh / 两个 `.desktop`）改写为单文件包的说法 ——
  目录形态仍需手工修一次，`.run` 不需要。
- 维护手册 §10.1 的过时数字（主脚本"3029 行"→3812；"4 个 install-*-home.sh 各 441~489 行"
  →已收敛为单引擎）。

### 健壮性验证（含反例，全部实跑）

- 8 个反例探针（每种破坏一份副本，看断言是否真报红）：改「进全量」标记、删 `verify_step`
  分支、表点到不存在的函数、横幅改回手写、README 删一行、入口步数改成 15、改掉抽取标记、
  函数名写错 —— **8/8 报红** ✔
- **反例 04 抓到一条假绿灯**：残留横幅判据写成 `step "\[[0-9]+/[0-9]+\]"`（带结尾引号），
  而真实形态是 `step "[11/16] 文字"`，`]` 后面是文字 → 永远匹配不到。已去尾引号并把教训写在判据旁。
- 自测过程中被自己的测试抓到的两个 bug：载荷偏移原本写死为打包时算的行数（头部多一行即失效，
  已改为运行时找哨兵）；带引号 heredoc 里误按"会展开"写了 `\$`（生成的头部留下字面反斜杠）。
- 真实投递演练：`.run` 拷到别处 → `--help/--list/--check` → 连装两次（第二次退 4 并指路
  `--force`）→ `--force` 后旧目录保留 → 符号链接调用 → 在装出来的副本里跑 `doctor`。
- 门禁：`check.sh` 全绿；shellcheck `-S warning` 0（含两个新脚本）。
- **边界**：涉及真机行为的本轮只做了静态与结构验证，步骤[12] 快照同步、免密链仍需 GPD Win5
  回归（清单见维护手册 §13.11.8）。未合并的两份 Steam 启动选项写入器（`set-steam-launchoptions.py`
  与步骤[6] 生成的 `steam-launch-games.py`）记为维护手册 §13.11.5 的下一轮候选。

详见维护手册 §13.11。

## [3.10.1] - 2026-09-27（跨平台执行位护栏 + pack 平台免疫）

**问题**：在 Windows 副本（OneDrive 目录，Git Bash）上复审时，`check.sh` 报了真机上不可能出现的
红项 `steamos.desktop 没有执行位`。深挖出三个平台事实（全部探针实测）：Windows/NTFS 上
`chmod +x` 是空操作；Git Bash 的 `-x` 靠 shebang 嗅探（`.desktop` 永假 → 磁盘位判据必然假红）；
`git add` 一律记 `100644`（新脚本从 Windows 提交会静默丢执行位 —— 8977c11 事故的复发通道）。

**加固一：check.sh 执行位判据跨平台化**
- 已入 git（含已暂存）→ 查 `git ls-files -s` 索引模式（跨平台同样有效），断言范围从点名 4 个文件
  **扩到全部已跟踪 `.sh`/`.desktop`**；未入 git → 先跑 `fs_can_x` 探针，本机表示不了执行位就
  明示跳过（"提交后由索引断言兜底"），不再假红。
- 反例验证：`git add steamos.desktop`（Windows 记 100644）→ 两处断言同时报警并教
  `git update-index --chmod=+x`；修复后转绿 ✔

**加固二：dist-verify 新增 tar 元数据执行位判据**
- 解包后在 Windows 上做 `-x` 必然假红，唯一两边都信的判据是 **tar 里存的模式**：
  包内 `.sh`/`.desktop` 丢 `x` 即判废。反例：Windows 上真打一次包 → 两个 `.desktop` 全 644 →
  被抓出（退 1）✔

**加固三：pack 改为平台免疫（模式显式写入，不看文件系统位）**
- 成员按"该是什么模式"分两趟显式 `--mode` 写包：执行位集合 = 名字规则（`.sh`/`.desktop`/目录）
  ∪ git 索引 `100755`（覆盖 `hooks/pre-commit` 这类无扩展名执行文件）；其余 644。
  `--no-recursion` 防止目录子树按 FS 位被二次塞入。
- 效果：**任何平台打出的包模式都正确**，"正式发布包只能在 Linux 造"的限制随之解除 ——
  本版发布包就是在 Windows 上造的，dist-verify（含元数据判据）全绿。

详见维护手册 §13.10.9。

## [3.10.0] - 2026-09-27

### 新增：全家桶统一入口 `steamos.sh`（把一目录散脚本收成一个应用）

**问题**：项目有 30+ 个脚本，命名按"干什么"起（`doctor` / `diag-` / `fix-` / `install-`）。
现场着急时最费时间的往往不是修，而是"我到底该跑哪个"—— 知识散在文档里，人记不住。

**做法：表驱动，一张注册表派生一切。**

```
bash steamos.sh              # 交互菜单(按"体检/重装/应用/修复/诊断/维护"分组)
bash steamos.sh list         # 命令行清单
bash steamos.sh <命令> [参数]  # 直接分发(退码透传)
bash steamos.sh selfcheck    # 自检: 注册表↔文件一致 / 跑的是哪一份 / 快照新旧
bash steamos.sh pack         # 打发布包 dist/steamos-toolbox-<版本>.tar.gz
bash steamos.sh dist-verify  # 把发布包解到临时目录**实跑一遍**(验证自包含)
```

每条命令登记为一行 `命令|文件|默认参数|模式|分组|说明`，菜单 / 清单 / 帮助 / 分发 /
自检全部由它派生 —— **以后加脚本只改一行**。模式分三档，含义各自明确：

| 模式 | 含义 | 非交互环境(stdin 不是终端)时的行为 |
|---|---|---|
| `只读` | 不改任何东西 | 照跑（无人值守体检/自检正需要） |
| `sudo` | 会自己提权，要密码 | **不跑**，只打印该执行的命令（退码 4） |
| `交互` | 需要人在终端前 | **不跑**，只打印该执行的命令（退码 4） |

**四条设计约束（都与项目铁律对齐）**
- 自包含单文件、不引 `lib/`，可单独拷走（铁律 1）。
- **自己不提权**：需要 root 的仍由各脚本自己 `sudo`。入口是用户可写的，
  写进 `sudoers` 等于放行任意提权 —— 已加断言把这条钉死（铁律 3）。
- 只分发、不复制逻辑：判据与修复都留在原脚本里，避免"两处各一份"的漂移。
- 非交互**绝不挂起**：项目踩过 `echo q | bash 可选组件安装.sh` 永久挂住的坑。

**配套**：`steamos.desktop`（双击入口，与 `重装后先运行我.desktop` 同款约束：不写
`TryExec`、用 `Terminal=true`、不新增图标依赖）、`dist/` 进 `.gitignore`。

### 修（真机现场踩到）：步骤[12] 的落地判据漏了第三条免密规则 → 永远"跳过"

**症状**（2026-09-27 实测）：

```
$ sudo bash steamos-setup.sh 12
[✓] [跳过] 12 升级后自愈服务 —— 已完成于 2026-09-26 12:32:23  (--force 可强制重跑)
```

看起来一切正常，其实**什么都没做**：新加的第三条免密规则（`fix-opt-deps.sh`，升级后自动补
`/usr` 依赖）补不上、免密快照也停在上一天的版本，自愈链就此瘸腿 —— 而且**不报错**。

**根因**：`setup_selfheal` 里"生成免密规则"和 `verify_step` 里"判定规则在不在"是**两处**。
v3.9.10 加第三条规则时只改了生成那处。同一类坑 2026-09-25 已经踩过一次
（当时的受害者是"开发文件补齐器"那条规则），这是**第二次复发**。

**修**：
- `verify_step setup_selfheal` 补上第三条规则的判据（文件在不在 + sudoers 里有没有）。
- `check.sh` 新增交叉核对断言，让这类问题**再也不能靠人记得**：从 `SNAP_*="$SNAP_DIR/xxx"`
  抽出全部规则脚本名，逐个要求在 `verify_step` 的分支里出现**在一行 grep 判据上**。
  > 这条断言的第一版是"分支里提到名字就算过"，结果被旁边的 `[ -f .../fix-opt-deps.sh ]`
  > 骗了过去（反例验证时发现的假绿灯）—— 改成必须出现在 grep 行上才作数。
  > 现在再加第四条规则时，改动两处这件事会被断言逼着做。

**你现在要做的**：把上面那条命令**再跑一次**即可（判据已修，不再跳过；会把快照刷成当前版本
并补上缺的规则）。想显式强制：`sudo bash <仓库>/steamos-setup.sh 12 --force`。

### 顺带确证并锁死：免密规则的"参数形态"必须与调用方式一致

修上面那个 bug 时顺手探了一次 sudoers 的真实语义（**用当前规则集直接试，不是查文档猜**）：

```
$ sudo -n bash /opt/steamos-backup/fix-opt-deps.sh --任意参数
sudo: 需要密码            ← 拒了(退 1)
$ sudo -n bash /opt/steamos-backup/fix-opt-deps.sh
[✓] 依赖齐全: webkit2gtk-4.1 libayatana-appindicator   ← 放行(退 0)
```

**结论**：不带 `*` 的规则**只放行"原样调用"**，带参数会被拒；`*` 才允许任意参数。
于是"调用传参 + 规则没 `*`" = 无人值守链上**静默失败**（与本次那个跳过同一类）。

当前两边是匹配的：自愈链调补依赖器**不传参** → 规则刻意**不带** `*`（最小提权面）。
`check.sh` 新增断言把这个"匹配关系"钉住，**双向都会报错**：
调用改成传参而规则没 `*` → 报"会被拒(静默失败)"；规则无谓加 `*` → 报"提权面被无谓放大"。
（两条都做了反例验证。）

### 新增护栏：入口的"注册表 ↔ 文件"双向不变量（`check.sh` +15 条断言，共 233 条）

这类漂移不报错、只让人白费时间，所以必须自动断言：
- **反向覆盖**：根目录每个 `.sh`/`.py` 都必须在注册表里 —— 新脚本不许被遗忘
  （否则它躺在目录里却没有任何入口指向它 = 等于不存在）。
- **正向存在**：注册表点名的文件都得在（否则菜单点下去只报"缺文件"）。
- **格式**：注册表每行必须正好 6 段。
- **内建命令必须有实现函数**（否则 `command not found`）。
- **安全红线**：入口不得出现提权调用；`sudoers` 不得引用它。
- **`VERSION` ↔ `CHANGELOG` 最新版本号必须一致**。

### 修：五处文档/元数据漂移（都是"不报错、只是慢慢错"的那类）

| 位置 | 原来 | 实际 |
|---|---|---|
| `VERSION` | `3.7.0`（停在半年前） | 已到 `3.9.10` —— 现在它是入口横幅与包名的来源 |
| `重装后先运行我.sh` 头注释 | "跑 steamos-setup.sh(15 步…)" | 16 步 |
| `可选组件安装.sh` 头注释 | "与 steamos-setup.sh **十二步**主线解耦" | 16 步 |
| `SCRIPT-MAINTENANCE.md` §1.1 | "主脚本（约 **1976** 行）"、步骤 2 = "IBus 原生输入法" | 3734 行；步骤 2 实为**已禁用** |
| `fix-workbuddy-wayland-ime.sh` | 让读者跑 `check-wayland-ime.sh` | 该脚本**从未存在过**（悬空引用） |

### 修：`check.sh` 自己的严格模式（判据宽一档，自己成了漏网的那个）

`check.sh` 当时只写了 `set -u`。把 2.15a 的判据从"有 `-u`"提到"有 `-u` 且有 `pipefail`"，
并给自己补上 `pipefail`（实跑确认全绿）。**判据本身失效就该报错**——
同节里"数不出最大步骤号"那条也是这个道理。

### 可行性分析（结论：低风险，因为零侵入）

| 关注点 | 结论 |
|---|---|
| 会不会破坏免密自举链 | **不会**：入口不提权、不进 `sudoers`，需要 root 的转发走原脚本原有的路径 |
| 会不会影响步骤[12] 的快照同步 | **不用改**：`sync_snapshot()` 本来就是"顶层所有文件一起搬"，新文件自动被带上 |
| 会不会影响断点续传状态机 | **不会**：入口不碰 `~/.cache/steamos-setup/state`，只转发 |
| 会不会与"单脚本可独立拷贝"冲突 | **不冲突**：入口本身也自包含、可单独拷走 |
| 新增维护负担 | 只有一处：加脚本要在注册表加一行 —— 而这条**有断言兜底** |

### 健壮性验证（都是实跑，含反例）

- `bash -n` 全过；`shellcheck -S warning` 对入口 **0 warning**；`check.sh` 全绿。
- 未知命令 → 退码 2 并指路；缺文件 → 退码 3；只读项 → 退码透传（实测 `status` = 0）。
- 非交互（`</dev/null`）：`setup`/`apps` 被拦下并打印该执行的命令（退码 4），**不挂起**。
- **反例验证**：临时移走 `fix-opt-deps.sh` → `selfcheck` 与 `dispatch` 都当场报警（退码 3）；
  移回后恢复 —— 判定类改动的规矩：只验"正常时不报"是假绿灯。
- **发布包端到端**：`pack` → 解到 `/tmp` → 包内 `selfcheck` 全绿（628K，无 git 依赖）。
  这一步是**真抓到 bug 的**：排除规则原先只锚定顶层 `./`，把子项目 `steamos-nix/`
  里的 `.workbuddy/`（会话记录）和 `__pycache__/` 打进了发布包 ——
  GNU tar 的不含 `/` 模式按"基名"在**任意层级**匹配，改成基名写法后干净。

### 踩到的坑（记下来免得再犯）

- **`GROUPS` 是 bash 特殊变量**（当前用户的组 ID 列表），赋值会被无声吞掉：
  菜单分组直接变成 `1000/998/973` 这种组号。改名为 `CMD_GROUPS`。
- `tar --exclude` 的作用域见上（必须用不含 `/` 的基名模式才能覆盖任意层级）。

## [3.9.10] - 2026-09-27

### 升级后自动补回便携化应用的依赖（用户拍板：要）
便携化应用本体在 /home（幸存），但依赖装在 /usr（如 Tauri 的 webkit2gtk）→ 升级会被冲。
现在自愈链会自动补回。**关键在怎么做才不扩大提权面**：

- ❌ 不做：`sudoers` 放行 `pacman` —— 那等于任何能以 deck 执行代码的东西都能免密装**任意**包。
- ✅ 做了：新增 `fix-opt-deps.sh`，放进 **root 属主快照**，sudoers 只放行它这一个
  （与已有的主脚本 / 开发文件补齐器同款）。于是提权面 = "重装这几个固定包"。
  包名的三个约束（都写进 check.sh 断言）：
  ① 写死在脚本内的 `OPT_DEPS` 数组；② 可选扩展走 **root 属主的** `/opt/steamos-backup/opt-deps.conf`
  （非 root 属主的配置直接忽略）；③ **不接受命令行传包名**（argv 一律忽略并警告）。
- 只在"确实装过便携化应用"时才动手：① 有 `.deb-portable` 清单，② 或 `~/.local/opt` 下有应用正缺库
  （第二条是实测补的：只认清单会让 clash-verge 这类 profile 安装的应用没人管）。
- 锁感知：`db.lck` 存在时不动，交给自愈定时器（每 20 分钟）重试 —— 不和补齐器抢锁。
- 装完复核：没真装上就返回非 0，让链下次重试（不写"假成功"）。

接入：步骤[12] 写第三条免密规则；自愈链 5b 环节调用；`doctor.sh` 会检查这条规则，
且**只在整条链缺失时才报"卡死"**，缺这一条时准确说明"本体仍在、只是不会自动补依赖"。

`check.sh` +7 条断言（共 **217 条**），含一条安全红线：**不许放行 pacman 本身**。

> ⚠️ 生效前提：需要跑一次 `sudo bash <仓库>/steamos-setup.sh 12`（把 fix-opt-deps.sh 同步进快照
> 并写入免密规则）。这是唯一需要输密码的一步。

## [3.9.9] - 2026-09-27

### 新增通用能力：`install-deb-portable.sh`（任意 deb → /home，可视化引导）
用户诉求："大部分项目都有 deb 包，帮我固化一个可视化功能 —— 从网上下载一个 deb，以不会被
系统冲掉的方式安装"。此前只有 WPS / Clash Verge 各自的特例实现，现在**通用化**：

```
deb(URL 或本地文件) → 取 data.tar.* → 整棵树(通常 usr/) → ~/.local/opt/<名>
入口 ~/.local/bin/<名> + 桌面项/图标 → ~/.local/share/...        ← 全扛原子升级
```
- **可视化**：有 `DISPLAY` + kdialog 时走对话框（选文件 / 输链接 / 选主程序 / 确认装依赖）；
  无图形环境自动回退终端交互（带 `-t` 超时守卫，非交互不会挂起）。
- **主程序怎么定**：优先包内 `.desktop` 的 `Exec=`；多个可执行文件时弹单选；
  也可 `--bin` 指定（`usr/bin/foo` 与相对树根 `bin/foo` 两种写法都接受 —— 实测修过一次路径基准混淆）。
- **依赖体检**：`ldd` 查缺失 .so，能反查包名（`pacman -F`）则提示候选包；入口 wrapper 会自检这些库，
  缺了打印可复制的装回命令，**绝不"点了没反应"**。
- **防假绿灯**：`ldd` 需要可执行位（先补 `+x`）；`ldd` 完全无输出时判 `UNKNOWN`（"无法判定"），
  不报成"依赖齐全"。用非 ELF 文件做了反例验证。
- 还带 `--check`（升级后体检已装应用与缺库）、`--remove`（卸载，只动 /home）。
- 菜单新增 `deb-portable` 项。`check.sh` +8 条断言（共 **210 条**）。

实测：用真实的 Clash Verge deb 跑通（自动从 `.desktop` 推出主程序 → 283M 落 /home →
`--check` 正常 → `--remove` 干净卸载）。顺带确认 Clash Verge 本体**真的启动成功**
（进程在 `~/.local/opt/clash-verge/usr/bin/clash-verge`，配置与内核数据也都在 `/home`）。

## [3.9.8] - 2026-09-27

### 新增可选组件：Clash Verge Rev（要求"千万不能被系统升级冲掉"）
上游 **Linux 不发 AppImage**（只有 deb/rpm），deb 直装会进 `/usr` → 升级必被冲。
按项目既有套路（WPS：官方 deb 拆包）给它加 `install-app-home.sh` 的 `clash-verge` profile，
但**落点选 /home**（WPS 是因为官方 Relocations 才必须 /opt）：

```
官方 deb(98MB) → 拆 data.tar.* → 整棵 usr/ 树搬进 ~/.local/opt/clash-verge/usr
入口 ~/.local/bin/clash-verge + 桌面项/图标 → ~/.local/share/...      ← 全部扛升级
```
- **保留 `usr/` 相对结构**：Tauri 的资源按可执行文件相对位置找，打散会起不来（实测确认）。
- 解包判据看**真二进制** `usr/bin/clash-verge`，不看目录（GE-Proton 假绿灯同款教训）。
- 桌面项字段照搬包内 `Clash Verge.desktop`（注意上游文件名带空格）。
- 菜单接入：`MENU_ORDER` / `MENU_NAME` / `MENU_CHECK=clashverge_installed` / `install_clash_verge`。
- 上游加入 `verify-upstreams.sh`（实测 ✓ 2.5.6）。

### ⚠️ 唯一会被升级冲掉的部分：Tauri 的 WebView（webkit2gtk-4.1）
本机原缺 `libwebkit2gtk-4.1.so.0`（ldd 实测 2 个库缺失）。它在 `/usr` → 升级会没。
extra-3.9 快照源有（36MB，版本对齐不会部分升级）。三层对策：
① 安装时一并 `pacman -S --needed webkit2gtk-4.1 libayatana-appindicator`；
② **入口 wrapper 自检该 .so**，缺了打印可复制的装回命令（不哑失败，实测有效）；
③ 菜单文案写明"升级后重跑本项补回"。
> **待用户决定**：要不要做成"升级后自动补回"。那需要在 sudoers 放行 `pacman`
> （即使限定包名也扩大提权面），属安全取舍，我没有擅自加。

`check.sh` 新增 6 条断言（共 201 条）；实测安装一次跑通：98MB deb → 283M 落 /home，`--check` 就绪。
**合规说明**：脚本只负责安装软件；代理节点/订阅与用途须遵守所在地法律法规与所在网络的管理规定。

## [3.9.7] - 2026-09-27（全项目复审 + 健壮性加固）

### 复审方法
① 跑既有门禁（`check.sh` / `doctor.sh` / `verify-upstreams.sh` / shellcheck / 全脚本 `bash -n`）；
② 按 §13 记录的 11 类脆弱模式做**静态全量扫描**（删根形态 / 下载超时 / 硬编码路径 /
`read` 挂起 / mktemp 续传 / 严格模式覆盖）；③ 针对 2026-09-26 两次最贵的现场教训做定向优化。

### 扫描结论（先看没问题的）
- 能删根的 `rm -rf "$VAR/..."` 形态：**0 处**（24 处 `rm -rf` 全是整变量或 `-exec {} +`）。
- 下载 `--max-time`：全覆盖（含 3600s 大包）；交互 `read` 全带 `-t` 超时；下载缓存一律固定路径（保 `-C -` 续传）。
- 上游可达性：`verify-upstreams.sh` **关键项全通**（Nightly/WPS/AUR/仓库清单/各 AppImage 镜像）。

### 三项优化（都是"消除不一致/补盲区"，不是加新机制）
1. **严格模式统一**：3 个脚本此前没开 `set -u`（`可选组件安装.sh` / `诊断-开机慢.sh` /
   **`self-heal-after-upgrade.sh`——它是无人值守跑的**）。已与项目标准 `set -uo pipefail` 对齐，
   并逐一实跑验证（自愈 `--dry-run`、可选组件非交互、开机慢诊断）。
2. **过期快照自检**（昨天最贵的一次教训：跑了旧快照 → 修好的 bug 原样复现，排查成本极高）：
   步骤[12] 同步时盖 `.snapmeta`（源路径 + 主脚本 sha256 + 时间）；之后凡**从快照目录启动**，
   自动比对仓库那份的 sha，不一致就警告并指路。三情形实测（落后→警告 / 最新→静默 / 无戳→静默）。
3. **自愈清点覆盖"装在 /opt 的 AUR 包"**（微信昨天凭空消失且无人告知）：新增 `orphanpkg` 判据
   （目录在 + pacman 台账没了 = 孤儿），**只报告不自动装**（可选组件不由自愈替用户决定；
   步骤写 `-` 表示不进自动修复表）。包名走第 5 字段，判据保持通用。

`check.sh` 新增 6 条断言（共 **195 条**全绿）。

## [3.9.6] - 2026-09-26

### 修：第三层悖论 —— 步骤[12]（修锁的钥匙）自己被锁挡在门外
用户照建议跑 `sudo /opt/steamos-backup/steamos-setup.sh 12` 想恢复免密，**还是失败**：
死在环境准备的 `pacman -Sy`（还是那个锁）。
而步骤[12] 的工作是**重建免密规则/快照/服务软链 —— 全是文件操作、不装包、与 pacman 无关**。
它陪跑 `-Sy`，等于"修锁的人被锁挡在门外"：补齐器持锁多久，免密就多久建不起来。

### 改动
- `prepare()` 新认 **`PREPARE_NO_REFRESH=1`**：跳过锁守卫与 `pacman -Sy`，直达正题；
  只读解除/密钥环/镜像表等快速无锁的准备工作照跑。`setup_selfheal()`（步骤[12]）设置它。
- 撞锁等待超时的提示补全：点明"补齐器可能要 1 小时+（`PACMAN_LOCK_WAIT=3600` 可加大等待）"与
  "**只想恢复免密 → 步骤[12] 不受锁影响，现在就能跑**"。
- `doctor.sh` 免密失效时的建议改为**优先仓库路径**（`$HERE != $SNAP` 时）：
  反正要人工输密码、无提权口子，而仓库版的步骤[12] 会**顺手把过期快照同步成最新**
  （新逻辑一并进快照）。"只能用快照"的告诫只适用于免密还活的场景（守卫会拒绝自刷）。
- `check.sh` +2 条断言（免刷新开关必须存在且被 setup_selfheal 设置）。
- `SCRIPT-MAINTENANCE §13.8b+` 记了这层悖论与两个口径修正。

### 3.9.6 补充二（11:27/11:58 现场：孤儿预检直通）
- 用户 11:27 跑的是**快照版**步骤[3]（快照 11:01 刷新 = 有锁守卫但没有 11:24 的 WB_LOG 修复）
  → tee 目录错误重现。两次教训指向同一件事：**快照永远落后于仓库**，修复要进快照必须重跑步骤[12]。
- 新增**孤儿预检直通**：装 workbuddy 前先抽样 `/opt/WorkBuddy` 的文件（`find -maxdepth 3 | head -15`）
  用 `pacman -Qo` 判主，全部无主 → 判定孤儿现场，**直接带 `--overwrite` 安装**——
  不再"两轮注定失败 + 一轮重试"（那要连输三次 sudo 密码）。实测现场数据命中。
- `check.sh` 再 +2 条断言（预检存在 + WB_OV 数组接入），共 188 条。
- 误建目录（11:27 二次出现）已再清（rmdir 验空）。

### 3.9.6 补充三（12:04 现场：AUR RPC 间歇性连不上 → 本地构建包兜底）
预检直通已生效（用户日志出现"抽样 15 个文件均无包拥有"），但 paru 又倒在
`aur.archlinux.org/rpc: unexpected EOF`（同日两次现场，**间歇性**——11:23 能通、12:04 不通）。
- 新增 **RPC 兜底**：日志含 `aur.archlinux.org/rpc` 且包未装上 → 在助手 clone 缓存
  （`~/.cache/{paru/clone,yay}/workbuddy/`）找**上次构建好的 .pkg.tar.zst** →
  `pacman -U --noconfirm --needed "${WB_OV[@]}" <包>` 直装——**不联网、不要密码**（脚本已是 root），
  `--overwrite` 沿用预检结论（非孤儿现场为空数组，不掩盖真冲突）。实测现场命中（265M，9-25 构建）。
- 顺手重构安装段：**统一日志**（首轮输出 tee 上屏+落盘，后面所有判定读同一份）、
  **删掉冗余的第二轮尝试**（原先"失败→再试一轮落日志→再判冲突"要白跑一轮、多输一次密码；
  现在一轮日志喂给孤儿重试与 RPC 兜底两条路）。
- `check.sh` 既有断言全部保持通过。

### 3.9.6 补充一（11:23 现场抓到的自家 bug）
- **WB_LOG 被 `homedir()` 建成了目录**：`homedir()` 对整个参数 `mkdir -p`，把日志**文件名**传进去
  就建出同名目录 → `tee: …: 是一个目录` → 冲突重试拿不到日志。改为只 `homedir .cache` 建目录、
  `WB_LOG="$REAL_HOME/.cache/steamos-setup-wb-install.log"` 直指文件。误建目录已清（rmdir 验空）。
- 步骤[3] 失败原因清单新增**第⓪条**：日志含 `无法锁定数据库` 时直接点明是锁（补齐器还在装包时
  重跑必然撞上），不再让用户往网络/包上猜。
- `check.sh` 再 +3 条断言（共 186 条）。

## [3.9.5] - 2026-09-26

### 修：pacman 锁守卫**从没生效过**，且撞锁被误报成「源的问题」
真机现场：用户手动跑 `sudo bash steamos-setup.sh 3`，得到
```
[!] pacman -Sy 刷新失败 —— 多半还是源的问题, 关键错误如下:
错误：未能同步所有数据库（无法锁定数据库）
```
用户的第一反应必然是"源坏了"。**追父进程链才看清真凶**：
```
37784 pacman -Sw --noconfirm breeze
 └─ 36284 bash /opt/steamos-backup/fix-missing-dev-files.sh --apply   ← 另一个实例在补 KDE 开发文件
```
即另一个补开发文件的进程正在下载 `breeze`（几十 MB）并握着锁，用户同时手动跑脚本 → 撞锁。

**两个真 bug（都不是"源"的问题）**
1. **锁路径写死 `/var/lib/pacman/db.lck`** —— 本机 DB 真身在 `/usr/lib/holo/pacmandb/`，
   `/var/lib/pacman` 根本不存在 → **这个守卫从没生效过**，每次直接落到 `pacman -Sy` 失败。
   → 改运行时探测（优先 holo，退回 /var/lib）。
2. **持有者匹配用 `pgrep -a -f '(^|/)(pacman|yay|paru)\b'`** —— `-f` 匹配整条命令行，
   把 `gpg-agent --homedir /etc/pacman.d/gnupg` 这种"路径里含 pacman"的也列成"持有者"（实测踩过）。
   → 改用 `pgrep -x pacman -a`（只认可执行名）。

**新增能力：等锁，而不是一撞就退**（持锁者常是我们自己的自愈链/补齐器，它下完包会放手）
- 打印**持有者是谁**；判定是自愈链时明说"它下完包会自己放手，干等一会儿通常就过了"；
- 最多等 **180 秒**（`PACMAN_LOCK_WAIT=秒数` 可调），每 30 秒报进度；等到继续、等不到才退出；
- `pacman -Sy` 失败后**再复核错误文本**：含 `无法锁定数据库|unable to lock` 就明确报"这是锁、不是源"。

`check.sh` 新增 4 条断言钉住（DB 路径不许写死 / 必须区分锁与源 / 必须能等 / 持有者匹配不许用 -f）。
`SCRIPT-MAINTENANCE §13.8` 记了完整现场与"报错文案本身就是产品的一部分"这条教训。

## [3.9.4] - 2026-09-26

### 修：AUR 装包报「文件系统中已存在」= 孤儿文件，不是包损坏
一次真机 `steamos-setup.sh` 跑下来两处失败，报错都是同一类：
```
workbuddy: 文件系统中已存在 /opt/WorkBuddy/app.asar.unpacked/resources/trayTemplate.png
wechat-universal-bwrap: 文件系统中已存在 /opt/wechat-universal/wechat
发生错误，没有软件包被更新。
```
**根因**（`pacman -Qo` 已实证"没有软件包拥有"、pacman 本地 DB 里也无该包记录）：
这两个包都把主体装进 `/opt`，而 `/opt` 是 offload（实际落在 /home 分区）。
原子升级整块换 rootfs 时 —— **`/opt` 里的文件幸存，`/usr` 里的入口/运行时连同 pacman 台账一起被冲掉**
→ 变成"文件在、台账没了"的孤儿。之后再装同一个包，pacman 看到文件已存在就拒绝覆盖。
所以它既不是包损坏，也不是网络问题（同一现场里 AUR RPC 也连不上，那是另一件事）。

### 改动
- 主脚本新增 **`aur_conflict_retry()`**：识别 `文件系统中已存在|exists in filesystem` →
  **用 `pacman -Qo` 逐条确认该路径"无包拥有"** → 确认后才带 `--overwrite='*'` 重试一次，
  并在日志里写明"这是覆盖孤儿文件、不是重装"。
  有主（真有包拥有）的路径**拒绝覆盖** —— 那种才是真冲突，不该被 `--overwrite` 掩盖。
- 接进 workbuddy 安装段（步骤[3]）：首次失败 → 落日志 → 判孤儿 → 覆盖重试 →
  仍失败才报错，且报错里直接给出四条可执行的排查线索（含"④ 孤儿文件"与 AUR 不可达）。
- `可选组件安装.sh` 的微信段同样兜底（该脚本与主脚本**有意不共享函数**，见 §9.4）：
  检测 `/opt/wechat-universal` 下无主文件 → 带 `--overwrite` 重试；失败时按三类原因分别给提示。
- `check.sh` 新增 5 条断言：能识别该类报错 / 有重试路径 / **覆盖前必须 `pacman -Qo` 确认孤儿** /
  微信段也有兜底 / **不允许出现无条件的 `--overwrite`**。
- `使用说明.txt` 新增「AUR 装包失败的三个常见"假象"」：孤儿文件、AUR RPC 连不上、开发文件被裁。
- `SCRIPT-MAINTENANCE.md` 新增 §13.7（现场 + 三条诊断命令 + 三选一修法 + 为什么不许滥加 `--overwrite`）。

## [3.9.3] - 2026-09-26

### 新增 Decky 插件体检/修复（现场：SteamGridDB 崩在 `Minified React error #130`）
游戏模式里 Decky 面板整屏报错，报错屏自己说"likely occurred in SteamGridDB"。现场查清了根因：
- `~/homebrew/settings/loader.json` 里 **`branch:1, store:1`** —— Decky 本体走 Pre-Release、插件商店走 **Testing**，
  于是装到的是 `decky-steamgriddb 1.7.1-b6bcdd0`、`protondb-decky 1.3.4-809751c` 这种**带哈希的 nightly 构建**；
  插件日志里同一天 22 次 `Unloaded` = 前端崩→被卸载的死循环。
- 我们仓库的插件安装器**没问题**：它取的是不带 `testing` 参数的商店清单（正式版叫 `1.7.1`，纯 semver）。
  所以这次是 Decky 自己的测试通道装上去的。

为此新增：
- **`diag-decky.sh`**（只读诊断 + 一键修）：报告 Decky 版本 / 两条通道 / 每个插件是否测试构建 / 包是否完整 /
  日志里的崩溃循环；`--repair [插件名]` 用**商店稳定版**重装（走步骤[5]）；`--channels-stable` 把
  `loader.json` 的 branch/store 改回 0（先备份）。
- 主脚本新增 **`--decky-plugins='A|B'`** 开关（`=` 形式，避免 `for arg in "$@"` 里 shift 取错位置参数；
  也用开关而非环境变量 —— 后者会被 sudo 的 `env_reset` 剥掉）。这样 `diag-decky --repair` 能免密跑。
- `fix_home_owner()` 补 `~/homebrew`：以 root 装 Decky 插件会把 `plugins/` 写成 root 属主，用户自己清不掉。
- `check.sh` 新增 4 条断言（含"插件安装必须走不带 testing 的稳定清单"）。

## [3.9.2] - 2026-09-25

### 纠正一条核心事实错误（/usr/local 不扛升级）+ 免密链路换 root 属主快照
- **事实纠正**：实测 `/usr/local` 属于 `/usr`（同一 btrfs 子卷），**不在 Valve 的 offload 清单里 → 升级会被冲**。
  这条错误此前抄进了 6 处文档（README 表格、使用说明、维护手册两处表格与两处建议）。已全部改正，
  并补上"怎么自查"（`findmnt -no SOURCE --target <路径>` 与 `/` 比）与"清单会随版本变 → 代码里要运行时判断"。
  顺带发现：`/var/log`、`/var/tmp`、`/var/cache/pacman`、`/var/lib/{docker,flatpak}` **也是 offload**（原文档漏了）。
- **免密链路改用 `/opt` 下的 root 属主快照**（`/opt/steamos-backup/`，步骤[12] 自动同步整套工具）：
  ① 关掉提权口子 —— 旧规则指向用户可写的备份包，等于"能以 deck 执行代码者即可免密提权"；
  ② 抗挪位 —— 快照路径固定且 `/opt` 扛升级，不再出现"备份包一挪 sudo -n 就失配"；
  ③ 删掉那条多余的"自愈脚本"免密（它用户身份跑，不需要 sudo）。
  代价是快照可能落后于仓库 → `doctor.sh` 比对 sha256 并提示刷新（同时也保证了无人值守恢复
  只跑"人工确认过的版本"）。同步失败会自动退回旧行为并告警。
- **背键守护落点统一到 `/home`**：`setup-win5-backkeys.sh` 原先装 `/usr/local/bin`（升级即失效），
  改为 `~/.local/opt/gpd-win5-backkeys/`（与主脚本步骤[4] 一致），并按 `SUDO_USER` 解析真实家目录。
- `check.sh` 新增 6 条断言锁住以上不变量（含"不许把持久物装进 `/usr/local`"）。
- 验证：快照 44 文件 root:root 落在 offload；`sudo -n` 对快照两个脚本实测可用；
  指向旧路径的规则条数 = 0；`doctor.sh` 三项全绿。

## [3.9.1] - 2026-09-25

### 健壮性审查：修 1 个 P0 假成功 + 3 个 P1 + 一批判据假绿灯/假红灯
全量静态审查（11 类脆弱模式 × 全部顶层脚本 + 主脚本高风险段精读 + 上游体检）。结论：可行性没问题，
问题全在"假成功/假判据"这一类。逐条见 **SCRIPT-MAINTENANCE §13**。

- **P0 假成功**：GE-Proton 安装是"先删旧版 → `tar -xzf … 2>/dev/null`（错误被吞）→ 无条件打印安装完成 →
  再删掉 500MB 下载缓存"。包损坏/空间不足时 = 旧版没了 + 新版空壳 + 还报成功。改成
  「暂存 → 校验 `proton` → `mv` 原子换」；只有成功才清缓存。配套把 `verify_step(setup_games)`
  从"有没有目录"改成"真存在 `proton` 文件"（原来解包半失败也能判达标）。
- **P1**：`systemctl enable … >/dev/null 2>&1` 后不回查 `is-enabled`（背键守护、Decky）→ 回查并告警。
- **P1**：`pacman -Sy` 失败只 warn 就继续（后续按过期列表装包 = 部分升级风险）→ 默认中止，
  `PKG_ALLOW_STALE=1` 放行；并新增 `/var/lib/pacman/db.lck` 守卫（抢锁时给出可执行的处理办法）。
- **P1**：`install-ge-proton.sh`(509MB) / `install-dwproton.sh`(268MB) 下载补 `--max-time`，
  解包同样改"暂存→校验→原子换"。
- **P2**：`可选组件安装.sh` 自提权缺 TTY 守卫（非交互会永久卡在 sudo 密码）→ 加 `[ -t 0 ]` 守卫 + 绝对路径；
  `check.sh` 一条恒真的断言、无 `.git` 时跳过执行位检查 → 都改严；`fix_home_owner` 补齐
  `~/.cache/ge-proton`、`Downloads/dwproton-dl`、`~/.local/share/icons`；
  以及 `read` 守卫、`${prev:?}` 一致性、askpass 清理等零散加固。
- **新增 `doctor.sh`**：一屏只读体检（空间/必装组件/自愈链/开发文件/免密/上游），给结论 + 下一步，
  退出码可被脚本复用；配套给 `self-heal-after-upgrade.sh` 加 `--dry-run`（只读预演）。
- **一条假红灯的教训**：`sudo -l` 的输出会按终端宽度折行（输出到管道时 80 列，命令与参数分行），
  直接 grep 整条命令行会把"有免密规则"报成"缺失" → 判定前必须先拉平空白。

## [3.9.0] - 2026-09-25

### 自动恢复链 v4：面向**游戏模式**（本机大多数时间）
- **会不会自动唤起？会。** 实测 `systemctl --user list-dependencies default.target` 里就有本服务，
  且 Valve 自己的 `gamemoded` / `dmemcg-booster-user` 同样是 `WantedBy=default.target`
  （游戏模式离不开 gamemode）；再加步骤[12] 的 `loginctl enable-linger` 双保险。
- 新增 **`steamos-self-heal.timer`**（`OnBootSec=45s` + `OnUnitActiveSec=20min`）：
  原来 oneshot 失败就等下次开机，现在每 20 分钟重试；无事可做时服务实测 0.5 秒秒退。
  定时器经 `timers.target`（`WantedBy=basic.target`，而 `default.target` `Requires=basic.target`）被拉起。
- 新增 **`wait_online()`**：游戏模式一上来就是 gamescope UI，Wi-Fi 常还没连上，而主脚本 prepare 要
  `pacman -Sy`/装包 → 动手前先等网络（`nm-online` 优先，兜底 HTTP 探活，最多 120 秒）；
  等不到就静默交给定时器，不算失败、不写标记。
- 新增**失败标记** `~/.local/opt/steamos-self-heal/NEEDS-ATTENTION.txt`：游戏模式**没有通知守护**
  （镜像里只有 plasmashell 提供 `org.freedesktop.Notifications`），那里 `notify-send` 是哑的，
  所以失败必须留一个看得见的文件（内含两条可粘贴的命令）+ journal + 定时器重试。
- 步骤[12] 的落地复核同步要求定时器与 `timers.target.wants` 软链（文件在 ≠ 已启用）。

### 升级后自动恢复链升级到 v3（含开发文件）+ 免密悬案结案
- `self-heal-after-upgrade.sh` **v3**：新增"开发文件清点" —— 原子升级同样会摘掉 `/usr` 的
  include/cmake/pkgconfig（§12 的根因），表现是"以后编译任何东西都莫名报缺头文件"，平时完全无感。
  v3 用**便宜哨兵**（`/usr/lib/cmake/Qt6/Qt6Config.cmake`）+ "包在而文件不在"的双判据，
  只在真缺时才做 20 秒全量体检，然后 `sudo -n` 自动 `--apply` 补回来。
- 步骤[12] 的免密规则同步放行 `fix-missing-dev-files.sh`（不带参/带 `*` 两条），
  并让**判定与落地复核都认识这条**，否则已装机的机器会走 info 分支永远补不上。
- 新增 `diag-sudo-selfheal.sh`（只读，需 root）：一次查清 include 有没有、
  sudoers.d 里哪些文件被 sudo 忽略、规则里的路径是否还对得上当前备份包、三条 NOPASSWD 是否都在。
- **结案：免密确实一直在生效**（§11.9 悬案）。`sudo -n true` 报"需要密码"（排除缓存时间戳）而
  `sudo -n bash <MAIN> --after-upgrade` 能跑通，说明 NOPASSWD 命中；`sudo -n -l` 里能看到那几条规则。
- ⚠️ 顺带纠正一个**错判据**：`sudo -n -l <命令>` 判不出 NOPASSWD —— 本机有 Valve 的
  `%wheel ALL=(ALL) ALL`，任何命令查询都会"匹配成功"并原样回显（实测连 `/tmp/nonexistent.sh` 都返回 0）。
  正确判法只有拉**全量** `sudo -n -l`，再按命令行里的路径去认那几行 NOPASSWD。

### 新增 `fix-missing-dev-files.sh`：补 SteamOS 镜像裁掉的开发文件
- **发现（NextKde 编译卡在 `find_package(Qt6)` 时挖出来的）**：Valve 基础镜像把
  `usr/include/**`、`usr/lib/cmake/**`、`usr/lib/pkgconfig/*.pc`（外加 locale/doc）摘掉了，
  **但 pacman 数据库仍保留完整清单** → DB 说"已装"、磁盘上文件不存在。本机实测：
  `/usr/include` 31088 条里缺 **22619** 条，`.cmake`/`.pc` 8404 条里缺 **3986** 条。
  这不是升级事故，是镜像常态；任何要编译的步骤（AUR 包、KDE 插件）都会撞上。
- 新脚本默认**只抽取那三类开发文件写回 /usr**（`bsdtar -tf` → `-T` 选择性解包）：
  不覆盖运行时库、不带回 locale/doc（省 ~90% 体积）、不进 pacman 事务。
  `--full` 才退化为 `pacman -U --overwrite='*'` 整包重装。
- **版本安全闸**：只接受与本机同名版本（去 pkgrel 后）的包。SteamOS 的 `*-3.9` 固定仓库
  与本机对齐，滚动 `core`/`extra` 已更新（qt6 6.11.2 / KF6 6.30.0）→ 混装即部分升级，直接拒绝。
- 用法：`--check`(默认只读) / `--apply` / `--set kde|all` / `--pkgs a,b` / `--dry-run` / `--force`。
- **默认集合扩成两组**：① 通用 C/C++/X11/Wayland 基础；② **CMake 自带 Find 模块最常探的库**
  （xorgproto / xz / zstd / bzip2 / libarchive / gmp / nettle / gnutls / krb5 / libcap / pcre /
  python / gettext / double-conversion / …）。
  起因是一次实打实的判据教训：补完 libx11 后 `find_package(X11)` 仍报
  `missing: X11_X11_INCLUDE_PATH` —— 因为 `FindX11.cmake` 第一个查的是 **`X11/X.h`**，
  而它属于 **`xorgproto`** 而不是 libx11（"我补过的包全齐"并不等于"CMake 要找的文件齐"）。
- 另外修了两个健壮性问题：`pacman -Sp --print-format '%v' | head -1` 会把 pacman 的
  `:: 安装 xxx 破坏依赖 …` 信息行当成"仓库版本号"（改为按包名精确匹配）；个别包连固定仓库都往前跑了
  （实测 libwireplumber 本机 0.5.15 / 仓库 0.5.17）→ 现在会识别并明确跳过，而不是给一句误导的"版本不一致"。
- 再修一个真故障（真机第一次跑就撞上）：**缓存文件名不能拼死 `-x86_64`** —— 像 `xorgproto`
  这类 `arch=any` 包的文件名是 `<pkg>-<ver>-any.pkg.tar.zst`，导致它被误报"下载失败"而跳过
  （偏偏 xorgproto 正是 `FindX11` 的必需项）。现改为从 `pacman -Sp` 的 URL 取 basename 精确解析，
  并留"已缓存任意架构"兜底。新增 `FIXDEV_CACHE=<目录>` 环境变量用于拿替身缓存目录自测这条路径。
- 默认集合再补 `libepoxy`（`KWinConfig.cmake → find_dependency(epoxy)` → ECM `Findepoxy` 要 `epoxy/gl.h`）。
- 新增**预检法**（写进 §12）：把待补包的开发文件抽到临时前缀，用
  `cmake -DCMAKE_PREFIX_PATH=<临时前缀>/usr -DCMAKE_INCLUDE_PATH=<前缀>/usr/include …` 配置并 `ninja` 编译，
  **不动系统就能把整条编译链验穿**。实测 NextKde：只补 `libepoxy` 一个临时包即
  `Configuring done` + `ninja 33/33 BUILD_RC=0` → 结论：kde 集合之外真正还缺的只有
  `xorgproto` 与 `libepoxy` 两个包。
- 文档：SCRIPT-MAINTENANCE §12（完整根因与边界）、§1.2 脚本表、使用说明.txt【备用脚本】。

## [3.8.0] - 2026-09-25

### 新增必装步骤 [16]: Firefox Nightly（从可选组件提为必装）
- `setup_firefox()`：复用 `install-app-home.sh firefox-nightly`（单引擎），官方 tar.xz 解到
  `~/.local/opt/firefox-nightly` —— 不占 rootfs、无沙箱、扛原子升级，且**装 /home 后自带更新器
  能真正自更新**（装 /usr 时更新器被禁用）。
- 从 `可选组件安装.sh` 移除 firefox-nightly 菜单项（`MENU_ORDER`/`MENU_NAME`/`MENU_PKGS`/
  `MENU_CHECK`/`install_firefox_nightly`），其余可选组件不变。
- 全部步骤横幅 `/15` → `/16`，`check.sh` 新增步骤[16] 的 5 条不变量断言
  （函数存在 / map_step / FUNCS 两处 / 落点 /home / 复用单引擎），README、使用说明、
  重装流程、SCRIPT-MAINTENANCE 步骤表同步。

## [3.7.1] - 2026-09-25

### 修: 真机全量重装暴露的 3 个真故障 + 3 个判据问题（逐条复盘的定案见 SCRIPT-MAINTENANCE §11）
- **真故障：`/usr/include` 被 SteamOS 镜像裁掉** → 任何要编译 C 的 AUR 包必挂
  （本次是微信：`make ... 错误 1`，真因 `fatal error: string.h：没有那个文件或目录`）。
  新增 `ensure_c_headers()`（步骤[3] 工具链之后调用）：从快照源 `core-3.9` **重装同版本**
  glibc/linux-api-headers 还原头文件；**版本不一致时只警告不动手**（绝不把 libc 顶到滚动源的 2.44）。
  已实测：用同版本头文件编译 wechat 的 `libuosdevicea` 桩 → `rc=0`，产出正常 ELF。
- **真故障：自愈 user 服务从未启用**（单元文件在 ≠ 已启用；实测 `default.target.wants/` 里只有
  `gamemoded.service`）。根因是 root 下 `su - 用户 -c "systemctl --user enable"` 连不上该用户
  bus、又被 `2>/dev/null` 吞掉。改为**直接建 wants 相对软链** + `loginctl enable-linger`，
  并给 `verify_step(setup_selfheal)` 加软链判据（防"文件齐但服务 disabled"复发）。
- **真故障：Decky 预置插件一个都没装上**（`~/homebrew/plugins/` 只有 SimpleDeckyTDP）。
  `ProtonDB Badges` 名字自带空格，空格分隔的旧列表表达不了；且 `DECKY_PLUGINS=""` 时
  `${VAR-def}` 取的是空值 → 循环 0 次且毫无提示。改为数组默认 + `|` 分隔自定义。
- **判据修：LocalSend 防火墙**。SteamOS 出厂 `public` zone 已开 1024-65535/tcp+udp，
  显式 add-port 会被判 `ALREADY_ENABLED` 而**不写盘** → 旧的 `grep 53317` 判据让步骤[14]
  **永远"落地复核未通过"、永不记进度**，自愈那条 `fwport` 也每次开机白报。新增
  `fw_53317_ok()`（显式规则 → 范围规则 → `--query-port` 兜底），与 `self-heal-after-upgrade.sh` 同步。
- **判据修：`pacman -Qq base-devel` 是整组查询**，最小集必然缺组内成员 → 每台机器白报一次
  "未让 base-devel 判定通过"。改为逐包确认 `$BD_MIN` 六件套，缺哪个点名报哪个。
- **顺手修：root 属主污染 /home**。脚本以 root 写 /home 的东西属主是 root，导致用户自己重跑
  安装器"权限不够"（鸿蒙字体脚本实测被 root 属主的 `~/.cache/harmony-sans` 卡死）。
  新增 `fix_home_owner()`（主脚本全量跑完调用）+ `可选组件安装.sh` 同款收尾 +
  `install-harmony-sans-home.sh` 建完目录立刻归还属主。

### 文档
- `SCRIPT-MAINTENANCE.md` 新增 §11：本次 6 条告警逐条定案（含**哪些是无害噪音**，免得下次
  重新排查一遍），并纠正两条过时注释（`/var/cache/pacman` 在 p8、不占 rootfs；
  3.9 起 pacman 数据库是 `/usr/lib/holo/pacmandb`，在 rootfs 里、随 `/usr` 一起被换）。
- `check.sh` 新增 6 条不变量断言（防火墙判据 / wants 软链 / C 头文件还原 / 属主回收），
  防止这些修复被下次改动悄悄改回去。

## [3.7.0] - 2026-09-25

### 新增必装步骤 [15]: markdown 阅读器（glow）
- `setup_mdread()`：把 glow 的**官方发布物（单个静态二进制）**装进 `~/.local/bin`，
  并注册 `text/markdown` 文件关联 —— 双击 `.md` 就能在终端里渲染出来。
- **为什么是 glow 而不是 marker / ghostwriter / marknote 那些 GUI**：
  查过 Arch 官方 `extra`，那几个都要把 Qt/GTK 运行时装进 **rootfs**，原子升级必被冲掉；
  而 glow 只依赖 glibc（Arch 包里 `depends=(glibc)`），放 `/home` 就**永久幸存**。
  这条选择是本项目"能放 /home 就放 /home"铁律的直接应用。
- 下载沿用既有做法：镜像优先（gh-proxy → ghfast → ghproxy → 直连，各带 `url_reachable` 探活）、
  固定缓存名（断了重跑能续传）、API 不通时用已知兜底版本 v3.0.0。
- 桌面项遵守上一版刚定下的两条规矩：`Terminal=true`（不硬写终端）、**不写 TryExec**。

### 顺手统一了"步骤横幅"里的总数
- 之前各步骤横幅的分母是历史遗留的 `/7 /9 /10 /11 /12 /14` 混着 —— 现在统一为 `/15`。
- `check.sh` 新增**不变量断言**：所有步骤横幅的分母必须一致，且等于**最大步骤号**。
  （注意分母 ≠ `FUNCS` 元素个数：步骤8 rootfs 瘦身是步骤3 里按需触发的子步骤，不在全量顺序列表里。）
- 步骤[15] 的 6 个注册点与文档（README 步骤表 / 使用说明 / 维护手册两张表 / 重装流程）全部同步。

## [3.6.1] - 2026-09-25

### 修: 「重装后先运行我」双击没反应（根因是执行位）
- **根因**: 仓库里 **一个文件都不是可执行的**（`git ls-files -s` 全为 `100644`）——
  `steamos-setup.sh`、启动器 `.desktop`、启动脚本全是 644。而 Linux 上 `.desktop`
  **必须有执行位** Dolphin 才肯运行，于是双击**静默无反应**（连"不受信任"提示都可能不出现）。
  从 Windows / OneDrive / U 盘 拷回来的包更是必然丢权限位。
  → 已给全部 62 个 `.sh` 与 `.desktop` 在 git 里补上 `100755`；并在 `check.sh` 加断言防回归。
- **启动器不再硬依赖 konsole**: 原来 `TryExec=konsole` —— 没装 konsole 的机器上
  **整个入口会直接消失**（TryExec 找不到就被隐藏）。改为 `Terminal=true`，让桌面环境
  自己挑默认终端；同时 `Exec` 里不再硬写 konsole。
- **启动器改为薄壳，消除重复实现**: 原 `.desktop` 的 `Exec` 有 668 字符，把
  「装图标 / cd / 跑主脚本 / 问可选组件」整套逻辑重写了一遍（与 `.sh` 各一份）。
  现在 `.desktop` 只负责调 `重装后先运行我.sh`，**逻辑只有一份**。
- **改名**: `重装后先运行我-备用.sh` → **`重装后先运行我.sh`**（它已不是"备用"，而是唯一实现）。
- 启动脚本加了守卫: 找不到 `steamos-setup.sh` 时给一句明白话，而不是 `command not found`。
- 文档: `重装流程.md` 阶段3 **把"最稳的方式"改成先在 Konsole 跑一行**
  （`chmod +x *.sh *.desktop && bash 重装后先运行我.sh`）—— 一条命令绕开执行位与信任设置两个坑；
  `使用说明.txt` / `README.md` 同步补上"从网盘拷回来要先 chmod"的提醒。

## [3.6.0] - 2026-09-25

### 新增可选组件: NextKde（KOS Desktop Shell）
- 新增 `install-nextkde-home.sh` + 可选菜单第 6 项。NextKde 是基于 QuickShell 的
  **KDE Plasma 桌面外壳**（顶栏/Dock/启动器/全局搜索/通知中心），GPL-3.0。
- **定位: 包装上游官方安装器 `tools/kosctl`，不重写构建**。上游自带
  `doctor|build|install|start|uninstall`，会自己装依赖、编译、处理 KWin 插件与 plasmashellrc；
  重写一遍只会与上游脱节。本脚本只补三件上游不管而本项目在乎的事：
  ① 前置检查（Plasma6 Wayland / KWin≥6.4 / quickshell）② 源码与构建都放
  `~/.local/opt/NextKde`（= /home，扛原子升级）并**记录构建时的 KWin 版本**
  ③ 把"会动系统哪些地方"讲明白 + `--check` 在升级后判定要不要重编。
- 查证过的事实：上游**没有任何 release**（只能源码编译）、**AUR 里没有**、
  但 `quickshell` 在 Arch 官方 `extra`（0.3.1），不必走 AUR。
- **三条会改系统的后果，脚本会先讲清并要确认**（`--yes` 可跳过，非交互环境安全退出）：
  ① 编译依赖（qt6/kf6/kwin 开发包 + go/cmake/ninja，几百 MB）进 **rootfs**，升级被冲；
  ② `kosctl install` 会改 `plasmashellrc` 的 `ShellPackage` = **切换桌面外壳**，
     切换会让 plasmashell 另建 appletsrc → **壁纸重置**（上游自动迁移旧的）；
  ③ KWin 特效插件与 KWin 版本耦合，升级后可能要重编（`--check` 比对 `6.4.4 → 6.5.0` 之类）。
- 关于"升级后自动恢复"的取舍：**没有把它塞进自愈清单**。自愈清单的修复动作绑定
  "主脚本步骤号"，而这是可选组件、没有步骤号；更要紧的是，让自愈服务在每次登录时
  静默往 rootfs 拉几百 MB 编译依赖，正是本项目一直在避免的事。
  所以采取"**检测自动、大动作需你点头**"：`--check` 会准确告诉你是依赖被冲了还是
  KWin 变了，以及该跑哪条命令。

## [3.5.0] - 2026-09-25

### 重构: 4 个 app 安装脚本 → 1 个单引擎(路线图第 2 项)
- 新增 **`install-app-home.sh`**: `firefox-nightly` / `dsh-desktop` / `wps-office` 共用一个引擎,
  骨架(取源/解包/准原子替换/入口/桌面项/图标/自检)只写一遍, 各应用只贡献一段 profile。
  **仍然是单文件, 可单独拷到新机器** —— 用"单引擎 + profile"而不是"抽公共库", 正是为了保住这点。
- **删掉 3 个旧脚本**(`install-firefox-nightly-home.sh` / `install-dsh-desktop-home.sh` /
  `install-wps-office-home.sh`, 合计 1382 行); 引擎 663 行 → **净减 719 行**。
- ⚠️ **`install-workbuddy-home.sh` 刻意不并入**: 它不下载任何产物, 而是"让 AUR 装好的
  `/opt/WorkBuddy` 在 /home 下自持", 与"下载便携包"是两个物种。硬塞进来只会得到一堆
  `if app == workbuddy` 特例分支 —— 引擎头部已写明原因, 免得后人再试一次。
- 功能不缩水: `--lang` / `--version` / `--remove-system`(卸系统 firefox 回收 290M) 都保留,
  且**用错 app 会明确报错**而不是默默忽略。
- 顺带改进两处语义: ①**已有缓存就用, `--force` 不再逼着重新下载**(离线时 `--force` 才装得上),
  想强制重下用 `REFETCH=1`; ②**已是同版本时只补入口/桌面项, 不动本体**(WPS 那 2GB 不该白复制)。
- 三个 app 都用隔离 harness(假 tar.xz / 可自解压的假 AppImage / 假 deb + 替身工具)逐个验通,
  期间**抓出并修掉 4 个真 bug**(见下), 全部落地物与旧脚本逐项比对一致。

### 重构中实测抓出的 bug(都是"看起来能跑"的那种)
1. **`fetch()` 里 `local ok=0` 遮蔽了 `ok()` 函数** —— 函数内调 `ok "..."` 会失败。
2. **`ARCHIVE="$(fetch ...)"` 里 fetch 的提示走 stdout** —— 路径被日志污染,
   后面 `bsdtar -xf "$ARCHIVE"` 必然失败。修法: 提示全部 `>&2`。
3. **`ffn_urls()` 以 `[ -n ... ] && printf` 收尾** —— 条件为假时函数返回 1,
   调用方 `meta="$(app_urls)" || return 1` 会**静默退出**(firefox 装不上还不报错)。
4. **`do_install` 直接调 `app_entry`(只打印内容)**, 没走 `write_entry` ——
   入口内容全打到屏幕上, 文件根本没生成。

### 校验
`bash check.sh` 全绿(shellcheck warning = 0); 断言改盯新不变量(3 个 app 都注册在引擎里、
各自的目标路径、WPS 的 Exec/TryExec 两条 sed、菜单接入), 并新增两条针对上述坑的防回归断言
(fetch 必须 `>&2`、"同版本跳过"快速路径必须存在)。另用 `REFRESH` 路径实测过:
firefox 真源下载 + WPS 官方 546MB 签名 URL 下载均成功。

## [3.4.0] - 2026-09-25

### 新增: 可选组件 —— 鸿蒙字体 HarmonyOS Sans 装成系统字体
- 新增 `install-harmony-sans-home.sh`: 字体装进 `~/.local/share/fonts`(**扛原子升级**),
  配置写进 `~/.config/fontconfig/conf.d/10-harmony-sans.conf`。
- **为什么不用 AUR 的 `ttf-harmonyos-sans`**: 实测它装到 `/usr/share/fonts`(rootfs, 升级必被冲),
  且取源是华为 CDN 的**签名直链**(路径带时间戳+哈希)会过期 → 本脚本不写死地址,
  改由 `HARMONY_ZIP`(自备 zip, 推荐)或 `HARMONY_URL` 提供, 缺包时给出取源指引。
- **实测过的字体包结构(2026.06.12, 21MB / 17 条目)**, 两处反直觉, 已写进脚本注释:
  1. **拉丁与中文是两个文件** —— `HarmonyOS_Sans.ttf`(家族 `HarmonyOS Sans`, 0.3MB,
     含 Italic/Condensed) 与 `HarmonyOS_Sans_SC.ttf`(家族 `HarmonyOS Sans SC`, 19.7MB)。
     → 只挑"名字带 SC 的"会把拉丁和斜体全丢掉; 故 SC 变体 = "拉丁全家 + SC", 排除 TC。
  2. **16 个 ttf 里 8 个是苹果垃圾**(`__MACOSX/`、`._*` AppleDouble、`.DS_Store`), 且目录名带空格。
- 三条设计约束(`check.sh` 断言 2.11 盯着, 改错就红):
  字体必须在 `/home`; fontconfig 必须落 `conf.d/`(**不覆盖**用户已有的 `fonts.conf`);
  **monospace 绝不能写 prefer**(鸿蒙是比例字体, 顶替会让终端/代码字体错乱)。
- 另修自身一个小 bug: `--force` 原本是个空开关(设了变量却没用), 现已接入
  "已装好则跳过"的判断, 加 `--force` 才重解包重装。

## [3.3.0] - 2026-09-25

### 许可变更: MIT → **GPL-3.0**
- `LICENSE` 换成 GNU GPL v3 官方全文(取自 GitHub 许可库, 非手打)。
- `README.md`: 许可段重写 —— 明确写出「自用无义务 / Fork 后发布必须同样 GPL-3.0 /
  借用代码闭源不允许」, 并特别说明**本项目不会被第三方 GPL 程序传染**
  (本仓库不复制任何 GPL 源码, 只是安装与调用, 属单纯聚合)。
- `steamos-setup.sh`: 头部加 `SPDX-License-Identifier: GPL-3.0-or-later` 与版权声明。
- 为什么改: 与同类项目(如 NextKde 等 GPL 桌面组件)保持同一许可阵营,
  使改进必须回馈社区; 对本项目的实际使用场景(自己装机、自己跑)没有任何额外义务。
- 说明: MIT → GPL 是**单向可行**的(加限制允许, 去限制不允许)。当前代码版权全归作者本人,
  未来若接受外部贡献, 再改许可就需要所有贡献者同意。

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
