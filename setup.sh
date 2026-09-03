#!/bin/sh
#
# OpenWrt setup for the Sophos XG 135w (and other x86/64 boxes)
# ---------------------------------------------------------------
# Idempotent: safe to re-run. Edit the CONFIGURATION block, copy to the router,
# then run it as root over SSH. Tested on OpenWrt 25.12 (apk); 24.10 (opkg) works too.
#
#   scp -O setup.sh root@192.168.1.1:/root/ && ssh root@192.168.1.1 sh /root/setup.sh
#
# What it does (each part can be switched off below):
#   - basic system, LAN/WAN, optional built-in WiFi
#   - LuCI (HTTPS) and SSH bound to the LAN only, SSH key-only login once a key exists
#   - DNS: AdGuard Home (filtering) -> Unbound (recursive, DNSSEC) with dnsmasq for DHCP/local names
#   - WireGuard server in its own locked-down firewall zone
#   - SQM (cake) on the WAN, banIP threat feeds, BBR
#   - optional /data partition on the unused disk space for logs, statistics and backups
#   - owut/Attended Sysupgrade pinned to a 1 GB root partition so upgrades keep working

# ===========================================
# CONFIGURATION - EDIT THESE AS NEEDED
# ===========================================

INITIAL_SETUP="yes"           # Configure LAN/WAN/WiFi (run once on a fresh install)

# System
TIMEZONE="Europe/London"      # tz name, e.g. America/New_York
DOMAIN_NAME="home.lan"        # local DNS domain for your devices
HOSTNAME="openwrt-xg135w"

# LAN
LAN_IP="192.168.1.1"
LAN_NETMASK="255.255.255.0"
DHCP_START="100"
DHCP_LIMIT="150"

# WAN: "dhcp", "pppoe", "static" or "none" (leave as-is)
WAN_TYPE="dhcp"
WAN_USERNAME=""               # PPPoE
WAN_PASSWORD=""               # PPPoE
WAN_STATIC_IP=""
WAN_STATIC_NETMASK=""
WAN_STATIC_GATEWAY=""
WAN_STATIC_DNS="1.1.1.1 1.0.0.1"

# Built-in WiFi (the XG 135w has one 5 GHz radio). "no" if a separate access point handles WiFi.
ENABLE_WIFI="no"
WIFI_SSID="MyNetwork"
WIFI_PASSWORD="ChangeMe-LongPassphrase"   # "" = open network (not recommended)
WIFI_COUNTRY="GB"
WIFI_CHANNEL="36"
WIFI_HTMODE="VHT80"
WIFI_ENCRYPTION="sae-mixed"   # sae-mixed = WPA2+WPA3, sae = WPA3 only, psk2 = WPA2

# Optional DHCP reservation for your access point (leave AP_MAC empty to skip)
AP_MAC=""                     # e.g. "AA:BB:CC:DD:EE:FF"
AP_IP="192.168.1.10"
AP_NAME="accesspoint"

# DNS
ENABLE_UNBOUND="yes"          # Recursive DNSSEC-validating resolver (127.0.0.1:5335)
ENABLE_ADBLOCK="yes"          # AdGuard Home on port 53 in front of Unbound
ADGUARD_UI_PORT="3000"
ADGUARD_ADMIN_USER="admin"
ADGUARD_PASSWORD_HASH=""      # bcrypt hash. Make one on your computer:
                              #   htpasswd -nbB admin 'YourPassword' | cut -d: -f2
                              # If empty, AdGuard is installed but not started and
                              # dnsmasq keeps port 53 forwarding to Unbound.

# WireGuard server (remote access). Peers are added afterwards, see README.
ENABLE_VPN_SERVER="yes"
WG_PORT="51820"               # UDP. Some networks only let 443/udp out; change if needed.
WG_SUBNET="10.8.0"            # server gets .1/24
WG_ALLOW_INTERNET="yes"       # let peers route all traffic through this router
WG_ALLOW_LAN="no"             # let peers reach the whole LAN (no = add per-host rules yourself)

