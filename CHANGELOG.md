# CHANGELOG — steamos-reinstall-backup

遵循语义化版本：`主版本.次版本.修订号`
- 主版本：步骤结构/目标环境变化（不保证旧机器直接复用）
- 次版本：新增步骤或功能
- 修订号：bug 修复与健壮性加固
每次提交后打标签 `vX.Y.Z`；`bash check.sh` 全绿才允许提交（pre-commit 钩子强制）。

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
