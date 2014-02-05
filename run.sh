#!/bin/bash 

unset LANG
unset LANGUAGE
export LC_ALL=C

TESTNAME=${1:-ryudev}
DEVSTACK=${DEVSTACK:-$TESTNAME}

VERBOSE=${VERBOSE:-False}
DEBUG=${DEBUG:-False}

SDATE=$(date -R)
TOP=$(readlink -f $(dirname "$0"))
cd $TOP
export HOME=$TOP
TMP=$TOP/tmp
LOG=$TOP/logs
LOGDATE=$(date +%Y%m%d%H%M%S)
SUMMARY=$LOG/summary.$TESTNAME.$LOGDATE
LOGFILE=$LOG/log.$TESTNAME.$LOGDATE
STACKLOG=$LOG/devstack.$TESTNAME
SUDO="sudo -S"
APTGETUPDATE="sudo apt-get update"
APTGETINSTALL="sudo DEBIAN_FRONTEND=noninteractive apt-get install -y"
APTGETREMOVE="sudo apt-get remove -y"

case $TESTNAME in
master-*)
  QUANTUM="neutron"
  RYUDEV_BASE="files/ryudev.qcow2"
  ;;
ml2-*)
  QUANTUM="neutron"
  RYUDEV_BASE="files/ryudev_saucy.qcow2"
  OSLOWORKAROUND=True
  ;;
*)
  QUANTUM="quantum"
  RYUDEV_BASE="files/ryudev.qcow2"
  ;;
esac

METAPROXY="$QUANTUM-ns-metadata-proxy"

RYUDEV1_IMG="ryu1.${TESTNAME}.qcow2"
RYUDEV1_PID="$TMP/kvm_ryudev1.pid"
RYUDEV1_PORT="4444"
RYUDEV1_MAC1="f0:00:00:00:00:01"
RYUDEV1_IP="192.168.1.10"
RYUDEV1_HOSTNAME="ryudev1"
RYUDEV1_MAC2="f0:00:00:00:00:11"
RYUDEV1_VNC="unix:$TMP/kvm_ryudev1_vnc.sock"

RYUDEV2_IMG="ryu2.${TESTNAME}.qcow2"
RYUDEV2_PID="$TMP/kvm_ryudev2.pid"
RYUDEV2_PORT="4445"
RYUDEV2_MAC1="f0:00:00:00:00:02"
RYUDEV2_IP="192.168.1.11"
RYUDEV2_HOSTNAME="ryudev2"
RYUDEV2_MAC2="f0:00:00:00:00:12"
RYUDEV2_VNC="unix:$TMP/kvm_ryudev2_vnc.sock"

RYUDEV3_IMG="ryu3.${TESTNAME}.qcow2"
RYUDEV3_PID="$TMP/kvm_ryudev3.pid"
RYUDEV3_PORT="4446"
RYUDEV3_MAC1="f0:00:00:00:00:03"
RYUDEV3_IP="192.168.1.12"
RYUDEV3_HOSTNAME="ryudev3"
RYUDEV3_MAC2="f0:00:00:00:00:13"
RYUDEV3_VNC="unix:$TMP/kvm_ryudev3_vnc.sock"

EXTIF=${EXTIF:-eth0}

BR_NAME1="br-ryudev"
BR_NAME2="br-ryudev-local"
DNSMASQ_PID="$TMP/dnsmasq.pid"
SSH_KEY="files/id_rsa"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=$TOP/.ssh/known_host"
SSHCMD="$SSH -i $SSH_KEY -t -l ubuntu"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=$TOP/.ssh/known_host"
SCPCMD="$SCP -i $SSH_KEY"

PUBLIC_NET="public"
PRIVATE_NET="private"

NOVA_LIST_IP_COL=12

function echo_summary() {
    echo "$@" >&6
}

function title() {
    prefix=${1:-"**"}
    echo_summary "$prefix $TITLE"
}

function result() {
    msg=$1
    rc=$2
    prefix=${3:-"***"}
    
    if [ $rc -eq 0 ]; then
        test -n "$msg" && echo_summary "$prefix $TITLE: $msg: success"
        test -n "$msg" || echo_summary "$prefix $TITLE: success"
    else
        test -n "$msg" && echo_summary "$prefix $TITLE: $msg: failed"
        test -n "$msg" || echo_summary "$prefix $TITLE: failed"
        die_error
    fi
}

function pause() {
    msg=$1
    
    test $DEBUG != "True" && return
    if [ -z "$msg" ]; then
        echo_summary "Enter key to continue"
    else
        echo_summary "Enter key to $msg"
    fi
    read
}

dying=0
function die() {
    rc=$1
    test $dying -ne 0 && return
    dying=1
    
    terminate_all_instances
    sleep 10
    stop_devstack $RYUDEV3_IP ryudev3
    umount_instance_dir $RYUDEV3_IP ryudev3
    sleep 10
    stop_devstack $RYUDEV2_IP ryudev2
    umount_instance_dir $RYUDEV2_IP ryudev2
    sleep 10
    stop_devstack $RYUDEV1_IP ryudev1
    sleep 10
    terminate_vm $RYUDEV3_PID $RYUDEV3_PORT
    terminate_vm $RYUDEV2_PID $RYUDEV2_PORT
    terminate_vm $RYUDEV1_PID $RYUDEV1_PORT
    test -e "$DNSMASQ_PID" && $SUDO kill `cat $DNSMASQ_PID`
    $SUDO iptables -t nat -D POSTROUTING -o ${EXTIF} -s 192.168.1.0/24 -j MASQUERADE
    $SUDO ip link set down $BR_NAME1
    $SUDO brctl delbr $BR_NAME1
    $SUDO ip link set down $BR_NAME2
    $SUDO brctl delbr $BR_NAME2
    echo_summary "Start:  $SDATE"
    echo_summary "Finish: $(date -R)"
    exit $rc
}
function die_intr() {
    echo_summary "Aborting by user interrupt"
    trap "" SIGINT
    die 1
}
function die_error() {
    pause "terminate"
    die 1
}

