#!/bin/bash
set -euxo pipefail

# configure apt for not asking interactive questions.
echo 'Defaults env_keep += "DEBIAN_FRONTEND"' >/etc/sudoers.d/env_keep_apt
chmod 440 /etc/sudoers.d/env_keep_apt
export DEBIAN_FRONTEND=noninteractive

# make sure grub can be installed in the current root disk.
# NB these anwsers were obtained (after installing grub-pc) with:
#
#   #sudo debconf-show grub-pc
#   sudo apt-get install debconf-utils
#   # this way you can see the comments:
#   sudo debconf-get-selections
#   # this way you can just see the values needed for debconf-set-selections:
#   sudo debconf-get-selections | grep -E '^grub-pc.+\s+' | sort
debconf-set-selections <<EOF
grub-pc	grub-pc/install_devices_disks_changed	multiselect	/dev/vda
grub-pc	grub-pc/install_devices	multiselect	/dev/vda
EOF

# upgrade the system.
apt-get update
apt-get dist-upgrade -y


#
# install tcpdump for being able to capture network traffic.

apt-get install -y tcpdump


#
# install vim.

apt-get install -y --no-install-recommends vim
cat >/etc/vim/vimrc.local <<'EOF'
syntax on
set background=dark
set esckeys
set ruler
set laststatus=2
set nobackup
EOF


#
# configure the shell.

cat >/etc/profile.d/login.sh <<'EOF'
[[ "$-" != *i* ]] && return
export EDITOR=vim
export PAGER=less
alias l='ls -lF --color'
alias ll='l -a'
alias h='history 25'
alias j='jobs -l'
EOF

cat >/etc/inputrc <<'EOF'
set input-meta on
set output-meta on
set show-all-if-ambiguous on
set completion-ignore-case on
"\e[A": history-search-backward
"\e[B": history-search-forward
"\eOD": backward-word
"\eOC": forward-word
EOF

cat >~/.bash_history <<'EOF'
ssh pi@rpi1.test
ansible -f 10 -b -m command -a 'vcgencmd measure_temp' cluster
source /opt/ansible/bin/activate && cd /home/vagrant/rpi-cluster
EOF

# configure the vagrant user home.
su vagrant -c bash <<'EOF-VAGRANT'
set -euxo pipefail

install -d -m 750 ~/.ssh
cat /vagrant/tmp/id_rsa.pub /vagrant/tmp/id_rsa.pub >>~/.ssh/authorized_keys

cat >~/.bash_history <<'EOF'
ssh pi@rpi1.test
sudo su -l
EOF
EOF-VAGRANT


#
# setup NAT.
# see https://help.ubuntu.com/community/IptablesHowTo

apt-get install -y iptables iptables-persistent

# enable IPv4 forwarding.
sysctl net.ipv4.ip_forward=1
sed -i -E 's,^\s*#?\s*(net.ipv4.ip_forward=).+,\11,g' /etc/sysctl.conf

# NAT through eth0.
# NB use something like -s 10.10.10/24 to limit to a specific network.
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# load iptables rules on boot.
iptables-save >/etc/iptables/rules.v4


#
# provision the DHCP server.
# see http://www.syslinux.org/wiki/index.php?title=PXELINUX

apt-get install -y --no-install-recommends isc-dhcp-server
cat >/etc/dhcp/dhcpd.conf <<'EOF'
# TODO only give addresses to rpi devices (mac vendors are dc:a6:32, b8:27:eb).

# NB IPv4 leases are stored at /var/lib/dhcp/dhcpd.leases
# NB IPv6 leases are stored at /var/lib/dhcp/dhcpd6.leases
# see dhcp-lease-list(8)
# see dhcpd.leases(5)

subnet 10.10.10.0 netmask 255.255.255.0 {
  range 10.10.10.100 10.10.10.254;
  authoritative;
  default-lease-time 300;
  max-lease-time 300;
  option subnet-mask 255.255.255.0;
  option routers 10.10.10.2;
  option domain-name-servers 10.10.10.2;
  option tftp-server-name "10.10.10.2";
}

