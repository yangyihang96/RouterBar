#!/usr/bin/env python3
"""Reviewed corrections applied on top of the generated settings catalog.

The generator reads form controls, but some controls are only page helpers: the page converts them and
submits another nvram variable, and httpd's validate_apply only writes names from router_defaults.
Others carry rules that live in the page's JavaScript instead of the input tag. Each entry below cites
the Asuswrt-Merlin 3006.102.5 page it follows (RT-BE88U uses the sysdep/GT-AXE11000 professional
wireless page and the Multi-Service WAN page). Running this again leaves the catalog unchanged.
"""
import json, re, sys
from pathlib import Path

# Page control → the variable the page actually submits.
RENAMED = {
    # Advanced_System_Content.asp: shell_timeout.value = shell_timeout_x * 60 (minutes → seconds).
    'shell_timeout_x': 'shell_timeout',
    # Advanced_System_Content.asp: postData.reboot_schedule_enable = the reboot_schedule_enable_x radio.
    'reboot_schedule_enable_x': 'reboot_schedule_enable',
}

# Never submitted: Advanced_DHCP_Content.asp keeps the SIP server input disabled, and defaults.c has no such variable.
REMOVED = {'sip_server'}

# Field types and ranges from the pages' validators (validator.range / numberRange / rangeAllowZero, isLegal_ipv6,
# validIPForm, domainName). Keys are generic: the unit number of wl0_, wan1_, vpn_client3_ … is removed.
TYPED = {
    'ct_max': dict(kind='integer', minimum=256, maximum=300000),  # Tools_OtherSettings.asp:50
    'ddns_refresh_x': dict(kind='integer', minimum=0, maximum=365),  # Advanced_ASUSDDNS_Content.asp:635
    'dhcp_end': dict(kind='ipv4'),  # Advanced_DHCP_Content.asp:514
    'dhcp_gateway_x': dict(kind='ipv4'),  # Advanced_DHCP_Content.asp:505
    'dhcp_lease': dict(kind='integer', minimum=120, maximum=604800),  # Advanced_DHCP_Content.asp:538
    'dhcp_start': dict(kind='ipv4'),  # Advanced_DHCP_Content.asp:513
    'dhcp_wins_x': dict(kind='ipv4'),  # Advanced_DHCP_Content.asp:507
    'dmz1_ip': dict(kind='ipv4'),  # Advanced_Exposed_Content.asp:71
    'dmz_ip': dict(kind='ipv4'),  # Advanced_Exposed_Content.asp:36
    'dnsfilter_custom1': dict(kind='ipv4'),  # DNSDirector.asp:594
    'dnsfilter_custom2': dict(kind='ipv4'),  # DNSDirector.asp:603
    'dnsfilter_custom3': dict(kind='ipv4'),  # DNSDirector.asp:612
    'dnsfilter_custom61': dict(kind='ipv6'),  # DNSDirector.asp:264
    'dnsfilter_custom62': dict(kind='ipv6'),  # DNSDirector.asp:265
    'dnsfilter_custom63': dict(kind='ipv6'),  # DNSDirector.asp:266
    'ipv6_6rd_ip4size': dict(kind='integer', minimum=0, maximum=32),  # Advanced_IPv6_Content.asp:958
    'ipv6_6rd_prefix': dict(kind='ipv6'),  # Advanced_IPv6_Content.asp:959
    'ipv6_6rd_prefixlen': dict(kind='integer', minimum=3, maximum=126),  # Advanced_IPv6_Content.asp:960
    'ipv6_6rd_router': dict(kind='ipv4'),  # Advanced_IPv6_Content.asp:957
    'ipv6_dhcp_lifetime': dict(kind='integer', minimum=120, maximum=604800),  # Advanced_IPv6_Content.asp:886
    'ipv6_dns1': dict(kind='ipv6'),  # Advanced_IPv6_Content.asp:934
    'ipv6_dns2': dict(kind='ipv6'),  # Advanced_IPv6_Content.asp:936
    'ipv6_dns3': dict(kind='ipv6'),  # Advanced_IPv6_Content.asp:938
    'ipv6_gateway': dict(kind='ipv6'),  # Advanced_IPv6_Content.asp:861
    'ipv6_ipaddr': dict(kind='ipv6'),  # Advanced_IPv6_Content.asp:856
    'ipv6_prefix': dict(kind='ipv6'),  # Advanced_IPv6_Content.asp:951
    'ipv6_prefix_len_wan': dict(kind='integer', minimum=3, maximum=128),  # Advanced_IPv6_Content.asp:857
    'ipv6_prefix_length': dict(kind='integer', minimum=3, maximum=126),  # Advanced_IPv6_Content.asp:866
    'ipv6_relay': dict(kind='ipv4'),  # Advanced_IPv6_Content.asp:942
    'ipv6_rtr_addr': dict(kind='ipv6'),  # Advanced_IPv6_Content.asp:868
    'ipv6_tun_addr': dict(kind='ipv6'),  # Advanced_IPv6_Content.asp:947
    'ipv6_tun_addrlen': dict(kind='integer', minimum=3, maximum=128),  # Advanced_IPv6_Content.asp:948
    'ipv6_tun_mtu': dict(kind='integer', minimum=1280, maximum=1480, allowsZero=True),  # Advanced_IPv6_Content.asp:924
    'ipv6_tun_peer': dict(kind='ipv6'),  # Advanced_IPv6_Content.asp:949
    'ipv6_tun_ttl': dict(kind='integer', minimum=0, maximum=255),  # Advanced_IPv6_Content.asp:925
    'ipv6_tun_v4end': dict(kind='ipv4'),  # Advanced_IPv6_Content.asp:946
    'lan_netmask': dict(kind='netmask'),  # Advanced_LAN_Content.asp:265
    'log_ipaddr': dict(kind='host'),  # Main_LogStatus_Content.asp:100
    'pagecache_ratio': dict(kind='integer', minimum=5, maximum=90),  # Advanced_System_Content.asp:2910
    'qos_mpu': dict(kind='integer', minimum=0, maximum=256),  # QoS_EZQoS.asp:2297
    'qos_overhead': dict(kind='integer', minimum=-64, maximum=256),  # QoS_EZQoS.asp:2293
    'st_max_user': dict(kind='integer', minimum=1, maximum=99),  # Advanced_AiDisk_samba.asp:780
    'switch_wan0prio': dict(kind='integer', minimum=0, maximum=7),  # Advanced_IPTV_Content.asp:608
    'switch_wan0tagid': dict(kind='integer', minimum=2, maximum=4094),  # Advanced_IPTV_Content.asp:599
    'switch_wan1prio': dict(kind='integer', minimum=0, maximum=7),  # Advanced_IPTV_Content.asp:611
    'switch_wan1tagid': dict(kind='integer', minimum=2, maximum=4094),  # Advanced_IPTV_Content.asp:602
    'switch_wan2prio': dict(kind='integer', minimum=0, maximum=7),  # Advanced_IPTV_Content.asp:614
    'switch_wan2tagid': dict(kind='integer', minimum=2, maximum=4094),  # Advanced_IPTV_Content.asp:605
    'udpxy_enable_x': dict(kind='integer', minimum=1024, maximum=65535, allowsZero=True),  # Advanced_IPTV_Content.asp:646
    'usb_idle_timeout': dict(kind='integer', minimum=60, maximum=9999),  # Advanced_System_Content.asp:924
    'vpn_client_addr': dict(kind='host'),  # Advanced_OpenVPNClient_Content.asp:431
    'vpn_client_connretry': dict(kind='integer', minimum=0, maximum=999),  # Advanced_OpenVPNClient_Content.asp:452
    'vpn_client_gw': dict(kind='ipv4'),  # Advanced_OpenVPNClient_Content.asp:1019
    'vpn_client_nm': dict(kind='ipv4'),  # Advanced_OpenVPNClient_Content.asp:999
    'vpn_client_remote': dict(kind='ipv4'),  # Advanced_OpenVPNClient_Content.asp:990
    'vpn_client_reneg': dict(kind='integer', minimum=-1, maximum=32767),  # Advanced_OpenVPNClient_Content.asp:451
    'vpn_client_verb': dict(kind='integer', minimum=0, maximum=6),  # Advanced_OpenVPNClient_Content.asp:450
    'vpn_server_local': dict(kind='ipv4'),  # Advanced_VPN_OpenVPN.asp:1895
    'vpn_server_local6': dict(kind='ipv6'),  # Advanced_VPN_OpenVPN.asp:559
    'vpn_server_r1': dict(kind='ipv4'),  # Advanced_VPN_OpenVPN.asp:497
    'vpn_server_r2': dict(kind='ipv4'),  # Advanced_VPN_OpenVPN.asp:510
    'vpn_server_remote': dict(kind='ipv4'),  # Advanced_VPN_OpenVPN.asp:1896
    'vpn_server_remote6': dict(kind='ipv6'),  # Advanced_VPN_OpenVPN.asp:564
    'vpn_server_sn': dict(kind='ipv4'),  # Advanced_VPN_OpenVPN.asp:453
    'vpn_server_verb': dict(kind='integer', minimum=0, maximum=6),  # Advanced_VPN_OpenVPN.asp:411
    'vts_ftpport': dict(kind='integer', minimum=1, maximum=65535),  # Advanced_NATPassThrough_Content.asp:90
    'wan_dot1p': dict(kind='integer', minimum=0, maximum=7),  # sysdep/FUNCTION/MULTISERVICE_WAN/Advanced_WAN_Content.asp:754
    'wan_gateway_x': dict(kind='ipv4'),  # sysdep/FUNCTION/MULTISERVICE_WAN/Advanced_WAN_Content.asp:2164
    'wan_ipaddr_x': dict(kind='ipv4'),  # sysdep/FUNCTION/MULTISERVICE_WAN/Advanced_WAN_Content.asp:2163
    'wan_mtu': dict(kind='integer', minimum=1280, maximum=1500),  # sysdep/FUNCTION/MULTISERVICE_WAN/Advanced_WAN_Content.asp:2259
    'wan_netmask_x': dict(kind='netmask'),  # sysdep/FUNCTION/MULTISERVICE_WAN/Advanced_WAN_Content.asp:2183 (0.0.0.0 allowed)
    'wan_ppp_echo_failure': dict(kind='integer', minimum=0),  # sysdep/FUNCTION/MULTISERVICE_WAN/Advanced_WAN_Content.asp:4328 (digits only)
    'wan_ppp_echo_interval': dict(kind='integer', minimum=0),  # sysdep/FUNCTION/MULTISERVICE_WAN/Advanced_WAN_Content.asp:4324 (digits only)
    'wan_pppoe_idletime': dict(kind='integer', minimum=0, maximum=4294967295),  # sysdep/FUNCTION/MULTISERVICE_WAN/Advanced_WAN_Content.asp:2216
    'wan_pppoe_mru': dict(kind='integer', minimum=128, maximum=1492),  # sysdep/FUNCTION/MULTISERVICE_WAN/Advanced_WAN_Content.asp:2222
    'wan_pppoe_mtu': dict(kind='integer', minimum=128, maximum=1492),  # sysdep/FUNCTION/MULTISERVICE_WAN/Advanced_WAN_Content.asp:2221
    'wan_vid': dict(kind='integer', minimum=2, maximum=4094),  # sysdep/FUNCTION/MULTISERVICE_WAN/Advanced_WAN_Content.asp:744
    'wgc_alive': dict(kind='integer', minimum=1, maximum=65535),  # Advanced_WireguardClient_Content.asp:366
    'wgc_ep_addr': dict(kind='host'),  # Advanced_WireguardClient_Content.asp:338
    'wgc_mtu': dict(kind='integer', minimum=576, maximum=1500),  # Advanced_WireguardClient_Content.asp:371
    'wgs_alive': dict(kind='integer', minimum=0),  # Advanced_WireguardServer_Content.asp:185 (digits only)
    'wl_bcn': dict(kind='integer', minimum=20, maximum=1000),  # sysdep/GT-AXE11000/www/Advanced_WAdvanced_Content.asp:1124
    'wl_bss_maxassoc': dict(kind='integer', minimum=1, maximum=128),  # sysdep/GT-AXE11000/www/Advanced_WAdvanced_Content.asp:1149
    'wl_dtim': dict(kind='integer', minimum=1, maximum=255),  # sysdep/GT-AXE11000/www/Advanced_WAdvanced_Content.asp:1123
    'wl_frag': dict(kind='integer', minimum=256, maximum=2346),  # sysdep/GT-AXE11000/www/Advanced_WAdvanced_Content.asp:1121
    'wl_radius_ipaddr': dict(kind='ip'),  # Advanced_WSecurity_Content.asp:82
    'wl_rts': dict(kind='integer', minimum=0, maximum=2347),  # sysdep/GT-AXE11000/www/Advanced_WAdvanced_Content.asp:1122
    'wl_user_rssi': dict(kind='integer', minimum=-90, maximum=-40, allowsZero=True),  # sysdep/GT-AXE11000/www/Advanced_WAdvanced_Content.asp:1157
}