function run_vm() {
    image=$1
    pidfile=$2
    port=$3
    mac1=$4
    ipaddr=$5
    mac2=$6
    vnc=$7
    
    TITLE="start virtual machine: $image"
    title "++"
    if [ ! -e $image ]; then
        cp $RYUDEV_BASE $image
    fi
    $SUDO kvm \
      -M pc-1.0 -enable-kvm \
      -m 2048 -smp 1,sockets=1,cores=1,threads=1 \
      -drive file=$image,if=virtio,format=qcow2 \
      -netdev tap,script=./ifup,downscript=./ifdown,id=hostnet0 \
      -device virtio-net-pci,netdev=hostnet0,mac=$mac1 \
      -netdev tap,script=./ifup2,downscript=./ifdown2,id=hostnet1 \
      -device virtio-net-pci,netdev=hostnet1,mac=$mac2 \
      -display vnc=$vnc -monitor telnet::$port,server,nowait \
      -pidfile $pidfile -daemonize
    result "" $? "++"
    
    TITLE="wait for virtual machine to come up: $image"
    title "++"
    fail=1
    for (( i=0; i<36; i++ )); do
        $SSHCMD $ipaddr true
        if [ $? -eq 0 ]; then
            fail=0
            break
        fi
        sleep 5
    done
    result "" $fail "++"
}

function terminate_vm() {
    pidfile=$1
    port=$2
    
    if [ ! -f $pidfile ]; then
        return
    fi
    pid=$($SUDO cat $pidfile)
    $SUDO kill -0 $pid
    if [ $? -ne 0 ]; then
        return
    fi
    echo_summary "++ terminate virtual machine: $pidfile: $pid"
    echo "system_powerdown" | nc localhost $port
    fail=1
    for (( i=0; i<120; i++ )); do
        $SUDO kill -0 $pid
        if [ $? -ne 0 ]; then
            fail=0
            break
        fi
        sleep 1
    done
    if [ $fail -ne 0 ]; then
        $SUDO kill $pid
    fi
}

function install_pkgs() {
    ipaddr=$1
    vmname=$2

    TITLE="install packages: $vmname"
    title "++"
    cat <<EOF | $SSHCMD $ipaddr
set -x

$APTGETUPDATE > /dev/null
$APTGETINSTALL python-dev

which pip
if [ \$? -ne 0 ]; then
  $APTGETINSTALL python-pip
fi
if dpkg -l python-pip >/dev/null 2>&1; then
  sudo pip install -U pip
  $APTGETREMOVE python-pip
fi

if [ -n "$OSLOWORKAROUND" ]; then
  if [ -d "/usr/local/lib/python2.7/dist-packages/oslo.config-1.2*" ]; then
    sudo rm -rf /usr/local/lib/python2.7/dist-packages/oslo.config-1.2*
  fi
  if [ -d "/usr/local/lib/python2.7/dist-packages/oslo" ]; then
    sudo rm -rf /usr/local/lib/python2.7/dist-packages/oslo
  fi
  python -c 'import oslo.config' || sudo pip install -U --force-reinstall oslo.config
  python -c 'import oslo.rootwrap.cmd' || sudo pip install -U --force-reinstall oslo.rootwrap
  #python -c 'import oslo.messaging' || sudo pip install -U --force-reinstall oslo.messaging
else
  ver=\$(pip show oslo.config|awk '\$1=="Version:"{print \$2}')
  ver=\${ver%%\.[0-9][^0-9.]*}
  if [ -n "\$ver" -a "\$ver" \\< "1.2" ]; then
    sudo pip uninstall oslo.config
    ver=""
  fi
  if [ -z "\$ver" ]; then
    sudo pip install -U oslo.config
  fi
fi
EOF
    result "" $? "++"
}

function export_instance_dir() {
    ipaddr=$1
    vmname=$2

    TITLE="nfs export instance dir: $vmname"
    title "++"
    cat <<EOF | $SSHCMD $ipaddr
set -x

nfs=\$(dpkg -l nfs-kernel-server|grep nfs-kernel-server|awk '{print \$1}')
libvirt=\$(dpkg -l libvirt-bin|grep libvirt-bin|awk '{print \$1}')
if [ "\$nfs" != "ii" -o "\$libvirt" != "ii" ]; then
  if [ "\$nfs" != "ii" ]; then
    $APTGETINSTALL nfs-kernel-server > /dev/null || exit 1
  fi
  if [ "\$libvirt" != "ii" ]; then
    $APTGETINSTALL libvirt-bin > /dev/null || exit 1
  fi
fi
sudo exportfs|grep /var/lib/instances && exit 0
sudo mkdir -p /var/lib/instances
sudo chgrp libvirtd /var/lib/instances || exit 1
sudo chmod g+w /var/lib/instances || exit 1
grep '/var/lib/instances' /etc/exports > /dev/null 2>&1
if [ \$? -ne 0 ]; then
  sudo sh -c 'echo "/var/lib/instances 192.168.1.0/255.255.255.0(rw,sync,no_root_squash)" >> /etc/exports' || exit 1
  sudo exportfs -a || exit 1
sudo /etc/init.d/nfs-kernel-server restart
fi
EOF
    result "" $? "++"
}

