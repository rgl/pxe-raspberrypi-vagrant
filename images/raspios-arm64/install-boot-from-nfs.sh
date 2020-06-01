#!/bin/bash
set -euxo pipefail

name="$1"

# create the loop device backed by the raspios-arm64.img image file.
# NB you can known a loop backing file with, e.g., cat /sys/class/block/loop0/loop/backing_file.
device="$(losetup --partscan --read-only --show --find raspios-arm64.img)"

# mount.
mkdir -p /mnt/raspios-arm64-mnt-boot && mount "${device}p1" -o ro /mnt/raspios-arm64-mnt-boot
mkdir -p /mnt/raspios-arm64-mnt-root && mount "${device}p2" -o ro /mnt/raspios-arm64-mnt-root

# copy to the nfs shared directory.
install -d -m 750 -o root -g nogroup /srv/nfs/$name
rsync -a --delete /mnt/raspios-arm64-mnt-root/ /srv/nfs/$name/root/
rsync -a --delete /mnt/raspios-arm64-mnt-boot/ /srv/nfs/$name/root/boot/

#
# configure the image to boot from nfs.

# enter the root directory.
pushd /srv/nfs/$name/root/

# configure the bootloader to use the serial port for diagnostics.
# NB we also configure it to use the PL011 UART.
# NB rpi 4b has two serial ports:
#      1. PL011 UART (aka UART0/ttyAMA0)
#      2. mini UART (aka UART1/ttyS0)
#    the config.txt file configures which of them is assigned to the serial
#    console GPIO pins 14 (TX) and 15 (RX).
#    see https://www.raspberrypi.org/documentation/configuration/uart.md
#    see https://github.com/raspberrypi/firmware/blob/dd8cbec5a6d27090e5eb080e13d83c35fdd759f7/boot/overlays/README#L1691-L1702
cat >>config.txt <<'EOF'
enable_uart=1
uart_2ndstage=1
dtoverlay=miniuart-bt
EOF

# configure the kernel command line to mount the root fs from our nfs export.
# configure to open a virtual terminal console in the PL011 UART serial port.
# NB the default is:
#     dwc_otg.lpm_enable=0
#     console=serial0,115200
#     console=tty1
#     root=PARTUUID=3b18e43a-02
#     rootfstype=ext4
#     elevator=deadline
#     fsck.repair=yes
#     rootwait
#     quiet
#     init=/usr/lib/raspi-config/init_resize.sh
#     splash
#     plymouth.ignore-serial-consoles
(cat | tr '\n' ' ') >boot/cmdline.txt <<EOF
console=ttyAMA0,115200
console=tty1
root=/dev/nfs
nfsroot=10.10.10.2:$PWD,vers=4.1,proto=tcp,port=2049
rw
rootwait
elevator=deadline
ip=dhcp
EOF

# do not mount any partition.
# NB normally, this mounts them from the sd-card, but we want to be able to run without a sd-card.
sed -i /PARTUUID=/d etc/fstab

# configure the system to go get its hostname and domain from dhcp.
# NB dhcpcd will set the hostname from dhcp iif the current hostname is blank,
#    "localhost", "(null)" or the dhcpcd force_hostname configuration setting
#    is set to "YES" or "TRUE".
echo localhost >etc/hostname
sed -i -E '/127.0.1.1\s+raspberrypi/d' etc/hosts
# restart the avahi-daemon when we get a hostname from dhcp.
# NB for some reason avahi-daemon does not pick up the
#    transient hostname set by dhcp, so we have to
#    restart it manually.
# NB the default hooks are at /lib/dhcpcd/dhcpcd-hooks.
cat >lib/dhcpcd/dhcpcd-hooks/99-restart-avahi <<'EOF'
# NB execute dhcpcd --variables to see all the available variables.
# NB to troubleshoot the pi set RUN="yes" inside /etc/dhcp/debug
#    and uncomment the next line.
#. /etc/dhcp/debug; hostnamectl >>/tmp/dhclient-script.debug

# the following variables are available in a BOUND event:
#
#   reason='BOUND'
#   interface='eth0'
#   new_ip_address='10.10.10.100'
#   new_host_name='rpi1'
#   new_network_number='10.10.10.0'
#   new_subnet_mask='255.255.255.0'
#   new_broadcast_address='10.10.10.255'
#   new_routers='10.10.10.2'
#   new_domain_name='local'
#   new_domain_search='local'
#   new_domain_name_servers='8.8.8.8 8.8.4.4'
#
# and in a RENEW event:
#
#   reason='RENEW'
#   interface='eth0'
#   new_ip_address='10.10.10.100'
#   new_host_name='rpi1'
#   new_network_number='10.10.10.0'
#   new_subnet_mask='255.255.255.0'
#   new_broadcast_address='10.10.10.255'
#   new_routers='10.10.10.2'
#   new_domain_name='local'
#   new_domain_search='local'
#   new_domain_name_servers='8.8.8.8 8.8.4.4'
#   old_ip_address='10.10.10.100'
#   old_host_name='rpi1'
#   old_network_number='10.10.10.0'
#   old_subnet_mask='255.255.255.0'
#   old_broadcast_address='10.10.10.255'
#   old_routers='10.10.10.2'
#   old_domain_name='local'
#   old_domain_name_servers='8.8.8.8 8.8.4.4'

if [ "$reason" = 'BOUND' ] && [ "$interface" = 'eth0' ]; then
    systemctl restart avahi-daemon
fi
EOF

# leave the root directory.
popd

# give it a bit of time to settle down before umount and rmdir can work.
# TODO see how can we wait for umount.
sleep 10

# umount.
umount /mnt/raspios-arm64-mnt-boot
umount /mnt/raspios-arm64-mnt-root
rmdir /mnt/raspios-arm64-mnt-boot
rmdir /mnt/raspios-arm64-mnt-root
losetup --detach "$device"

# configure the nfs share.
install -d -m 700 /etc/exports.d
echo "/srv/nfs/$name 10.10.10.0/24(rw,async,no_root_squash,no_subtree_check,insecure)" >/etc/exports.d/$name.exports
exportfs -a

# list nfs shares.
showmount -e localhost
cat /var/lib/nfs/etab

# configure the tftp share.
rm -f /srv/tftp/$name
ln -s /srv/nfs/$name/root/boot /srv/tftp/$name

# test downloading a file from our tftp server.
atftp --get --local-file /tmp/tftp-start4.elf --remote-file $name/start4.elf 127.0.0.1
atftp --get --local-file /tmp/tftp-cmdline.txt --remote-file $name/cmdline.txt 127.0.0.1
