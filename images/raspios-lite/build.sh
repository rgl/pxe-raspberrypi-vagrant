#!/bin/bash
set -euxo pipefail

# download the image ourselfs to the host.
# NB these raspberrypi.org images were built with https://github.com/RPi-Distro/pi-gen.
# see https://downloads.raspberrypi.org/raspios_lite_armhf/release_notes.txt
# see https://downloads.raspberrypi.org/raspios_lite_armhf/images/
raspios_url='http://downloads.raspberrypi.org/raspios_lite_armhf/images/raspios_lite_armhf-2020-05-28/2020-05-27-raspios-buster-lite-armhf.zip'
raspios_sha256='f5786604be4b41e292c5b3c711e2efa64b25a5b51869ea8313d58da0b46afc64'
raspios_path='/vagrant/tmp/raspios-lite.zip'
if [ ! -f "$raspios_path" ]; then
    mkdir -p "$(dirname $raspios_path)"
    wget -qO "$raspios_path.tmp" "$raspios_url"
    echo "$raspios_sha256 $raspios_path.tmp" | sha256sum --check --status
    mv "$raspios_path.tmp" "$raspios_path"
fi

# build the image if its not there.
if [ ! -f raspios-lite.img ]; then
    # setup the authorized ssh keys.
    cat \
        /root/.ssh/id_rsa.pub \
        /vagrant/tmp/id_rsa.pub \
        >/tmp/authorized_keys

    # NB the grep is for ignoring the harmless error lines:
    #       ERROR: ld.so: object '/usr/lib/arm-linux-gnueabihf/libarmmem-${PLATFORM}.so' from /etc/ld.so.preload cannot be preloaded (cannot open shared object file): ignored.
    # NB PACKER_CACHE_DIR=/tmp is needed because packer misbehaves (always downloads an already
    #    downloaded file) when placed in a NFS share like our /vagrant.
    CHECKPOINT_DISABLE=1 PACKER_CACHE_DIR=/tmp PACKER_LOG=1 PACKER_LOG_PATH=raspios-lite.log \
        packer build raspios-lite.json \
            | grep -v '/etc/ld.so.preload cannot be preloaded'

    # zero free the rootfs.
    # NB this is need until https://github.com/solo-io/packer-builder-arm-image/issues/45 is added.
    apt-get install -y zerofree
    device="$(losetup --partscan --show --find output-arm-image/image)"
    zerofree "${device}p2"
    losetup --detach "$device"

    # TODO use "output_filename": "raspios-lite.img" inside raspios-lite.json when its available.
    mv output-arm-image/image raspios-lite.img
    rmdir output-arm-image

    # also create a zip of it so we can easily burn it with etcher.
    apt-get install -y zip
    zip - raspios-lite.img >raspios-lite.img.zip
fi