function mount_instance_dir() {
    ipaddr=$1
    vmname=$2
    nfsip=$3

    TITLE="mount instance dir: $vmname"
    title "++"
    cat <<EOF | $SSHCMD $ipaddr
set -x

nfs=\$(dpkg -l nfs-common|grep nfs-common|awk '{print \$1}')
libvirt=\$(dpkg -l libvirt-bin|grep libvirt-bin|awk '{print \$1}')
if [ "\$nfs" != "ii" -o "\$libvirt" != "ii" ]; then
  if [ "\$nfs" != "ii" ]; then
    $APTGETINSTALL nfs-common > /dev/null || exit 1
  fi
  if [ "\$libvirt" != "ii" ]; then
    $APTGETINSTALL libvirt-bin > /dev/null || exit 1
  fi
fi
mount|grep /var/lib/instances && exit 0
sudo mkdir -p /var/lib/instances
sudo chgrp libvirtd /var/lib/instances || exit 1
sudo chmod g+w /var/lib/instances || exit 1
grep '/var/lib/instances' /etc/fstab > /dev/null 2>&1
if [ \$? -ne 0 ]; then
  sudo sh -c 'echo "$nfsip:/var/lib/instances /var/lib/instances nfs defaults,soft 0 0" >> /etc/fstab' || exit 1
  sudo mount /var/lib/instances || exit 1
fi
EOF
    result "" $? "++"
}

function umount_instance_dir() {
    ipaddr=$1
    vmname=$2

    TITLE="umount instance dir: $vmname"
    title "++"
    $SSHCMD $ipaddr sudo umount -f /var/lib/instances
}

function setup_libvirtd() {
    ipaddr=$1
    vmname=$2

    TITLE="setup libvirtd.conf for live-migration: $vmname"
    title "++"
    cat <<EOF | $SSHCMD $ipaddr
set -x
sudo sed -i 's/#*listen_tls = .*/listen_tls = 0/; s/#*listen_tcp = .*/listen_tcp = 1/; s/#*auth_tcp = .*/auth_tcp = "none"/' /etc/libvirt/libvirtd.conf
sudo sed -i 's/^libvirtd_opts=.*/libvirtd_opts="-d -l"/' /etc/default/libvirt-bin
sudo sed -i 's/^env libvirtd_opts=.*/env libvirtd_opts="-d -l"/' /etc/init/libvirt-bin.conf
sudo service libvirt-bin restart
EOF
}

function setup_phy-br() {
    ipaddr=$1
    vmname=$2

    TITLE="setup physical bridge: $vmname"
    title "++"
    cat <<EOF | $SSHCMD $ipaddr
set -x
sudo ovs-vsctl --no-wait -- --may-exist add-br br-eth1
sudo ovs-vsctl --no-wait -- --may-exist add-port br-eth1 eth1
EOF
}

function start_devstack() {
    ipaddr=$1
    vmname=$2
    
    TITLE="install devstack: $vmname/$ipaddr"
    title "++"
    if [ ! -e $TOP/devstack ]; then
        tar zxf devstack.tar.gz
    fi
    $SSHCMD $ipaddr rm -rf devstack
    $SCPCMD -r devstack/$DEVSTACK/devstack ubuntu@$ipaddr:
    result "" $? "++"
    
    $SSHCMD $ipaddr rm -rf /opt/stack/glance/bin
    $SSHCMD $ipaddr sudo ip link set up eth1
    
    TITLE="start devstack: $vmname/$ipaddr"
    title "++"
    $SSHCMD $ipaddr rm -rf logs
    $SSHCMD $ipaddr VERBOSE=True devstack/stack.sh &
    pid=$!
    fail=1
    for (( i=0; i<120; i++ )); do
        kill -0 $pid 2>/dev/null
        if [ $? -ne 0 ]; then
            fail=0
            break
        fi
        sleep 60
    done
    msg=""
    if [ $fail -ne 0 ]; then
        kill $pid
        msg="timeout"
    fi
    wait $pid
    result "$msg" $? "++"
}

function stop_devstack() {
    ipaddr=$1
    vmname=$2
    
    echo_summary "++ stop devstack: $vmname/$ipaddr"
    $SSHCMD $ipaddr devstack/unstack.sh
    mkdir -p $STACKLOG/$vmname
    $SCPCMD -r ubuntu@$ipaddr:logs/* $STACKLOG/$vmname

    TITLE="cleanup bridge and netns: $vmname/$ipaddr"
    title "++"
    cat <<EOF | $SSHCMD $ipaddr
set -x
test -e /etc/logrotate.d/mysql-server && sudo logrotate /etc/logrotate.d/mysql-server
sudo killall dnsmasq
sudo killall $METAPROXY
ip link|awk '\$2 ~ /tap|qvo|qbr/{sub(/:/,"",\$2);print \$2}'|xargs --verbose -r -l1 sudo ip link set down
ip link|awk '\$2 ~ /tap|qvo|qbr/{sub(/:/,"",\$2);print \$2}'|xargs --verbose -r -l1 sudo ip link delete
sudo ovs-vsctl del-br br-int
sudo ovs-vsctl del-br br-ex
ip netns|while read ns; do sudo ip netns delete \$ns; done
sudo ovs-vsctl show|sed 's/^  *//'|egrep '^(Bridge|Port)'|tr -d '"'|while read ln; do key=\$(echo \$ln|awk '{print \$1}'); val=\$(echo \$ln|awk '{print \$2}'); if [ "\$key" = "Bridge" ]; then br=\$val; elif [ "\$key" = "Port" -a "\$val" != "\$br" ]; then sudo ovs-vsctl del-port \$br \$val; fi; done
cd /opt/stack/data/$QUANTUM/external/pids/ && ls -1|xargs -n 10 -r -t sudo rm -rf
cd /opt/stack/data/$QUANTUM/dhcp/ && ls -1|xargs -n 10 -r -t sudo rm -rf
EOF
}


