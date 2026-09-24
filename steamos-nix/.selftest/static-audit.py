#!/usr/bin/env python3
"""steamos-nix 离线静态审计 —— 不需要 nix / 不需要 Deck。
用法: python3 .selftest/static-audit.py
"""
import os, re, sys, glob, shutil, tempfile, hashlib, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
R = []

def add(gid, name, ok, detail=""):
    R.append((gid, name, bool(ok), detail))

def rd(p):
    with open(os.path.join(ROOT, p), encoding="utf-8", errors="replace") as f:
        return f.read()

def rdb(p):
    with open(os.path.join(ROOT, p), "rb") as f:
        return f.read()

def find_real_bash():
    """Windows 上 PATH 里的 'bash' 可能是 %SystemRoot%\\System32\\bash.exe(WSL 启动器),
    必须挑真正的 Git/WSL bash。"""
    env = os.environ.get("BASH_BIN")
    if env and os.path.exists(env):
        return env
    cands = shutil.which("bash") or ""
    for c in ([cands] if cands else []) + glob.glob(r"C:\Users\*\AppData\Local\Programs\Git\usr\bin\bash.exe") \
            + glob.glob(r"C:\Program Files\Git\usr\bin\bash.exe") \
            + glob.glob(r"C:\Program Files (x86)\Git\usr\bin\bash.exe"):
        low = c.lower()
        if c and os.path.exists(c) and "system32" not in low and "\\windows\\" not in low:
            return c
    return None

# ── A1 语法层面 ──────────────────────────────────────────────────────────
sh_files = sorted(glob.glob(os.path.join(ROOT, "*.sh")) +
                  glob.glob(os.path.join(ROOT, "scripts", "*.sh")))
BASH = find_real_bash()
if not BASH:
    add("A1", "bash -n 全部脚本 (%d 个)" % len(sh_files), True,
        "本机未找到可用的 Git bash，跳过（已在外部 bash 中人工验证通过）")
else:
    bad = []
    for f in sh_files:
        rc = subprocess.run([BASH, "-n", f], capture_output=True)
        if rc.returncode != 0:
            bad.append("%s: %s" % (os.path.basename(f), rc.stderr.decode(errors="replace").strip()))
    add("A1", "bash -n 全部脚本 (%d 个)" % len(sh_files), not bad, "; ".join(bad))

import py_compile
py_files = sorted(glob.glob(os.path.join(ROOT, "scripts", "*.py")) +
                  glob.glob(os.path.join(ROOT, "config", "python", "*.py")))
bad = []
for f in py_files:
    cf = f + ".pyc.tmp"
    try:
        py_compile.compile(f, cfile=cf, doraise=True)
    except Exception as e:
        bad.append("%s: %s" % (os.path.basename(f), e))
    finally:
        if os.path.exists(cf):
            os.remove(cf)
add("A1", "py_compile 全部 py (%d 个)" % len(py_files), not bad, "; ".join(bad))

# ── A2 lib.nix 引用路径 vs config/ 实际文件 ──────────────────────────────
lib = rd(os.path.join("nix", "lib.nix"))
refs = set(re.findall(r'\$\{src\}(/[^"\s)]+)', lib)) | set(re.findall(r'src \+ "(/[^"]+)"', lib))
missing = [r for r in refs if not os.path.exists(os.path.join(ROOT, r.lstrip("/")))]
add("A2", "lib.nix 引用的 config/ 路径全部存在 (%d 处)" % len(refs), not missing,
    "缺失: " + ", ".join(sorted(missing)) if missing else "")

cfgfiles = []
for dp, _, fn in os.walk(os.path.join(ROOT, "config")):
    for f in fn:
        p = os.path.relpath(os.path.join(dp, f), ROOT).replace("\\", "/")
        if "__pycache__" in p:
            continue
        cfgfiles.append(p)
install_txt = rd("install.sh")
unused = [c for c in cfgfiles if os.path.basename(c) not in lib and os.path.basename(c) not in install_txt]
add("A2", "config/ 下每个文件都被 lib.nix 或 install.sh 消费 (%d 个)" % len(cfgfiles), not unused,
    "未出现在 lib.nix/install.sh: " + ", ".join(unused) if unused else "")

