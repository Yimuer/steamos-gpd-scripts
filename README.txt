======================================================================
 SteamOS / Arch 重装后环境重建脚本备份包
 生成日期: 2026-09-08
======================================================================

★★★ 重装系统的完整操作流程请看【重装流程.md】(一页纸, 从U盘到验收) ★★★
★★★ 双击【重装后先运行我】即可开始重建环境(断点续传, 中断可重来)    ★★★

【本备份包用途】
重装 SteamOS(或 Arch 系)后, 在无 AI 辅助的环境下重建开发环境。
所有脚本已自包含, 不依赖旧机器任何文件, 解压到 Downloads 即可运行。

======================================================================
【最核心的文件: steamos-setup.sh】 (唯一必需)
======================================================================
这是一个"一键配置脚本", 已内嵌背键守护进程源码、输入法配置、
Steam 游戏启动工具、dsh 安装逻辑等全部内容(完全自包含)。

用法(在解压目录打开终端运行):
  1) 先看状态:    bash steamos-setup.sh --status
  2) 分步安装(推荐, 便于定位错误):
       bash steamos-setup.sh 1    # archlinuxcn 源
       bash steamos-setup.sh 2    # IBus 原生输入法 + 中文引擎(打中文关键)
       bash steamos-setup.sh 3    # WorkBuddy (AUR包, 装/opt+electron)
       bash steamos-setup.sh 4    # GPD Win5 背键(自动检测机型, 非Win5跳过)
       bash steamos-setup.sh 5    # Decky Loader
       bash steamos-setup.sh 6    # 游戏: GE-Proton + 鸣潮/终末地辅助
       bash steamos-setup.sh 7    # DeepSeek Harness (dsh, 补充AI CLI, 走npm国内镜像)
       bash steamos-setup.sh 8    # rootfs 瘦身(可选, 清 locale/man/doc/缓存)
       bash steamos-setup.sh 9    # TDP 控制(SimpleDeckyTDP, 插电/离电分档)
       bash steamos-setup.sh 10   # 换境内NTP(加速开机, 解决 atomupd 白等20秒)
       bash steamos-setup.sh 11   # GPU 加速建议(DLSS/FSR/XeSS, 按显卡自动提示)
       bash steamos-setup.sh 12   # 升级后自愈服务(开机自动重建被系统升级冲掉的配置)
  3) 或一次全量:  bash steamos-setup.sh
  4) 复查:        bash steamos-setup.sh --status

断点续传(2026-09-08 起):
  - 中断后重跑同一条命令会跳过已完成步骤, 从断点继续。
  - 进度记在 ~/.cache/steamos-setup/state; --reset 清进度; FORCE=1 强制重跑。
  - --adopt 只检测不安装(把本机已达标的步骤登记为完成)。

系统大版本升级后恢复(2026-09-09 起, 重要):
  - SteamOS 用 A/B 原子更新, 大版本升级会整块替换 rootfs 镜像,
    /etc /usr /opt 下的修改(含 pacman 装的包)全部被覆盖, 只有 /home 幸存。
  - 升级后跑这一条即可自动恢复:
        sudo bash steamos-setup.sh --after-upgrade      (等价 restore)
  - 它会: 自动检测版本变化 → 逐个复核落地物 → 只重建被冲掉的, 完好的跳过。
  - 两个前提: ① 需联网(pacman 重装包) ② rootfs 需余量(建议 >600MB, 不足先跑
    sudo bash free-rootfs.sh --apply)。
  - 幸存不用管: 游戏本体 / GE-Proton·DW-Proton / Steam 前缀 / Decky 插件 /
    快捷方式 / 输入法 dconf 配置 / 脚本进度文件。
  - 说明: 步骤[12] 的自愈服务只能补 /etc 下的配置项, 装不了 pacman 包,
    且其 sudoers 也在 /etc(升级必被冲) → 大版本升级后仍要手动跑一次上面那条。

前提:
  - 已进入 KDE 桌面、能联网。
  - 每步需 root(自动 sudo, 在终端输密码)。
  - 全程联网下载。第6步游戏本体需你自行从备份放回下载目录。

