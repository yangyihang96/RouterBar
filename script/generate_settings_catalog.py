#!/usr/bin/env python3
"""Generate only reviewed form structure, never current values, from the local firmware audit."""
from html.parser import HTMLParser
from pathlib import Path
import json,re,sys
source=Path(sys.argv[1])
class Form(HTMLParser):
    def __init__(self):
        super().__init__();self.fields={};self.row='';self.script=False;self.select=None;self.option=None
    def handle_starttag(self,tag,attrs):
        a=dict(attrs)
        if tag in ('script','style'):self.script=True
        if tag=='tr':self.row=''
        if tag not in ('input','select','textarea','option'):return
        if tag=='option' and self.select:
            self.option={'value':a.get('value',''),'label':''};self.select['options'].append(self.option);return
        key=a.get('name','');typ=a.get('type','text')
        if not key or typ in ('hidden','submit','button','reset','file'):return
        label=re.sub(r'\s+',' ',self.row).strip().rstrip(':：')[:110]
        f={'key':key,'label':label or key,'kind':'text','options':[],'columns':[]}
        if typ in ('radio','checkbox'):f['kind']='toggle'
        if 'password'==typ or (typ not in ('radio','checkbox') and re.search('passwd|password|_psk$|_priv$|_key$|_secret$',key)):f['kind']='secret'
        if tag=='textarea':f['kind']='multiline'
        if a.get('maxlength','').isdigit():f['maxLength']=int(a['maxlength'])
        if 'onblur' in a:
            m=re.search(r'validator.range\(this,\s*(\d+),\s*(\d+)\)',a['onblur'])
            if m:f.update(kind='integer',minimum=int(m[1]),maximum=int(m[2]))
        if typ=='radio':
            v=a.get('value','')
            if re.fullmatch(r'[A-Za-z0-9_.-]{0,24}',v):
                f['options']=[{'value':v,'label':{'0':'关闭 / 否','1':'开启 / 是','udp':'UDP','tcp-client':'TCP','tls':'TLS','secret':'静态密钥','tun':'TUN','tap':'TAP'}.get(v,v)}]
            if key in self.fields:
                self.fields[key]['options']+=f['options'];return
        self.fields[key]=f
        if tag=='select':f['kind']='choice';self.select=f
    def handle_endtag(self,tag):
        if tag in ('script','style'):self.script=False
        if tag=='select':self.select=None;self.option=None
        if tag=='option':self.option=None
    def handle_data(self,s):
        if not self.script:self.row+=s
        if self.option is not None:self.option['label']+=s

def opt(values):return [{'value':str(a),'label':b} for a,b in values]
def field(key,label,kind='text',options=None,columns=None,**kw):
    return dict(key=key,label=label,kind=kind,options=opt(options or []),columns=columns or [],**kw)
def toggle(k,l):return field(k,l,'toggle')
def rules(k,l,cols):return field(k,l,'rules',columns=cols)
sections=[]
def section(id,title,category,symbol,page,service,keys='',extra=None,transform=None,wait=5,impact=None):
    p=source/page
    if not p.exists():raise ValueError('missing source '+page)
    parser=Form();parser.feed(p.read_text());fields=[]
    for key in keys.split():
        if key not in parser.fields:raise ValueError(page+' missing '+key)
        f=dict(parser.fields[key]);f['options']=[dict(x,label=re.sub(r'\s+',' ',x['label']).strip()) for x in f['options']]
        f['options']=list({x['value']:x for x in f['options']}.values())
        if f['kind']=='choice' and not f['options']:continue
        if f['kind']=='toggle':
            if not f['options']:f['options']=opt([('0','关闭'),('1','开启')])
            if set(o['value'] for o in f['options']) != {'0','1'}:f['kind']='choice' 
        if re.search(r'(?:ipaddr|netmask|gateway|dns[12]_x)$',key):f['kind']='ipv4'
        if key.endswith('_port') and f['kind']=='text':f.update(kind='integer',minimum=1,maximum=65535)
        if transform:f['key']=transform(f['key'])
        fields.append(f)
    fields+=extra or []
    if any(not f['label'] or f['label']==f['key'] for f in fields):
        pass
    sec=dict(id=id,title=title,category=category,symbol=symbol,subtitle=title+' · 从路由器读取并直接保存',source=page,service=service,wait=wait,
        impact=impact or ('保存会重启路由器并暂时中断网络。' if 'reboot' in service else '保存后路由器会重载相关服务，连接可能短暂中断。'),fields=fields)
    sections.append(sec);return sec