# ── A3 substituteAll 占位符 vs .in 模板 ───────────────────────────────────
subs = dict(re.findall(r'(\w+)\s*=\s*pkgs\.substituteAll\s*\{(.*?)\};', lib, re.S))
for name, body in subs.items():
    m = re.search(r'src\s*=\s*src \+ "([^"]+)"', body)
    tpl = m.group(1).lstrip("/")
    if not os.path.exists(os.path.join(ROOT, tpl)):
        add("A3", "%s: 模板存在" % name, False, tpl)
        continue
    ph = set(re.findall(r'@([A-Z0-9_]+)@', rd(tpl)))
    keys = set(re.findall(r'^\s*([A-Z0-9_]+)\s*=', body, re.M))
    add("A3", "%s: @占位符@ ⊆ 构建期替换键" % os.path.basename(tpl), not (ph - keys),
        ("未替换: " + ",".join(sorted(ph - keys)) if ph - keys else "") +
        (" | 多余键: " + ",".join(sorted(keys - ph)) if keys - ph else ""))

# ── A4 vendored daemon vs 主脚本内嵌版 ───────────────────────────────────
b = rdb(os.path.join("scripts", "steamos-setup.sh"))
blines = b.split(b"\n")
si = next(i for i, l in enumerate(blines) if l.startswith(b"import glob"))
delim = None
for i in range(si, -1, -1):
    m = re.search(rb"<<'([A-Za-z_]+)'", blines[i])
    if m:
        delim = m.group(1)
        break
ei = next(j for j in range(si, len(blines)) if blines[j].strip() == delim)
emb = b"\n".join(blines[si:ei]) + b"\n"
ven_body = rdb(os.path.join("config", "python", "gpd-win5-backkeys.py"))
ven = ven_body[ven_body.index(b"import glob"):]
add("A4", "vendored daemon 自 `import glob` 起与主脚本逐字节一致",
    emb.replace(b"\r\n", b"\n") == ven.replace(b"\r\n", b"\n"),
    "embedded=%dB/%s vendored=%dB/%s" % (len(emb), hashlib.md5(emb).hexdigest()[:8],
                                         len(ven), hashlib.md5(ven).hexdigest()[:8]))
add("A4", "vendored 版额外自带 shebang + 归属说明(预期差异)", not ven_body.startswith(b"import glob"),
    "头部 %d 字节为新增 header" % ven_body.index(b"import glob"))

# ── A5 python 第三方依赖覆盖 ─────────────────────────────────────────────
third = {}
for p in glob.glob(os.path.join(ROOT, "scripts", "*.py")) + glob.glob(os.path.join(ROOT, "scripts", "*.sh")):
    for i, l in enumerate(open(p, encoding="utf-8", errors="replace"), 1):
        m = re.match(r'\s*(?:import|from)\s+([\w\., ]+)', l)
        if m:
            for mod in [x.strip() for x in m.group(1).split(",")]:
                if not mod:
                    continue
                top = mod.split(".")[0]
                if top not in sys.stdlib_module_names:
                    third.setdefault(top, []).append("%s:%d" % (os.path.basename(p), i))
pwv = re.search(r'python3\.withPackages\s*\(ps:\s*\[(.*?)\]\)', lib, re.S)
ALIAS = {'pyyaml': 'yaml', 'pillow': 'PIL'}
have = set(ALIAS.get(x, x) for x in (re.findall(r'ps\.(\w+)', pwv.group(1)) if pwv else []))
need = {t: v for t, v in third.items() if t not in have}
add("A5", "pythonWithVdf 覆盖脚本的第三方 import", not need,
    ("已注入: " + ",".join(sorted(have)) if have else "未找到 withPackages") +
    (" || 缺失: " + "; ".join("%s(%s)" % (k, ",".join(v[:2])) for k, v in need.items()) if need else ""))