注意事项:
  - [2] 装完需注销重登使输入法生效。
  - [3] WorkBuddy 装到 /opt(818M)+electron(/usr), 装前确认 rootfs 空间(脚本会预检)。
  - [4] 只在检测到 GPD Win5 时执行; 换机型重装自动跳过。
  - [6] 游戏需在 Steam 里手动"添加非Steam游戏"指向启动器 exe 后,
        python3 steam-launch-games.py 才能写入启动选项(该工具在脚本运行时生成)。
        本步会自动修复鸣潮启动器黑屏(WPF AllowsTransparency bug, patch launcher_main.dll);
        启动器更新后会还原 dll, 黑屏复发时重跑一次本步即可。
  - [7] dsh 固定版本0.1.2-rc.1(开发者预览会破坏兼容), 升级改脚本顶部 DSH_VER。
  - [9] TDP 默认档位: 插电 75W / 离电 40W; 改默认值用 TDP_AC=xx TDP_DC=xx 变量。
  - [10] 换境内 NTP: 默认阿里+腾讯; 改默认值用 NTP_SERVERS='...' 变量。
         开机慢的元凶通常是 atomupd 等 NTP 校时最多 20 秒(默认 arch.pool 境内延迟高)。
  - [11] GPU 加速建议(纯提示, 无落地物): 按显卡自动给出 DLSS/FSR/XeSS 建议。
         AMD 卡提示 FSR(8060S/7900XTX 当前不能用 FSR4, 那是 RDNA4 专属; 用 FSR3.1/系统级FSR);
         N 卡提示 DLSS 4.5 并引导走 Bazzite(官方 SteamOS 不支持 N 卡);
         Intel Panther Lake(Xe3/Arc B3xx)提示 XeSS 硬件加速(同样引导走 Bazzite)。
  - [12] 升级后自愈服务: SteamOS 大版本升级(如 3.8→3.9)会整块替换 rootfs,
         把脚本写进 /etc 的系统级修改(背键/inputplumber/NTP/WorkBuddy IME)全部冲掉。
         本步放一个 user 服务在 /home, 开机自动检测并重建这些被冲掉的配置。

【rootfs 磁盘告急专用】
free-rootfs.sh
  - rootfs 只有 5G, 官方镜像本身就吃 4.2G, 属于结构性紧张。
  - 注意: 清 pacman 缓存/日志/coredump 完全无效(那些早已 offload 到 p8);
    删 WorkBuddy 也无效(它的 776M 全在 /opt, 同样在 p8)。
  - 真正有效: ①btrfs 元数据平衡(+334M, 零风险) ②删 gcc/孤儿包(+212M)
              ③删 firefox(+290M, 需确认) ④zstd 重压缩 /usr(+数百M~1G)
  - 用法: bash free-rootfs.sh                 # 只体检
          sudo bash free-rootfs.sh --apply    # 执行安全项
          sudo bash free-rootfs.sh --apply --with-firefox --with-opencv --compress
  - 前置: 需 steamos-readonly disable(脚本自动处理)。

【多机型兼容】(2026-09-08 起自动检测)
  - 自动识别: GPD Win5 / AMD 台式独显 / N 卡机器 / Intel 核显(含 Panther Lake)。
  - 背键[4]只在 Win5 上执行; TDP[9]只在 APU/核显上执行(台式独显自动跳过)。
  - N 卡 / Panther Lake 核显机器装不了官方 SteamOS, 脚本会引导走 Bazzite。

======================================================================
【备用脚本】(steamos-setup.sh 已覆盖同样功能; 以下供单步/手动补救用)
======================================================================
fix-workbuddy-wayland-ime.sh
  - 修复 WorkBuddy wrapper 的 Wayland 输入法参数(AUR升级会冲掉)。
  - 用途: 单独重装/升级 WorkBuddy 后跑。  sudo bash 本文件

upgrade-workbuddy-aur.sh
  - 一键升级 WorkBuddy(AUR) 并恢复中文输入参数。
  - 用途: 日常升级。  bash 本文件

install-ge-proton.sh
  - 单独安装 GE-Proton(游戏兼容层, 装 ~/.local/share/Steam/compatibilitytools.d)。
  - 对应 steamos-setup.sh 步骤6 的 GE-Proton 部分。

fix-endfield-qt.sh
  - 修复《明日方舟:终末地》进游戏后报 "no Qt platform plugin could be initialized"。
  - 根因: 游戏目录自带 Qt5 DLL 却缺 Qt 平台插件 qwindows.dll(全盘搜不到),
    而启动器目录有且同为 Qt 5.15.8 → 复制过去即可。
  - 幂等、纯新增文件、不动原游戏文件; 游戏更新后重跑仍有效。
  - 用法: bash fix-endfield-qt.sh [--dry-run]   (已并入步骤6, 自动调用)

install-dwproton.sh
  - 安装 DW-Proton —— 终末地/异环等带 ACE 反作弊的游戏**必须**用它。
  - 原因: 游戏自带 AntiCheatExpert, 在 GE-Proton / 官方 Proton 下点开始游戏必闪退
    (日志: unimplemented function ntoskrnl.exe.PsGetProcessExitStatus)。
    DW-Proton 内建 ACE 补丁, 11.0-7 起专门修过 Endfield 启动问题。
  - 用法: bash install-dwproton.sh  (装完需完全退出 Steam 重开, 再在兼容性里选 dwproton)
  - 若加载异常慢, 启动选项加: UMU_ID=umu-endfield %command%

