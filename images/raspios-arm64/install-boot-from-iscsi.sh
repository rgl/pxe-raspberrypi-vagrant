#!/bin/bash
set -euxo pipefail

name="$1"

# create the loop device backed by the raspios-arm64.img image file.
# NB you can known a loop backing file with, e.g., cat /sys/class/block/loop0/loop/backing_file.
device="$(losetup --partscan --read-only --show --find raspios-arm64.img)"

# mount the boot partition.
mkdir -p /mnt/raspios-arm64-mnt-boot && mount "${device}p1" -o ro /mnt/raspios-arm64-mnt-boot

# copy the boot fs to the nfs shared directory.
install -d -m 750 -o root -g nogroup /srv/nfs/$name/root
rsync -a --delete /mnt/raspios-arm64-mnt-boot/ /srv/nfs/$name/root/boot/

# give it a bit of time to settle down before umount and rmdir can work.
# TODO see how can we wait for umount.
sleep 10

# umount boot.
umount /mnt/raspios-arm64-mnt-boot
rmdir /mnt/raspios-arm64-mnt-boot

# copy the root fs to the iscsi target directory as an image file.
install -d -m 750 -o root -g root /srv/iscsi
cp --sparse=always "${device}p2" /srv/iscsi/$name.img

# detach the image loop device.
losetup --detach "$device"

# increase the image size.
truncate --size=+2G /srv/iscsi/$name.img
dumpe2fs -h /srv/iscsi/$name.img
# after a truncate we cannot immediately execute resize2fs because it refuses
# to run with "Please run 'e2fsck -f /srv/iscsi/rpi1.img' first.".
e2fsck -p -f /srv/iscsi/$name.img
resize2fs /srv/iscsi/$name.img


#
# configure the image to boot from iscsi.

# enter the boot directory.
pushd /srv/nfs/$name/root/boot

# configure the bootloader to load initrd.
# see https://www.raspberrypi.org/documentation/configuration/config-txt/README.md
# see https://www.raspberrypi.org/documentation/configuration/config-txt/boot.md
echo "initramfs $(ls initrd.img-*-v8+) followkernel" >>config.txt

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

# configure the kernel command line to mount the root fs from our iscsi export.
# configure to open a virtual terminal console in the PL011 UART serial port.
# see "Root on iSCSI" at /usr/share/doc/open-iscsi/README.Debian.gz
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
(cat | tr '\n' ' ') >cmdline.txt <<EOF
console=ttyAMA0,115200
console=tty1
root=UUID=$(blkid --probe --match-tag UUID --output value /srv/iscsi/$name.img)
iscsi_initiator=iqn.2020-01.test:$name
iscsi_target_name=iqn.2020-01.test.gateway:$name.root
iscsi_target_ip=10.10.10.2
iscsi_target_port=3260
rw
rootwait
elevator=deadline
ip=dhcp
EOF

# leave the boot directory.
popd


#
# configure the rootfs.

# create the loop device backed by the $name.img image file.
# NB you can known a loop backing file with, e.g., cat /sys/class/block/loop0/loop/backing_file.
device="$(losetup --show --find /srv/iscsi/$name.img)"
mkdir -p /mnt/raspios-arm64-mnt-root && mount "$device" /mnt/raspios-arm64-mnt-root
pushd /mnt/raspios-arm64-mnt-root

# do not mount any partition.
# NB normally, this mounts them from the sd-card, but we want to be able to run without a sd-card.
sed -i /PARTUUID=/d etc/fstab

# mount /boot from nfs.
# see nfs(5).
# NB to manually mount the share use, e.g.:
#       mount -t nfs -o defaults,hard,vers=4.1,proto=tcp,port=2049,noatime,nolock 10.10.10.2:/srv/nfs/rpijoy/root/boot /mnt
echo "10.10.10.2:/srv/nfs/$name/root/boot /boot nfs defaults,hard,vers=4.1,proto=tcp,port=2049,noatime,nolock 0 0" >etc/fstab

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

# umount boot.
umount /mnt/raspios-arm64-mnt-root
rmdir /mnt/raspios-arm64-mnt-root

# detach the image loop device.
losetup --detach "$device"

# configure the nfs share.
install -d -m 700 /etc/exports.d
echo "/srv/nfs/$name 10.10.10.0/24(rw,async,no_root_squash,no_subtree_check,insecure)" >/etc/exports.d/$name.exports
exportfs -a

# list nfs shares.
showmount -e localhost
cat /var/lib/nfs/etab

# configure the tftp boot share.
rm -f /srv/tftp/$name
ln -s /srv/nfs/$name/root/boot /srv/tftp/$name

# configure the iscsi root target.
# NB to manually mount the iscsi target use, e.g.:
#       apt-get install -y open-iscsi
#       echo 'InitiatorName=iqn.2020-01.test:rpijoy' >/etc/iscsi/initiatorname.iscsi
#       systemctl restart iscsid
#       iscsiadm --mode discovery --type sendtargets --portal 10.10.10.2:3260 # list the available targets.
#       iscsiadm --mode node --targetname iqn.2020-01.test.gateway:rpijoy.root --login # start using the target.
#       find /etc/iscsi -type f # list the configuration files.
#       ls -lh /dev/disk/by-path/*-iscsi-iqn.* # list all iscsi block devices (e.g. /dev/disk/by-path/ip-10.10.10.2:3260-iscsi-iqn.2020-01.test.gateway:rpijoy.root-lun-1 -> ../../sda)
#       lsblk /dev/sda # lsblk -O /dev/sda
#       blkid /dev/sda
#       mount -o noatime /dev/sda /mnt
#       ls -laF /mnt
#       umount /mnt
#       iscsiadm --mode node --targetname iqn.2020-01.test.gateway:rpijoy.root --logout # stop using the target.
# see tgtadm(8)
# see tgtd(8)
# see tgtimg(8)
# see targets.conf(5)
# see https://wiki.archlinux.org/index.php/Open-iSCSI
# see https://github.com/open-iscsi/open-iscsi
# see http://stgt.sourceforge.net/
# see https://tools.ietf.org/html/rfc7143
cat >/etc/tgt/conf.d/$name.conf <<EOF
# the iscsi target name (iqn) has the format:
#   iqn.<domain registration year>-<domain registration month>.<reverse domain>:<a name>
<target iqn.2020-01.test.gateway:$name.root>
    <backing-store /srv/iscsi/$name.img>
        params thin_provisioning=1
    </backing-store>
    initiator-name iqn.2020-01.test:$name
    #incominguser $name $name # TODO enable authentication to prevent configuration mistakes?
</target>
EOF
systemctl reload tgt

# list iscsi targets.
tgtadm --mode target --op show

# test downloading a file from our tftp server.
atftp --get --local-file /tmp/tftp-start4.elf --remote-file $name/start4.elf 127.0.0.1
atftp --get --local-file /tmp/tftp-cmdline.txt --remote-file $name/cmdline.txt 127.0.0.1