# Explicit, source-backed band keys; no implicit wl_unit reads.
for band,name in [(0,'2.4 GHz'),(1,'5 GHz')]:
    p=f'wl{band}_';x=lambda k,p=p:p+k
    extra=[field(x('ssid'),'网络名称','text',maxLength=32),toggle(x('closed'),'隐藏网络名称'),field(x('auth_mode_x'),'安全方式','choice',[('open','开放网络'),('psk2','WPA2-Personal'),('sae','WPA3-Personal'),('psk2sae','WPA2 / WPA3-Personal')]),field(x('wpa_psk'),'无线密码','secret',maxLength=64),field(x('crypto'),'加密方式','choice',[('aes','AES'),('aes+gcmp256','AES + GCMP-256'),('gcmp256','GCMP-256'),('tkip+aes','TKIP + AES')]),field(x('mfp'),'管理帧保护','choice',[('0','关闭'),('1','可选'),('2','必须')]),field(x('wpa_gtk_rekey'),'密钥轮换间隔（秒）','integer',minimum=0,maximum=2592000)]
    section(f'wifi{band}',name+' 无线网络','无线网络','wifi','Advanced_Wireless_Content.asp','restart_wireless',extra=extra,wait=15)
    # 1.6.0: the 160 MHz switch is shown under 一般设置 › 5 GHz, as on the web, in a section of its own.
    if band == 1: section('band1','5 GHz 频宽选项','无线网络','dot.radiowaves.left.and.right','Advanced_Wireless_Content.asp','restart_wireless',extra=[toggle('wl1_bw_160','允许 160 MHz 频宽')],wait=15)
    section(f'radio{band}',name+' 专业设置','无线网络','antenna.radiowaves.left.and.right','Advanced_WAdvanced_Content.asp','restart_wireless','wl_radio wl_ap_isolate wl_bss_maxassoc wl_user_rssi wl_nmode_x wl_11ax wl_11be wl_mbo_enable wl_twt wl_btc_mode wl_igs wl_plcphdr wl_frag wl_ampdu_rts wl_rts wl_dtim wl_bcn wl_frameburst wl_wme wl_wme_no_ack wl_wme_apsd wl_atf wl_mumimo wl_ofdma wl_txbf wl_itxbf',transform=lambda k,p=p:k.replace('wl_',p,1),wait=15)
    section(f'radius{band}',name+' RADIUS','无线网络','person.badge.key','Advanced_WSecurity_Content.asp','restart_wireless','wl_radius_ipaddr wl_radius_port wl_radius_key',transform=lambda k,p=p:k.replace('wl_',p,1),wait=15)
    section(f'acl{band}',name+' MAC 访问控制','无线网络','checkmark.shield','Advanced_ACL_Content.asp','restart_wireless',extra=[field(x('macmode'),'访问模式','choice',[('disabled','关闭'),('allow','仅允许列表设备'),('deny','阻止列表设备')]),rules(x('maclist_x'),'设备列表',['MAC 地址'])],wait=15)