# QoS / bandwidth shaping (SQM with cake). Worth enabling on slow or asymmetric lines
# (DSL, cable, anything under ~200 Mbit) where one upload can add hundreds of ms of
# latency. On symmetric gigabit fibre it costs ~10% throughput for a few ms gain, so
# it is off by default. Set the speeds to ~85-90% of what you measure with SQM off.
ENABLE_QOS="no"
SQM_DOWNLOAD_KBPS="850000"
SQM_UPLOAD_KBPS="950000"

# Security
ENABLE_BANIP="yes"            # block known-bad IPs on the WAN + auto-ban failed logins
BANIP_FEEDS="firehol1 threat dshield"

# Storage
ENABLE_DATA_PARTITION="yes"   # create /data on unused disk space; logs, stats, backups go there
ENABLE_USB_STORAGE="yes"
ENABLE_SAMBA="no"
ENABLE_DLNA="no"

# Monitoring / extras
ENABLE_MONITORING="yes"       # collectd + LuCI statistics
ENABLE_DDNS="no"
ENABLE_WAKELAN="yes"
ENABLE_MULTIWAN="no"          # mwan3, only with a second WAN
ENABLE_SSL_CERTS="no"         # Let's Encrypt for LuCI (needs a public DNS name)
ENABLE_OPENVPN="no"
ENABLE_SNMP="no"
ENABLE_DOCKER="no"
ENABLE_BACKUP_AUTO="yes"      # weekly config backup (to /data/backups or /root/backups)

# Upgrades
ROOTFS_SIZE_MB="1024"         # root partition size for ASU/owut builds; keep constant (max 1024)

REBOOT_WHEN_DONE="yes"

# ===========================================
# END OF CONFIGURATION
# ===========================================

set -u
say()  { printf '\n==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*"; }

# --- package manager (apk on 25.12+, opkg on 24.10) ---
if command -v apk >/dev/null 2>&1; then
    PKG=apk
    pkg_update()  { apk update >/dev/null; }
    pkg_install() { apk add "$@" >/dev/null 2>&1 || warn "Failed to install: $*"; }
    pkg_remove()  { apk del "$@" >/dev/null 2>&1; }
else
    PKG=opkg
    pkg_update()  { opkg update >/dev/null; }
    pkg_install() { opkg install "$@" >/dev/null 2>&1 || warn "Failed to install: $*"; }
    pkg_remove()  { opkg remove "$@" >/dev/null 2>&1; }
fi

zone_index() { uci show firewall | sed -n "s/^firewall\.@zone\[\([0-9]*\)\]\.name='$1'$/\1/p" | head -1; }
rule_index() { uci show firewall | sed -n "s/^firewall\.@rule\[\([0-9]*\)\]\.name='$1'$/\1/p" | head -1; }

# add a named firewall rule once; extra args are "option=value" pairs
fw_rule() {
    name="$1"; shift
    [ -n "$(rule_index "$name")" ] && return 0
    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name="$name"
    for kv in "$@"; do
        k=${kv%%=*}; v=${kv#*=}
        case "$k" in
            proto) for p in $v; do uci add_list firewall.@rule[-1].proto="$p"; done ;;
            *) uci set "firewall.@rule[-1].$k=$v" ;;
        esac
    done
}

sysctl_set() {
    if grep -q "^$1" /etc/sysctl.conf 2>/dev/null; then sed -i "s|^$1.*|$1 = $2|" /etc/sysctl.conf
    else echo "$1 = $2" >> /etc/sysctl.conf; fi
}

check_root_space() {
    usage=$(df / | tail -1 | awk '{print $5}' | tr -d %)
    echo "Root partition: ${usage}% used, $(df -h / | tail -1 | awk '{print $4}') free"
    [ "$usage" -gt 80 ] && warn "Root partition is getting full. See README: Upgrading OpenWrt."
}

ULA=$(uci -q get network.globals.ula_prefix | sed 's|::/48|::1|')
WG_ADDR="${WG_SUBNET}.1"

echo "=================================================="
echo " OpenWrt setup for Sophos XG 135w  (pkg: $PKG)"
echo "=================================================="
check_root_space

