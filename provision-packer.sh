#!/bin/bash
# abort this script on errors.
set -euxo pipefail

# prevent apt-get et al from opening stdin.
# NB even with this, you'll still get some warnings that you can ignore:
#     dpkg-preconfigure: unable to re-open stdin: No such file or directory
export DEBIAN_FRONTEND=noninteractive

# install Packer.
apt-get install -y unzip
# NB packer-builder-arm-image is only compatible with packer 1.4.x.
packer_version=1.4.5
wget -q -O/tmp/packer_${packer_version}_linux_amd64.zip https://releases.hashicorp.com/packer/${packer_version}/packer_${packer_version}_linux_amd64.zip
unzip /tmp/packer_${packer_version}_linux_amd64.zip -d /usr/local/bin

# install the packer-builder-arm-image plugin.
# see https://github.com/solo-io/packer-builder-arm-image
apt-get install -y kpartx qemu-user-static
wget -q -O/tmp/packer-builder-arm-image https://github.com/solo-io/packer-builder-arm-image/releases/download/v0.1.3/packer-builder-arm-image
install /tmp/packer-builder-arm-image -m 755 -C /usr/local/bin
rm /tmp/packer-builder-arm-image
