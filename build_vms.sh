#!/bin/bash
###################################
# edit vars
###################################
set -e
num=7 #3 or larger please!
prefix=student
password=Pa22word
zone=sfo2
size=s-2vcpu-4gb
key=30:98:4f:c5:47:c2:88:28:fe:3c:23:cd:52:49:51:01

######  NO MOAR EDITS #######
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
NORMAL=$(tput sgr0)
BLUE=$(tput setaf 4)

#better error checking
command -v curl >/dev/null 2>&1 || { echo "$RED" " ** Curl was not found. Please install before preceeding. ** " "$NORMAL" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "$RED" " ** Jq was not found. Please install before preceeding. ** " "$NORMAL" >&2; exit 1; }
command -v pdsh >/dev/null 2>&1 || { echo "$RED" " ** Pdsh was not found. Please install before preceeding. ** " "$NORMAL" >&2; exit 1; }

build_list=""
for i in $(seq 1 $num); do
 build_list="$prefix-$i-a $build_list"
 build_list="$prefix-$i-b $build_list"
 build_list="$prefix-$i-c $build_list"
done
echo -n " building $num vms : "
doctl compute droplet create $build_list --region $zone --image centos-7-x64 --size $size --ssh-keys $key --wait > /dev/null 2>&1
doctl compute droplet list|grep -v ID|grep $prefix|awk '{print $3" "$2}'> hosts.txt
echo "$GREEN" "[ok]" "$NORMAL"

sleep 60

echo -n " checking for ssh "
for ext in $(awk '{print $1}' hosts.txt); do
  until [ $(ssh -o ConnectTimeout=1 root@$ext 'exit' 2>&1 | grep 'timed out' | wc -l) = 0 ]; do echo -n "." ; sleep 5; done
done
echo "$GREEN" "[ok]" "$NORMAL"

host_list=$(awk '{printf $1","}' hosts.txt|sed 's/,$//')

echo -n " updating dns "
for i in $(seq 1 $num); do
 doctl compute domain records create dockr.life --record-type A --record-name $prefix-$i-a --record-ttl 150 --record-data $(cat hosts.txt|grep $prefix-$i-a|awk '{print $1}') > /dev/null 2>&1
 doctl compute domain records create dockr.life --record-type A --record-name $prefix-$i-b --record-ttl 150 --record-data $(cat hosts.txt|grep $prefix-$i-b|awk '{print $1}') > /dev/null 2>&1
 doctl compute domain records create dockr.life --record-type A --record-name $prefix-$i-c --record-ttl 150 --record-data $(cat hosts.txt|grep $prefix-$i-c|awk '{print $1}') > /dev/null 2>&1
done
echo "$GREEN" "[ok]" "$NORMAL"

echo -n " updating sshd "
pdsh -l root -w $host_list 'systemctl enable docker;  echo Pa22word | passwd root --stdin; sed -i "s/PasswordAuthentication no/PasswordAuthentication yes/g" /etc/ssh/sshd_config ;  systemctl restart sshd' > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"

sleep 1

echo -n " updating kernel settings "
pdsh -l root -w $host_list 'cat << EOF >> /etc/sysctl.conf

# SWAP settings
vm.swappiness=0
vm.overcommit_memory=1

# Have a larger connection range available
net.ipv4.ip_local_port_range=1024 65000

# Increase max connection
net.core.somaxconn = 10000

# Reuse closed sockets faster
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15

# The maximum number of "backlogged sockets".  Default is 128.
net.core.somaxconn=4096
net.core.netdev_max_backlog=4096

# 16MB per socket - which sounds like a lot,
# but will virtually never consume that much.
net.core.rmem_max=16777216
net.core.wmem_max=16777216

# Various network tunables
net.ipv4.tcp_max_syn_backlog=20480
net.ipv4.tcp_max_tw_buckets=400000
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_wmem=4096 65536 16777216

# ARP cache settings for a highly loaded docker swarm
net.ipv4.neigh.default.gc_thresh1=8096
net.ipv4.neigh.default.gc_thresh2=12288
net.ipv4.neigh.default.gc_thresh3=16384

# ip_forward and tcp keepalive for iptables
net.ipv4.tcp_keepalive_time=600
net.ipv4.ip_forward=1

# needed for host mountpoints with RHEL 7.4
fs.may_detach_mounts=1

# monitor file system events
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=1048576
EOF
sysctl -p'  > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"

echo -n " updating the os and installing docker ee "
pdsh -l root -w $host_list 'yum update -y; yum install -y vim yum-utils; yum downgrade -y container-selinux-2.74-1.el7; echo "https://storebits.docker.com/ee/m/sub-cd49e6a5-5e6f-4912-8f29-19397129084e/centos" > /etc/yum/vars/dockerurl; echo "7" > /etc/yum/vars/dockerosversion; yum-config-manager --add-repo $(cat /etc/yum/vars/dockerurl)/docker-ee.repo; yum makecache fast; yum-config-manager --enable '"$centos_engine_repo"'; yum -y install docker-ee; systemctl start docker; systemctl enable docker'  > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"

echo -n " adding daemon configs "
pdsh -l root -w $host_list 'echo -e "{\n \"selinux-enabled\": true, \n \"log-driver\": \"json-file\", \n \"log-opts\": {\"max-size\": \"10m\", \"max-file\": \"3\"} \n }" > /etc/docker/daemon.json; systemctl restart docker'
echo "$GREEN" "[ok]" "$NORMAL"

echo ""
echo "===== Cluster ====="
doctl compute droplet list --no-header |grep $prefix

echo ""
echo " to kill : $GREEN for i in \$(doctl compute droplet list --no-header|grep $prefix|awk '{print \$1}'); do doctl compute droplet delete --force \$i; done ; for i in \$(doctl compute domain records list dockr.life --no-header|grep $prefix|awk '{print \$1}'); do doctl compute domain records delete dockr.life \$i --force; done; rm -rf hosts.txt $NORMAL"