function sg_add_icmp() {
    sgname=$1
    tenant=$2
    if [ $TESTNAME = "folsom" ]; then
        echo "nova secgroup-add-rule $sgname icmp -1 -1 0.0.0.0/0"
    else
        cat <<EOF
tenant_id=\$(keystone tenant-list|awk '\$4=="$tenant"{print \$2}')
sg_id=\$($QUANTUM security-group-list -c id -c name -c tenant_id|awk '(\$6=="'\$tenant_id'" && \$4=="$sgname"){print \$2}')
$QUANTUM security-group-rule-create --protocol icmp \$sg_id
EOF
    fi
}

function sg_del_icmp() {
    sgname=$1
    tenant=$2
    if [ $TESTNAME = "folsom" ]; then
        echo "nova secgroup-delete-rule $sgname icmp -1 -1 0.0.0.0/0"
    else
        cat <<EOF
tenant_id=\$(keystone tenant-list|awk '\$4=="$tenant"{print \$2}')
sg_id=\$($QUANTUM security-group-list -c id -c name -c tenant_id|awk '(\$6=="'\$tenant_id'" && \$4=="$sgname"){print \$2}')
rule_id=\$($QUANTUM security-group-rule-list -c id -c protocol -c security_group|awk '(\$6=="$sgname" && \$4=="icmp"){print \$2}')
$QUANTUM security-group-rule-delete \$rule_id
EOF
    fi
}

function sg_add_ssh() {
    sgname=$1
    tenant=$2
    if [ $TESTNAME = "folsom" ]; then
        echo "nova secgroup-add-rule $sgname tcp 22 22 0.0.0.0/0"
    else
        cat <<EOF
tenant_id=\$(keystone tenant-list|awk '\$4=="$tenant"{print \$2}')
sg_id=\$($QUANTUM security-group-list -c id -c name -c tenant_id|awk '(\$6=="'\$tenant_id'" && \$4=="$sgname"){print \$2}')
$QUANTUM security-group-rule-create --protocol tcp --port-range-min 22 --port-range-max 22 \$sg_id
EOF
    fi
}

function sg_del_ssh() {
    sgname=$1
    tenant=$2
    if [ $TESTNAME = "folsom" ]; then
        echo "nova secgroup-delete-rule $sgname tcp 22 22 0.0.0.0/0"
    else
        cat <<EOF
tenant_id=\$(keystone tenant-list|awk '\$4=="$tenant"{print \$2}')
sg_id=\$($QUANTUM security-group-list -c id -c name -c tenant_id|awk '(\$6=="'\$tenant_id'" && \$4=="$sgname"){print \$2}')
rule_id=\$($QUANTUM security-group-rule-list -c id -c protocol -c security_group|awk '(\$6=="$sgname" && \$4=="tcp"){print \$2}')
$QUANTUM security-group-rule-delete \$rule_id
EOF
    fi
}

function prepare_test() {
    keyname=$1
    user=$2
    tenant=$3
    
    cat <<EOF | $SSHCMD $RYUDEV1_IP
set -x
cd devstack
. ./openrc $user $tenant
nova keypair-add $keyname > ~/$keyname
$(sg_add_icmp default $tenant)
$(sg_add_ssh default $tenant)
exit 0
EOF
    test $? -ne 0 && return 1
    $SCPCMD ubuntu@$RYUDEV1_IP:$keyname $TMP/$keyname
    chmod 600 $TMP/$keyname
    return 0
}

function terminate_all_instances() {
    cat <<EOF | $SSHCMD $RYUDEV1_IP
set -x
cd devstack
. ./openrc admin admin
tenants=\$(keystone tenant-list|awk '\$6=="True"{print \$4}')
for tenant in \$tenants; do
    . ./openrc admin $tenant
    nova list|while read line; do
        ID=\$(echo \$line|awk '{print \$2}')
        test -n "\$ID" && nova delete \$ID
    done
    for (( i=0; i<6; i++ )); do
        LN=\$(nova list|wc -l)
        if [ \$LN -le 4 ]; then
            break
        fi
        sleep 10
    done
done
EOF
}

