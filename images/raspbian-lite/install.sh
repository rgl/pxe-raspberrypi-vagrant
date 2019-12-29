#!/bin/bash
set -eux

name="$1"

# create the loop device backed by the raspbian-lite.img image file.
# NB you can known a loop backing file with, e.g., cat /sys/class/block/loop0/loop/backing_file.
device="$(losetup --partscan --read-only --show --find raspbian-lite.img)"

# mount.
mkdir -p raspbian-lite-mnt-boot && mount "${device}p1" -o ro raspbian-lite-mnt-boot
mkdir -p raspbian-lite-mnt-root && mount "${device}p2" -o ro raspbian-lite-mnt-root

# copy to the nfs shared directory.
install -d -m 750 -o root -g nogroup /srv/nfs/$name
rsync -a --delete raspbian-lite-mnt-root/ /srv/nfs/$name/root/
rsync -a --delete raspbian-lite-mnt-boot/ /srv/nfs/$name/root/boot/

#
# configure the image to boot from nfs.

# enter the root directory.
pushd /srv/nfs/$name/root/

# configure rpi kernel command line to mount the root fs from our nfs export.
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
console=serial0,115200
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

# enable sshd.
touch boot/ssh

# leave the root directory.
popd

# give it a bit of time to settle down before umount and rmdir can work.
# TODO see how can we wait for umount.
sleep 10

# umount.
umount raspbian-lite-mnt-boot
umount raspbian-lite-mnt-root
rmdir raspbian-lite-mnt-boot
rmdir raspbian-lite-mnt-root
losetup --detach "$device"

# configure the nfs share.
exportfs -v -o rw,async,no_root_squash,no_subtree_check,insecure 10.10.10.0/24:/srv/nfs/$name

# list nfs shares.
showmount -e localhost
cat /var/lib/nfs/etab

# configure the tftp share.
ln -fs /srv/nfs/$name/root/boot /srv/tftp/$name

# test downloading a file from our tftp server.
atftp --get --local-file /tmp/tftp-start4.elf --remote-file $name/start4.elf 127.0.0.1
atftp --get --local-file /tmp/tftp-cmdline.txt --remote-file $name/cmdline.txt 127.0.0.1