# Tools_OtherSettings.asp: the timeouts are page inputs joined into ct_tcp_timeout ("0 est syn_sent syn_recv fin_wait
# time_wait close close_wait last_ack 0") and ct_udp_timeout ("unreplied assured"); established allows 1–432000 s,
# the others 1–86400 s.
TCP_TIMEOUTS = [('established', '已建立'), ('syn_sent', 'SYN 已发送'), ('syn_recv', 'SYN 已接收'), ('fin_wait', 'FIN 等待'),
                ('time_wait', 'TIME_WAIT'), ('close', '关闭'), ('close_wait', 'CLOSE_WAIT'), ('last_ack', 'LAST_ACK')]
PACKED = {f'tcp_{name}': dict(label=f'TCP 超时：{title}（秒）', kind='integer', minimum=1, maximum=432000 if name == 'established' else 86400,
                              packed=dict(key='ct_tcp_timeout', index=index, count=10))
          for index, (name, title) in enumerate(TCP_TIMEOUTS, start=1)}
PACKED['udp_unreplied'] = dict(label='UDP 超时：未回复（秒）', kind='integer', minimum=1, maximum=86400, packed=dict(key='ct_udp_timeout', index=0, count=2))
PACKED['udp_assured'] = dict(label='UDP 超时：已确认（秒）', kind='integer', minimum=1, maximum=86400, packed=dict(key='ct_udp_timeout', index=1, count=2))

