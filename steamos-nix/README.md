# steamos-nix —— nix 迁移试验分支（已冻结，与主脚本互不干扰）

> 这一整个目录是**另一条技术路线的试验**：用 nix（`flake.nix` + `nix/lib.nix` + `home-module.nix`）来
> 管理 SteamOS 的环境，替代主目录那套"直接跑 bash 脚本"的做法。
> 主目录的 `steamos-setup.sh` 才是维护中的正路；**本目录仅供参考**。

## ⚠️ 重要：`scripts/` 下的脚本与主目录重复是**故意的**，不要去重

`scripts/` 里那 25 个 `.sh` / `.py` 看起来像是主目录脚本的拷贝 —— **它们确实是，而且必须保持**。

原因在 `nix/lib.nix`：

```nix
# ── 1. steamos-tools: every .sh/.py in scripts/, deps injected ──
for f in "$src"/scripts/*.sh; do ... install -m 0755 "$f" "$out/bin/$b"
for f in "$src"/scripts/*.py; do ...
```

- nix 的 `src` 是**参与哈希的固定源树**（FOD / 可复现构建的前提），
  所以 nix 分支必须自带一份"当时那一版"的脚本，不能指向主目录。
- 删掉任何一个都会连带影响：
  - `steamos-tools` 这个 derivation 会少部署对应工具
  - `verify.sh`（它检查 `steamos-setup.sh`、`self-heal-after-upgrade.sh` 等是否在）
  - `.selftest/static-audit.py`（它直接读取 `scripts/steamos-setup.sh`）

**所以见到重复请不要"顺手优化掉"。** 若哪天不再需要这条线，正确做法是**整个目录迁到独立仓库或删除**，
而不是只删重复的脚本。

## 目录说明

| 路径 | 作用 |
|---|---|
| `flake.nix` / `machine.nix` | 入口与机型开关（`desktop` / `gpd-win5` / `steam-deck`） |
| `nix/lib.nix` | 核心：把脚本、字体、WPS/微信/LocalSend 等打成包 |
| `nix/home-module.nix` | 可选 home-manager 模块 |
| `config/` | vendor 配置真身（udev / systemd / sudoers / ntp / backkeys） |
| `scripts/` | **nix 分支自带的工具源树**（见上，勿去重） |
| `.selftest/` | 静态审计与仿真测试（`static-audit.py`、`b-harness.sh`） |
| `install.sh` / `verify.sh` / `bootstrap-nix.sh` | 安装、体检、引导 |

## 状态

2026-09-15~16 开发，之后冻结。里面的主脚本副本停留在 `v2.0.0` 时代，**不随主目录更新**。
