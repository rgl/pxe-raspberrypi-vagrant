#!/bin/bash
set -euxo pipefail

domain=$(hostname --fqdn)

if [ ! -f /vagrant/tmp/ssh/id_rsa ]; then
    mkdir -p /vagrant/tmp/ssh
    ssh-keygen -f /vagrant/tmp/ssh/id_rsa -t rsa -b 2048 -C "$USER@$domain" -N ''
fi
if [ ! -f ~/.ssh/id_rsa ]; then
    install -d -m 700 ~/.ssh
    cp /vagrant/tmp/ssh/* ~/.ssh
fi

# build the images.
for image in /vagrant/images/*; do 
    pushd $image
    ./build.sh
    popd
done

# install the images.
# NB you must use iscsi when you need to use overlayfs, e.g., when hosting
#    containers file-systems on behalf of docker/moby/containerd.
flavor='iscsi' # iscsi or nfs.
pushd /vagrant/images/raspios-lite
for i in `seq 4`; do
    ./install-boot-from-$flavor.sh rpi$i
done
./install-boot-from-$flavor.sh rpijoy
popd