AP_MODE_NOTE = '仅在接入点（AP）等非路由器模式下使用；路由器模式下路由器网页不显示此项。'

# Generic key → attributes to set; None removes the attribute. Applied after TYPED.
FIELDS = {
    'shell_timeout': dict(
        label='SSH / Telnet 闲置超时（秒）', kind='integer', minimum=600, maximum=59940, allowsZero=True, maxLength=None,
        note='单位为秒：0 表示不自动断开，其余为 600–59940 秒（路由器网页中的 10–999 分钟）。'),
    'http_autologout': dict(
        label='网页自动退出（分钟）', kind='integer', minimum=10, maximum=999, allowsZero=True,
        note='0 表示不自动退出。'),
    # Advanced_System_Content.asp validForm: validator.range(1, 65535); the remote HTTPS port needs 1024-65535.
    # Both remote ports sit in one table row whose title the page rewrites, hence the explicit labels.
    'http_lanport': dict(label='HTTP 局域网端口', kind='integer', minimum=1, maximum=65535),
    'https_lanport': dict(label='HTTPS 局域网端口', kind='integer', minimum=1, maximum=65535),
    # hideport(): on routers with HTTPS support the remote HTTP port input stays disabled, so the page never submits it.
    'misc_httpport_x': dict(label='远程管理 HTTP 端口', kind='readonly', minimum=None, maximum=None,
                            note='支持 HTTPS 的路由器只能通过 HTTPS 从互联网管理，路由器网页不提交此项。'),
    'misc_httpsport_x': dict(label='远程管理 HTTPS 端口', kind='integer', minimum=1024, maximum=65535,
                             note='请避开路由器其他服务已使用的端口；路由器网页会额外检查端口冲突。'),
    # Advanced_System_Content.asp: the time_zone_select list (zones in Sources/RouterCore/Resources/TimeZones.json,
    # from script/generate_time_zones.py); applyRule() copies the choice into time_zone. RouterBar edits the zone and
    # the two variables below together in one picker.
    'time_zone': dict(kind='timeZone', label='时区', note=None),
    'reboot_schedule': dict(
        pattern=r'^[01]{7}([01][0-9]|2[0-3])[0-5][0-9]$',
        note='11 位：周日到周六各 1 位（1 表示重启），再接 24 小时制的时和分，例如 01000000330 表示每周一 03:30。'
             '若路由器设为按月重启，此项不生效。'),
    # Advanced_LAN_Content.asp reboots the router when redirect_dname changes.
    'redirect_dname': dict(note='修改后需要重启路由器才会生效；路由器网页保存这一项时会直接重启。'),
    # Advanced_System_Content.asp: needReboot = (usb_usb3 changed).
    'usb_usb3': dict(note='修改后需要重启路由器才会生效；路由器网页保存这一项时会直接重启。'),
    # Advanced_System_Content.asp: the button radio is WPS (0/0), Wi-Fi toggle (radiotoggle 1, btn_ez_mode 0) or LED (0/1);
    # RouterCore sends btn_ez_mode=0 with the Wi-Fi choice. The LED choice stays in the router page.
    'btn_ez_radiotoggle': dict(
        kind='choice', options=[{'value': '0', 'label': 'WPS（或在路由器网页设为指示灯开关）'}, {'value': '1', 'label': '开关 Wi-Fi'}],
        note='若路由器有独立的 Wi-Fi 开关按钮，路由器网页不提供“开关 Wi-Fi”，此项不会生效。'),
    # Advanced_LAN_Content.asp hides these rows when sw_mode is 1 (router).
    'lan_gateway': dict(note=AP_MODE_NOTE),
    'lan_dns1_x': dict(note=AP_MODE_NOTE),
    'lan_dns2_x': dict(note=AP_MODE_NOTE),
    # Advanced_ASUSDDNS_Content.asp: for WWW.ASUS.COM the page asks for the name only and appends .asuscomm.com.
    'ddns_hostname_x': dict(note='使用 WWW.ASUS.COM 时请填写完整名称，例如 myhome.asuscomm.com。'),
    # Advanced_ASUSDDNS_Content.asp:638 rejects only values below 30; the input holds five digits.
    'ddns_regular_period': dict(kind='integer', minimum=30, maximum=99999, note='单位为分钟，最少 30。'),
    'ddns_refresh_x': dict(note='单位为天。'),
    # QoS_EZQoS.asp:793/857: the page shows Mb/s and saves Mb/s × 1024, which may have a fraction (0.1 → 102.4).
    'qos_obw': dict(label='上传带宽（kbit/s）', kind='text', pattern=r'^[0-9]+(\.[0-9]+)?$',
                    note='路由器网页以 Mb/s 显示，这里保存的是 Mb/s × 1024（可带小数），例如 100 Mb/s 为 102400。手动设置带宽时不能为 0。'),
    'qos_ibw': dict(label='下载带宽（kbit/s）', kind='text', pattern=r'^[0-9]+(\.[0-9]+)?$',
                    note='路由器网页以 Mb/s 显示，这里保存的是 Mb/s × 1024（可带小数），例如 100 Mb/s 为 102400。手动设置带宽时不能为 0。'),
    # Advanced_TimeMachine.asp:80/180/183: shown in GB, saved as GB × 1024 MB, 0 means no limit.
    'tm_vol_size': dict(label='Time Machine 卷容量（MB）', kind='integer', minimum=0,
                        note='0 表示不限制；路由器网页以 GB 显示，这里保存的是 GB × 1024，不能超过所选磁盘分区的可用空间。'),
    # Advanced_VPN_OpenVPN.asp:481 maskRange 255.255.0.0–255.255.255.248; :613 valid_IP_CIDR(…, "IPv6").
    'vpn_server_nm': dict(kind='netmask', minimum=16, maximum=29),
    'vpn_server_sn6': dict(kind='ipv6Prefix'),
    # Multi-Service WAN page :2252 check_macaddr: six hex pairs, unicast (even first octet).
    'wan_hwaddr_x': dict(kind='mac', pattern=r'^[0-9A-Fa-f][02468ACEace](:[0-9A-Fa-f]{2}){5}$', note='需为单播地址（第一个字节为偶数）。'),
    # Multi-Service WAN page :2226-2229 lowers the PPPoE MTU to wan_mtu − 8 when it would exceed it.
    'wan_pppoe_mtu': dict(note='需比 WAN 的 MTU 至少小 8；路由器网页会自动调低超出的值。'),
    'wl_user_rssi': dict(note='0 表示关闭漫游助手；其余为 −90 到 −40 dBm。'),
    'udpxy_enable_x': dict(note='填写 UDP 代理端口；0 表示关闭。'),
    'ipv6_tun_mtu': dict(note='0 表示使用默认值。'),
    'vpn_client_reneg': dict(note='单位为秒；-1 表示使用默认值。'),
    # sysdep/GT-AXE11000 Advanced_WAdvanced_Content.asp:1038-1068 (applyRule) and 1523-1611 (wifi7_mode): switching
    # 802.11be also changes auth_mode_x, crypto and mfp (WPA3 / OWE when on), then a second saveNvram request (1070-1088)
    # copies 11be, auth, crypto and mfp to the other Smart Connect bands; with MLO on it sends the user to MLO.asp. The app does
    # not make that second request, so the row stays read-only here. Where the main Wi-Fi is an SDN network (ui_support
    # sdn_mainfh) the page hides the row (808-810, 1793) and the 网络 page switches Wi-Fi 7 per network instead
    # (WebMenuCatalog.fieldConditions and SDNWiFi7 in RouterCore).
    'wl_11be': dict(kind='readonly',
                    note='切换 Wi-Fi 7 时，路由器网页会同时调整认证方式、加密和 MFP（开启时改为 WPA3 类方式），再把这些设置同步到 Smart Connect 的其他频段，并与 MLO 联动；请在路由器网页中修改。'),
}
FIELDS.update(PACKED)