section('lan','局域网地址','局域网','network','Advanced_LAN_Content.asp','restart_net_and_phy','lan_hostname lan_domain lan_ipaddr lan_netmask lan_gateway lan_dns1_x lan_dns2_x redirect_dname',wait=35,impact='修改局域网地址后，可能需要在连接设置中输入新地址。网络会暂时断开。')
section('dhcp','DHCP 与地址保留','局域网','list.bullet.rectangle','Advanced_DHCP_Content.asp','restart_net_and_phy','dhcp_enable_x dhcpd_querylog lan_domain dhcp_start dhcp_end dhcp_lease dhcp_gateway_x sip_server dhcp_dns1_x dhcp_dns2_x dhcpd_dns_router dhcp_wins_x dhcp_static_x',extra=[rules('dhcp_staticlist','固定地址',['MAC 地址','IP 地址','DNS 地址','主机名'])],wait=30)
section('routes','静态路由','局域网','arrow.triangle.branch','Advanced_GWStaticRoute_Content.asp','restart_net','sr_enable_x',extra=[rules('sr_rulelist','路由表',['目标网络','子网掩码','网关','跃点数','接口'])],wait=10)
section('switch','交换机与链路聚合','局域网','point.3.connected.trianglepath.dotted','Advanced_SwitchCtrl_Content.asp','reboot','jumbo_frame_enable ctf_disable_force lan_stp aqr_hwnat_type aqr_link_speed aqr_ipg sfpp_hwnat_type sfpp_max_speed sfpp_force_on lacp_enabled bonding_policy',wait=90)
section('iptv','IPTV 与组播','局域网','tv','Advanced_IPTV_Content.asp','restart_net','switch_wantag switch_wan0tagid switch_wan0prio switch_wan1tagid switch_wan1prio switch_wan2tagid switch_wan2prio dr_enable_x mr_enable_x mr_igmp_ver mr_mld_ver mr_qleave_x emf_enable udpxy_enable_x',wait=15)
for unit in range(2):
    section(f'wan{unit}',f'WAN {unit+1} 互联网','互联网','globe','Advanced_WAN_Content.asp','restart_wan_if','wan_proto wan_enable wan_nat_x wan_upnp_enable wan_dhcpfilter_enable wan_dot1q wan_vid wan_dot1p wan_dhcpenable_x wan_ipaddr_x wan_netmask_x wan_gateway_x wan_vendorid wan_clientid wan_auth_x wan_pppoe_username wan_pppoe_passwd wan_pppoe_auth wan_pppoe_idletime wan_pppoe_mtu wan_pppoe_mru wan_pppoe_service wan_pppoe_ac wan_pppoe_hostuniq wan_pptp_options_x wan_ppp_echo wan_ppp_echo_interval wan_ppp_echo_failure wan_pppoe_options_x wan_heartbeat_x wan_vpndhcp wan_hostname wan_hwaddr_x wan_dhcp_qry wan_mtu',transform=lambda k,u=unit:k.replace('wan_',f'wan{u}_',1),extra=[toggle(f'wan{unit}_dnsenable_x','自动获取 DNS'),field(f'wan{unit}_dns1_x','DNS 服务器 1','ipv4'),field(f'wan{unit}_dns2_x','DNS 服务器 2','ipv4')],wait=15)
