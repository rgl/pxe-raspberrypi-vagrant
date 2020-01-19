#!/bin/bash
set -eux

domain=$(hostname --fqdn)

if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -f ~/.ssh/id_rsa -t rsa -b 2048 -C "$USER@$domain" -N ''
fi

# build the images.
for image in /vagrant/images/*; do 
    cd $image && ./build.sh
done

# install the images at the nfs /srv/nfs/rpiN/root
# shared directory and configure the nfs server.
pushd /vagrant/images/raspbian-lite
for i in `seq 4`; do
    ./install.sh rpi$i
done
./install.sh rpijoy
popd