fix-ibus-simplified.sh
  - 修复"输入法打出繁体 / 又变繁体"。
  - 根因: ibus-libpinyin 的 trad-switch(简繁切换)默认快捷键是 **Ctrl+Shift+F**,
    打字时极易误触, 且会记住状态 → 反复变繁体。
  - 本脚本切到 libpinyin 智能拼音 + 强制简体 + **解绑该热键**(根治)。
  - 用法: bash fix-ibus-simplified.sh   (以 deck 身份跑, 不要 sudo)

install-decky-loader.sh
  - 单独安装 Decky Loader(插件平台)。
  - 对应 steamos-setup.sh 步骤5。

setup-win5-backkeys.sh
  - 单独配置 GPD Win5 背键(L4/R4)。
  - 对应 steamos-setup.sh 步骤4。守护进程源码已内嵌, 自包含。

setup-fcitx5-flypy.sh
  - 单独配置 fcitx5 + 小鹤双拼输入法(旧方案)。
  - 注意: 主脚本步骤2 已改用 IBus 原生输入法; 此脚本仅作 fcitx5 备选。

setup-steam-game-mode-ime.sh
  - 修复 Steam 游戏模式(大屏幕)虚拟键盘无法输入中文。
  - 注意: 这是针对较旧方案/特定环境的辅助脚本, 新装优先用 steamos-setup.sh。

set-steam-launchoptions.py
  - 给 Steam 非Steam快捷方式写启动选项(自动探测 userid, 无需改 ID)。
  - 新装优先用 steamos-setup.sh 步骤6 自动生成的 steam-launch-games.py。

diag-gpd-inputs.sh / diag-ip.sh
  - 输入链路诊断脚本(服务/udev/inputplumber 接管/按键码抓取), 排查背键/手柄问题用。

fix-inputplumber-cycle.sh
  - 修复 inputplumber 因 systemd ordering cycle 无法开机启动的问题。

======================================================================
【备份文件来源】
这些文件来自原机器 /home/deck/Downloads/steamos-reinstall-backup/ 目录。
重装会清空该目录, 所以先整体备份到 U 盘。
======================================================================

======================================================================
【2026-09-24 变更与目录说明】
======================================================================
1. 输入法约束(重要):
   - 按要求不再改动原系统(SteamOS)输入法的任何内容。
   - 主脚本步骤[2] setup_im 已改为空函数(运行即跳过),
     原实现完整存档于 disabled/setup_im.disabled.sh。
   - 三个会动系统输入法的历史脚本已归档到 disabled/(不执行):
     fix-ibus-simplified.sh / setup-fcitx5-flypy.sh / setup-steam-game-mode-ime.sh
   - WorkBuddy 应用自身的 IME 启动参数自愈(步骤[12])按约定保留。
   - 历史事故: 曾用 ": <<'EOF' ... EOF" 包住 setup_im 禁用段, 因段内还有
     自己的 EOF, 内层提前终结外层 → 剩余代码变活代码 → 全脚本语法损坏。
     教训已固化进 check.sh 断言(2.5), 此手法禁止再现。

2. Decky 预置插件:
   - 第[5]步装完 Decky 后自动安装 SteamGridDB + ProtonDB Badges(商店分发)。
   - DECKY_PLUGINS="A B" 可自定义; DECKY_PLUGINS="" 置空跳过。
   - AutoDarkMode 已从商店下架(Steam 客户端已内置昼夜主题), 不再提供。

3. 目录布局:
   - check.sh          自检脚本(bash -n 全部 + 关键不变量断言, 只读免root)
   - archive/          历史版本存档(0909 原版 / lean 精简版), 不会被执行
   - disabled/         按约束禁用的输入法相关脚本存档
   - steamos-nix/      nix 迁移试验分支(与主脚本互不影响)

4. 健壮性修复(2026-09-24, shellcheck warning 级清零):
   - 递归删除路径加非空护栏(${VAR:?})
   - local 声明与赋值分离(避免返回值被掩盖)
   - 移除未使用变量(m / MAIN_ABS / WB_MARK)
   - ls|grep 改 glob 循环; 通配符 -f 判断改为循环判定(nix ime 脚本)

5. 日常自检: 修改任何脚本后跑一次 `bash check.sh`, 全绿再入库。

【v1.1.0 升级自愈钩子】
  - 步骤[12] 升级为版本变更钩子: 开机自动对比系统版本, 检测到原子更新即清点
    被冲掉内容(last-report.txt + 桌面通知), sudoers 幸存时全自动恢复。
  - 大版本升级后 sudoers 必被冲, 首次恢复仍需手动:
        sudo bash steamos-setup.sh --after-upgrade
    之后的局部损坏全自动修复, 无需人工。
  - 顺带修复: 步骤[7] dsh 落地复核与新安装路径脱节的问题。
