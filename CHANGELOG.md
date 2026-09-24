# CHANGELOG — steamos-reinstall-backup

遵循语义化版本：`主版本.次版本.修订号`
- 主版本：步骤结构/目标环境变化（不保证旧机器直接复用）
- 次版本：新增步骤或功能
- 修订号：bug 修复与健壮性加固
每次提交后打标签 `vX.Y.Z`；`bash check.sh` 全绿才允许提交（pre-commit 钩子强制）。

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