section('dns','DNS 安全与加密','互联网','lock.shield','Advanced_WAN_Content.asp','restart_stubby;restart_dnsmasq','dns_fwd_local dns_norebind dnssec_enable dnssec_check_unsigned_x dns_priv_override dnspriv_enable dnspriv_profile',extra=[rules('dnspriv_rulelist','DNS over TLS 服务器',['服务器地址','端口','TLS 主机名','公钥指纹'])])
section('portforward','端口转发 / Open NAT','互联网','arrow.left.arrow.right','Advanced_VirtualServer_Content.asp','restart_firewall',extra=[toggle('vts_enable_x','启用端口转发'),rules('vts_rulelist','转发规则',['名称','外部端口','内部 IP','内部端口','协议','来源 IP'])])
section('trigger','端口触发','互联网','arrow.turn.down.right','Advanced_PortTrigger_Content.asp','restart_firewall','autofw_enable_x',extra=[rules('autofw_rulelist','触发规则',['名称','触发端口','触发协议','转发端口','转发协议'])])
section('dmz','DMZ','互联网','rectangle.connected.to.line.below','Advanced_Exposed_Content.asp','restart_firewall','dmz_ip dmz1_ip')
section('ddns','动态 DNS','互联网','globe.americas','Advanced_ASUSDDNS_Content.asp','restart_ddns','ddns_wan_unit ddns_ipv6_update ddns_server_x ddns_hostname_x ddns_username_x ddns_passwd_x ddns_wildcard_x ddns_regular_check ddns_regular_period ddns_refresh_x',extra=[toggle('ddns_enable_x','启用动态 DNS')])
section('nat','NAT 穿透','互联网','arrow.triangle.swap','Advanced_NATPassThrough_Content.asp','restart_firewall;restart_pppoe_relay','fw_pt_pptp fw_pt_l2tp fw_pt_ipsec fw_pt_rtsp fw_pt_h323 fw_pt_sip fw_pt_sip_mode fw_pt_pppoerelay pppoerelay_unit vts_ftpport')
section('ipv6','IPv6','互联网','network','Advanced_IPv6_Content.asp','restart_net','ipv6_service ipv6_dhcp_pd ipv6_dhcp6c_release ipv6_tun_v4end ipv6_relay ipv6_6rd_dhcp ipv6_6rd_prefix ipv6_6rd_prefixlen ipv6_6rd_router ipv6_6rd_ip4size ipv6_tun_addr ipv6_tun_addrlen ipv6_tun_peer ipv6_tun_mtu ipv6_tun_ttl ipv6_ipaddr ipv6_prefix_len_wan ipv6_gateway ipv6_rtr_addr ipv6_prefix_length ipv6_prefix ipv6_autoconf_type ipv6_dhcp_lifetime ipv6_dnsenable ipv6_dns1 ipv6_dns2 ipv6_dns3',wait=30)
section('firewall','防火墙','安全防护','shield.lefthalf.filled','Advanced_BasicFirewall_Content.asp','restart_firewall','fw_enable_x fw_dos_x fw_log_x misc_ping_x ipv6_fw_enable',extra=[rules('ipv6_fw_rulelist','IPv6 入站规则',['名称','远程 IP','本地 IP','端口','协议'])])
section('urlfilter','网址过滤','安全防护','link.badge.plus','Advanced_URLFilter_Content.asp','restart_firewall','url_enable_x url_mode_x',extra=[rules('url_rulelist','网址规则',['启用 0/1','来源 IP / MAC','网址'])])
section('keywords','关键词过滤','安全防护','text.magnifyingglass','Advanced_KeywordFilter_Content.asp','restart_firewall','keyword_enable_x',extra=[rules('keyword_rulelist','关键词',['关键词'])])
section('networkfilter','网络服务过滤','安全防护','line.3.horizontal.decrease.circle','Advanced_Firewall_Content.asp','restart_firewall','fw_lw_enable_x filter_lw_default_x filter_lw_icmp_x',extra=[rules('filter_lwlist','服务规则',['来源 IP','来源端口','目标 IP','目标端口','协议'])])
section('aiprotection','AiProtection','安全防护','checkmark.shield.fill','AiProtection_HomeProtection.asp','restart_wrs;restart_firewall',extra=[toggle('wrs_protect_enable','AiProtection 网络防护'),toggle('wrs_mals_enable','恶意网站拦截'),toggle('wrs_vp_enable','双向 IPS 防护'),toggle('wrs_cc_enable','受感染设备拦截')])
section('qos','QoS 与游戏加速','流量与加速','speedometer','QoS_EZQoS.asp','restart_qos;restart_firewall','qos_overhead qos_mpu qos_atm',extra=[toggle('qos_enable','启用 QoS'),field('qos_type','QoS 类型','choice',[('0','传统 QoS'),('1','自适应 QoS'),('2','带宽限制')]),field('qos_obw','上传带宽（Kbps）','integer'),field('qos_ibw','下载带宽（Kbps）','integer'),rules('qos_bw_rulelist','带宽限制设备',['启用 0/1','设备 IP / MAC','下载 Kbps','上传 Kbps','优先级'])],wait=15)
section('qosrules','传统 QoS 规则','流量与加速','line.3.horizontal.decrease','Advanced_QOSUserRules_Content.asp','restart_qos;restart_firewall',extra=[rules('qos_rulelist','服务优先级',['服务名称','来源 IP / MAC','目标端口','协议','传输大小 KB','优先级 0–4'])])
section('vpndirector','VPN Director 分流','VPN','arrow.triangle.branch','Advanced_VPNDirector.asp','restart_vpnrouting0',extra=[rules('vpndirector_rulelist','分流规则',['启用 0/1','说明','本地 IP / 子网','远程 IP / 子网','接口 WAN / OVPN1…'])])
for unit in range(1,6):
    section(f'ovpn{unit}',f'OpenVPN 客户端 {unit}','VPN','lock.shield','Advanced_OpenVPNClient_Content.asp',f'restart_vpnclient{unit}','vpn_client_desc vpn_client_proto vpn_client_addr vpn_client_port vpn_client_bridge vpn_client_nat vpn_client_fw vpn_client_remote vpn_client_nm vpn_client_adns vpn_client_rgw vpn_client_gw vpn_client_enforce vpn_client_crypt vpn_client_userauth vpn_client_username vpn_client_password vpn_client_useronly vpn_client_ncp_ciphers vpn_client_cipher vpn_client_hmac vpn_client_digest vpn_client_verb vpn_client_comp vpn_client_reneg vpn_client_connretry vpn_client_tlsremote vpn_client_cn',transform=lambda k,u=unit:k.replace('vpn_client_',f'vpn_client{u}_',1),wait=10)