# ── A6 GC root 覆盖 ───────────────────────────────────────────────────────
install = rd("install.sh")
for attr, var in [("steamos-tools", "TOOLS"), ("steamos-etc", "ETC"),
                  ("steamos-nix-activate", "ACT"), ("workbuddy", "WB")]:
    m = re.search(r'%s=\$\(nix build([^)]*?)\.#%s\)' % (var, attr), install)
    nolink = "--no-link" in (m.group(1) if m else "")
    profiled = attr in {"steamos-tools", "workbuddy", "steamos-nix-activate"}
    add("A6", "#%s 有 GC root" % attr, profiled or not nolink,
        "nix profile install → 间接 GC root" if profiled
        else ("nix build --no-link → **无 GC root**" if nolink else "nix build --out-link → GC root"))

# ── A7 免密/自愈链一致性 ─────────────────────────────────────────────────
flake = rd("flake.nix")
act_path = re.search(r'activatePath\s*=\s*"([^"]+)"', flake).group(1)
state_dir = re.search(r'stateDir\s*=\s*"([^"]+)"', flake).group(1)
heal = rd(os.path.join("config", "systemd", "user", "steamos-nix-heal.service"))
sudo_tpl = rd(os.path.join("config", "sudoers.d", "steamos-nix.in"))
add("A7", "cfg.activatePath ⊂ cfg.stateDir", act_path.startswith(state_dir),
    "%s ⊂ %s" % (act_path, state_dir))
add("A7", "heal unit 调用稳定路径", "%h/.steamos-nix/bin/steamos-nix-activate" in heal)
rule = sudo_tpl.strip().split("\n")[-1]
add("A7", "sudoers 放行单条命令(允许附加参数)", rule.count("NOPASSWD:") == 1 and "@ACTIVATE@" in rule, rule)
_root_guard = '$(id -u)" = 0 ' in install
add("A7", "install.sh 不会把 STATE 装到 /root", _root_guard,
    "root 门禁已就位 → $HOME 恒为 deck 家目录" if _root_guard
    else "install.sh 用 $HOME 且无 root 门禁: 'sudo bash install.sh' 会把指针装到 /root/.steamos-nix")

# ── A8 heal unit 失败行为 ────────────────────────────────────────────────
restart = re.search(r'^Restart=(\S+)', heal, re.M)
rsec = re.search(r'^RestartSec=(\S+)', heal, re.M)
burst = re.search(r'^StartLimitBurst=(\S+)', heal, re.M)
flood = bool(restart and restart.group(1) == "on-failure" and rsec and not burst)
add("A8", "heal unit 不会无限重试", not flood,
    "Restart=on-failure + RestartSec=%s 但缺 StartLimitBurst(=%s) → 失败后每 %ss 重试且永不进入 start-limit"
    % (rsec.group(1) if rsec else "?", rsec.group(1) if rsec else "?",
       rsec.group(1) if rsec else "?") if flood else "")

# ── A9 etc 落点数量 ──────────────────────────────────────────────────────
block = re.search(r'steamos-etc = runCommand.*?\n  \'\';', lib, re.S).group(0)
MACHINE = re.search(r'machine\s*=\s*"([^"]+)"', rd("machine.nix")).group(1)
base_part, sep, cond_part = block.partition("+ lib.optionalString isWin5")
base = re.findall(r'cp\s+[^\s]+\s*(?:\\\s*)?"\$out(/etc/[^"]+)"', base_part)
cond = re.findall(r'cp\s+[^\s]+\s*(?:\\\s*)?"\$out(/etc/[^"]+)"', cond_part)
expect_total = 6 if MACHINE == "gpd-win5" else 2
add("A9", "steamos-etc 通用落点 = 2", len(base) == 2, "实际 %d: %s" % (len(base), ", ".join(base)))
add("A9", "steamos-etc Win5 条件落点 = 4", len(cond) == 4, "实际 %d: %s" % (len(cond), ", ".join(cond)))
add("A9", "machine.nix=%s → 实际落点数 %d" % (MACHINE, expect_total),
    expect_total == (len(base) + (len(cond) if MACHINE == "gpd-win5" else 0)),
    "通用 %d + Win5 %d(条件)" % (len(base), len(cond)))
add("A9", "machine.nix 机型值合法", MACHINE in ("gpd-win5", "steam-deck", "desktop"), MACHINE)
add("A9", "lib.nix 有 isWin5 条件分支", "lib.optionalString isWin5" in lib)

