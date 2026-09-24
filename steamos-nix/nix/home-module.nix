# Optional home-manager module. Users who already run home-manager on the
# Deck can import `inputs.steamos-nix.homeManagerModules.steamos-nix` (or the
# path directly). Everyone else: use install.sh + `nix profile`, which needs
# no home-manager at all.
#
# It re-derives the package set from *this* flake tree so paths always match
# the profile contents (no dangling store references after upgrades).
{ config, pkgs, lib, ... }:
let
  cfg = config.steamos-nix;
  flakeSrc = lib.cleanSource ./..;
  mods = import ./lib.nix {
    inherit pkgs;
    lib = pkgs.lib;
    src = pkgs.lib.sourceByRegex flakeSrc [
      "flake\.nix" "flake\.lock"
      "nix(/.*)?" "config(/.*)?" "scripts(/.*)?"
    ];
    cfg = {
      user = config.home.username;
      stateDir = config.home.homeDirectory + "/.steamos-nix";
      activatePath = config.home.homeDirectory + "/.steamos-nix/bin/steamos-nix-activate";
      ntpServers = cfg.ntpServers;
      # 机型: home-manager 也是纯求值, 同样不能探测硬件 → 由选项显式指定
      machine = cfg.machine;
      installApps = cfg.installApps;
      wpsChinese = cfg.wpsChinese;
      # 中文字体: 必须传, 否则 lib.nix 读 cfg.cjkFont 会直接求值失败
      cjkFont = cfg.cjkFont;
      harmonySansHash = cfg.harmonySansHash;

      # WorkBuddy: nix 只提供转发器, electron 仅兜底(见 lib.nix 第 5 节)
      workbuddyDir = cfg.workbuddyDir;
      workbuddyElectron = cfg.electronPackage;
      workbuddyFlags = cfg.workbuddyFlags;
      dshVersion = "0.1.2-rc.1";
      dshTarballHash = cfg.dshTarballHash;
      dshNpmDepsHash = cfg.dshNpmDepsHash;
    };
  };
in
{
  options.steamos-nix = {
    enable = lib.mkEnableOption "nix-managed SteamOS/GPD-Win5 environment";
    ntpServers = lib.mkOption {
      type = lib.types.str;
      default = "ntp.aliyun.com ntp.tencent.com";
    };
    machine = lib.mkOption {
      type = lib.types.enum [ "gpd-win5" "steam-deck" "desktop" ];
      default = "desktop";
      description = "Machine class; decides which /etc entries get generated.";
    };
    installApps = lib.mkOption { type = lib.types.bool; default = false;
      description = "Build the desktop app bundle (WPS/WeChat/LocalSend). Needs allowUnfree."; };
    wpsChinese = lib.mkOption { type = lib.types.bool; default = true; };
    cjkFont = lib.mkOption {
      type = lib.types.enum [ "harmony-sans" "noto" "none" ];
      default = "harmony-sans";
      description = "CJK font source. harmony-sans pulls Huawei's zip (external FOD, unfree).";
    };
    harmonySansHash = lib.mkOption { type = lib.types.str;
      default = "sha256-c10AIlce3WSqzKI9cq9LoobRJHgbqnzBo/d958Acz/A=";
      description = "fetchzip hash for the HarmonyOS Sans zip (FOD — fix via two-pass build)."; };

    workbuddyDir = lib.mkOption { type = lib.types.str; default = "/opt/workbuddy"; };
    workbuddyFlags = lib.mkOption {
      type = lib.types.str;
      default = "--enable-features=UseOzonePlatform --ozone-platform=wayland --enable-wayland-ime --wayland-text-input-version=3";
    };
    # ★ 仅兜底: 转发器优先用 /usr/bin/workbuddy, 其次系统 electron, 轮不到这个
    electronPackage = lib.mkOption { type = lib.types.package; default = pkgs.electron;
      description = "Last-resort Electron only. The launcher prefers the system wrapper/electron." };
    dshTarballHash = lib.mkOption { type = lib.types.str; default = lib.fakeSha256; };
    dshNpmDepsHash = lib.mkOption { type = lib.types.str; default = lib.fakeSha256; };
    installDsh = lib.mkOption { type = lib.types.bool; default = false;
      description = "Add dsh once its npm hashes have been bootstrapped (needs network + two-pass build)."; };
    enableHealUnit = lib.mkOption { type = lib.types.bool; default = true; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ mods.steamos-tools mods.workbuddy mods.steamos-nix-activate ]
      ++ lib.optionals cfg.installDsh [ mods.dsh ];

    systemd.user.services.steamos-nix-heal = lib.mkIf cfg.enableHealUnit {
      Unit.Description = "SteamOS atomic-update self-heal (nix-managed /etc re-link)";
      Service.Type = "oneshot";
      Service.ExecStart =
        let activate = config.home.homeDirectory + "/.steamos-nix/bin/steamos-nix-activate";
        in "${pkgs.shadow}/bin/sudo -n ${activate} --state ${config.home.homeDirectory}/.steamos-nix --quiet";
      Service.Restart = "on-failure";
      Service.RestartSec = 20;
      Install.WantedBy = [ "default.target" ];
    };
  };
}
