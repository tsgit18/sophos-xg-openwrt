# OpenWrt on the Sophos XG 135w

A tested recipe for running [OpenWrt](https://openwrt.org/) on a Sophos XG 135w firewall appliance, with a setup script that turns it into a hardened home router: WireGuard remote access, DNS filtering, a recursive DNSSEC resolver, traffic shaping, threat-feed blocking and proper upgrades.

Tested with **OpenWrt 25.12** (x86/64, `apk` package manager) on an **XG 135w rev. 3**. Other XG/SG desktop models with the same x86 architecture should work the same way.

## Why do this?

Sophos Firewall OS (SFOS) is an excellent product, and if your appliance is still supported the best thing you can do is keep running it. But Sophos hardware reaches end-of-life like everything else, and once an appliance can no longer get SFOS updates or a licence you are left with a capable, fanless, multi-port x86 box that would be a shame to throw away.

The XG 135w rev. 3 is a good example: an Intel Atom C3558, 6 GB of RAM, a 64 GB SSD, eight gigabit ports, a 5 GHz radio and a serial console. Running OpenWrt on it gives you:

- A fully supported, actively patched firewall/router OS for as long as x86/64 is supported upstream, which is indefinitely.
- Line-rate routing for a gigabit connection, with enough CPU left for WireGuard at several hundred Mbit/s and cake shaping.
- All of OpenWrt's package ecosystem: AdGuard Home, Unbound, banIP, SQM, WireGuard, collectd and so on.
- A web UI (LuCI) and a plain Linux shell.

This project is not affiliated with or endorsed by Sophos. Sophos, XG and SFOS are trademarks of Sophos Ltd. Installing another operating system on the appliance will void any remaining support, so only do this with hardware that is out of support or that you own outright and no longer license.

## Contents

- [What you get](#what-you-get)
- [Hardware notes](#hardware-notes)
- [Installing OpenWrt](#installing-openwrt)
- [First login and SSH keys](#first-login-and-ssh-keys)
- [Configuring and running setup.sh](#configuring-and-running-setupsh)
- [After setup](#after-setup)
- [How it is put together](#how-it-is-put-together)
- [Upgrading OpenWrt](#upgrading-openwrt)
- [Disaster recovery](#disaster-recovery)
- [Troubleshooting](#troubleshooting)
- [Repository layout and licence](#repository-layout-and-licence)

## What you get

| Area | What the script sets up |
|------|------------------------|
| Management | LuCI over HTTPS and SSH bound to the LAN address only; SSH password login disabled once a key is installed |
| Firewall | firewall4 (nftables), WAN input and forward rejected, nothing exposed except the WireGuard port |
| DNS | AdGuard Home (filtering, query log, per-client stats) → Unbound (full recursion, DNSSEC validation, no third-party forwarder) → root servers. dnsmasq keeps DHCP and local names |
| Remote access | WireGuard server in its own firewall zone that rejects everything by default; peers only get what you allow |
| Threat blocking | banIP with the FireHOL level 1, Emerging Threats and DShield feeds, plus automatic banning of failed SSH/LuCI logins |
| QoS | SQM with cake on the WAN device, optional (off by default; useful on slow or asymmetric lines) |
| Storage | The unused part of the SSD becomes `/data` for logs, statistics, AdGuard data and backups, so the 1 GB root partition stays small and upgrades stay simple |
| Upgrades | `owut` and Attended Sysupgrade pinned to a 1 GB root partition so images build and the partition layout never changes |
| Monitoring | collectd/LuCI statistics, nlbwmon bandwidth accounting, weekly config backups |
| Optional | built-in 5 GHz WiFi, USB storage automount, Samba, DLNA, DDNS, Let's Encrypt, mwan3, OpenVPN, SNMP, Docker |

## Hardware notes

XG 135w rev. 3 as used here:

- CPU Intel Atom C3558 (4 cores), 6 GB RAM, 64 GB SATA SSD
- 8 × 1 GbE. OpenWrt names them `eth0`–`eth8`; the board profile uses `eth6` as WAN and bridges the rest as LAN. Check the labels on your unit against `ip link` before plugging in.
- 5 GHz Qualcomm Atheros radio (`ath10k`, QCA988x). Works as an access point. If you have a separate AP you can leave it disabled.
- 2 × USB, VGA and a serial console (115200 8N1). Only two USB ports matters for the install: a stick plus one of keyboard or mouse.
- BIOS: press **Delete** for setup, **F7** for the boot menu. Secure Boot must be off.

## Installing OpenWrt

### 1. Build an image with a 1 GB root partition

The stock x86 image has a ~100 MB root partition. That is too small for this package set, and it is the root cause of both the "not enough space" upgrade failures and the need to resize partitions by hand. Build a custom image instead:

1. Go to https://firmware-selector.openwrt.org/, search for **x86/64**, choose the latest 25.12 release.
2. Open **Customize installed packages and/or first boot script**.
3. Set **Root filesystem partition size (MB)** to `1024` (the maximum the build server allows).
4. Request the build and download **`...-x86-64-generic-ext4-combined-efi.img.gz`**.

Keep the number `1024`: every upgrade uses the same value so the on-disk partition table always matches the image.

### 2. Write it to a USB stick

```bash
gunzip openwrt-*-x86-64-generic-ext4-combined-efi.img.gz

# macOS (find the disk with `diskutil list`, unmount it first)
diskutil unmountDisk /dev/disk4
sudo dd if=openwrt-*-combined-efi.img of=/dev/rdisk4 bs=4m

# Linux
sudo dd if=openwrt-*-combined-efi.img of=/dev/sdX bs=4M status=progress
```

On Windows use Rufus or Raspberry Pi Imager (choose "Use custom").

### 3. Boot the stick and copy it to the SSD

1. Plug in the stick and a keyboard, power on, press **F7** and pick the **UEFI:** entry for the stick.
2. OpenWrt boots from USB in a minute or two. At the console, find the disks:
   ```sh
   cat /proc/partitions      # the ~60 GB device is the SSD (usually sdb when booted from USB)
   ```
3. Copy the running USB image onto the SSD:
   ```sh
   dd if=/dev/sda of=/dev/sdb bs=1M conv=fsync
   ```
   Double-check the device names first. `dd` prints nothing while it runs; with a 1 GB image it finishes in a minute.
4. `poweroff`, remove the stick, power on. OpenWrt boots from the SSD with LAN at 192.168.1.1.

If the SSD will not boot afterwards, the BIOS boot mode probably does not match the image: the `-efi` image needs UEFI mode; the non-`efi` image needs Legacy/CSM. Change the mode in the BIOS rather than re-imaging.

### If you used a stock image: growing the root filesystem

Skip this if you built a 1 GB image. With a stock image the root partition is ~100 MB and OpenWrt does not grow it automatically on this hardware. Boot a live Linux to resize it:

- **GParted Live** (https://gparted.org/download.php) written to a second USB stick. Boot it via **F7**, take the defaults, and at the graphical desktop swap the keyboard for a mouse (two USB ports). Right-click the second partition → **Resize/Move** → drag to fill the disk → apply. About a minute.
- Or any Linux live USB with a shell: `parted /dev/sda resizepart 2 100%`, then `e2fsck -f /dev/sda2 && resize2fs /dev/sda2`.

Be aware that a hand-resized partition will not match any image the build server produces, so the *next* sysupgrade rewrites the whole disk (see [Upgrading OpenWrt](#upgrading-openwrt)). Doing the 1 GB build first avoids this entirely.

## First login and SSH keys

Connect a computer to a LAN port (or the built-in WiFi once enabled). Then:

```bash
ssh root@192.168.1.1          # no password on a fresh install
passwd                        # set a strong root password

# On your computer, create a key if you do not have one, and copy it over
ssh-keygen -t ed25519
ssh-copy-id root@192.168.1.1  # or: cat ~/.ssh/id_ed25519.pub | ssh root@192.168.1.1 'cat >> /etc/dropbear/authorized_keys'
ssh root@192.168.1.1          # should log in without a password prompt
```

The setup script turns off SSH password login only when it finds a key in `/etc/dropbear/authorized_keys`, so do this first.

## Configuring and running setup.sh

1. Edit the **CONFIGURATION** block at the top of [setup.sh](setup.sh). Everything is a plain shell variable. The defaults produce the configuration described in this README; the main things to change are:

   | Variable | Notes |
   |----------|-------|
   | `TIMEZONE`, `HOSTNAME`, `DOMAIN_NAME` | Local domain for your devices, e.g. `home.lan` |
   | `LAN_IP`, `DHCP_START`, `DHCP_LIMIT` | LAN addressing |
   | `WAN_TYPE` and the `WAN_*` fields | `dhcp` for most cable/fibre, `pppoe` for DSL logins, `static`, or `none` |
   | `ENABLE_WIFI`, `WIFI_*` | Built-in radio. `sae-mixed` gives WPA2+WPA3 |
   | `AP_MAC`, `AP_IP` | Optional DHCP reservation for a separate access point |
   | `ADGUARD_PASSWORD_HASH` | Required for AdGuard Home. Generate on your computer: `htpasswd -nbB admin 'YourPassword' \| cut -d: -f2` |
   | `WG_PORT`, `WG_SUBNET`, `WG_ALLOW_INTERNET`, `WG_ALLOW_LAN` | WireGuard server. UDP 51820 is conventional; 443 gets through more hotel/office networks |
   | `SQM_DOWNLOAD_KBPS`, `SQM_UPLOAD_KBPS` | 85–90% of the speed you measure with SQM off, in kbit/s. See [Tuning SQM](#tuning-sqm) |
   | `ENABLE_DATA_PARTITION` | Create `/data` on the free space after the root partition |
   | `ROOTFS_SIZE_MB` | Leave at 1024 |

2. Copy it to the router and run it:
   ```bash
   scp -O setup.sh root@192.168.1.1:/root/     # -O because OpenWrt has no sftp server
   ssh root@192.168.1.1 sh /root/setup.sh
   ```
   It takes 5–15 minutes depending on your connection, prints what it is doing, and reboots at the end. It is idempotent: re-run it after changing a setting.

## After setup

### LuCI and AdGuard Home

- LuCI: `https://<LAN_IP>` (self-signed certificate; accept it). Reachable from the LAN only.
- AdGuard Home: `http://<LAN_IP>:3000`, user `admin`, the password whose hash you set. Query log, per-client statistics, blocklists and allowlists live here.

### Adding WireGuard peers

The script creates the server interface `wg0` and prints its public key. For each device:

```sh
# on the router
PEER_PRIV=$(wg genkey); PEER_PUB=$(echo "$PEER_PRIV" | wg pubkey); PSK=$(wg genpsk)
uci add network wireguard_wg0
uci set network.@wireguard_wg0[-1].description='my-phone'
uci set network.@wireguard_wg0[-1].public_key="$PEER_PUB"
uci set network.@wireguard_wg0[-1].preshared_key="$PSK"
uci add_list network.@wireguard_wg0[-1].allowed_ips='10.8.0.2/32'   # next free address
uci set network.@wireguard_wg0[-1].route_allowed_ips='1'
uci commit network && ifup wg0
echo "client private key: $PEER_PRIV   psk: $PSK   server pubkey: $(uci get network.wg0.private_key | wg pubkey)"
```

Client configuration (phone, laptop, travel router):

```ini
[Interface]
PrivateKey = <client private key>
Address = 10.8.0.2/32
DNS = 10.8.0.1

[Peer]
PublicKey = <server public key>
PresharedKey = <psk>
Endpoint = <your public IP or DDNS name>:51820
AllowedIPs = 0.0.0.0/0, ::/0      # or 10.8.0.0/24, 192.168.1.0/24 for split tunnel
PersistentKeepalive = 25
```

What a connected peer can do is decided entirely by firewall rules in the `vpn` zone. Out of the box: DNS and ping to the router, and internet access if `WG_ALLOW_INTERNET=yes`. To reach a specific LAN service, add a rule in LuCI (Network → Firewall → Traffic Rules): source zone `vpn`, source address the peer's tunnel IP, destination zone `lan`, destination address and port of the service, action accept. Prefer that over `WG_ALLOW_LAN=yes`.

Always set a pre-shared key: it adds a symmetric layer that stays secure even if Curve25519 is ever broken.

### The /data partition

```
/data/log/syslog        system log (logd rotates it to syslog.old at 8 MB)
/data/adguardhome       AdGuard working directory: query log, statistics, filter cache
/data/rrd               collectd round-robin databases (LuCI → Statistics)
/data/nlbwmon           bandwidth accounting database
/data/banip             banIP reports and set backups
/data/backups           weekly sysupgrade -b backups (copy them off the router too)
```

`/data` is a separate partition, so it is untouched by upgrades as long as the partition layout stays the same, and it never fills the root filesystem. If the script does not find at least 2 GB of unallocated space after the root partition (for example on a hand-resized disk) it skips this and uses `/root/backups` and `/srv/adguardhome` instead.

### Tuning SQM

SQM is off by default. Enable it (`ENABLE_QOS="yes"`) if your line is slow or asymmetric, or if latency during heavy transfers bothers you. Cake only removes bufferbloat when the router is the bottleneck, so the shaper has to sit a little below the line's real ceiling. Measure from the router itself, which avoids WiFi limits:

```sh
/etc/init.d/sqm stop; speedtest-go          # raw line speed and loaded latency
/etc/init.d/sqm start; speedtest-go         # with shaping
```

Set `download`/`upload` in Network → SQM QoS (or the script variables) to about 85–90% of the raw figures and compare the "Latency" numbers printed next to Download and Upload. On a gigabit fibre line on this hardware, cake at 850/950 Mbit costs about 10% of download throughput and cuts loaded latency from ~25 ms with 13 ms jitter to ~8 ms with 3 ms jitter, at a CPU load around 1. `networkQuality -s` on macOS gives the same picture from a client, including a responsiveness (RPM) score.

### Checks worth running

```sh
# nothing but WireGuard reachable from the WAN
nft list chain inet fw4 input_wan | grep accept
# management bound to the LAN
netstat -tlnp | grep -E ':(22|80|443) '
# DNS chain
dig @192.168.1.1 openwrt.org          # answered via Unbound
dig @192.168.1.1 doubleclick.net      # 0.0.0.0 = blocked by AdGuard
dig @192.168.1.1 -x 192.168.1.1       # PTR via dnsmasq
# banIP feeds and SQM
/etc/init.d/banip status | grep active_feeds
tc qdisc show dev $(uci get network.wan.device) | head -1
sysctl net.ipv4.tcp_congestion_control   # bbr
```

## How it is put together

**DNS.** Clients are handed the router as their resolver (IPv4 via DHCP, IPv6 via router advertisements using the router's ULA address).

| Component | Listens on | Job |
|-----------|-----------|-----|
| AdGuard Home | LAN IP, WireGuard IP, ULA and loopback, port 53; UI on port 3000 | Filtering, query log, statistics |
| Unbound | 127.0.0.1:5335 | Recursive resolution from the root servers with DNSSEC validation. No upstream forwarder, so no third party sees your full query stream |
| dnsmasq | port 54 | DHCP, DHCPv6/RA (via odhcpd) and authoritative answers for the local domain and reverse lookups |

AdGuard forwards everything to Unbound except the local domain and private reverse zones, which go to dnsmasq. If `ADGUARD_PASSWORD_HASH` is empty, dnsmasq stays on port 53 and forwards to Unbound, so you still get recursion and DNSSEC without filtering.

**Firewall zones.**

| Zone | Input | Forward | Notes |
|------|-------|---------|-------|
| lan | accept | accept | lan → wan forwarding allowed |
| wan | reject | reject | masquerade + MTU fix; only `Allow-WireGuard` (UDP) and the OpenWrt defaults for DHCP/ICMP/DHCPv6 are accepted |
| vpn | reject | reject | DNS and ping to the router; vpn → wan if enabled; anything else needs an explicit rule |

**Management.** uhttpd binds only to the LAN IPv4 address and the LAN ULA; dropbear binds to the `lan` interface. Both are therefore unreachable from the WAN and from WireGuard peers even if a firewall rule were ever wrong.

## Upgrading OpenWrt

### How sysupgrade works on x86

`sysupgrade` compares the partition table on the SSD with the one inside the new image:

- **Same layout** → only partition *contents* are rewritten, configuration is restored, `/data` is untouched. This is the normal case when every image is built with the same 1024 MB root size.
- **Different layout** (hand-resized root, or a different `rootfs_size`) → the whole image is written to the disk. Root shrinks or grows to the image size, any extra partition such as `/data` disappears from the partition table, and on x86 the configuration restore is known to fail occasionally. Have a backup off the router before doing this.

### Why LuCI said there was not enough space

The build server sizes the image from the requested root partition size (default ~100 MB), not from your disk. A full package set does not fit, so the build is refused. Pinning `rootfs_size` to 1024 fixes it; the LuCI Attended Sysupgrade app reads that value from UCI (`attendedsysupgrade.owut.rootfs_size`), which the setup script sets, and `owut` uses it directly.

### Standard procedure (owut)

```bash
# 0. On your computer: copy a backup off the router
ssh root@192.168.1.1 "sysupgrade -k -b -" > router-backup-$(date +%Y%m%d).tar.gz

# 1. On the router: see what would change (read-only)
owut check --verbose

# 2. Build and download, without installing
owut download -k

# 3. Dry run. "Partition layout has changed" means a full-disk write is coming (see above)
sysupgrade -T /tmp/firmware.bin

# 4. Install. Configuration is kept. Allow 2–3 minutes for the reboot.
sysupgrade /tmp/firmware.bin
```

If `owut check` reports *"N packages missing in target version, cannot upgrade"*, a package was dropped or renamed upstream. Exclude it and add the replacement: `owut download -k -r acme -a acme-acmesh`. Attended Sysupgrade in LuCI (System → Attended Sysupgrade) is the same thing with less diagnostic output.

After the upgrade: `df -h / /data`, `/etc/init.d/adguardhome status`, `wg show`, and re-run the checks above. `sysupgrade` writes `/etc/uci-defaults/10_disable_services` into every backup listing services that were disabled at backup time, so services you deliberately stopped stay stopped after a restore.

## Disaster recovery

This box is your internet connection, so plan for the upgrade going wrong before you start.

**Before you flash**

1. Copy the backup and the firmware image off the router (`scp -O root@192.168.1.1:/tmp/firmware.bin .`). The backup contains WireGuard and SSH host keys; keep it private.
2. Give the computer you are working from a second way online, such as a phone hotspot over USB, so you can keep reading documentation while the router reboots. Keep it on the LAN as well (WiFi through your access point, or a cable to a LAN port). If the hotspot is on WiFi and the LAN on Ethernet, the LAN subnet stays reachable because it is directly connected.
3. Have a USB keyboard and a screen (VGA) or a serial cable within reach.

**If the router comes back with default settings**

Symptoms: LuCI answers on `http://192.168.1.1` without a password, WiFi off, your custom rules gone. WAN via DHCP usually still works because the board profile knows which port is WAN.

```bash
# from your computer; the default install has no root password and accepts password SSH
scp -O router-backup-YYYYMMDD.tar.gz root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "sysupgrade -r /tmp/router-backup-YYYYMMDD.tar.gz && reboot"
```

Everything, including keys and the DNS chain, is back after the reboot. The `/data` partition is only lost if the partition layout changed; re-run `setup.sh` to recreate it.

**If it does not boot at all**

Plug in the keyboard and screen. GRUB and the kernel messages will tell you what happened. Worst case, boot the OpenWrt USB stick again and repeat the install, then restore the backup. Nothing about this process can brick the hardware: the BIOS is untouched.

## Troubleshooting

**`opkg: not found`** — OpenWrt 25.12 uses `apk`: `apk update`, `apk add <pkg>`, `apk del <pkg>`, `apk list -I` (installed), `apk list -u` (upgradable), `apk info -r <pkg>` (reverse dependencies).

**"Selected packages exceed device storage" / not enough space in Attended Sysupgrade** — see [Upgrading OpenWrt](#upgrading-openwrt); pin `rootfs_size` to 1024 and use `owut`.

**`owut check`: packages missing in target version** — a package was renamed upstream. `owut check --verbose` shows which; exclude it with `-r` and add the replacement with `-a`. Known ones: `acme` → `acme-acmesh` (25.12.5), `kmod-fs-ntfs` → `kmod-fs-ntfs3`.

**`AdGuardHome --check-config` never returns** — in 0.107.x it starts the full server instead of validating. Do not use it; the setup script tests port 53 directly and falls back to dnsmasq if AdGuard is not answering.

**AdGuard fails with `session_storage ... timeout`** — another AdGuard process is holding the database in the work directory. `killall AdGuardHome`, then `/etc/init.d/adguardhome start`.

**Clients get no DNS server from DHCP** — dnsmasq only advertises itself as DNS when it serves port 53. With AdGuard on 53 the script sets DHCP option 6 explicitly (`uci get dhcp.lan.dhcp_option` should show `6,<LAN_IP>`). Clients need to renew their lease after the change.

**banIP shows only some feeds active after first start** — the first download raced the DNS change. `/etc/init.d/banip reload`.

**WiFi will not come up** — `dmesg | grep ath10k` for firmware errors; `wifi status`; make sure `WIFI_COUNTRY` is set, as the radio refuses 5 GHz channels without a regulatory domain.

**Cannot reach LuCI** — it listens only on the LAN address: `netstat -tlnp | grep uhttpd`. From a WireGuard peer it is deliberately unreachable.

**Resetting** — there is no reset button and no overlay on an ext4 x86 install, so `firstboot` does nothing. Restore a backup, or reinstall from USB.

## Repository layout and licence

```
setup.sh                  the configuration script (edit the block at the top)
adguardhome.yaml.example  the AdGuard Home configuration the script generates, for reference
README.md                 this file
LICENSE                   MIT
```

Contributions and reports from other Sophos models are welcome. This is a personal project, provided as-is under the MIT licence, with no connection to Sophos.