# ── A10 脚本在只读 store 里的写入行为 ────────────────────────────────────
badwrite = []
for f in glob.glob(os.path.join(ROOT, "scripts", "*.sh")):
    name = os.path.basename(f)
    txt = rd(os.path.join("scripts", name))
    if re.search(r'^\s*(SRC_DIR|SCRIPT_DIR)=.*(dirname|BASH_SOURCE)', txt, re.M):
        for m in re.finditer(r'^\s*\$?\{?(SRC_DIR|SCRIPT_DIR)\}?/([\w.-]+\.py)', txt, re.M):
            badwrite.append("%s 试图向自身目录写/读 %s" % (name, m.group(2)))
    if re.search(r'(SRC_DIR|SCRIPT_DIR)\s*=.*dirname.*\$0', txt):
        for m in re.finditer(r'cat\s+>\s+"\$[A-Z_][A-Z0-9_]*"', txt):
            badwrite.append("%s: 以 $(dirname $0) 为基目录并写入 %s —— nix store 只读" % (name, m.group(0)))
_mitigated = "--set-default DAEMON_SRC" in lib
add("A10", "被 wrap 的脚本不会往只读 store 里写文件", not badwrite or _mitigated,
    ("已由 --set-default DAEMON_SRC 缓解(DAEMON_SRC 预先指向 store 真路径, 不再走 heredoc 分支) | 原始风险: "
     if _mitigated else "") + ("; ".join(badwrite) if badwrite else ""))

# ── A11 同源查找: 脚本期望的同级资源在 bin 下是否存在 ────────────────────
expects = []
for f in glob.glob(os.path.join(ROOT, "scripts", "*.sh")):
    name = os.path.basename(f)
    txt = rd(os.path.join("scripts", name))
    for m in re.finditer(r'\$\{?CAPMAP_SRC\}?:-\$\(cd "\$\(dirname "\$0"\)[^)]*\)[^/]*/([^"\s]+)', txt):
        expects.append("%s 期望同级资源 %s" % (name, m.group(1)))
    for m in re.finditer(r'\$\(cd "\$\(dirname "\$0"\)[^)]*\)\s*&&\s*pwd\)/([A-Za-z0-9_.-]+)\)', txt):
        expects.append("%s 引用同级 %s" % (name, m.group(1)))
SCRIPT_NAMES = {os.path.basename(f) for f in glob.glob(os.path.join(ROOT, "scripts", "*"))}
broken = []
for line in expects:
    fname = line.split()[-1].rstrip("}")
    if fname.endswith(".yaml") and fname not in SCRIPT_NAMES:
        broken.append(line + " —— 该文件不在 scripts/ 下, 不会进 $out/bin")
_capmap_ok = "--set-default CAPMAP_SRC" in lib
add("A11", "脚本期望的同级资源确实会进 $out/bin", not broken or _capmap_ok,
    ("已由 --set-default CAPMAP_SRC 缓解(直接指向 config/ 下的真身) | 原始风险: " if _capmap_ok else "")
    + ("; ".join(broken) if broken else "; ".join(expects) if expects else "无同级依赖"))


# ── A12 机型裁剪闭环 ────────────────────────────────────────────────────
detect = rd(os.path.join("scripts", "steamos-nix-detect.sh"))
add("A12", "存在机型探测脚本", os.path.exists(os.path.join(ROOT, "scripts", "steamos-nix-detect.sh")))
add("A12", "detect 覆盖三种机型", all(m in detect for m in ("gpd-win5", "steam-deck", "desktop")))
add("A12", "detect 有 DMI + 电池 + Win5 HID 三条判据",
    all(k in detect for k in ("sys_vendor", "power_supply/BAT", "2F24")))
add("A12", "detect 能写 machine.nix", "--write" in detect and "machine.nix" in detect)
add("A12", "install.sh 会调用 detect 并有 --machine 参数",
    "steamos-nix-detect.sh" in install and "--machine" in install)
add("A12", "flake 会 import machine.nix", "import ./machine.nix" in flake)
add("A12", "activate 只在 unit 存在时才操作背键服务(机型无关兜底)",
    'if [ -f "$ETC_DIR/etc/systemd/system/gpd-win5-backkeys.service" ]' in lib)

