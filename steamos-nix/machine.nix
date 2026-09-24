# machine.nix — 本机机型类别, 决定 steamos-nix 构建哪些部件。
#
# 由 scripts/steamos-nix-detect.sh --write 自动生成; 也可以直接手改。
# 可选值:
#   "gpd-win5"    GPD Win 5 —— 含背键守护/udev/inputplumber 三件套
#   "steam-deck"  Valve 掌机 —— 通用掌机集
#   "desktop"     台式机/HTPC —— 外接键鼠+手柄场景
{ machine = "desktop"; }
