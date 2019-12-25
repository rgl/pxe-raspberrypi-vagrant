Vagrant.configure('2') do |config|
  config.vm.box = 'ubuntu-18.04-amd64'

  config.vm.provider :libvirt do |lv, config|
    lv.memory = 256
    lv.cpus = 2
    lv.cpu_mode = 'host-passthrough'
    # lv.nested = true
    lv.keymap = 'pt'
    config.vm.synced_folder '.', '/vagrant', type: 'nfs'
  end

  config.vm.define :gateway do |config|
    config.vm.hostname = 'gateway'
    config.vm.network :public_network, ip: '10.10.10.2', dev: 'br-rpi'
    config.vm.provision :shell, path: 'gateway.sh'
  end
end
