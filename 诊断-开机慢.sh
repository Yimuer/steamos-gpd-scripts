#!/bin/bash
# =============================================================================
#  开机慢诊断 (只读, 不改任何配置) —— 在 SteamOS 设备上运行
#  用法: bash 诊断-开机慢.sh          (建议 sudo, 能看全日志)
#  结果: 终端输出 + 报告存 ~/开机慢-诊断报告.txt (把报告发回来分析)
# =============================================================================
OUT="$HOME/开机慢-诊断报告.txt"
sec() { echo; echo "════════ $1 ════════"; }

{
sec "1. 总耗时与关键链路"
systemd-analyze 2>/dev/null
systemd-analyze blame 2>/dev/null | head -15
systemd-analyze critical-chain 2>/dev/null | head -25

sec "2. NTP 校时(元凶之一, 步骤[10]应已换境内源)"
timedatectl 2>/dev/null | grep -Ei "NTP|synchronized|Time zone"
echo "-- /etc/systemd/timesyncd.conf.d/ --"
grep -r "NTP" /etc/systemd/timesyncd.conf.d/ 2>/dev/null || echo "(未配置境内 NTP → 步骤[10]未装或被升级冲掉)"

sec "3. 网络等待类服务(卡死的常见位置)"
for s in systemd-networkd-wait-online.service NetworkManager-wait-online.service; do
    printf "%-45s enabled=%s active=%s\n" "$s" \
        "$(systemctl is-enabled "$s" 2>/dev/null)" "$(systemctl is-active "$s" 2>/dev/null)"
done
systemctl is-active NetworkManager systemd-networkd 2>/dev/null

sec "4. atomupd / 系统更新客户端(连 Valve 更新服务器)"
systemctl list-units --all 2>/dev/null | grep -iE "atomupd|steamos-update|update" | head -5
systemctl status atomupd-client 2>/dev/null | head -8

sec "5. 本次开机的超时告警(journal)"
journalctl -b -p warning --no-pager 2>/dev/null | grep -iE "timed out|timeout" | tail -15

sec "6. 到 Steam/Valve 服务器的连通性(境内关键)"
for u in https://steamcommunity.com https://store.steampowered.com https://api.steamcontent.com https://steamdeck-images.steamos.cloud; do
    r="$(curl -o /dev/null -s --connect-timeout 5 --max-time 10 -w '%{http_code} 连接%{time_connect}s 总%{time_total}s' "$u" 2>/dev/null)"
    printf "  %-40s %s\n" "$u" "${r:-超时/不可达}"
done

sec "7. DNS 配置"
grep -E "^nameserver" /etc/resolv.conf 2>/dev/null | head -3
resolvectl status 2>/dev/null | grep -A2 "DNS Servers" | head -6
} 2>&1 | tee "$OUT"

echo
echo "报告已保存: $OUT —— 请把此文件内容发回来分析。"
