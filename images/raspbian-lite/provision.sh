#!/bin/bash
set -eux

export DEBIAN_FRONTEND=noninteractive

# disable automatic flash updates.
systemctl mask rpi-eeprom-update

# upgrade the system.
apt-get update
apt-get dist-upgrade -y

# enable sshd.
systemctl enable ssh

# configure the system to go get its hostname and domain from dhcp.
# NB dhcpcd will set the hostname from dhcp iif the current hostname is blank,
#    "localhost", "(null)" or the dhcpcd force_hostname configuration setting
#    is set to "YES" or "TRUE".
echo localhost >/etc/hostname
sed -i -E '/127.0.1.1\s+raspberrypi/d' /etc/hosts

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

# configure the keyboard layout.
# NB this file was indirectly generated by raspi-config.
cat >/etc/default/keyboard <<'EOF'
# KEYBOARD CONFIGURATION FILE
# Consult the keyboard(5) manual page.
XKBMODEL="pc105"
XKBLAYOUT="pt"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

# add support for mounting iscsi targets.
apt-get install -y --no-install-recommends open-iscsi
sed -i -E 's,#(INITRD)=.+,\1=Yes,g' /etc/default/raspberrypi-kernel
# install the initrd binaries needed for mounting an iscsi target.
# NB this is needed because dpkg-reconfigure raspberrypi-kernel does not
#    work under packer-builder-arm-image.
# NB the initrd must match the kernel version provided by the raspberrypi-kernel package.
initrd_version='v0.0.0.20200208'
wget -qO/tmp/raspberrypi-kernel-iscsi-initrd.tgz https://github.com/rgl/raspberrypi-kernel-iscsi-initrd/releases/download/$initrd_version/raspberrypi-kernel-iscsi-initrd.tgz
tar xf /tmp/raspberrypi-kernel-iscsi-initrd.tgz -C /boot

# install dig et al.
apt-get install -y --no-install-recommends dnsutils

# install useful tools.
apt-get install -y --no-install-recommends lsof

# tidy the fs permissions.
install -d -m 700 -o pi -g pi /home/pi/.ssh
install -m 600 -o pi -g pi /tmp/authorized_keys /home/pi/.ssh

# configure the pi user home.
su pi -c bash <<'EOF-PI'
set -eux

cat >~/.bash_history <<'EOF'
vcgencmd measure_temp
vcgencmd measure_volts
vcgencmd bootloader_config
sudo su -l
EOF
EOF-PI

# cleanup.
apt-get autoremove -y --purge
apt-get clean -y
rm -rf /tmp/*