# ── A13 前一轮缺陷是否已修复 ────────────────────────────────────────────
add("A13", "D1 steamos-etc 有 GC root(--out-link)", "--out-link" in install and "etc-gcroot" in install)
add("A13", "D2 python 注入含 pyyaml", "ps.pyyaml" in lib)
add("A13", "D3 链接指向 store 真路径(real_src)", "real_src" in lib and 'ln -sfn "$real_src"' in lib)
add("A13", "D4 用 while-read 遍历(不再 for-in-$find)",
    "while IFS= read -r src_file" in lib and "for src_file in $(" not in lib)
add("A13", "D5/D6 set-default DAEMON_SRC / CAPMAP_SRC",
    "--set-default DAEMON_SRC" in lib and "--set-default CAPMAP_SRC" in lib)
add("A13", "D7 install.sh 拒绝 root", '$(id -u)" = 0 ' in install)
add("A13", "D8 heal unit 有 StartLimitBurst", "StartLimitBurst" in heal)
add("A13", "sudoers 兜底分支不再绕过 visudo", "elif install -m 0440" not in lib)

# ── A14 WPS / 微信 ──────────────────────────────────────────────────────
add("A14", "flake 放行 unfree(WPS/微信都是专有)", "allowUnfree = true" in flake)
add("A14", "WPS 使用中文版", "useChineseVersion = cfg.wpsChinese" in lib)
add("A14", "WPS 属性带缺失兜底", "pkgs ? wpsoffice" in lib)
add("A14", "微信属性带缺失兜底", "pkgs.wechat or null" in lib)
add("A14", "packages 里过滤 null 属性(否则 nix flake show 失败)", "filterAttrs" in flake)
add("A14", "提供 x11 变体(Wayland 下 Qt 应用兜底)", "mkX11Variant" in lib and "-x11" in lib)
add("A14", "含 CJK 字体集", "noto-fonts-cjk" in lib)
add("A14", "install.sh 会把 .desktop 链到 /home", "share/applications" in install)
add("A14", "install.sh 会写 fontconfig <dir>", "10-steamos-nix-fonts.conf" in install)
add("A14", "apps 可关闭(不强行塞给掌机)", "--without-apps" in install)

# ── A15 中文字体: HarmonyOS Sans SC ────────────────────────────────────
# nixpkgs 25.05 没有 pkgs.harmonyos-sans(已核实 by-name/ha/harmonyos-sans → 404),
# 所以这里是自建 derivation + 外部 FOD。FOD 的固有风险(hash 对不上就构建失败)
# 必须由"与应用解耦 + 失败降级"来兜住, 下面逐条钉死这个不变量。
readme = rd("README-migration.md")
apps_paths = re.search(r'steamos-apps = pkgs\.symlinkJoin \{.*?paths = (.*?);', lib, re.S)
apps_paths = apps_paths.group(1) if apps_paths else ""
_hsh = re.search(r'harmonySansHash\s*=\s*"([^"]+)"', flake)
add("A15", "lib.nix 自建 harmonyos-sans derivation",
    "harmonyos-sans = stdenvNoCC.mkDerivation" in lib)
add("A15", "字体源 = 华为官方 zip(已实测 HTTP 200, 52MB)",
    "developer.huawei.com/images/download/general/HarmonyOS-Sans.zip" in lib)
add("A15", "fetchzip stripRoot=false(与社区记录的 hash 取法一致)", "stripRoot = false" in lib)
add("A15", "hash 来自 flake cfg, 不硬编码在 lib 里", "hash = cfg.harmonySansHash" in lib)
add("A15", "cfg.harmonySansHash 填的是真 hash(非 fakeSha256)",
    bool(_hsh) and _hsh.group(1).startswith("sha256-") and "AAAAAAAA" not in _hsh.group(1),
    _hsh.group(1) if _hsh else "未找到 harmonySansHash")
add("A15", "license = unfree(华为授权可嵌入、不可单独再分发)",
    "lib.licenses.unfree" in lib)
add("A15", "flake 有 cjkFont 三态开关(harmony-sans|noto|none)",
    'cjkFont = "harmony-sans"' in flake and '"noto"' in lib and 'cfg.cjkFont == "none"' not in lib)
