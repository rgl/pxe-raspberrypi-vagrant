#!/bin/bash
set -euxo pipefail

gateway_fqdn="${1:-gateway.test}"; shift || true
gateway_ip_address="${1:-10.10.10.2}"; shift || true
test_domain="${1:-test}"; shift || true
default_dns_resolver="$(systemd-resolve --status | awk '/DNS Servers: /{print $3}')" # recurse queries through the default vagrant environment DNS server.


#
# provision the DNS authoritative server.
# NB this will be controlled by the kubernetes external dns controller.

# these anwsers were obtained (after installing pdns-backend-sqlite3) with:
#
#   #sudo debconf-show pdns-backend-sqlite3
#   sudo apt-get install debconf-utils
#   # this way you can see the comments:
#   sudo debconf-get-selections
#   # this way you can just see the values needed for debconf-set-selections:
#   sudo debconf-get-selections | grep -E '^pdns-.+\s+' | sort
debconf-set-selections<<EOF
pdns-backend-sqlite3 pdns-backend-sqlite3/dbconfig-install boolean true
EOF

apt-get install -y --no-install-recommends dnsutils pdns-backend-sqlite3

# stop pdns before changing the configuration.
systemctl stop pdns

function pdns-set-config {
    local key="$1"; shift
    local value="${1:-}"; shift || true
    sed -i -E "s,^(\s*#\s*)?($key\s*)=.*,\2=$value," /etc/powerdns/pdns.conf
}

# save the original config.
cp /etc/powerdns/pdns.conf{,.orig}
# listen at the localhost.
pdns-set-config local-address 127.0.0.2
# do not listen on ipv6.
pdns-set-config local-ipv6
# configure the api server.
pdns-set-config api yes
pdns-set-config api-key vagrant
pdns-set-config webserver-address "$gateway_ip_address"
pdns-set-config webserver-port 8081
pdns-set-config webserver-allow-from "$gateway_ip_address/24"
# increase the logging level.
# you can see the logs with journalctl --follow -u pdns
#pdns-set-config loglevel 10
#pdns-set-config log-dns-queries yes
# diff the changes.
diff -u /etc/powerdns/pdns.conf{.orig,} || true

# load the test zone into the database.
# NB we use 1m for testing purposes, in real world, this should probably be 10m+.
zone="
\$TTL 1m
\$ORIGIN $test_domain. ; base domain-name
@               IN      SOA     a.ns    hostmaster (
    2019090800 ; serial number (this number should be increased each time this zone file is changed)
    1m         ; refresh (the polling interval that slave DNS server will query the master for zone changes)
               ; NB the slave will use this value insted of \$TTL when deciding if the zone it outdated
    1m         ; update retry (the slave will retry a zone transfer after a transfer failure)
    3w         ; expire (the slave will ignore this zone if the transfer keeps failing for this long)
    1m         ; minimum (the slave stores negative results for this long)
)
                IN      NS      a.ns
$gateway_fqdn.  IN      A       $gateway_ip_address
rpi1            IN      A       10.10.10.101
rpi2            IN      A       10.10.10.102
rpi3            IN      A       10.10.10.103
rpi4            IN      A       10.10.10.104
rpijoy          IN      A       10.10.10.123
"
zone2sql --zone=<(echo "$zone") --gsqlite | sqlite3 /var/lib/powerdns/pdns.sqlite3

# load the reverse test zone into the database.
# NB we use 1m for testing purposes, in real world, this should probably be 10m+.
reverse_test_domain="$(python3 -c 'import sys; r = sys.argv[1].split(".")[:-1]; r.reverse(); print("%s.in-addr.arpa" % ".".join(r))' $gateway_ip_address)"
reverse_gateway_fqdn="$(python3 -c 'import sys; r = sys.argv[1].split("."); r.reverse(); print("%s.in-addr.arpa" % ".".join(r))' $gateway_ip_address)"
reverse_zone="
\$TTL 1m
\$ORIGIN $reverse_test_domain. ; base domain-name
@               IN      SOA     a.ns    hostmaster (
    2019090800 ; serial number (this number should be increased each time this zone file is changed)
    1m         ; refresh (the polling interval that slave DNS server will query the master for zone changes)
               ; NB the slave will use this value insted of \$TTL when deciding if the zone it outdated
    1m         ; update retry (the slave will retry a zone transfer after a transfer failure)
    3w         ; expire (the slave will ignore this zone if the transfer keeps failing for this long)
    1m         ; minimum (the slave stores negative results for this long)
)
                        IN  NS  a.ns
$reverse_gateway_fqdn.  IN  PTR $gateway_fqdn.
101                     IN  PTR rpi1.$test_domain.
102                     IN  PTR rpi2.$test_domain.
103                     IN  PTR rpi3.$test_domain.
104                     IN  PTR rpi4.$test_domain.
123                     IN  PTR rpijoy.$test_domain.
"
zone2sql --zone=<(echo "$reverse_zone") --gsqlite | sqlite3 /var/lib/powerdns/pdns.sqlite3

# start it up.
systemctl start pdns

# use the API.
# see https://doc.powerdns.com/authoritative/http-api
apt-get install -y --no-install-recommends jq
wget -qO- --header 'X-API-Key: vagrant' http://$gateway_ip_address:8081/api/v1/servers | jq .
wget -qO- --header 'X-API-Key: vagrant' http://$gateway_ip_address:8081/api/v1/servers/localhost/zones | jq .
wget -qO- --header 'X-API-Key: vagrant' http://$gateway_ip_address:8081/api/v1/servers/localhost/zones/$test_domain | jq .
wget -qO- --header 'X-API-Key: vagrant' http://$gateway_ip_address:8081/api/v1/servers/localhost/zones/$reverse_test_domain | jq .


#
# provision the DNS server/resolver/recursor.
# this will resolve all entries from /etc/hosts by default (like our $test_domain).
# and will redirect all *.$rancher_domain to the local pdns server.
# NB docker/rancher/coredns/kubernetes inherits resolv.conf from the host.
# NB we cannot use systemd-resolved because it cannot be configured in a non-loopback interface.
# see http://www.thekelleys.org.uk/dnsmasq/docs/setup.html
# see http://www.thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html

apt-get install -y --no-install-recommends dnsutils dnsmasq
systemctl stop systemd-resolved
systemctl disable systemd-resolved
systemctl mask systemd-resolved
cat >/etc/dnsmasq.d/local.conf <<EOF
no-resolv
bind-interfaces
interface=eth1
listen-address=$gateway_ip_address
# all *.$test_domain (and $reverse_test_domain) which arent in /etc/hosts are forwarded to our pdns server.
server=/$test_domain/127.0.0.2
server=/$reverse_test_domain/127.0.0.2
server=$default_dns_resolver
EOF
rm /etc/resolv.conf
cat >/etc/resolv.conf <<EOF
nameserver 127.0.0.1
search $test_domain
EOF
systemctl restart dnsmasq

# test the DNS.
dig $gateway_fqdn @$gateway_ip_address
dig -x $gateway_ip_address @$gateway_ip_address
dig $gateway_fqdn
dig -x $gateway_ip_address