for unit in range(1,6):
    section(f'wgc{unit}',f'WireGuard 客户端 {unit}','VPN','key.horizontal','Advanced_WireguardClient_Content.asp','restart_wgc','wgc_enable wgc_desc wgc_nat wgc_fw wgc_enforce wgc_priv wgc_mtu wgc_addr wgc_dns wgc_ppub wgc_psk wgc_aips wgc_ep_addr wgc_ep_port wgc_alive',transform=lambda k,u=unit:k.replace('wgc_',f'wgc{u}_',1),wait=5)
section('wgs1','WireGuard 服务器','VPN','server.rack','Advanced_WireguardServer_Content.asp','restart_wgs;restart_dnsmasq','wgs_enable wgs_dns wgs_nat6 wgs_psk wgs_alive wgs_addr wgs_port',transform=lambda k:k.replace('wgs_','wgs1_',1))
section('samba','SMB 文件共享','USB 与存储','externaldrive','Advanced_AiDisk_samba.asp','restart_ftpsamba;restart_dnsmasq','computer_name st_samba_workgroup smbd_protocol smbd_simpler_naming smbd_master smbd_wins st_max_user usb_fs_ntfs_sparse',extra=[toggle('enable_samba','启用 SMB 共享')])
section('ftp','FTP 文件共享','USB 与存储','externaldrive.badge.wifi','Advanced_AiDisk_ftp.asp','restart_ftpsamba','ftp_tls st_max_user ftp_lang',extra=[toggle('enable_ftp','启用 FTP')])
section('ntp','时间与自动重启','系统管理','clock','Advanced_System_Content.asp','restart_time','ntpd_enable ntpd_server_redir ntp_server0 ntp_server1 reboot_schedule_enable_x',extra=[field('time_zone','时区规则'),field('reboot_schedule','重启时间表',maxLength=11)])
section('admin','管理访问','系统管理','person.crop.circle.badge.checkmark','Advanced_System_Content.asp','restart_time;restart_httpd;restart_upnp','captcha_enable http_autologout nat_redirect_enable http_enable http_lanport https_lanport misc_http_x misc_httpport_x misc_httpsport_x',impact='修改管理协议、端口或访问权限后，当前连接可能断开；请使用新地址重新连接。')
section('ssh','SSH 与系统服务','系统管理','terminal','Advanced_System_Content.asp','restart_time;restart_httpd;restart_upnp','jffs2_scripts telnetd_enable sshd_enable sshd_forwarding sshd_port sshd_pass sshd_authkeys shell_timeout_x',extra=[],impact='管理服务设置会改变路由器登录方式；保存后会重载系统服务。')
section('led','指示灯与电源','系统管理','lightbulb','Advanced_System_Content.asp','restart_time;restart_leds;restart_usb_idle;pagecache_ratio','AllLED btn_ez_radiotoggle usb_idle_enable usb_idle_timeout usb_usb3 pagecache_ratio')
section('snmp','SNMP','系统管理','chart.xyaxis.line','Advanced_SNMP_Content.asp','restart_snmpd','snmpd_enable snmpd_wan sysName sysLocation sysContact roCommunity rwCommunity v3_auth_type v3_auth_passwd v3_priv_type v3_priv_passwd')
section('logs','系统日志设置','系统管理','doc.text','Main_LogStatus_Content.asp','restart_logger','log_ipaddr log_port message_loglevel log_level')
section('conntrack','连接追踪与其他设置','系统管理','point.topleft.down.to.point.bottomright.curvepath','Tools_OtherSettings.asp','restart_conntrack','ct_max tcp_established tcp_syn_sent tcp_syn_recv tcp_fin_wait tcp_time_wait tcp_close tcp_close_wait tcp_last_ack udp_assured udp_unreplied http_dut_redir ipv6_ns_drop aae_disable_force dhcpd_send_wpad')
section('nfs','NFS 文件共享','USB 与存储','externaldrive.connected.to.line.below','Advanced_AiDisk_NFS.asp','restart_nasapps',extra=[toggle('nfsd_enable','启用 NFS'),toggle('nfsd_enable_v2','启用 NFS v2'),rules('nfsd_exportlist','共享目录',['目录路径','允许的客户端','挂载选项'])])
section('media','媒体服务器','USB 与存储','play.tv','mediaserver.asp','restart_media','dms_friendly_name daapd_friendly_name',extra=[toggle('dms_enable','启用 DLNA'),toggle('daapd_enable','启用 iTunes 服务器'),toggle('dms_web','启用媒体服务器网页状态')])
section('dnsdirector','DNS Director','安全防护','arrow.triangle.branch','DNSDirector.asp','restart_dnsfilter','dnsfilter_mode dnsfilter_custom1 dnsfilter_custom2 dnsfilter_custom3 dnsfilter_custom61 dnsfilter_custom62 dnsfilter_custom63',extra=[toggle('dnsfilter_enable_x','启用 DNS Director')])
for unit in range(1,3):
    section(f'ovpns{unit}',f'OpenVPN 服务器 {unit}','VPN','server.rack','Advanced_VPN_OpenVPN.asp',f'restart_vpnserver{unit}','vpn_server_port vpn_server_proto vpn_server_if vpn_server_crypt vpn_server_dhcp vpn_server_local vpn_server_remote vpn_server_sn vpn_server_nm vpn_server_r1 vpn_server_r2 vpn_server_ip6 vpn_server_nat6 vpn_server_local6 vpn_server_remote6 vpn_server_sn6 vpn_server_cipher vpn_server_ncp_ciphers vpn_server_digest vpn_server_comp vpn_server_verb vpn_server_pdns vpn_server_c2c vpn_server_ccd vpn_server_ccd_excl vpn_server_hmac vpn_server_igncrt',transform=lambda k,u=unit:k.replace('vpn_server_',f'vpn_server{u}_',1),wait=10)
