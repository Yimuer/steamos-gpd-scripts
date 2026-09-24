{
  description = "Persistent, update-surviving SteamOS environment managed by Nix (machine-aware)";

  # 境内提示: 构建闭包大头由 ~/.config/nix/nix.conf 的国内 substituters 承担
  # (bootstrap-nix.sh 自动写入 USTC/TUNA); 若 GitHub 解析不通, 挂 https_proxy
  # 或用 `nix flake update --override-flake nixpkgs <本地克隆>`。
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";

      # ── 机型: 由 scripts/steamos-nix-detect.sh --write 维护 ────────────
      # nix 是纯求值, 不能在构建期探测硬件; 所以探测在 nix 之外做,
      # 结论落到这个文件里,再由 lib.nix 决定"构建哪些部件"。
      machineCfg = import ./machine.nix;

      pkgs = import nixpkgs {
        inherit system;
        config = {
          # WPS Office(unfreeRedistributable)与微信(unfree)都是专有软件;
          # HarmonyOS Sans 的授权是"可嵌入、不可单独再分发", 同样是 unfree。
          # 不显式放行的话 nix 会在**求值阶段**就拒绝(_may_ not be built)。
          # 若你把 apps 相关选项全关掉、cjkFont 设为 "none", 这里也可以改回 false。
          allowUnfree = true;
        };
      };

      # ── tunables (edit here, this flake is the single source of truth) ──
      cfg = {
        user = "deck";                       # SteamOS login user
        stateDir = "/home/deck/.steamos-nix";# persistent pointer dir (on /home)
        # stable path the sudoers rule + heal unit use (maintained by install.sh)
        activatePath = "/home/deck/.steamos-nix/bin/steamos-nix-activate";

        # 机型: gpd-win5 | steam-deck | desktop  (来自 machine.nix)
        machine = machineCfg.machine;

        # 桌面生产力软件是否纳入构建/安装
        installApps = true;
        # WPS 中文版(自带中文字体包装更好)。台式机通常要 true。
        wpsChinese = true;

        # ── 中文字体 ──────────────────────────────────────────────────────
        # "harmony-sans" → 自建 harmonyos-sans derivation(华为官方 zip, 简中 SC)
        # "noto"         → Noto CJK + 文泉驿(兜底, 不需要外部 FOD)
        # "none"         → 不装字体(WPS/微信会显示豆腐块, 仅调试用)
        cjkFont = "harmony-sans";
        # fetchzip 是 FOD: 这个值必须与实际解包结果一致。
        # 若 nix 报 "hash mismatch ... got: sha256-XXX", 把 XXX 整串填回来即可。
        harmonySansHash = "sha256-c10AIlce3WSqzKI9cq9LoobRJHgbqnzBo/d958Acz/A=";

        ntpServers = "ntp.aliyun.com ntp.tencent.com";

        # WorkBuddy **不进 nix**: nix 只提供一个转发器, 优先 exec 系统原生的
        # /usr/bin/workbuddy(AUR), 其次系统 electron, nix electron 仅最后兜底。
        # 理由见 nix/lib.nix 第 5 节 —— 只读 store 会让自更新/插件/输入法/portal 全废。
        workbuddyDir = "/opt/workbuddy";                 # app payload(offload→home, 升级幸存)
        workbuddyElectron = pkgs.electron;               # ★ 仅兜底, 正常轮不到它
        workbuddyFlags = "--enable-features=UseOzonePlatform --ozone-platform=wayland --enable-wayland-ime --wayland-text-input-version=3";

        dshVersion = "0.1.2-rc.1";
        dshTarballHash = pkgs.lib.fakeSha256;
        dshNpmDepsHash = pkgs.lib.fakeSha256;
      };

      # only what the packages actually read from the flake tree
      src = pkgs.lib.sourceByRegex self [
        "flake\.nix" "flake\.lock" "machine\.nix" "README-migration\.md"
        "nix(/.*)?" "config(/.*)?" "scripts(/.*)?"
      ];

      mods = import ./nix/lib.nix { inherit pkgs nixpkgs; lib = pkgs.lib; inherit src cfg; };

      corePackages = {
        inherit (mods) steamos-tools steamos-etc steamos-nix-activate workbuddy dsh;
        gpd-win5-backkeys-daemon = mods.backkeys-daemon;
      };
      # 专有软件可能在某些 nixpkgs commit 上缺失/改名 —— lib.nix 里用 `pkgs.X or null`
      # 兜底成 null; 这里把它从 attribute set 里滤掉, 否则 `nix flake show` 会因为
      # "expected derivation" 而整体失败(连带 A 组验证也过不去)。
      appPackages =
        pkgs.lib.filterAttrs (_: v: v != null) {
          inherit (mods)
            wps-office wechat localsend
            harmonyos-sans steamos-cjk-fonts steamos-cjk-fonts-fallback
            steamos-apps;
        };
    in
    {
      packages.${system} = corePackages // appPackages // {
        # build the machine-relevant set (dsh excluded: its hashes need a network bootstrap)
        all = pkgs.symlinkJoin {
          name = "steamos-nix-bundle";
          paths =
            [ mods.steamos-tools mods.steamos-etc mods.steamos-nix-activate mods.workbuddy ]
            ++ pkgs.lib.optional (cfg.installApps && mods.steamos-apps != null) mods.steamos-apps;
        };
      };
      defaultPackage.${system} = mods.steamos-tools;

      apps.${system} = {
        activate = {
          type = "app";
          program = "${mods.steamos-nix-activate}/bin/steamos-nix-activate";
        };
        detect = {
          type = "app";
          program = "${mods.steamos-tools}/bin/steamos-nix-detect.sh";
        };
      };

      # For users who keep a home-manager setup: import this module.
      homeManagerModules.steamos-nix = ./nix/home-module.nix;
    };
}
