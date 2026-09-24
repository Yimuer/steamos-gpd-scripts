# steamos-nix package set
# ---------------------------------------------------------------------------
# Turns everything steamos-setup.sh used to scatter across /etc and /usr into
# content-addressed, update-surviving /nix/store artifacts:
#   - steamos-tools         : all maintenance scripts on PATH via nix profile
#   - gpd-win5-backkeys-daemon : vendored python daemon (Win5 machines only)
#   - steamos-etc           : the volatile /etc files — **裁剪到当前机型**
#   - steamos-nix-activate  : idempotent post-wipe re-linker
#   - workbuddy             : electron launcher with the IME flags baked in
#   - dsh                   : @deepseek-ai/dsh pinned via npm
#   - wps-office / wechat   : 桌面生产力软件(专有, 需 allowUnfree)
#   - localsend             : 局域网传文件(Flutter, MIT)
#   - harmonyos-sans        : 鸿蒙简体中文字体(自建 derivation, 上游 zip 是 FOD)
#   - steamos-cjk-fonts     : 上面字体与 Noto 兜底集之间的开关
#
# 机型开关见 ../machine.nix —— 由 scripts/steamos-nix-detect.sh 维护。
# ---------------------------------------------------------------------------
{ pkgs, nixpkgs ? null, lib, src, cfg }:

let
  inherit (pkgs) stdenvNoCC runCommand;

  # ── 机型 ──────────────────────────────────────────────────────────────
  machine = cfg.machine or "desktop";
  isWin5 = machine == "gpd-win5";
  isHandheld = machine == "gpd-win5" || machine == "steam-deck";

  # ── runtime toolchain the vendored scripts expect on PATH ───────────────
  # NOTE: pyyaml 是必需的 —— steamos-setup.sh 的能力表派生(std 1265)与
  # 写后自检(std 1318)都用 `import sys, yaml`; 少了它 step4 会静默失败。
  pythonForScripts = pkgs.python3.withPackages (ps: [ ps.vdf ps.pyyaml ]);
  runtimeDeps = [
    pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.gawk
    pkgs.findutils pkgs.diffutils pkgs.gnutar pkgs.gzip pkgs.bzip2
    pkgs.zip pkgs.unzip pkgs.zstd pkgs.curl pkgs.wget pkgs.jq
    pkgs.git pkgs.file pkgs.patch pkgs.procps pkgs.util-linux
    pythonForScripts
  ];
  runtimePath = lib.makeBinPath runtimeDeps;

  # ── 1. steamos-tools: every .sh/.py in scripts/, deps injected ──────────
  steamos-tools = stdenvNoCC.mkDerivation {
    pname = "steamos-tools";
    version = "1.1.0";
    inherit src;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    dontPatchShebangs = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/libexec/steamos-tools"

      for f in "$src"/scripts/*.sh; do
        b=$(basename "$f")
        install -m 0755 "$f" "$out/bin/$b"
        wrapProgram "$out/bin/$b" --prefix PATH : "${runtimePath}"
      done

      for f in "$src"/scripts/*.py; do
        b=$(basename "$f" .py)
        install -m 0644 "$f" "$out/libexec/steamos-tools/$b.py"
        makeWrapper "${pythonForScripts}/bin/python3" "$out/bin/$b" \
          --add-flags "$out/libexec/steamos-tools/$b.py" \
          --prefix PATH : "${runtimePath}"
      done

      # ── 修复: setup-win5-backkeys.sh 的"同级文件"假设 ──
      # 它按 $(dirname $0) 找 gpd-win5-backkeys.py 与 20-gpd_win5.capmap.yaml。
      # nix 里 $0 落在只读的 store, 且这两个资源不在 $out/bin —— 直接把真路径喂给它,
      # 既避免它往 store 里写文件, 也避免它降级用上游默认能力表。
      wrapProgram "$out/bin/setup-win5-backkeys.sh" \
        --set-default DAEMON_SRC "${src}/config/python/gpd-win5-backkeys.py" \
        --set-default CAPMAP_SRC "${src}/config/inputplumber/capability_maps.d/20-gpd_win5.yaml"

      # convenience alias used by the legacy self-heal sudoers rule
      ln -s "$out/bin/self-heal-after-upgrade.sh" "$out/bin/steamos-self-heal"
      runHook postInstall
    '';
    meta.description = "SteamOS maintenance scripts, nix-wrapped with their runtime deps";
  };

  # ── 2. backkeys daemon (vendored source → store, Win5 only in practice) ──
  backkeys-daemon = runCommand "gpd-win5-backkeys-daemon" {} ''
    mkdir -p "$out"
    install -m 0644 ${src}/config/python/gpd-win5-backkeys.py "$out/gpd-win5-backkeys.py"
  '';

  # ── 3. volatile /etc files, generated from templates ────────────────────
  ntp-conf = pkgs.substituteAll {
    src = src + "/config/ntp/ntp.conf.in";
    NTP_SERVERS = cfg.ntpServers;
  };
  sudoers-frag = pkgs.substituteAll {
    src = src + "/config/sudoers.d/steamos-nix.in";
    USER     = cfg.user;
    ACTIVATE = cfg.activatePath;
  };

  # 这三件只在 GPD Win 5 上有意义
  backkeys-unit = pkgs.substituteAll {
    src = src + "/config/systemd/gpd-win5-backkeys.service.in";
    PYTHON  = "${pkgs.python3}/bin/python3";
    DAEMON  = "${backkeys-daemon}/gpd-win5-backkeys.py";
  };
  udev-rule = pkgs.copyPathToStore (src + "/config/udev/rules.d/70-gpd-backkeys.rules");

  # ── the assembled /etc overlay — steamos-nix-activate symlinks this ─────
  # 跨机型通用部分: NTP drop-in + sudoers
  # Win5 专属部分:  背键 unit + udev + inputplumber 覆盖/能力表
  steamos-etc = runCommand "steamos-etc-${machine}" {} ''
    mkdir -p "$out/etc/systemd/timesyncd.conf.d" "$out/etc/sudoers.d"
    cp ${ntp-conf}     "$out/etc/systemd/timesyncd.conf.d/ntp.conf"
    cp ${sudoers-frag} "$out/etc/sudoers.d/steamos-nix"
  '' + lib.optionalString isWin5 ''
    mkdir -p "$out/etc/systemd/system" \
             "$out/etc/udev/rules.d" \
             "$out/etc/inputplumber/devices.d" \
             "$out/etc/inputplumber/capability_maps.d"
    cp ${backkeys-unit} "$out/etc/systemd/system/gpd-win5-backkeys.service"
    cp ${udev-rule}     "$out/etc/udev/rules.d/70-gpd-backkeys.rules"
    cp ${src}/config/inputplumber/devices.d/20-gpd_win5.yaml \
       "$out/etc/inputplumber/devices.d/20-gpd_win5.yaml"
    cp ${src}/config/inputplumber/capability_maps.d/20-gpd_win5.yaml \
       "$out/etc/inputplumber/capability_maps.d/20-gpd_win5.yaml"
  '';

  # ── 4. steamos-nix-activate — the single post-update recovery command ───
  steamos-nix-activate = pkgs.writeShellScriptBin "steamos-nix-activate" ''
    # explicit PATH: runs fine under sudo's stripped environment
    export PATH="${runtimePath}:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin"
    set -u
    MODE=apply
    PREFIX=''${STEAMOS_NIX_PREFIX:-}
    STATE=''${STEAMOS_NIX_STATE:-}
    if [ -z "$STATE" ]; then STATE="${cfg.stateDir}"; fi
    while [ $# -gt 0 ]; do
      case "$1" in
        --check) MODE=check ;;
        --state) shift; STATE=$1 ;;
        --prefix) shift; PREFIX=$1 ;;
        --quiet|-q) QUIET=1 ;;
        *) echo "usage: steamos-nix-activate [--check] [--state DIR] [--prefix DIR] [--quiet]" >&2; exit 64 ;;
      esac
      shift
    done
    QUIET=''${QUIET:-0}
    say() { [ "$QUIET" = 1 ] || echo "$@"; }
    err() { echo "$@" >&2; }

    ETC_DIR="$STATE/etc-current/etc"
    if [ ! -d "$ETC_DIR" ]; then
      err "[steamos-nix-activate] missing $ETC_DIR"
      err "  → store 大概率被 GC 了: 重跑 bash install.sh(联网一次)即可重建。"
      err "  → 若确实没有 store: 先在 steamos-nix 目录里跑 bash install.sh。"
      exit 1
    fi

    if [ "$MODE" = apply ] && [ -z "$PREFIX" ] && [ "$(id -u)" != 0 ]; then
      err "[steamos-nix-activate] apply mode needs root (sudo steamos-nix-activate), or pass --prefix for a sandbox dry run"
      exit 1
    fi

    # ── rootfs write gate (SteamOS mounts / ro by default) ──
    if [ "$MODE" = apply ] && [ -z "$PREFIX" ]; then
      if ! touch /etc/.steamos-nix-wtest 2>/dev/null; then
        if command -v steamos-readonly >/dev/null 2>&1; then
          steamos-readonly disable || true
        fi
        if ! touch /etc/.steamos-nix-wtest 2>/dev/null; then
          mount -o remount,rw / 2>/dev/null || true
        fi
        if ! touch /etc/.steamos-nix-wtest 2>/dev/null; then
          err "[steamos-nix-activate] /etc is not writable even after steamos-readonly disable; aborting."
          exit 1
        fi
      fi
      rm -f /etc/.steamos-nix-wtest
    fi

    # ── sanity: warn if /nix shares the rootfs device (survival premise) ──
    if command -v findmnt >/dev/null 2>&1 && [ "$MODE" = apply ]; then
      nix_src=$(findmnt -no SOURCE /nix 2>/dev/null || true)
      root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
      if [ -n "$nix_src" ] && [ "$nix_src" = "$root_src" ]; then
        case "$nix_src" in
          *overlay*) say "[steamos-nix-activate] NOTE: /nix resolves onto the volatile rootfs image — content may NOT survive the next atomic update." ;;
        esac
      fi
    fi

    CHANGED=0
    MISSING=0
    # NOTE: 用 while-read 而非 for-in-$(find): ① 路径含空格不会被分词
    # ② 循环体内对 MISSING/CHANGED 的赋值不会被子 shell 吃掉。
    FILELIST="$(mktemp 2>/dev/null || echo /tmp/.steamos-nix-filelist.$$)"
    trap 'rm -f "$FILELIST" 2>/dev/null' EXIT
    find "$ETC_DIR" -type f | sort > "$FILELIST"
    while IFS= read -r src_file; do
      [ -n "$src_file" ] || continue
      tgt="$PREFIX$(echo "$src_file" | sed "s#^$STATE/etc-current##")"
      case "$MODE" in
        check)
          if [ ! -e "$tgt" ]; then
            err "MISSING $tgt"
            MISSING=1
          fi
          ;;
        apply)
          mkdir -p "$(dirname "$tgt")" || { err "[steamos-nix-activate] mkdir failed: $tgt"; MISSING=1; continue; }
          case "$tgt" in
            */sudoers.d/*)
              # sudo enforces 0440/root-owned on sudoers fragments: copy, do not symlink
              tmp="$tgt.steamos-nix.tmp"
              if install -m 0440 "$src_file" "$tmp" 2>/dev/null; then
                if command -v visudo >/dev/null 2>&1 && ! visudo -cf "$tmp" >/dev/null 2>&1; then
                  err "[steamos-nix-activate] generated sudoers failed visudo — NOT installing it."
                  rm -f "$tmp"; MISSING=1; continue
                fi
                mv "$tmp" "$tgt" || { err "[steamos-nix-activate] sudoers move failed: $tgt"; MISSING=1; }
              else
                err "[steamos-nix-activate] could not install sudoers: $tgt"
                MISSING=1
              fi
              ;;
            *)
              # NOTE: 解析到 store 真路径再链接。若直接 link 到
              # $STATE/etc-current/..., target 会是一条指向 /home 的软链 ——
              # systemd/udev 在 /home 挂载前 open 它只会拿到 ENOENT。
              real_src="$(readlink -f "$src_file" 2>/dev/null || echo "$src_file")"
              if [ "$(readlink -f "$tgt" 2>/dev/null)" != "$real_src" ]; then
                if ln -sfn "$real_src" "$tgt"; then
                  CHANGED=1
                else
                  err "[steamos-nix-activate] link failed: $tgt -> $real_src"
                  MISSING=1
                fi
              fi
              ;;
          esac
          ;;
      esac
    done < "$FILELIST"

    if [ "$MODE" = check ]; then
      [ "$MISSING" = 0 ] && say "[steamos-nix-activate] all nix-managed /etc entries present."
      exit "$MISSING"
    fi

    # ── reload subsystems (skipped in --prefix sandbox runs) ──
    if [ -n "$PREFIX" ]; then
      say "[steamos-nix-activate] sandbox (prefix=$PREFIX): $CHANGED link(s) created, live subsystems untouched."
      exit "$MISSING"
    fi
    udevadm control --reload 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    # ── 背键守护: 只有当 etc 树里真的有这个 unit 才操作 ──
    # (机型裁剪的直接后果 —— desktop 机型下不该出现任何 GPD 相关动作)
    if [ -f "$ETC_DIR/etc/systemd/system/gpd-win5-backkeys.service" ]; then
      VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
      PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
      if { echo "$VENDOR$PRODUCT" | grep -qi GPD && echo "$VENDOR$PRODUCT" | grep -q "G1618-05"; } \
         || [ "''${WIN5_FORCE:-0}" = 1 ]; then
        systemctl enable --now gpd-win5-backkeys.service 2>/dev/null || true
        say "[steamos-nix-activate] backkeys daemon enabled (GPD Win5 detected)."
      else
        systemctl disable --now gpd-win5-backkeys.service 2>/dev/null || true
        say "[steamos-nix-activate] unit shipped but hardware is $VENDOR/$PRODUCT: backkeys left disabled."
      fi
    fi

    systemctl restart systemd-timesyncd 2>/dev/null || true
    say "[steamos-nix-activate] done. nix-managed /etc re-linked from $ETC_DIR (machine=${machine})."
  '';

  # ── 5. WorkBuddy: 系统原生优先的转发器 —— 绝不把它塞进 nix ──────────────
  #
  # ⚠ 设计决定(别改回去): WorkBuddy 是 Electron 应用, 它的**自更新、dsh/MCP 插件安装、
  #   native 模块(.node)、IBus 输入法模块、xdg-desktop-portal(文件对话框/截屏)、
  #   dbus 通知与托盘** —— 全都依赖一个**可写的、完整的系统环境**。
  #
  #   而 /nix/store 是只读的。之前"用 pkgs.electron 去启动 /opt/workbuddy 的 app.asar"
  #   这个做法等于把它关进半个沙盒, 后果是:
  #     · electron ABI 与 app 自带 native 模块对不上 → 插件加载失败
  #     · 看不到系统 dbus / portal / 输入法模块路径 → 打不了中文、开不了文件对话框
  #     · store 只读 → 不能自更新、装不了插件
  #
  # 所以现在 nix 只提供一个**转发器**(本体在 ~/.nix-profile, 升级幸存):
  #   ① 优先 exec 系统原生的 /usr/bin/workbuddy —— AUR 的原生 wrapper, 完全跑在系统里
  #   ② 系统 wrapper 被原子升级冲掉了 → 用**系统 electron**(不是 nix 的)启动 /opt 的 payload
  #   ③ 都没有 → 才用 nix electron 兜底, 并且显式关掉 chromium sandbox
  # 强制指定: STEAMOS_NIX_WORKBUDDY=system | nix
  workbuddy = pkgs.writeShellScriptBin "workbuddy" ''
    # 系统路径排在最前: 让 WorkBuddy 看到系统库 / dbus / portal / 输入法模块,
    # 而不是 nix 那一套。nix 的 runtimePath 放最后, 只作兜底。
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${runtimePath}"

    MODE=''${STEAMOS_NIX_WORKBUDDY:-auto}
    # 仅 chroot / 沙盒测试需要改这个; 真机上就是 /usr
    SYSROOT=''${STEAMOS_NIX_SYSROOT:-/usr}

    # ① 系统原生 wrapper —— 最理想的一条路: WorkBuddy 完全不在 nix 里
    if [ "$MODE" != nix ] && [ -x "$SYSROOT/bin/workbuddy" ] && [ ! -L "$SYSROOT/bin/workbuddy" ]; then
      exec "$SYSROOT/bin/workbuddy" "$@"
    fi

    # 能走到这里 = /usr 里那个 wrapper 已被原子升级冲掉(正是本方案要解决的问题)。
    # /opt 是 offload→home, 升级幸存, 所以 app payload 还在。
    DIR=''${WORKBUDDY_DIR:-${cfg.workbuddyDir}}
    APP=""
    for cand in "$DIR/resources/app.asar.unpacked" "$DIR/resources/app.asar" "$DIR"; do
      [ -e "$cand" ] && { APP="$cand"; break; }
    done
    if [ -z "$APP" ]; then
      echo "workbuddy(nix): $DIR 下没有 app payload —— 先用 AUR 装 workbuddy(yay -S workbuddy)。" >&2
      exit 1
    fi

    # ②/③ 挑 electron: 系统的优先(ABI 与本机 native 模块一致), nix 的只兜底
    ELECTRON_BIN=''${WORKBUDDY_ELECTRON:-}
    if [ -z "$ELECTRON_BIN" ]; then
      for c in "$SYSROOT/bin/electron" "$SYSROOT/bin/electron-"*; do
        [ -x "$c" ] && { ELECTRON_BIN="$c"; break; }
      done
    fi
    if [ -z "$ELECTRON_BIN" ]; then
      ELECTRON_BIN="${cfg.workbuddyElectron}/bin/electron"
      echo "workbuddy(nix): 系统 electron 不可用, 退回 nix electron —— 输入法/portal/原生插件可能异常, 重装 AUR electron 可恢复。" >&2
    fi

    # Electron/Chromium 的 sandbox 一律关掉 —— 要的是完整系统访问
    # (IBus 输入法模块、xdg-desktop-portal、dbus 通知/托盘都依赖它)
    export ELECTRON_DISABLE_SANDBOX=1
    NO_SANDBOX="--no-sandbox --disable-setuid-sandbox"

    # native 模块(.node)常要链接系统库; 追加而非覆盖, 且放末尾不抢 nix 的
    export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$SYSROOT/lib:$SYSROOT/lib64"

    # 输入法(全机型统一 IBus, SteamOS 自带):
    #   系统已设就尊重(比如 KDE 的 plasma-workspace/env 已经设了), 全空才补。
    #   而且 **Wayland 下只补 XMODIFIERS** —— KWin 自己拉起输入法
    #   (kwinrc [Wayland] InputMethod); 再强设 GTK/QT_IM_MODULE 会让 WorkBuddy
    #   改走 XWayland 的 IM 模块, 结果候选框不跟随、甚至打不出中文。
    #   与 scripts/setup-ibus-xiaohe.sh 写出的 env 片段是同一套判断, 别改歪。
    if [ -z "''${GTK_IM_MODULE:-}" ] && [ -z "''${QT_IM_MODULE:-}" ] && [ -z "''${XMODIFIERS:-}" ]; then
      if [ "''${XDG_SESSION_TYPE:-}" = wayland ]; then
        export XMODIFIERS=@im=ibus
      else
        export GTK_IM_MODULE=ibus QT_IM_MODULE=ibus XMODIFIERS=@im=ibus
      fi
    fi

    exec "$ELECTRON_BIN" $NO_SANDBOX "$APP" ${cfg.workbuddyFlags} "$@"
  '';

  # ── 6. dsh (@deepseek-ai/dsh) pinned via npm ────────────────────────────
  dsh = pkgs.buildNpmPackage {
    pname = "dsh";
    version = cfg.dshVersion;
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-${cfg.dshVersion}.tgz";
      hash = cfg.dshTarballHash;
    };
    npmDepsHash = cfg.dshNpmDepsHash;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib/node_modules" "$out/bin"
      cp -r package "$out/lib/node_modules/dsh"
      bin=$(node -e 'const p=require("'"$out"'/lib/node_modules/dsh/package.json"); const b=p.bin; console.log(typeof b==="string"? b : (b && Object.values(b)[0]) || "index.js");')
      cat > "$out/bin/dsh" <<EOF
#!/bin/sh
exec ${pkgs.nodejs}/bin/node "$out/lib/node_modules/dsh/$bin" "\$@"
EOF
      chmod 0755 "$out/bin/dsh"
      runHook postInstall
    '';
    meta.description = "DeepSeek Agent Harness CLI (pinned version, nix-managed)";
  };

  # ── 7. 桌面生产力软件: WPS Office / 微信 / LocalSend ───────────────────
  # 前两个在 nixpkgs 是 binary redistribution + unfree license:
  #   wpsoffice  : deb 解包 + autoPatchelfHook   (attr: pkgs.wpsoffice)
  #   wechat     : AppImage 解包 + wrapAppImage  (attr: pkgs.wechat)
  #   localsend  : Flutter 源码构建               (attr: pkgs.localsend, MIT, 不 unfree)
  # 用 `pkgs.X or null` 兜底 —— 万一后续 channel 改名或下线, 不会拖垮整个 flake 求值。
  wpsPkg =
    if pkgs ? wpsoffice then
      # 中文版自带中文字体, 免得 WPS 界面全是豆腐块
      pkgs.wpsoffice.override { useChineseVersion = cfg.wpsChinese; }
    else
      null;
  wechatPkg = pkgs.wechat or null;
  localsendPkg = pkgs.localsend or null;

  # GUI 包装: Wayland 会话下 Qt / GTK 应用有时会出现缩放/输入法跟随异常,
  # 提供 -x11 变体强制走 XWayland。Qt 用 QT_QPA_PLATFORM=xcb, GTK(Flutter) 用
  # GDK_BACKEND=x11。IME 变量不写死(统一 IBus, 但系统已设就尊重),
  # 需要时用 STEAMOS_NIX_IME 注入。
  mkX11VariantFor = envVar: envVal: binName: target:
    pkgs.runCommand "${binName}-x11" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
      mkdir -p "$out/bin"
      makeWrapper "${target}/bin/${binName}" "$out/bin/${binName}-x11" \
        --set ${envVar} ${envVal}
    '';
  mkX11Variant = mkX11VariantFor "QT_QPA_PLATFORM" "xcb";

  wps-office = if wpsPkg == null then null else
    pkgs.symlinkJoin {
      name = "wps-office-nix";
      paths = [ wpsPkg (mkX11Variant "wps" wpsPkg) ];
      meta.description = "WPS Office (nixpkgs binary redistribution) + x11 variant";
    };

  wechat = if wechatPkg == null then null else
    pkgs.symlinkJoin {
      name = "wechat-nix";
      paths = [ wechatPkg (mkX11Variant "wechat" wechatPkg) ];
      meta.description = "WeChat for Linux (AppImage) + x11 variant";
    };

  # LocalSend: 局域网传文件(手机↔PC 的 AirDrop 替代品)。
  # nixpkgs 从 GitHub tag 拉源码用 flutter324 构建, mainProgram = localsend_app,
  # 自带 share/applications/LocalSend.desktop 与 hicolor 图标 → install.sh 的
  # .desktop 循环会自动把它链到 ~/.local/share/applications。
  # 运行期需要防火墙放行 53317/tcp + 53317/udp(组播发现 + HTTP 传输), 见 README §3。
  localsend = if localsendPkg == null then null else
    pkgs.symlinkJoin {
      name = "localsend-nix";
      paths = [
        localsendPkg
        (mkX11VariantFor "GDK_BACKEND" "x11" "localsend_app" localsendPkg)
      ];
      meta.description = "LocalSend (LAN file transfer, Flutter) + x11 variant";
    };

  # ── 8. 中文字体: HarmonyOS Sans SC ─────────────────────────────────────
  # nixpkgs 25.05 **没有** harmonyos-sans(pkgs/by-name/ha/harmonyos-sans → 404;
  # 现存的都是 NUR / 第三方 overlay)。所以这里自写一个 derivation:
  # fetchzip 华为官方 zip(52MB, 内含 SC / TC / 多语种 / 阿语等多套),
  # 只取 HarmonyOS_Sans_SC 的 6 个字重(Thin/Light/Regular/Medium/Bold/Black)。
  #
  # ⚠ 三个必须知道的点:
  #   ① 华为授权 = 可随产品嵌入、不可单独再分发 → license = unfree
  #      (flake 里已 allowUnfree)。不要把 $out 推到任何公共 binary cache。
  #   ② fetchzip 是 FOD: hash 必须与实际解包结果逐字节对应。下面填的是社区记录值;
  #      若 nix 报 hash mismatch, 它会打印 "got: sha256-...", 把 got 的值填回
  #      flake.nix 的 cfg.harmonySansHash 即可(两遍法, 与 dsh 同一种套路)。
  #   ③ 字体 family 名实测为 "HarmonyOS Sans SC"(postscript: HarmonyOS_Sans_SC) ——
  #      install.sh 的 fontconfig <prefer> 用的就是这个字符串,别手改。
  #
  # 注意 "HarmonyOS Sans" 这个目录名里**有空格**: 所有引用都必须加引号,
  # 这正是 .selftest 里 B11 用例要覆盖的回归点。
  harmonyos-sans = stdenvNoCC.mkDerivation {
    pname = "harmonyos-sans-sc";
    version = "1.0";
    src = pkgs.fetchzip {
      url = "https://developer.huawei.com/images/download/general/HarmonyOS-Sans.zip";
      hash = cfg.harmonySansHash;
      stripRoot = false;
    };
    dontPatch = true;
    dontConfigure = true;
    dontBuild = true;
    doCheck = false;
    dontFixup = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/fonts/truetype/harmonyos-sans-sc"
      # NOTE: 这个 zip 是 macOS 打的, 里面有 __MACOSX/ 与一堆 ._xxx.ttf 的
      # AppleDouble 元数据文件 —— 它们**也**匹配 '*.ttf', 不排除就会被当字体装进去
      # (fontconfig 扫到 0 字节的假 ttf 会告警甚至让该 family 不可用)。
      # .selftest 的 B11 专门守这个回归点。
      find "$src/HarmonyOS Sans/HarmonyOS_Sans_SC" -maxdepth 1 -type f \
        -name '*.ttf' ! -name '._*' \
        -exec install -m 0644 -t "$out/share/fonts/truetype/harmonyos-sans-sc" {} +
      if [ -z "$(ls -A "$out/share/fonts/truetype/harmonyos-sans-sc" 2>/dev/null)" ]; then
        echo "harmonyos-sans: 没捞出任何 ttf —— 上游 zip 结构变了?" >&2
        exit 1
      fi
      runHook postInstall
    '';
    meta = {
      description = "HarmonyOS Sans SC — 鸿蒙简体中文字体(6 字重, 含拉丁)";
      homepage = "https://developer.huawei.com/consumer/cn/design/resource/";
      license = lib.licenses.unfree;
      platforms = lib.platforms.all;
    };
  };

  # 兜底字体集: HarmonyOS Sans 的 FOD 没打通、或你就想要 Noto 时,
  # 把 flake.nix 的 cfg.cjkFont 改成 "noto" 即可(不用动这里)。
  notoCjkPkgs = lib.filter (p: p != null) [
    (pkgs.noto-fonts-cjk-serif or null)
    (pkgs.noto-fonts-cjk-sans or null)
    (pkgs.wqy_zenhei or null)
  ];
  steamos-cjk-fonts-fallback =
    if notoCjkPkgs == [ ] then null
    else pkgs.symlinkJoin {
      name = "steamos-cjk-fonts-fallback";
      paths = notoCjkPkgs;
      meta.description = "Noto/WQY CJK 兜底字体集(cfg.cjkFont = \"noto\" 时启用)";
    };

  steamos-cjk-fonts =
    if cfg.cjkFont == "harmony-sans" then harmonyos-sans
    else if cfg.cjkFont == "noto" then steamos-cjk-fonts-fallback
    else null;

  # fontconfig 要 prefer 的 family 名 —— install.sh 会写进 conf 文件。
  # 必须与 ttf 的 name 表一致, 否则 prefer 不生效、回落到默认字体。
  cjkFontFamily =
    if cfg.cjkFont == "harmony-sans" then "HarmonyOS Sans SC"
    else if cfg.cjkFont == "noto" then "Noto Sans CJK SC"
    else "";

  # 桌面机型的一站式 bundle —— **故意不含字体**:
  # 字体是外部 FOD, hash 一旦对不上会让整个 symlinkJoin 直接失败;
  # 把 WPS/微信/LocalSend 与字体解耦后, 字体构建失败只降级告警, 不连坐应用。
  steamos-apps = pkgs.symlinkJoin {
    name = "steamos-apps";
    paths = lib.filter (p: p != null) [ wps-office wechat localsend ];
    meta.description = "WPS + 微信 + LocalSend(字体另装: steamos-cjk-fonts)";
  };
in
{
  inherit steamos-tools backkeys-daemon steamos-etc steamos-nix-activate workbuddy dsh;
  inherit wps-office wechat localsend harmonyos-sans;
  inherit steamos-cjk-fonts steamos-cjk-fonts-fallback steamos-apps;
  inherit machine isWin5 isHandheld cjkFontFamily;
  # extra attrs for consumers (home module, flake apps)
  inherit runtimeDeps pythonForScripts;
}