section('timemachine','Time Machine','USB 与存储','clock.arrow.circlepath','Advanced_TimeMachine.asp','restart_timemachine','tm_vol_size',extra=[toggle('timemachine_enable','启用 Time Machine')])
# 1.12: PrinterServer.asp submits usb_printer with action_script "restart_lpd;restart_u2ec;" and action_wait 5 (109–112).
section('printer','网络打印机服务器','USB 与存储','printer','PrinterServer.asp','restart_lpd;restart_u2ec;',extra=[toggle('usb_printer','网络打印机服务器')])
# Firmware fields are rendered in the dedicated native update screen as well.
section('updates','更新检查偏好','系统管理','arrow.down.circle','Advanced_FirmwareUpgrade_Content.asp','',extra=[toggle('firmware_check_enable','自动检查新固件')],impact='只改变更新检查偏好，不会安装固件。')
# Verify unique keys and replace mechanical labels with readable nouns.
labels={'AllLED':'全部指示灯','wl_11ax':'Wi-Fi 6 / 802.11ax','wl_11be':'Wi-Fi 7 / 802.11be','qos_mpu':'最小数据包（字节）','sysName':'系统名称','sysLocation':'位置','sysContact':'联系人','roCommunity':'只读 Community','rwCommunity':'读写 Community','ct_max':'最大连接数'}
labels.update({'wl_user_rssi':'漫游助手信号阈值（dBm）','wl_twt':'目标唤醒时间（TWT）','ipv6_ns_drop':'丢弃 IPv6 邻居发现广播'})
for sec in sections:
    seen=set()
    for f in sec['fields']:
        if f['key'] in seen:raise ValueError('duplicate '+f['key'])
        seen.add(f['key'])
        label_key=re.sub(r'^wl[01]_', 'wl_', f['key'])
        if label_key in labels:f['label']=labels[label_key]
        if f['kind']=='toggle' and not f['options']:f['options']=opt([('0','关闭'),('1','开启')])
        if f['key'].endswith('_wpa_psk'):f['note']='WPA2/WPA3 密码通常为 8–63 个字符；64 位十六进制密钥仅适用于兼容模式。'
        if f['label']==f['key']:f['label']=f['key'].replace('_',' ').upper()
        if 'Community' in f['key'] or 'authkeys' in f['key']:f['kind']='secretText' if 'authkeys' in f['key'] else 'secret'
sys.path.insert(0,str(Path(__file__).resolve().parent))
from refine_settings_catalog import refine
refine(sections)
out=Path(__file__).resolve().parents[1]/'Sources/RouterCore/Resources/SettingsCatalog.json'
out.write_text(json.dumps(sections,ensure_ascii=False,indent=2)+'\n')
print(f'{len(sections)} native sections, {sum(len(s["fields"]) for s in sections)} fields; no current values exported')
