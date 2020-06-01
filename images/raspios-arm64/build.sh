#!/bin/bash
set -euxo pipefail

# download the image ourselfs to the host.
# see https://www.raspberrypi.org/blog/8gb-raspberry-pi-4-on-sale-now-at-75/
# see https://www.raspberrypi.org/forums/viewtopic.php?f=117&t=275370
raspios_url='https://downloads.raspberrypi.org/raspios_arm64/images/raspios_arm64-2020-05-28/2020-05-27-raspios-buster-arm64.zip'
raspios_sha256='d06d8eecfa3980e18f9061777ca2dac50d98037373e1bd04e8726d79467dc7c7'
raspios_path='/vagrant/tmp/raspios-arm64.zip'
if [ ! -f "$raspios_path" ]; then
    mkdir -p "$(dirname $raspios_path)"
    wget -qO "$raspios_path.tmp" "$raspios_url"
    echo "$raspios_sha256 $raspios_path.tmp" | sha256sum --check --status
    mv "$raspios_path.tmp" "$raspios_path"
fi

# build the image if its not there.
if [ ! -f raspios-arm64.img ]; then
    # setup the authorized ssh keys.
    cat \
        /root/.ssh/id_rsa.pub \
        /vagrant/tmp/id_rsa.pub \
        >/tmp/authorized_keys

    # NB the grep is for ignoring the harmless error lines:
    #       ERROR: ld.so: object '/usr/lib/arm-linux-gnueabihf/libarmmem-${PLATFORM}.so' from /etc/ld.so.preload cannot be preloaded (cannot open shared object file): ignored.
    # NB PACKER_CACHE_DIR=/tmp is needed because packer misbehaves (always downloads an already
    #    downloaded file) when placed in a NFS share like our /vagrant.
    CHECKPOINT_DISABLE=1 PACKER_CACHE_DIR=/tmp PACKER_LOG=1 PACKER_LOG_PATH=raspios-arm64.log \
        packer build raspios-arm64.json \
            | grep -v '/etc/ld.so.preload cannot be preloaded'

    # zero free the rootfs.
    # NB this is need until https://github.com/solo-io/packer-builder-arm-image/issues/45 is added.
    apt-get install -y zerofree
    device="$(losetup --partscan --show --find output-arm-image/image)"
    zerofree "${device}p2"
    losetup --detach "$device"

    # TODO use "output_filename": "raspios-arm64.img" inside raspios-arm64.json when its available.
    mv output-arm-image/image raspios-arm64.img
    rmdir output-arm-image

    # also create a zip of it so we can easily burn it with etcher.
    apt-get install -y zip
    zip - raspios-arm64.img >raspios-arm64.img.zip
fi