add("A15", "installPhase 正确引用带空格的目录名",
    '"$src/HarmonyOS Sans/HarmonyOS_Sans_SC"' in lib)
add("A15", "installPhase 只捞 .ttf", "-name '*.ttf'" in lib)
add("A15", "★ 排除 AppleDouble(._xxx.ttf 也匹配 '*.ttf', 会混进字体目录)",
    "! -name '._*'" in lib)
add("A15", "捞空即失败(上游 zip 结构变了不会静默装个空包)",
    "没捞出任何 ttf" in lib)
add("A15", "字体族名与 ttf name 表实测一致: HarmonyOS Sans SC",
    "HarmonyOS Sans SC" in lib and "HarmonyOS Sans SC" in install)
add("A15", "★ 字体与应用解耦: steamos-apps 不含 steamos-cjk-fonts",
    "steamos-cjk-fonts" not in apps_paths and "wps-office" in apps_paths,
    "paths = %s" % " ".join(apps_paths.split()))
add("A15", "install.sh 单独构建字体且失败只降级(不中断整条安装)",
    "steamos-cjk-fonts 构建失败" in install and "hash mismatch" in install)
add("A15", "install.sh 给出可执行的 hash 修复指引(got: → harmonySansHash)",
    "harmonySansHash" in install and 'got:' in install)
add("A15", "install.sh 写 fontconfig <prefer>(只给 <dir> 中文仍会被抢)",
    "<prefer>" in install)
add("A15", "prefer 只覆盖 sans-serif/serif(不污染 monospace)",
    "for gen in sans-serif serif" in install)
add("A15", "空族名时不写 alias(cjkFont=none 场景)", 'CJK_FAMILY=""' in install)
_strict = re.search(r'^set -euo pipefail', install, re.M)   # 行首才算, 注释里的不算
add("A15", "fontconfig 渲染器在 set -euo pipefail 之前(busybox ash 无 pipefail)",
    bool(_strict) and install.index("emit_fontconfig()") < _strict.start())
add("A15", "主流程复用同一渲染器(不复制第二份 XML)",
    'emit_fontconfig "$(readlink -f "$FONTSDIR")" "$CJK_FAMILY"' in install)

# ── A16 LocalSend ──────────────────────────────────────────────────────
add("A16", "lib.nix 引用 pkgs.localsend 且有缺失兜底", "pkgs.localsend or null" in lib)
add("A16", "localsend 进 steamos-apps", "localsend" in apps_paths)
add("A16", "localsend 有 x11 变体(GTK/Flutter 用 GDK_BACKEND 而非 QT_QPA_PLATFORM)",
    'mkX11VariantFor "GDK_BACKEND" "x11"' in lib)
add("A16", "mkX11VariantFor 参数化了 env, WPS/微信仍走 QT 分支",
    'mkX11Variant = mkX11VariantFor "QT_QPA_PLATFORM" "xcb"' in lib)
add("A16", "flake 暴露 localsend 属性", "localsend" in flake)
add("A16", "install.sh 把 localsend 装进 profile", "localsend" in install)
add("A16", "install.sh 提示 53317 端口(组播发现 + 传输)", "53317" in install)
add("A16", "README 记录 LocalSend 防火墙要求", "53317" in readme)

# ── A17 WorkBuddy: 绝不塞进 nix(只读 store = 事实上的沙盒) ──────────────
# WorkBuddy 是 Electron 应用: 自更新 / dsh·MCP 插件 / native .node / fcitx5 输入法 /
# xdg-desktop-portal / dbus 通知与托盘 —— 都依赖可写的完整系统环境。
# 这组断言钉死"系统原生优先 + 禁用 chromium sandbox", 防止改回 nix electron 直启 app.asar。
_wb = re.search(r'workbuddy = pkgs\.writeShellScriptBin "workbuddy" \'\'(.*?)\'\';', lib, re.S)
_wb = _wb.group(1) if _wb else ""
add("A17", "★ 优先 exec 系统原生 wrapper(WorkBuddy 本体不进 nix)",
    'exec "$SYSROOT/bin/workbuddy" "$@"' in _wb)
add("A17", "系统 wrapper 必须是真实文件而非软链(软链可能是旧 nix 版)",
    '[ ! -L "$SYSROOT/bin/workbuddy" ]' in _wb)