mkdir -p $TMP
$SUDO rm -f $TMP/*
mkdir -p $LOG
mkdir -p $STACKLOG

# setup output redirection
exec 3>&1
if [ "$VERBOSE" = "True" ]; then
    exec 1> >( tee "$LOGFILE" ) 2>&1
    exec 6> >( tee "$SUMMARY" )
else
    exec 1> "$LOGFILE" 2>&1
    exec 6> >( tee "$SUMMARY" /dev/fd/3 ) 
fi

trap die_intr SIGINT
echo_summary "++ preparing networking"
$SUDO brctl addbr $BR_NAME1
$SUDO ip link set up $BR_NAME1
$SUDO ip addr add 192.168.1.1/24 dev $BR_NAME1
$SUDO brctl addbr $BR_NAME2
$SUDO ip link set up $BR_NAME2
$SUDO dnsmasq --bind-interfaces --except-interface lo --interface $BR_NAME1 \
--pid-file=$DNSMASQ_PID \
--dhcp-host=$RYUDEV1_MAC1,$RYUDEV1_IP,$RYUDEV1_HOSTNAME \
--dhcp-host=$RYUDEV2_MAC1,$RYUDEV2_IP,$RYUDEV2_HOSTNAME \
--dhcp-host=$RYUDEV3_MAC1,$RYUDEV3_IP,$RYUDEV3_HOSTNAME \
--dhcp-range=interface:$BR_NAME1,192.168.1.2,192.168.1.254 \
--dhcp-option=option:router,192.168.1.1 \
--dhcp-option=option:dns-server,192.168.1.1 \
--dhcp-leasefile=$TMP/dnsmasq.lease \
--log-facility=$TMP/dnsmasq.log \
--log-dhcp
$SUDO iptables -t nat -A POSTROUTING -o ${EXTIF} -s 192.168.1.0/24 -j MASQUERADE

echo_summary "++ preparing virtual machine"
run_vm $RYUDEV1_IMG $RYUDEV1_PID $RYUDEV1_PORT $RYUDEV1_MAC1 $RYUDEV1_IP $RYUDEV1_MAC2 $RYUDEV1_VNC
run_vm $RYUDEV2_IMG $RYUDEV2_PID $RYUDEV2_PORT $RYUDEV2_MAC1 $RYUDEV2_IP $RYUDEV2_MAC2 $RYUDEV2_VNC
run_vm $RYUDEV3_IMG $RYUDEV3_PID $RYUDEV3_PORT $RYUDEV3_MAC1 $RYUDEV3_IP $RYUDEV3_MAC2 $RYUDEV3_VNC

install_pkgs $RYUDEV1_IP ryudev1
install_pkgs $RYUDEV2_IP ryudev2
install_pkgs $RYUDEV3_IP ryudev3

export_instance_dir $RYUDEV1_IP ryudev1
mount_instance_dir $RYUDEV2_IP ryudev2 $RYUDEV1_IP
mount_instance_dir $RYUDEV3_IP ryudev3 $RYUDEV1_IP

setup_libvirtd $RYUDEV1_IP ryudev1
setup_libvirtd $RYUDEV2_IP ryudev2
setup_libvirtd $RYUDEV3_IP ryudev3

if [ $TESTNAME = "ml2-vlan" ]; then
  setup_phy-br $RYUDEV1_IP ryudev1
  setup_phy-br $RYUDEV2_IP ryudev2
  setup_phy-br $RYUDEV3_IP ryudev3
fi

pause "start devstack"

start_devstack $RYUDEV1_IP ryudev1|sed 's/^/[ryudev1]/'
start_devstack $RYUDEV2_IP ryudev2|sed 's/^/[ryudev2]/'
start_devstack $RYUDEV3_IP ryudev3|sed 's/^/[ryudev3]/'
$SUDO ip route add 192.168.100.0/24 via $RYUDEV1_IP dev $BR_NAME1

if [ $TESTNAME = "folsom" ]; then
    TITLE="upload non-metadata instance image"
    title "++"
    IMGFILE=cirros-0.3.0-x86_64-uec_custom.tar.gz
    $SCPCMD files/$IMGFILE ubuntu@$RYUDEV1_IP:
    cat <<EOF | $SSHCMD $RYUDEV1_IP
set -x
tar zxf $IMGFILE
cd devstack
. ./openrc admin admin
GLANCE=$RYUDEV1_IP:9292
TOKEN=\$(keystone token-get|grep ' id '|awk '{print \$4}')
test -z "\$TOKEN" && exit 1
KERNEL="cirros-0.3.0-x86_64-vmlinuz"
RAMDISK="cirros-0.3.0-x86_64-initrd"
IMAGE="cirros-0.3.0-x86_64-blank.img"
IMAGENAME="cirros-0.3.0-x86_64-uec_wo-metadata"
KERNEL_ID=\$(glance --os-auth-token \$TOKEN --os-image-url http://\$GLANCE/ image-create --name "\$IMAGENAME-kernel" --is-public True --container-format aki --disk-format aki < "../\$KERNEL"|grep ' id '|awk '{print \$4}')
test -z "\$KERNEL_ID" && exit 1
RAMDISK_ID=\$(glance --os-auth-token \$TOKEN --os-image-url http://\$GLANCE/ image-create --name "\$IMAGENAME-ramdisk" --is-public True --container-format ari --disk-format ari < "../\$RAMDISK"|grep ' id '|awk '{print \$4}')
test -z "\$RAMDISK_ID" && exit 1
glance --os-auth-token \$TOKEN --os-image-url http://\$GLANCE/ image-create --name "\$IMAGENAME" --is-public True --container-format ami --disk-format ami --property kernel_id=\$KERNEL_ID --property ramdisk_id=\$RAMDISK_ID < "../\$IMAGE"
test \$? -ne 0 && exit 1
exit 0
EOF
    result "" $? "++"
fi

##################################################################3

function test_instance() {
    img=$1
    name=$2
    net=$3
    keyname=$4
    user=$5
    tenant=$6
    zone=$7
    ipaddr=$8
    
    cat <<EOF | $SSHCMD $RYUDEV1_IP
set -x
cd devstack
. ./openrc $user $tenant
IMG=\$(nova image-list|grep ' $img '|awk '{print \$2}')
NET=\$($QUANTUM net-list|grep ' $net '|awk '{print \$2}')
if [ -z "$ipaddr" ]; then
  ID=\$(nova boot --flavor 1 --image \$IMG --nic net-id=\$NET --key-name $keyname --availability-zone $zone $name|grep ' id '|awk '{print \$4}')
else
  ID=\$(nova boot --flavor 1 --image \$IMG --nic net-id=\$NET,v4-fixed-ip=$ipaddr --key-name $keyname --availability-zone $zone $name|grep ' id '|awk '{print \$4}')
fi
test -z "\$ID" && exit 1
fail=1
for (( i=0; i<30; i++ )); do
    ST=\$(nova list|grep \$ID|awk '{print \$6}')
    if [ "\$ST" = "ACTIVE" ]; then
        fail=0
        break
    elif [ "\$ST" = "ERROR" ]; then
        break
    fi
    sleep 10
done
test \$fail -ne 0 && exit 1
fail=1
for (( i=0; i<36; i++ )); do
    CONSOLE_LOG="\$(nova console-log \$ID)"
    echo "\${CONSOLE_LOG}"|sed 's/^/[$name]/'|egrep 'cirros login:'
    if [ \$? -eq 0 ]; then
        fail=0
        break
    fi
    sleep 10
done
test \$fail -ne 0 && exit 1
CONSOLE_LOG="\$(nova console-log \$ID)"
echo "\${CONSOLE_LOG}"|sed 's/^/[$name]/'|egrep 'Lease of .* obtained,'
test \$? -ne 0 && exit 1
IP=\$(nova list|grep $name|awk '{print \$$NOVA_LIST_IP_COL}'|sed 's/.*=\\([0-9.]*\\).*/\\1/')
echo -n \$IP > ~/fixedip-$name
exit 0
EOF
    test $? -ne 0 && return 1
    
    IP=$($SSHCMD $RYUDEV1_IP cat fixedip-$name)
    test -z "$IP" && return 1
    echo -n $IP > $TMP/fixedip-$name
    
    return 0
}