# NB My Raspberry Pi 4 has the DC:A6:32 MAC vendor; other MAC vendors are
#    are allocated though, see https://www.wireshark.org/tools/oui-lookup.html.
# NB My Raspberry Pi 4 DHCP Discover packet is something like:
#     Frame 19406: 364 bytes on wire (2912 bits), 364 bytes captured (2912 bits) on interface 0
#     Ethernet II, Src: Raspberr_27:f5:46 (dc:a6:32:27:f5:46), Dst: Broadcast (ff:ff:ff:ff:ff:ff)
#         Destination: Broadcast (ff:ff:ff:ff:ff:ff)
#             Address: Broadcast (ff:ff:ff:ff:ff:ff)
#             .... ..1. .... .... .... .... = LG bit: Locally administered address (this is NOT the factory default)
#             .... ...1 .... .... .... .... = IG bit: Group address (multicast/broadcast)
#         Source: Raspberr_27:f5:46 (dc:a6:32:27:f5:46)
#             Address: Raspberr_27:f5:46 (dc:a6:32:27:f5:46)
#             .... ..0. .... .... .... .... = LG bit: Globally unique address (factory default)
#             .... ...0 .... .... .... .... = IG bit: Individual address (unicast)
#         Type: IPv4 (0x0800)
#     Internet Protocol Version 4, Src: 0.0.0.0, Dst: 255.255.255.255
#         0100 .... = Version: 4
#         .... 0101 = Header Length: 20 bytes (5)
#         Differentiated Services Field: 0x00 (DSCP: CS0, ECN: Not-ECT)
#         Total Length: 350
#         Identification: 0x507a (20602)
#         Flags: 0x0000
#         Time to live: 64
#         Protocol: UDP (17)
#         Header checksum: 0x2916 [validation disabled]
#         [Header checksum status: Unverified]
#         Source: 0.0.0.0
#         Destination: 255.255.255.255
#     User Datagram Protocol, Src Port: 68, Dst Port: 67
#     Bootstrap Protocol (Discover)
#         Message type: Boot Request (1)
#         Hardware type: Ethernet (0x01)
#         Hardware address length: 6
#         Hops: 0
#         Transaction ID: 0xcf8ce22a
#         Seconds elapsed: 0
#         Bootp flags: 0x0000 (Unicast)
#             0... .... .... .... = Broadcast flag: Unicast
#             .000 0000 0000 0000 = Reserved flags: 0x0000
#         Client IP address: 0.0.0.0
#         Your (client) IP address: 0.0.0.0
#         Next server IP address: 0.0.0.0
#         Relay agent IP address: 0.0.0.0
#         Client MAC address: Raspberr_27:f5:46 (dc:a6:32:27:f5:46)
#         Client hardware address padding: 00000000000000000000
#         Server host name not given
#         Boot file name not given
#         Magic cookie: DHCP
#         Option: (53) DHCP Message Type (Discover)
#             Length: 1
#             DHCP: Discover (1)
#         Option: (55) Parameter Request List
#             Length: 14
#             Parameter Request List Item: (1) Subnet Mask
#             Parameter Request List Item: (3) Router
#             Parameter Request List Item: (43) Vendor-Specific Information
#             Parameter Request List Item: (60) Vendor class identifier
#             Parameter Request List Item: (66) TFTP Server Name
#             Parameter Request List Item: (67) Bootfile name
#             Parameter Request List Item: (128) DOCSIS full security server IP [TODO]
#             Parameter Request List Item: (129) PXE - undefined (vendor specific)
#             Parameter Request List Item: (130) PXE - undefined (vendor specific)
#             Parameter Request List Item: (131) PXE - undefined (vendor specific)
#             Parameter Request List Item: (132) PXE - undefined (vendor specific)
#             Parameter Request List Item: (133) PXE - undefined (vendor specific)
#             Parameter Request List Item: (134) PXE - undefined (vendor specific)
#             Parameter Request List Item: (135) PXE - undefined (vendor specific)
#         Option: (93) Client System Architecture
#             Length: 2
#             Client System Architecture: IA x86 PC (0)
#         Option: (94) Client Network Device Interface
#             Length: 3
#             Major Version: 2
#             Minor Version: 1
#         Option: (97) UUID/GUID-based Client Identifier
#             Length: 17
#             Client Identifier (UUID): f2c24e9c-4e9c-f2c2-9c4e-c2f29c4ec2f2
#         Option: (60) Vendor class identifier
#             Length: 32
#             Vendor class identifier: PXEClient:Arch:00000:UNDI:002001
#         Option: (255) End
#             Option End: 255