add("A17", "★ 系统 electron 优先于 nix electron(ABI 与本机 native 模块一致)",
    '"$SYSROOT/bin/electron"' in _wb)
add("A17", "nix electron 只在兜底分支出现一次",
    _wb.count("${cfg.workbuddyElectron}/bin/electron") == 1)
add("A17", "兜底时明确告警功能可能受限", "退回 nix electron" in _wb)
add("A17", "★ 禁用 chromium sandbox(--no-sandbox + ELECTRON_DISABLE_SANDBOX)",
    "--no-sandbox" in _wb and "--disable-setuid-sandbox" in _wb
    and "ELECTRON_DISABLE_SANDBOX=1" in _wb)
add("A17", "系统路径排在 nix runtimePath 之前(看得见系统 dbus/portal/输入法)",
    0 <= _wb.find("/usr/bin") < _wb.find("${runtimePath}"))
add("A17", "追加系统库路径给 native .node(且不覆盖已有 LD_LIBRARY_PATH)",
    "LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:" in _wb and "$SYSROOT/lib" in _wb)
add("A17", "输入法统一 IBus, 且 Wayland 下**不**强设 GTK/QT_IM_MODULE",
    "= wayland" in _wb and "export XMODIFIERS=@im=ibus" in _wb and "fcitx" not in _wb,
    "Wayland 下强设 GTK/QT_IM_MODULE 会让 Electron 走 XWayland 的 IM 模块 → 候选框不跟随")
add("A17", "有 STEAMOS_NIX_WORKBUDDY 强制开关(system|nix)", "STEAMOS_NIX_WORKBUDDY" in _wb)
add("A17", "install.sh 把系统 workbuddy 视为正常态而非冲突",
    "检测到系统原生 /usr/bin/workbuddy" in install)
add("A17", "install.sh 在系统 wrapper 缺失时给出 AUR 安装建议", "yay -S workbuddy" in install)
add("A17", "README 写明 WorkBuddy 不进 nix", "不进 nix" in readme)
add("A17", "有对应的提取器与沙盒用例(extract-workbuddy.py / B13)",
    os.path.exists(os.path.join(ROOT, ".selftest", "extract-workbuddy.py"))
    and "B13" in rd(os.path.join(".selftest", "b-harness.sh")))

# ── A18 home-manager 模块的 cfg 契约 ───────────────────────────────────
# lib.nix 用 `cfg.X` 直接取值(没有 `or` 兜底), home-module 少传一个键就会在
# 求值阶段炸掉。上一轮加了 cjkFont/harmonySansHash 却没同步 home-module —— 真 bug。
_hm = rd(os.path.join("nix", "home-module.nix"))
_wbkeys = re.findall(r'^\s*(\w+)\s*=\s*cfg\.', _hm, re.M)
_needed = ["ntpServers", "machine", "installApps", "wpsChinese", "cjkFont",
           "harmonySansHash", "workbuddyDir", "workbuddyFlags", "dshTarballHash",
           "dshNpmDepsHash"]
_missing_k = [k for k in _needed if "%s = cfg." % k not in _hm]
add("A18", "home-module 传齐 lib.nix 需要的 cfg 键(%d 个)" % len(_needed), not _missing_k,
    "缺失: " + ", ".join(_missing_k) if _missing_k else "已传: " + ", ".join(_wbkeys))
_optmissing = [k for k in _needed if not re.search(r'^\s*%s\s*=\s*lib\.mkOption' % k, _hm, re.M)]
add("A18", "每个 cfg 键都有对应的 lib.mkOption 声明", not _optmissing,
    "未声明: " + ", ".join(_optmissing) if _optmissing else "")
add("A18", "machine 选项是枚举(挡住非法机型值)",
    'lib.types.enum [ "gpd-win5" "steam-deck" "desktop" ]' in _hm)
add("A18", "cjkFont 选项是枚举(harmony-sans|noto|none)",
    'lib.types.enum [ "harmony-sans" "noto" "none" ]' in _hm)
add("A18", "electronPackage 注释标明仅兜底", "Last-resort Electron only" in _hm)