function test_float() {
    name=$1
    netname=$2
    ip=$3
    keyname=$4
    user=$5
    tenant=$6
    login=$7
    
    cat <<EOF | $SSHCMD $RYUDEV1_IP
set -x
cd devstack
. ./openrc $user $tenant
NETID=\$($QUANTUM net-list|grep ' $PUBLIC_NET '|awk '{print \$2}')
test -z "\$NETID" && exit 1
SUBNETID=\$($QUANTUM net-list|grep $netname|awk '{print \$6}')
test -z "\$SUBNETID" && exit 1
PORTID=\$($QUANTUM port-list|grep $ip|grep \$SUBNETID|awk '{print \$2}')
test -z "\$PORTID" && exit 1
FLOATID=\$($QUANTUM floatingip-create \$NETID|grep ' id '|awk '{print \$4}')
test -z "\$FLOATID" && exit 1
$QUANTUM floatingip-associate \$FLOATID \$PORTID
test \$? -ne 0 && exit 1
FIP=\$($QUANTUM floatingip-list|grep \$FLOATID|awk '{print \$6}')
test -z "\$FIP" && exit 1
echo -n \$FIP > ~/floatingip-$name
exit 0
EOF
    test $? -ne 0 && return 1
    
    FIP=$($SSHCMD $RYUDEV1_IP cat floatingip-$name)
    test -z "$FIP" && return 1
    echo -n $FIP > $TMP/floatingip-$name
    
    fail=1
    for (( i=0; i<3; i++ )); do
        $SSH -i $TMP/$keyname -l $login $FIP true
        if [ $? -eq 0 ]; then
            fail=0
            break
        fi
        sleep 10
    done
    test $fail -ne 0 && return 1
    
    ping -c 1 $FIP || return 1
    
    return 0
}

function test_secgroup() {
    ip=$1
    sgname=$2
    user=$3
    tenant=$4
    
    cat <<EOF | $SSHCMD $RYUDEV1_IP
set -x
cd devstack
. ./openrc $user $tenant
$(sg_del_icmp $sgname $tenant)
test \$? -ne 0 && exit 1
exit 0
EOF
    test $? -ne 0 && return 1
    
    fail=1
    for (( i=0; i<3; i++ )); do
        ping -c 1 $ip
        if [ $? -ne 0 ]; then
            fail=0
            break
        fi
        sleep 5
    done
    test $fail -ne 0 && return 1
    
    cat <<EOF | $SSHCMD $RYUDEV1_IP
set -x
cd devstack
. ./openrc $user $tenant
$(sg_add_icmp $sgname $tenant)
test \$? -ne 0 && exit 1
exit 0
EOF
    test $? -ne 0 && return 1
    
    fail=1
    for (( i=0; i<3; i++ )); do
        ping -c 1 $ip
        if [ $? -eq 0 ]; then
            fail=0
            break
        fi
        sleep 5
    done
    test $fail -ne 0 && return 1
    
    cat <<EOF | $SSHCMD $RYUDEV1_IP
set -x
cd devstack
. ./openrc $user $tenant
$(sg_del_ssh $sgname $tenant)
test \$? -ne 0 && exit 1
exit 0
EOF
    test $? -ne 0 && return 1
    fail=1
    for (( i=0; i<3; i++ )); do
        $SSH -i $TMP/$keyname -l cirros $ip true
        if [ $? -ne 0 ]; then
            fail=0
            break
        fi
        sleep 5
    done 
    test $fail -ne 0 && return 1
    
    cat <<EOF | $SSHCMD $RYUDEV1_IP
set -x
cd devstack
. ./openrc $user $tenant
$(sg_add_ssh $sgname $tenant)
test \$? -ne 0 && exit 1
exit 0
EOF
    test $? -ne 0 && return 1
    
    fail=1
    for (( i=0; i<3; i++ )); do
        $SSH -i $TMP/$keyname -l cirros $ip true
        if [ $? -eq 0 ]; then
            fail=0
            break
        fi
        sleep 5
    done 
    test $fail -ne 0 && return 1
    
    return 0
}

