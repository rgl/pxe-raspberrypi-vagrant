Vagrant.configure('2') do |config|
  config.vm.box = 'ubuntu-18.04-amd64'

  config.vm.provider :libvirt do |lv, config|
    lv.memory = 2*1024
    lv.cpus = 4
    lv.cpu_mode = 'host-passthrough'
    # lv.nested = true
    lv.keymap = 'pt'
    config.vm.synced_folder '.', '/vagrant', type: 'nfs'
  end

  config.vm.provider :virtualbox do |vb|
    vb.linked_clone = true
    vb.memory = 2*1024
    vb.cpus = 4
    vb.customize ['modifyvm', :id, '--cableconnected1', 'on']
  end

  config.vm.define :gateway do |config|
    config.vm.hostname = 'gateway'
    config.vm.network :public_network, ip: '10.10.10.2', dev: 'br-rpi'
    config.vm.provision :shell, path: 'gateway.sh'
    config.vm.provision :shell, path: 'provision-dns-server.sh'
    config.vm.provision :shell, path: 'provision-ansible.sh'
    config.vm.provision :shell, path: 'provision-packer.sh'
    config.vm.provision :shell, path: 'provision-images.sh'
  end
end