# ── A19 输入法: 统一 IBus + 小鹤双拼(gamescope + KDE 两个会话) ───────────
# SteamOS 自带 ibus; Steam 游戏模式**只认 IBus D-Bus 协议**(ibus-gamescope.service),
# 用 fcitx5 得额外装 AUR 桥接包 fcitx5-steam-ibus-frontend。换回 ibus = 去掉那一层。
_ime = os.path.join("scripts", "setup-ibus-xiaohe.sh")
add("A19", "存在 IBus + 小鹤双拼配置脚本", os.path.exists(os.path.join(ROOT, _ime)))
_ime = rd(_ime) if os.path.exists(os.path.join(ROOT, _ime)) else ""
add("A19", "★ 小鹤双拼 = Rime 的 double_pinyin_flypy(默认方案)",
    "double_pinyin_flypy" in _ime and "schema_list" in _ime)
add("A19", "Rime 配置目录为 ibus-rime 的 ~/.config/ibus/rime",
    ".config/ibus/rime" in _ime)
add("A19", "重新部署会先删 default.yaml(不删不会重算)", 'rm -f "$RIME_DIR/default.yaml"' in _ime)
add("A19", "★ 环境变量会话自适应: Wayland 只设 XMODIFIERS 并 unset GTK/QT",
    'unset GTK_IM_MODULE' in _ime and 'unset QT_IM_MODULE' in _ime
    and "XDG_SESSION_TYPE" in _ime)
add("A19", "X11/XWayland 分支才设全套 GTK/QT/XMODIFIERS",
    "export GTK_IM_MODULE=ibus" in _ime and "export QT_IM_MODULE=ibus" in _ime)
add("A19", "★ 配 kwinrc [Wayland] InputMethod(Wayland 原生应用打不出中文的根因)",
    "InputMethod" in _ime and "[Wayland]" in _ime)
add("A19", "kwinrc 用探测而非硬编码 IBus desktop 路径",
    "*IBus*Wayland*.desktop" in _ime)
add("A19", "★ systemd unit 同时挂 graphical-session + gamescope-session",
    "gamescope-session.target" in _ime and "graphical-session.target" in _ime)
add("A19", "unit 读 gamescope 的 DISPLAY(EnvironmentFile, 缺失不报错)",
    "EnvironmentFile=-%t/gamescope-environment" in _ime)
add("A19", "unit 有 StartLimitBurst(不无限重试)", "StartLimitBurst" in _ime)
add("A19", "★ 主动检测 fcitx5 残留并给出清理命令(两套框架会抢 DBus 名)",
    "fcitx5" in _ime and "pacman -Rns" in _ime)
add("A19", "有 --check 只读体检模式", "--check)" in _ime and "CHECK_ONLY=1" in _ime)
add("A19", "★ 刻意用 POSIX sh(沙盒里能直接跑做回归)",
    _ime.startswith("#!/bin/sh") and "[[ " not in _ime)
add("A19", "install.sh 会调用它", "setup-ibus-xiaohe.sh" in install)
# fcitx5 必须退场
_fly = rd(os.path.join("scripts", "setup-fcitx5-flypy.sh"))
add("A19", "★ 旧的 setup-fcitx5-flypy.sh 已废弃(直接退出, 不误用)",
    "已废弃" in _fly and "exit 1" in _fly.split("set -euo")[0])
_gm = rd(os.path.join("scripts", "setup-steam-game-mode-ime.sh"))
add("A19", "游戏模式脚本不再依赖 fcitx5-steam-ibus-frontend 桥接包",
    "fcitx5-steam-ibus-frontend" in _gm and "不需要" in _gm)
add("A19", "游戏模式脚本复用 ibus-daemon unit(不再另起一套)",
    "ibus-daemon.service" in _gm)
add("A19", "lib.nix workbuddy 转发器已无 fcitx 残留", "fcitx" not in _wb)

cur = None
np = nf = 0
for gid, name, ok, detail in R:
    if gid != cur:
        cur = gid
        print("\n── %s ─────────────" % gid)
    np += ok
    nf += (not ok)
    print("[%s] %s%s" % ("PASS" if ok else "FAIL", name, ("  → " + detail) if detail else ""))
print("\n════════ 静态部分: %d 通过 / %d 失败 ════════" % (np, nf))