function test_traffic() {
    ip1=$1
    ip2=$2
    key1=$3
    user1=$4
    key2=$5
    user2=$6
    
    $SCP -i $TMP/$key1 $TMP/$key2 $user1@$ip1: || return 1
    $SSH -i $TMP/$key1 -l $user1 $ip1 dropbearconvert openssh dropbear $key2 $key2.db || return 1

    cat <<EOF | $SSH -i $TMP/$key1 -l $user1 $ip1
set -x
chmod 600 $key2.db
ssh -y -i $key2.db $user2@$ip2 true
test \$? -ne 0 && exit 1
exit 0
EOF
    test $? -ne 0 && return 1
    return 0
}

function test_create_tenant() {
    tenant=$1
    net=$2
    gateway=$3
    cidr=$4
    
    cat <<EOF | $SSHCMD $RYUDEV1_IP
set -x
cd devstack
. ./openrc admin admin
TENANTID=\$(keystone tenant-create --name $tenant|grep ' id '|awk '{print \$4}')
test -z "\$TENANTID" && exit 1
USERID=\$(keystone user-list|grep ' admin '|awk '{print \$2}')
test -z "\$USERID" && exit 1
ROLEID=\$(keystone role-list|grep ' admin '|awk '{print \$2}')
test -z "\$ROLEID" && exit 1
keystone user-role-add --user-id \$USERID --role-id \$ROLEID --tenant-id \$TENANTID
test \$? -ne 0 && exit 1
. ./openrc admin $tenant
NETID=\$($QUANTUM net-create --tenant_id \$TENANTID $net|grep ' id '|awk '{print \$4}')
test -z "\$NETID" && exit 1
SUBNETID=\$($QUANTUM subnet-create --tenant_id \$TENANTID --ip_version 4 --gateway $gateway \$NETID $cidr|grep ' id '|awk '{print \$4}')
test -z "\$SUBNETID" && exit 1
RTID=\$($QUANTUM router-create $net-router1|grep ' id '|awk '{print \$4}')
test -z "\$RTID" && exit 1
$QUANTUM router-interface-add \$RTID \$SUBNETID
test \$? -ne 0 && exit 1
EXTNETID=\$($QUANTUM net-list|grep ' $PUBLIC_NET '|awk '{print \$2}')
test -z "\$EXTNETID" && exit 1
$QUANTUM port-list -c device_owner -c fixed_ips|grep ' network:router_gateway '|awk -F '"' '{print \$8}' > a
cat a
$QUANTUM router-gateway-set \$RTID \$EXTNETID
test \$? -ne 0 && exit 1
$QUANTUM port-list -c device_owner -c fixed_ips|grep ' network:router_gateway '|awk -F '"' '{print \$8}' > b
cat b
GATEWAY=\$(diff a b|grep '^> '|sed 's/> //')
rm -f a b
test -z \$GATEWAY && exit 1
sudo route add -net $cidr gw \$GATEWAY
exit 0
EOF
    test $? -ne 0 && return 1
    
    return 0
}

function test_live_migration() {
    name=$1
    host=$2
    ip=$3
    user=$4
    tenant=$5

    cat <<EOF | $SSHCMD $RYUDEV1_IP
set -x
cd devstack
. ./openrc $user $tenant
nova live-migration $name $host
test \$? -ne 0 && exit 1
fail=1
for (( i=0; i<6; i++ )); do
    ST=\$(nova list|grep $name|awk '{print \$6}')
    if [ "\$ST" = "ACTIVE" ]; then
        fail=0
        break
    elif [ "\$ST" = "ERROR" ]; then
        break
    fi
    sleep 10
done
test \$fail -ne 0 && exit 1
dest=\$(nova show $name|awk '\$2=="OS-EXT-SRV-ATTR:host"{print \$4}')
test \$dest != $host && exit 1
exit 0
EOF
    test $? -ne 0 && return 1

    fail=1
    for (( i=0; i<3; i++ )); do
        ping -c 1 $ip
        if [ $? -eq 0 ]; then
            fail=0
            break
        fi
        sleep 5
    done
    test $fail -ne 0 && return 1
    return 0
}

function terminate_instance() {
    name=$1
    user=$2
    tenant=$3
    
    cat <<EOF | $SSHCMD $RYUDEV1_IP
set -x
cd devstack
. ./openrc $user $tenant
nova delete $name
fail=1
for (( i=0; i<6; i++ )); do
    nova list|grep $name
    if [ \$? -ne 0 ]; then
        fail=0
        break
    fi
    sleep 10
done
test \$fail -ne 0 && exit 1
exit 0
EOF
    return $?
}

##################################################################3

TITLE="prepare misc"
title "++"
prepare_test "key1" "admin" "demo"
result "" $? "++"

TITLE="launch instance: vm1"
title
test_instance "cirros-0.3.1-x86_64-uec" "vm1" $PRIVATE_NET "key1" "admin" "demo" "nova:ryudev1"
result "" $?
TITLE="launch instance: vm2"
title
test_instance "cirros-0.3.1-x86_64-uec" "vm2" $PRIVATE_NET "key1" "admin" "demo" "nova:ryudev2"
result "" $?
TITLE="launch instance: vm3"
title
test_instance "cirros-0.3.1-x86_64-uec" "vm3" $PRIVATE_NET "key1" "admin" "demo" "nova:ryudev3"
result "" $?
    