# ===========================================
# INITIAL SETUP
# ===========================================
if [ "$INITIAL_SETUP" = "yes" ]; then
    say "Initial setup: network"
    pkg_update

    uci set network.lan.ipaddr="$LAN_IP"
    uci set network.lan.netmask="$LAN_NETMASK"
    case "$WAN_TYPE" in
        pppoe)
            uci set network.wan.proto='pppoe'
            uci set network.wan.username="$WAN_USERNAME"
            uci set network.wan.password="$WAN_PASSWORD"
            uci set network.wan.ipv6='auto' ;;
        static)
            uci set network.wan.proto='static'
            uci set network.wan.ipaddr="$WAN_STATIC_IP"
            uci set network.wan.netmask="$WAN_STATIC_NETMASK"
            uci set network.wan.gateway="$WAN_STATIC_GATEWAY"
            uci set network.wan.dns="$WAN_STATIC_DNS" ;;
        dhcp)
            uci set network.wan.proto='dhcp'
            uci set network.wan.ipv6='auto' ;;
        *) echo "WAN left unconfigured" ;;
    esac
    uci commit network

    uci set dhcp.lan.start="$DHCP_START"
    uci set dhcp.lan.limit="$DHCP_LIMIT"
    uci set dhcp.lan.leasetime='12h'
    [ -n "$ULA" ] && uci set dhcp.lan.dns="$ULA"      # IPv6 clients get the router as DNS
    if [ -n "$AP_MAC" ] && ! uci show dhcp | grep -qi "mac='$AP_MAC'"; then
        uci add dhcp host >/dev/null
        uci set dhcp.@host[-1].name="$AP_NAME"
        uci set dhcp.@host[-1].mac="$AP_MAC"
        uci set dhcp.@host[-1].ip="$AP_IP"
    fi
    uci commit dhcp

    if [ "$ENABLE_WIFI" = "yes" ]; then
        say "Initial setup: built-in WiFi"
        # wpad-wolfssl in the stock image supports WPA3; do not install hostapd separately.
        pkg_install kmod-ath10k ath10k-board-qca988x ath10k-firmware-qca988x
        wifi config >/dev/null 2>&1
        uci set wireless.radio0.disabled='0'
        uci set wireless.radio0.country="$WIFI_COUNTRY"
        uci set wireless.radio0.band='5g'
        uci set wireless.radio0.channel="$WIFI_CHANNEL"
        uci set wireless.radio0.htmode="$WIFI_HTMODE"
        uci set wireless.default_radio0.disabled='0'
        uci set wireless.default_radio0.ssid="$WIFI_SSID"
        uci set wireless.default_radio0.mode='ap'
        uci set wireless.default_radio0.network='lan'
        if [ -n "$WIFI_PASSWORD" ]; then
            uci set wireless.default_radio0.encryption="$WIFI_ENCRYPTION"
            uci set wireless.default_radio0.key="$WIFI_PASSWORD"
            [ "$WIFI_ENCRYPTION" != "psk2" ] && uci set wireless.default_radio0.ieee80211w='1'
        else
            uci set wireless.default_radio0.encryption='none'
            warn "WiFi is an open network"
        fi
        uci commit wireless
        wifi reload
    else
        uci -q set wireless.radio0.disabled='1'
        uci -q set wireless.default_radio0.disabled='1'
        uci -q commit wireless
    fi
fi

# ===========================================
# PACKAGES
# ===========================================
say "Packages: base tools"
pkg_update
pkg_install curl ca-certificates htop nano less bind-dig tcpdump \
    block-mount kmod-fs-ext4 e2fsprogs parted partx-utils blkid lsblk fdisk usbutils pciutils

say "Packages: LuCI and upgrade tooling"
pkg_install luci-ssl uhttpd-mod-ubus luci-app-advanced-reboot luci-app-attendedsysupgrade owut
uci -q set attendedsysupgrade.owut='owut'
uci set attendedsysupgrade.owut.rootfs_size="$ROOTFS_SIZE_MB"
uci set attendedsysupgrade.owut.keep='true'
uci commit attendedsysupgrade

say "Packages: features"
pkg_install luci-app-nlbwmon
[ "$ENABLE_MONITORING" = "yes" ] && pkg_install collectd collectd-mod-cpu collectd-mod-memory collectd-mod-load \
    collectd-mod-network collectd-mod-interface collectd-mod-rrdtool collectd-mod-thermal luci-app-statistics iftop