# Exact key → attributes, for the rare field whose band changes the rules.
EXACT = {
    # regen_mode(): 5 GHz offers Auto, AX only (9), N/AC/AX mixed (8) and Legacy (2); N only (1) is 2.4 GHz.
    'wl1_nmode_x': dict(options=[{'value': '0', 'label': '自动'}, {'value': '9', 'label': 'AX only'},
                                 {'value': '8', 'label': 'N/AC/AX mixed'}, {'value': '2', 'label': 'Legacy'}]),
}

# Hidden inputs the page submits with time_zone, inserted after it (section, after key, fields).
ADDED = [
    ('ntp', 'time_zone', [
        # select_time_zone(): 1 when the zone value contains DST or TDT, else 0; rc appends time_zone_dstoff only when 1.
        dict(key='time_zone_dst', label='夏令时', kind='toggle', options=[{'value': '1', 'label': '开启 / 是'}, {'value': '0', 'label': '关闭 / 否'}],
             columns=[]),
        # applyRule(): "M" + month.week.day/hour of the start and end selects, joined by a comma (POSIX TZ rule).
        dict(key='time_zone_dstoff', label='夏令时规则', kind='dstRule', options=[], columns=[]),
    ]),
]

# The page's row order where the generated catalog differs: the time zone rows follow the NTP server switches.
ORDER = {
    'ntp': ['ntpd_enable', 'ntpd_server_redir', 'time_zone', 'time_zone_dst', 'time_zone_dstoff', 'ntp_server0', 'ntp_server1',
            'reboot_schedule_enable', 'reboot_schedule'],
}