TITLE="floatingip: vm1"
title
ip=$(cat $TMP/fixedip-vm1)
test_float "vm1" $PRIVATE_NET $ip "key1" "admin" "demo" "cirros"
result "" $?
TITLE="floatingip: vm2"
title
ip=$(cat $TMP/fixedip-vm2)
test_float "vm2" $PRIVATE_NET $ip "key1" "admin" "demo" "cirros"
result "" $?
TITLE="floatingip: vm3"
title
ip=$(cat $TMP/fixedip-vm3)
test_float "vm3" $PRIVATE_NET $ip "key1" "admin" "demo" "cirros"
result "" $?

TITLE="security groups"
title
ip=$(cat $TMP/floatingip-vm1)
test_secgroup $ip "default" "admin" "demo"
result "vm1" $?
ip=$(cat $TMP/floatingip-vm2)
test_secgroup $ip "default" "admin" "demo"
result "vm2" $?

TITLE="communicate to an instance of the same tenant"
title
ip1=$(cat $TMP/floatingip-vm1)
ip2=$(cat $TMP/fixedip-vm2)
test_traffic $ip1 $ip2 "key1" "cirros" "key1" "cirros"
result "vm1 -> vm2" $?

ip1=$(cat $TMP/floatingip-vm1)
ip2=$(cat $TMP/fixedip-vm3)
test_traffic $ip1 $ip2 "key1" "cirros" "key1" "cirros"
result "vm1 -> vm3" $?

ip1=$(cat $TMP/floatingip-vm2)
ip2=$(cat $TMP/fixedip-vm3)
test_traffic $ip1 $ip2 "key1" "cirros" "key1" "cirros"
result "vm2 -> vm3" $?

TITLE="live migration"
title
ip=$(cat $TMP/floatingip-vm3)
test_live_migration "vm3" $RYUDEV2_HOSTNAME $ip "admin" "demo"
result "" $?
terminate_instance "vm3" "admin" "demo"

TITLE="create tenant"
title
test_create_tenant "test" "test" "10.0.1.1" "10.0.1.0/24"
result "tenant" $?
prepare_test "key2" "admin" "test"
result "keypair" $?
test_instance "cirros-0.3.1-x86_64-uec" "vm4" "test" "key2" "admin" "test" "nova:ryudev2"
result "instance" $?
ip=$(cat $TMP/fixedip-vm4)
test_float "vm4" "test" $ip "key2" "admin" "test" "cirros"
result "floatingip" $?

TITLE="communicate via Floating-IP to an instance of the other tenant"
title
ip1=$(cat $TMP/floatingip-vm1)
ip2=$(cat $TMP/floatingip-vm4)
test_traffic $ip1 $ip2 "key1" "cirros" "key2" "cirros"
result "" $?

TITLE="launch an instance with overlapping IP range"
title
test_create_tenant "demo2" "demo2" "10.0.0.1" "10.0.0.0/24"
result "tenant" $?
prepare_test "key3" "admin" "demo2"
result "keypair" $?
ip1=$(cat $TMP/fixedip-vm1)
if [ $TESTNAME = "folsom" ]; then
    test_instance "cirros-0.3.0-x86_64-uec_wo-metadata" "vm5" "demo2" "key3" "admin" "demo2" "nova:ryudev3" $ip1
else
    test_instance "cirros-0.3.1-x86_64-uec" "vm5" "demo2" "key3" "admin" "demo2" "nova:ryudev3" $ip1
fi
result "instance" $?
ip=$(cat $TMP/fixedip-vm5)
if [ $TESTNAME = "folsom" ]; then
    test_float "vm5" "demo2" $ip "key3" "admin" "demo2" "root"
else
    test_float "vm5" "demo2" $ip "key3" "admin" "demo2" "cirros"
fi
result "floatingip" $?

TITLE="communicate to the instance of the same tenant has overlapping IP range"
title
ip1=$(cat $TMP/floatingip-vm1)
ip2=$(cat $TMP/fixedip-vm2)
test_traffic $ip1 $ip2 "key1" "cirros" "key1" "cirros"
result "" $?

TITLE="communicate to the instance of the other tenant has overlapping IP range"
title
ip1=$(cat $TMP/floatingip-vm5)
ip2=$(cat $TMP/fixedip-vm2)
if [ $TESTNAME = "folsom" ]; then
    test_traffic $ip1 $ip2 "key3" "root" "key1" "cirros"
else
    test_traffic $ip1 $ip2 "key3" "cirros" "key1" "cirros"
fi
rc=$?
result "" $((!rc))

TITLE="communicate via Floating-IP to the instance of the other tenant has overlapping IP range"
title
ip1=$(cat $TMP/floatingip-vm5)
ip2=$(cat $TMP/floatingip-vm1)
if [ $TESTNAME = "folsom" ]; then
    test_traffic $ip1 $ip2 "key3" "root" "key1" "cirros"
else
    test_traffic $ip1 $ip2 "key3" "cirros" "key1" "cirros"
fi
result "" $?

pause "finish"

TITLE="terminate instance"
terminate_instance "vm1" "admin" "demo"
result "vm1" $? "++"
terminate_instance "vm2" "admin" "demo"
result "vm2" $? "++"
terminate_instance "vm3" "admin" "demo"
result "vm3" $? "++"
terminate_instance "vm4" "admin" "test"
result "vm4" $? "++"
terminate_instance "vm5" "admin" "demo2"
result "vm5" $? "++"

die 0
