# install ansible into /opt/ansible
# see https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#installing-ansible-with-pip

apt-get install -y --no-install-recommends python3-pip python3-venv
python3 -m venv /opt/ansible
source /opt/ansible/bin/activate
# NB this pip install will display several "error: invalid command 'bdist_wheel'"
#    messages, those can be ignored.
python3 -m pip install ansible ansible-lint


#
# create an example ansible project for the rpi-cluster.

mkdir rpi-cluster
cd rpi-cluster
cat >inventory.yml <<'EOF'
all:
  children:
    cluster:
      hosts:
        10.10.10.10[1:4]:
      vars:
        ansible_user: pi
        ansible_python_interpreter: /usr/bin/python3
EOF
cat >playbook.yml <<'EOF'
- hosts: cluster
  name: Example
  gather_facts: no
  tasks:
    - name: Ping
      ping:
EOF
cat >ansible.cfg <<'EOF'
[defaults]
inventory = inventory.yml
host_key_checking = False # NB only do this in test scenarios.
EOF
#ansible-doc -l # list all the available modules
ansible-inventory --list --yaml
ansible-lint playbook.yml
ansible-playbook playbook.yml --syntax-check
ansible-playbook playbook.yml --list-hosts

# execute the example.
#ansible-playbook playbook.yml -f 10 #-vvv
#ansible -f 10 -m ping cluster
#ansible -f 10 -m command -a id cluster
#ansible -f 10 -b -m command -a id cluster
#ansible -f 10 -b -m command -a poweroff cluster
#ansible -f 10 -b -m command -a 'vcgencmd measure_temp' cluster
