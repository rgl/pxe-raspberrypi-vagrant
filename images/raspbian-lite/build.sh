#!/bin/bash
set -euxo pipefail

# download the image ourselfs to the host.
# NB these raspberrypi.org images were built with https://github.com/RPi-Distro/pi-gen.
# see https://github.com/solo-io/packer-builder-arm-image/issues/44
# see https://downloads.raspberrypi.org/raspbian/release_notes.txt
# see https://downloads.raspberrypi.org/raspbian_lite/images/
raspbian_url='https://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2020-02-14/2020-02-13-raspbian-buster-lite.zip'
raspbian_sha256='12ae6e17bf95b6ba83beca61e7394e7411b45eba7e6a520f434b0748ea7370e8'
raspbian_path='/vagrant/tmp/raspbian-lite.zip'
if [ ! -f "$raspbian_path" ]; then
    mkdir -p "$(dirname $raspbian_path)"
    wget -qO "$raspbian_path.tmp" "$raspbian_url"
    echo "$raspbian_sha256 $raspbian_path.tmp" | sha256sum --check --status
    mv "$raspbian_path.tmp" "$raspbian_path"
fi

# build the image if its not there.
if [ ! -f raspbian-lite.img ]; then
    # setup the authorized ssh keys.
    cat \
        /root/.ssh/id_rsa.pub \
        /vagrant/tmp/id_rsa.pub \
        >/tmp/authorized_keys

    # NB the grep is for ignoring the harmless error lines:
    #       ERROR: ld.so: object '/usr/lib/arm-linux-gnueabihf/libarmmem-${PLATFORM}.so' from /etc/ld.so.preload cannot be preloaded (cannot open shared object file): ignored.
    # NB PACKER_CACHE_DIR=/tmp is needed because packer misbehaves (always downloads an already
    #    downloaded file) when placed in a NFS share like our /vagrant.
    CHECKPOINT_DISABLE=1 PACKER_CACHE_DIR=/tmp PACKER_LOG=1 PACKER_LOG_PATH=raspbian-lite.log \
        packer build raspbian-lite.json \
            | grep -v '/etc/ld.so.preload cannot be preloaded'

    # zero free the rootfs.
    # NB this is need until https://github.com/solo-io/packer-builder-arm-image/issues/45 is added.
    apt-get install -y zerofree
    device="$(losetup --partscan --show --find output-arm-image/image)"
    zerofree "${device}p2"
    losetup --detach "$device"

    # TODO use "output_filename": "raspbian-lite.img" inside raspbian-lite.json when its available.
    mv output-arm-image/image raspbian-lite.img
    rmdir output-arm-image

    # also create a zip of it so we can easily burn it with etcher.
    apt-get install -y zip
    zip - raspbian-lite.img >raspbian-lite.img.zip
fi