[ "$ENABLE_UNBOUND" = "yes" ]    && pkg_install unbound-daemon unbound-control luci-app-unbound
[ "$ENABLE_ADBLOCK" = "yes" ]    && pkg_install adguardhome
[ "$ENABLE_VPN_SERVER" = "yes" ] && pkg_install wireguard-tools kmod-wireguard luci-proto-wireguard
[ "$ENABLE_OPENVPN" = "yes" ]    && pkg_install openvpn-openssl luci-app-openvpn
[ "$ENABLE_QOS" = "yes" ]        && pkg_install sqm-scripts luci-app-sqm
[ "$ENABLE_BANIP" = "yes" ]      && pkg_install banip luci-app-banip
[ "$ENABLE_DDNS" = "yes" ]       && pkg_install ddns-scripts ddns-scripts-services luci-app-ddns ddns-scripts-cloudflare
[ "$ENABLE_MULTIWAN" = "yes" ]   && pkg_install mwan3 luci-app-mwan3
[ "$ENABLE_WAKELAN" = "yes" ]    && pkg_install etherwake luci-app-wol
[ "$ENABLE_SSL_CERTS" = "yes" ]  && pkg_install acme-acmesh luci-app-acme
[ "$ENABLE_SNMP" = "yes" ]       && pkg_install snmpd luci-app-snmp
[ "$ENABLE_DOCKER" = "yes" ]     && pkg_install docker dockerd luci-app-dockerman
[ "$ENABLE_SAMBA" = "yes" ]      && pkg_install samba4-server luci-app-samba4
[ "$ENABLE_DLNA" = "yes" ]       && pkg_install minidlna luci-app-minidlna
if [ "$ENABLE_USB_STORAGE" = "yes" ]; then
    pkg_remove kmod-fs-ntfs                       # removed upstream; ntfs3 replaces it
    pkg_install kmod-usb-storage kmod-usb2 kmod-usb3 kmod-fs-ntfs3 kmod-fs-exfat kmod-fs-vfat exfat-fsck
    uci set fstab.@global[0].anon_mount='1'       # hotplugged drives appear under /mnt/<dev>
    uci set fstab.@global[0].check_fs='1'
    uci commit fstab
    /etc/init.d/fstab enable
    rm -f /etc/hotplug.d/block/10-mount           # legacy script from older versions of this repo
fi
pkg_install luci-app-package-manager