# my raspberry pi 4 b #1.
host rpi1 {
  hardware ethernet dc:a6:32:27:e0:37;
  fixed-address 10.10.10.101;

  # NB rpi 4 ignores this (although it requests it).
  #    see https://github.com/raspberrypi/rpi-eeprom/issues/69
  #filename "rpi1/start4.elf";

  # configure the hostname.
  # NB for this to work the image hostname must be set
  #    to "localhost" at /etc/hostname AND for avahi-daemon
  #    to pick the new name it must be restarted from
  #    /etc/dhclient-enter-hooks.d/99-restart-avahi.
  # NB the default raspios hostname is "raspberrypi".
  option host-name "rpi1";
  option domain-name "test";
}

# my raspberry pi 4 b #2.
host rpi2 {
  hardware ethernet dc:a6:32:27:f7:cb;
  fixed-address 10.10.10.102;
  option host-name "rpi2";
  option domain-name "test";
}

# my raspberry pi 4 b #3.
host rpi3 {
  hardware ethernet dc:a6:32:27:f7:fb;
  fixed-address 10.10.10.103;
  option host-name "rpi3";
  option domain-name "test";
}

# my raspberry pi 4 b #4.
host rpi4 {
  hardware ethernet dc:a6:32:27:f7:89;
  fixed-address 10.10.10.104;
  option host-name "rpi4";
  option domain-name "test";
}

# my raspberry pi 4 b in the joy-it case.
host rpijoy {
  hardware ethernet dc:a6:32:27:f5:46;
  fixed-address 10.10.10.123;
  option host-name "rpijoy";
  option domain-name "test";
}