# The system page composes its service list from what changed; RouterCore adds restart_httpd and restart_dnsmasq.
SYSTEM_SERVICE = 'restart_time;restart_firewall'
SECTIONS = {
    'lan': dict(impact='修改局域网地址后，DHCP 地址池会改到新网段，手动绑定的 IP、端口转发等规则仍保留旧地址，需要另行更新；'
                       '网络会暂时断开，请在连接设置中使用新地址。'),
    # rc/services.c "time": restart_time stops and starts cron, NTP, the system log, Telnet and SSH around setup_timezone().
    'ntp': dict(service=SYSTEM_SERVICE,
                impact='保存后路由器会重新应用时区，并重启 NTP、系统记录、定时任务、SSH / Telnet 服务和防火墙；已有的 SSH 会话可能断开。'),
    'admin': dict(service=SYSTEM_SERVICE,
                  impact='修改管理协议或端口后，路由器会重启管理网页服务，当前连接会中断，请按新的协议或端口重新连接；其他项目保存后会重载防火墙。'),
    'ssh': dict(service=SYSTEM_SERVICE, impact='管理服务设置会改变路由器登录方式；保存后会重启 SSH / Telnet 并重载防火墙，已有的 SSH 会话会断开。'),
}


def generic(key):
    return re.sub(r'^(wl|wan|vpn_client|vpn_server|wgc|wgs)\d+_', r'\1_', key)