# ===========================================
# DATA PARTITION (/data)
# ===========================================
DATA_DIR=""
if [ "$ENABLE_DATA_PARTITION" = "yes" ]; then
    say "Data partition"
    ROOTPART=$(block info 2>/dev/null | sed -n 's|^/dev/\([a-z0-9]*\):.*MOUNT="/".*|\1|p' | head -1)
    DISK=$(echo "$ROOTPART" | sed 's/[0-9]*$//')
    DATAPART="${DISK}3"
    if [ -z "$DISK" ]; then
        warn "Could not determine the root disk; skipping /data"
    elif [ -b "/dev/$DATAPART" ]; then
        echo "/dev/$DATAPART already exists"
    else
        END_S=$(parted -sm "/dev/$DISK" unit s print 2>/dev/null | awk -F: '$1=="2"{gsub("s","",$3); print $3}')
        DISK_S=$(parted -sm "/dev/$DISK" unit s print 2>/dev/null | awk -F: 'NR==2{gsub("s","",$2); print $2}')
        if [ -n "$END_S" ] && [ -n "$DISK_S" ] && [ $((DISK_S - END_S)) -gt 4194304 ]; then   # > 2 GiB free
            START_MIB=$(( (END_S + 1) * 512 / 1048576 + 1 ))
            echo "Creating /dev/$DATAPART from ${START_MIB}MiB to end of disk"
            # -f fixes the GPT backup header, which an image built for a smaller disk leaves at the wrong place
            parted -s -f -a optimal "/dev/$DISK" mkpart data ext4 "${START_MIB}MiB" 100% && partx -a "/dev/$DISK" 2>/dev/null
            sleep 2
            if [ -b "/dev/$DATAPART" ]; then
                mkfs.ext4 -q -L data "/dev/$DATAPART" 2>/dev/null || mke2fs -q -t ext4 -L data "/dev/$DATAPART"
            else
                warn "Partition did not appear; skipping"
            fi
        else
            warn "Not enough unallocated space after the root partition; skipping /data"
        fi
    fi
    if [ -b "/dev/$DATAPART" ]; then
        UUID=$(block info "/dev/$DATAPART" 2>/dev/null | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')
        if [ -n "$UUID" ] && ! uci show fstab | grep -q "uuid='$UUID'"; then
            uci add fstab mount >/dev/null
            uci set fstab.@mount[-1].uuid="$UUID"
            uci set fstab.@mount[-1].target='/data'
            uci set fstab.@mount[-1].fstype='ext4'
            uci set fstab.@mount[-1].options='rw,noatime'
            uci set fstab.@mount[-1].enabled='1'
            uci commit fstab
        fi
        mkdir -p /data
        grep -q " /data " /proc/mounts || mount -t ext4 -o rw,noatime "/dev/$DATAPART" /data
        grep -q " /data " /proc/mounts && DATA_DIR=/data
    fi
fi
[ -n "$DATA_DIR" ] && echo "/data mounted: $(df -h /data | tail -1 | awk '{print $4}') free" || warn "No /data partition; logs stay in RAM, backups go to /root/backups"

# Where persistent data lives
if [ -n "$DATA_DIR" ]; then
    LOGDIR=/data/log; ADG_DIR=/data/adguardhome; STATS_DIR=/data/rrd; NLBW_DIR=/data/nlbwmon; BANIP_DIR=/data/banip; BACKUP_DIR=/data/backups
    mkdir -p $LOGDIR $ADG_DIR $STATS_DIR $NLBW_DIR $BANIP_DIR $BACKUP_DIR
    # system log to disk (ring buffer in RAM is kept too)
    uci set system.@system[0].log_file="$LOGDIR/syslog"
    uci set system.@system[0].log_size='8192'          # KiB; logd rotates to syslog.old beyond this
    uci set system.@system[0].log_type='file'
    /etc/init.d/log restart
    [ "$ENABLE_MONITORING" = "yes" ] && { uci -q set luci_statistics.collectd_rrdtool.DataDir="$STATS_DIR"; uci -q commit luci_statistics; }
    uci -q set nlbwmon.@nlbwmon[0].database_directory="$NLBW_DIR"; uci -q commit nlbwmon
    [ "$ENABLE_BANIP" = "yes" ] && { uci -q set banip.global.ban_reportdir="$BANIP_DIR"; uci -q set banip.global.ban_backupdir="$BANIP_DIR"; }
else
    ADG_DIR=/srv/adguardhome; BACKUP_DIR=/root/backups
    mkdir -p $ADG_DIR $BACKUP_DIR
fi
uci commit system

# ===========================================
# DNS: AdGuard Home -> Unbound, dnsmasq for DHCP/local names
# ===========================================
if [ "$ENABLE_UNBOUND" = "yes" ]; then
    say "DNS: Unbound recursive resolver on 127.0.0.1:5335"
    uci set unbound.ub_main.listen_port='5335'
    uci set unbound.ub_main.dhcp_link='none'
    uci set unbound.ub_main.domain="$DOMAIN_NAME"
    uci set unbound.ub_main.localservice='1'
    uci set unbound.ub_main.validator='1'
    uci set unbound.ub_main.rebind_protection='1'
    uci set unbound.ub_main.enabled='1'
    for z in fwd_cloudflare fwd_google fwd_isp; do uci -q set unbound.$z.enabled='0'; done
    uci commit unbound
    /etc/init.d/unbound enable
    /etc/init.d/unbound restart

    uci set dhcp.@dnsmasq[0].domain="$DOMAIN_NAME"
    uci set dhcp.@dnsmasq[0].local="/$DOMAIN_NAME/"
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5335'
    uci set dhcp.@dnsmasq[0].rebind_protection='1'
    uci commit dhcp
fi

if [ "$ENABLE_ADBLOCK" = "yes" ] && [ "$ENABLE_UNBOUND" = "yes" ]; then
    if [ -z "$ADGUARD_PASSWORD_HASH" ] && [ ! -s /etc/adguardhome/adguardhome.yaml ]; then
        warn "ADGUARD_PASSWORD_HASH is empty: AdGuard installed but not enabled; dnsmasq stays on port 53"
        uci set dhcp.@dnsmasq[0].port='53'; uci commit dhcp
    else
        say "DNS: AdGuard Home on port 53"
        uci set adguardhome.config.workdir="$ADG_DIR"; uci commit adguardhome
        mkdir -p /etc/adguardhome "$ADG_DIR"; chown adguardhome:adguardhome "$ADG_DIR" 2>/dev/null
        if [ ! -s /etc/adguardhome/adguardhome.yaml ]; then
            BIND_HOSTS="    - 127.0.0.1
    - $LAN_IP"
            [ "$ENABLE_VPN_SERVER" = "yes" ] && BIND_HOSTS="$BIND_HOSTS
    - $WG_ADDR"
            [ -n "$ULA" ] && BIND_HOSTS="$BIND_HOSTS
    - $ULA"
            cat > /etc/adguardhome/adguardhome.yaml <<EOF
http:
  address: $LAN_IP:$ADGUARD_UI_PORT
  session_ttl: 720h
users:
  - name: $ADGUARD_ADMIN_USER
    password: $ADGUARD_PASSWORD_HASH
auth_attempts: 5
block_auth_min: 15
theme: auto
dns:
  bind_hosts:
$BIND_HOSTS
  port: 53
  ratelimit: 0
  refuse_any: true
  upstream_dns:
    - 127.0.0.1:5335
    - '[/$DOMAIN_NAME/]127.0.0.1:54'
  bootstrap_dns:
    - 127.0.0.1:5335
  upstream_mode: load_balance
  cache_size: 4194304
  enable_dnssec: false
  use_private_ptr_resolvers: true
  local_ptr_upstreams:
    - 127.0.0.1:54
  serve_plain_dns: true
  hostsfile_enabled: true
querylog:
  dir_path: "$ADG_DIR"
  interval: 72h
  size_memory: 1000
  enabled: true
  file_enabled: true
statistics:
  dir_path: "$ADG_DIR"
  interval: 168h
  enabled: true
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
  - enabled: true
    url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt
    name: HaGeZi Multi PRO
    id: 3
filtering:
  filtering_enabled: true
  protection_enabled: true
  safebrowsing_enabled: false
  parental_enabled: false
  blocking_mode: default
  filters_update_interval: 24
  safe_fs_patterns:
    - $ADG_DIR/userfilters/*
clients:
  runtime_sources:
    whois: false
    arp: true
    rdns: true
    dhcp: true
    hosts: true
log:
  enabled: true
  file: ""
  verbose: false
schema_version: 28
EOF
            chmod 600 /etc/adguardhome/adguardhome.yaml; chown adguardhome:adguardhome /etc/adguardhome/adguardhome.yaml 2>/dev/null
        fi
        uci set dhcp.@dnsmasq[0].port='54'
        # dnsmasq only advertises itself as DNS server when it serves port 53, so say it explicitly
        uci -q delete dhcp.lan.dhcp_option
        uci add_list dhcp.lan.dhcp_option="6,$LAN_IP"
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        /etc/init.d/adguardhome enable
        /etc/init.d/adguardhome restart
        sleep 5
        if dig +short +time=5 @127.0.0.1 openwrt.org A | grep -q .; then
            echo "AdGuard answering on port 53. UI: http://$LAN_IP:$ADGUARD_UI_PORT"
        else
            warn "AdGuard not answering; falling back to dnsmasq on port 53 (check: logread | grep -i adguard)"
            /etc/init.d/adguardhome stop; /etc/init.d/adguardhome disable
            uci set dhcp.@dnsmasq[0].port='53'; uci -q delete dhcp.lan.dhcp_option; uci commit dhcp; /etc/init.d/dnsmasq restart
        fi
    fi
fi

# ===========================================
# FIREWALL AND MANAGEMENT ACCESS
# ===========================================
say "Firewall and management access"
uci set firewall.@defaults[0].syn_flood='1'
uci set firewall.@defaults[0].input='REJECT'
uci set firewall.@defaults[0].output='ACCEPT'
uci set firewall.@defaults[0].forward='REJECT'
uci set firewall.@defaults[0].drop_invalid='1'
WZ=$(zone_index wan)
if [ -n "$WZ" ]; then
    uci set firewall.@zone[$WZ].input='REJECT'
    uci set firewall.@zone[$WZ].output='ACCEPT'
    uci set firewall.@zone[$WZ].forward='REJECT'
    uci set firewall.@zone[$WZ].masq='1'
    uci set firewall.@zone[$WZ].mtu_fix='1'
fi
# OpenWrt's default IPsec pass-through rules are not needed here
for n in Allow-IPSec-ESP Allow-ISAKMP; do i=$(rule_index $n); [ -n "$i" ] && uci set firewall.@rule[$i].enabled='0'; done
uci commit firewall

# LuCI: HTTPS, LAN addresses only
LISTEN_HTTP="$LAN_IP:80";  LISTEN_HTTPS="$LAN_IP:443"
[ -n "$ULA" ] && { LISTEN_HTTP="$LISTEN_HTTP [$ULA]:80"; LISTEN_HTTPS="$LISTEN_HTTPS [$ULA]:443"; }
uci set uhttpd.main.listen_http="$LISTEN_HTTP"
uci set uhttpd.main.listen_https="$LISTEN_HTTPS"
uci set uhttpd.main.redirect_https='1'
uci set uhttpd.main.rfc1918_filter='1'
uci commit uhttpd
/etc/init.d/uhttpd restart

# SSH: LAN only, key-only once a key is present
uci set dropbear.@dropbear[0].Interface='lan'
if [ -s /etc/dropbear/authorized_keys ]; then
    uci set dropbear.@dropbear[0].PasswordAuth='off'
    uci set dropbear.@dropbear[0].RootPasswordAuth='off'
    echo "SSH password login disabled (authorized key present)"
else
    warn "No key in /etc/dropbear/authorized_keys; SSH password login left ON. Add a key, then re-run."
fi
uci commit dropbear
/etc/init.d/dropbear restart

# ===========================================
# WIREGUARD SERVER
# ===========================================
if [ "$ENABLE_VPN_SERVER" = "yes" ]; then
    say "WireGuard server"
    if ! uci -q get network.wg0 >/dev/null; then
        PRIV=$(wg genkey)
        uci set network.wg0='interface'
        uci set network.wg0.proto='wireguard'
        uci set network.wg0.private_key="$PRIV"
        uci set network.wg0.listen_port="$WG_PORT"
        uci add_list network.wg0.addresses="$WG_ADDR/24"
        uci commit network
    fi
    VZ=$(zone_index vpn)
    if [ -z "$VZ" ]; then
        uci add firewall zone >/dev/null
        uci set firewall.@zone[-1].name='vpn'
        uci add_list firewall.@zone[-1].network='wg0'
    else
        uci -q get firewall.@zone[$VZ].network | grep -q wg0 || uci add_list firewall.@zone[$VZ].network='wg0'
    fi
    VZ=$(zone_index vpn)
    uci set firewall.@zone[$VZ].input='REJECT'       # peers get nothing on the router by default
    uci set firewall.@zone[$VZ].output='ACCEPT'
    uci set firewall.@zone[$VZ].forward='REJECT'
    uci -q delete firewall.@zone[$VZ].masq
    fw_rule Allow-WireGuard  src=wan proto=udp dest_port="$WG_PORT" target=ACCEPT
    fw_rule VPN-Router-DNS   src=vpn "proto=tcp udp" dest_port=53 target=ACCEPT
    fw_rule VPN-Router-Ping  src=vpn proto=icmp target=ACCEPT
    [ "$WG_ALLOW_INTERNET" = "yes" ] && fw_rule VPN-to-Internet src=vpn dest=wan target=ACCEPT
    [ "$WG_ALLOW_LAN" = "yes" ]      && fw_rule VPN-to-LAN src=vpn dest=lan target=ACCEPT
    uci commit firewall
    ifup wg0 >/dev/null 2>&1
    echo "WireGuard public key: $(uci get network.wg0.private_key | wg pubkey)"
    echo "Endpoint: <your public IP or DDNS name>:$WG_PORT   (add peers: see README)"
fi

fw4 check >/dev/null 2>&1 && fw4 reload >/dev/null 2>&1 || warn "fw4 check failed; firewall NOT reloaded"

# ===========================================
# QoS, banIP, performance, maintenance
# ===========================================
if [ "$ENABLE_QOS" = "yes" ]; then
    say "SQM (cake) on the WAN device"
    WAN_DEV=$(uci -q get network.wan.device)
    uci -q get sqm.wan >/dev/null || uci set sqm.wan='queue'
    uci set sqm.wan.interface="$WAN_DEV"
    uci set sqm.wan.qdisc='cake'
    uci set sqm.wan.script='piece_of_cake.qos'
    uci set sqm.wan.download="$SQM_DOWNLOAD_KBPS"
    uci set sqm.wan.upload="$SQM_UPLOAD_KBPS"
    uci set sqm.wan.enabled='1'
    uci commit sqm
    /etc/init.d/sqm enable; /etc/init.d/sqm restart >/dev/null 2>&1
fi

if [ "$ENABLE_BANIP" = "yes" ]; then
    say "banIP"
    uci set banip.global.ban_enabled='1'
    uci -q delete banip.global.ban_feed
    for f in $BANIP_FEEDS; do uci add_list banip.global.ban_feed="$f"; done
    uci set banip.global.ban_autoallowlist='1'
    uci set banip.global.ban_autoblocklist='1'
    uci set banip.global.ban_logcount='3'
    uci commit banip
    /etc/init.d/banip enable; /etc/init.d/banip restart >/dev/null 2>&1
fi

[ "$ENABLE_QOS" != "yes" ] && [ -x /etc/init.d/sqm ] && { uci -q set sqm.wan.enabled='0'; uci -q commit sqm; /etc/init.d/sqm stop >/dev/null 2>&1; /etc/init.d/sqm disable; }
[ "$ENABLE_MULTIWAN" != "yes" ] && [ -x /etc/init.d/mwan3 ] && { /etc/init.d/mwan3 stop >/dev/null 2>&1; /etc/init.d/mwan3 disable; }

say "Performance"
pkg_install kmod-tcp-bbr
sysctl_set net.core.rmem_max 16777216
sysctl_set net.core.wmem_max 16777216
sysctl_set net.ipv4.tcp_congestion_control bbr
sysctl -p /etc/sysctl.conf >/dev/null 2>&1
uci set network.@globals[0].packet_steering='1'; uci commit network

say "System settings"
uci set system.@system[0].zonename="$TIMEZONE"
uci set system.@system[0].hostname="$HOSTNAME"
uci commit system

if [ "$ENABLE_BACKUP_AUTO" = "yes" ]; then
    mkdir -p /etc/backup-scripts "$BACKUP_DIR"
    cat > /etc/backup-scripts/auto-backup.sh <<EOF
#!/bin/sh
# Weekly config backup. Copy these off the router too; /root does not survive a sysupgrade.
BACKUP_DIR="$BACKUP_DIR"
mkdir -p "\$BACKUP_DIR"
sysupgrade -k -b "\$BACKUP_DIR/openwrt-backup-\$(date +%Y%m%d_%H%M%S).tar.gz"
ls -t "\$BACKUP_DIR"/openwrt-backup-*.tar.gz | tail -n +9 | xargs -r rm -f
EOF
    chmod +x /etc/backup-scripts/auto-backup.sh
    grep -q auto-backup.sh /etc/crontabs/root 2>/dev/null || echo "0 3 * * 0 /etc/backup-scripts/auto-backup.sh" >> /etc/crontabs/root
fi
/etc/init.d/cron enable; /etc/init.d/cron restart
uci commit

echo
echo "=================================================="
echo " Done"
echo "=================================================="
check_root_space
echo "LuCI:     https://$LAN_IP  (LAN only)"
[ "$ENABLE_ADBLOCK" = "yes" ] && echo "AdGuard:  http://$LAN_IP:$ADGUARD_UI_PORT"
[ "$ENABLE_VPN_SERVER" = "yes" ] && echo "WireGuard: UDP $WG_PORT, server $WG_ADDR/24"
[ -n "$DATA_DIR" ] && echo "Data:     /data (logs, statistics, backups)"
echo
if [ "$REBOOT_WHEN_DONE" = "yes" ]; then
    echo "Rebooting in 15 seconds (Ctrl+C to cancel)..."
    sleep 15
    reboot
fi