# run dhcp-event when a lease changes state.
# see dhcpd.conf(5) and dhcp-eval(5)
on commit {
  set client_ip = binary-to-ascii(10, 8, ".", leased-address);
  set client_hw = binary-to-ascii(16, 8, ":", substring(hardware, 1, 6));
  execute("/usr/local/sbin/dhcp-event", "commit", client_ip, client_hw, host-decl-name);
}
on release {
  set client_ip = binary-to-ascii(10, 8, ".", leased-address);
  set client_hw = binary-to-ascii(16, 8, ":", substring(hardware, 1, 6));
  execute("/usr/local/sbin/dhcp-event", "release", client_ip, client_hw, host-decl-name);
}
on expiry {
  set client_ip = binary-to-ascii(10, 8, ".", leased-address);
  set client_hw = binary-to-ascii(16, 8, ":", substring(hardware, 1, 6));
  execute("/usr/local/sbin/dhcp-event", "expiry", client_ip, client_hw, host-decl-name);
}
EOF
# NB recent versions of the isc-dhcp-server package are fubar because they define
#    INTERFACESv4/v6 BUT the daemon does not seem to use them... so we comment
#    those lines and append a INTERFACES= variable.
sed -i -E 's,^(INTERFACES(v[46])?=.*),#\1,' /etc/default/isc-dhcp-server
echo 'INTERFACES="eth1"' >>/etc/default/isc-dhcp-server
# tune apparmor to allow the execution of our dhcp-event script.
# see http://manpages.ubuntu.com/manpages/bionic/en/man5/apparmor.d.5.html
# see http://manpages.ubuntu.com/manpages/bionic/en/man7/apparmor.7.html
# NB if something fails due to arparmor see the journalctl output; it will contain something like (look at the requested_mask to known what needs to be allowed):
#         Dec 12 22:31:31 gateway dhcpd[664]: execute_statement argv[0] = /usr/local/sbin/dhcp-event
#         Dec 12 22:31:31 gateway audit[719]: AVC apparmor="DENIED" operation="exec" profile="/usr/sbin/dhcpd" name="/usr/local/sbin/dhcp-event" pid=719 comm="dhcpd" requested_mask="x" denied_mask="x" fsuid=108 ouid=0
#         Dec 14 18:16:24 gateway audit[3176]: AVC apparmor="DENIED" operation="open" profile="/usr/sbin/dhcpd" name="/dev/tty" pid=3176 comm="dhcp-event" requested_mask="wr" denied_mask="wr" fsuid=108 ouid=0
#         Dec 14 18:16:24 gateway audit[3176]: AVC apparmor="DENIED" operation="open" profile="/usr/sbin/dhcpd" name="/usr/local/sbin/dhcp-event" pid=3176 comm="dhcp-event" requested_mask="r" denied_mask="r" fsuid=108 ouid=0
#         Dec 14 18:22:03 gateway audit[3256]: AVC apparmor="DENIED" operation="exec" profile="/usr/sbin/dhcpd" name="/usr/bin/logger" pid=3256 comm="dhcp-event" requested_mask="x" denied_mask="x" fsuid=108 ouid=0
#         Dec 14 18:22:03 gateway audit[3256]: AVC apparmor="DENIED" operation="open" profile="/usr/sbin/dhcpd" name="/usr/bin/logger" pid=3256 comm="dhcp-event" requested_mask="r" denied_mask="r" fsuid=108 ouid=0
#         Dec 14 18:22:03 gateway audit[3257]: AVC apparmor="DENIED" operation="exec" profile="/usr/sbin/dhcpd" name="/usr/bin/env" pid=3257 comm="dhcp-event" requested_mask="x" denied_mask="x" fsuid=108 ouid=0
#         Dec 14 18:22:03 gateway audit[3257]: AVC apparmor="DENIED" operation="open" profile="/usr/sbin/dhcpd" name="/usr/bin/env" pid=3257 comm="dhcp-event" requested_mask="r" denied_mask="r" fsuid=108 ouid=0
cat >/etc/apparmor.d/local/usr.sbin.dhcpd <<'EOF'
/usr/local/sbin/dhcp-event rix,
/dev/tty rw,
/usr/bin/logger rix,
/usr/bin/env rix,
EOF
systemctl reload apparmor
aa-status
cat >/usr/local/sbin/dhcp-event <<'EOF'
#!/bin/bash
# this is called when a lease changes state.
# NB you can see these log entries with journalctl -t dhcp-event
logger -t dhcp-event "argv: $*"
for e in $(env); do
  logger -t dhcp-event "env: $e"
done
EOF
chmod +x /usr/local/sbin/dhcp-event
systemctl restart isc-dhcp-server

# get the MAC vendor list (used by dhcp-lease-list(8)).
# NB the upstream is at http://standards-oui.ieee.org/oui/oui.txt
#    BUT linuxnet.ca version is better taken care of.
wget -qO- https://linuxnet.ca/ieee/oui.txt.bz2 | bzcat >/usr/local/etc/oui.txt


#
# provision the TFTP server.
# see https://help.ubuntu.com/community/Installation/QuickNetboot
# see https://help.ubuntu.com/community/PXEInstallServer
# see https://wiki.archlinux.org/index.php/PXE

apt-get install -y --no-install-recommends atftp atftpd
# NB if you need to troubleshoot edit the configuration by adding --verbose=7 --trace
sed -i -E 's,(USE_INETD=).+,\1false,' /etc/default/atftpd
systemctl restart atftpd


#
# provision the stgt iSCSI target (aka iSCSI server).
# see tgtd(8)
# see http://stgt.sourceforge.net/
# see https://tools.ietf.org/html/rfc7143
# TODO use http://linux-iscsi.org/ instead?
# TODO increase the nic MTU to be more iSCSI friendly.
# TODO use a dedicated VLAN for storage traffic. make it have higher priority then the others at the switch?

apt-get install -y --no-install-recommends tgt
systemctl status tgt


#
# provision the NFS server.
# see exports(5).

apt-get install -y nfs-kernel-server

# dump the supported nfs versions.
cat /proc/fs/nfsd/versions | tr ' ' "\n" | grep '^+' | tr '+' 'v'

# test access to the NFS server using NFSv3 (UDP and TCP) and NFSv4 (TCP).
showmount -e localhost
rpcinfo -u localhost nfs 3
rpcinfo -t localhost nfs 3
rpcinfo -t localhost nfs 4