def apply(field, attributes):
    for name, value in attributes.items():
        if value is None:
            field.pop(name, None)
        else:
            field[name] = value


def refine(sections):
    for section in sections:
        for name, value in SECTIONS.get(section['id'], {}).items():
            section[name] = value
        section['fields'] = [field for field in section['fields'] if field['key'] not in REMOVED]
        for field in section['fields']:
            field['key'] = RENAMED.get(field['key'], field['key'])
            for table in (TYPED.get(generic(field['key'])), FIELDS.get(generic(field['key'])), EXACT.get(field['key'])):
                apply(field, table or {})
        for section_id, after, added in ADDED:
            if section['id'] != section_id:
                continue
            keys = [field['key'] for field in section['fields']]
            fresh = [dict(field) for field in added if field['key'] not in keys]
            for field in added:
                if field['key'] in keys:
                    section['fields'][keys.index(field['key'])] = dict(field)
            position = keys.index(after) + 1
            section['fields'][position:position] = fresh
        if section['id'] in ORDER:
            order = ORDER[section['id']]
            if sorted(order) != sorted(field['key'] for field in section['fields']):
                raise SystemExit(f"{section['id']}: field order list does not match the catalog")
            section['fields'].sort(key=lambda field: order.index(field['key']))
    return sections


if __name__ == '__main__':
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'Sources/RouterCore/Resources/SettingsCatalog.json'
    sections = refine(json.loads(path.read_text()))
    path.write_text(json.dumps(sections, ensure_ascii=False, indent=2) + '\n')
    print(f'{len(sections)} sections refined')
