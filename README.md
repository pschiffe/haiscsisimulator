# HA iSCSI Storage Simulator

This repo describes simple `HA iSCSI Storage` simulator with his `iSCSI Clients`. The HA Storage simulator is managed by 2 iSCSI controllers which are sharing one storage device. Remote clients of iSCSI Storage use multipath setup.

```
   /----------\
   | client 1 |
   \----------/
       |
       |  /----------\
       |  | client 2 |
       |  \----------/
       |       |
       |    /--+--------------\
       |    |                 |
       +--------------------\ |
       |    |               | |
       |    |               | |
   /-------------\     /------------\
   | Controller1 |     | Contoller2 |
   \-------------/     \------------/
        |                    |
        \--------+-----------/
                 |
          ( Local Storage )
```

## Infrastructure

Infrastructure for the simulator consists of 3 virtual machines, client1, client2 and controller with CentOS 7.1. All machines have 2 network interfaces connected in 2 different networks. Controller has attached 2 virtual drives. For the quick and easy deployment I've used [Vagrant](https://www.vagrantup.com/) with [oh-my-vagrant](https://github.com/purpleidea/oh-my-vagrant).

### Storage

To simulate storage I've created 2 virtual drives attached to the controller, one for each client. We can pretend that they are LUNs in some SAN. Alternative way could be single virtual drive with 2 image files. I chose the former option because I think it's closer to the real world scenario.

### Controller

Reason why I used single machine for both iSCSI controllers is that virtual drives can be attached only to single machine. If we want both clients to be connected to both controllers, both controllers need access to both drives. To model this, I used one machine running 2 iSCSI targets with one drive each, listening on 2 network interfaces.

### Clients

Each client is connected to one iSCSI target via both network interfaces, using multipath setup.

## Deployment

This section contains steps how to deploy described architecture.

### Controller

On controller, I used [LIO](http://linux-iscsi.org/wiki/Main_Page) for iSCSI target. To install it:
```
yum install python-rtslib targetcli
```

`targetcli` is powerful tool for configuring LIO iSCSI target: (reference [here](http://linux-iscsi.org/wiki/Targetcli) and [here](http://linux-iscsi.org/wiki/ISCSI))
```
targetcli
  # Create 2 backstores of block type, one for each drive
cd /backstores/block/
create disk1 /dev/vdb
create disk2 /dev/vdc
  # Create 2 targets, one for each drive
cd /iscsi/
create iqn.2015-10.local.iscsi:disk1
create iqn.2015-10.local.iscsi:disk2
  # Add LUN to each target
cd /iscsi/iqn.2015-10.local.iscsi:disk1/tpg1/luns/
create /backstores/block/disk1
cd /iscsi/iqn.2015-10.local.iscsi:disk2/tpg1/luns/
create /backstores/block/disk2
  # Delete default portals and create new for both interfaces
cd /iscsi/iqn.2015-10.local.iscsi:disk1/tpg1/portals/
delete 0.0.0.0 3260
cd /iscsi/iqn.2015-10.local.iscsi:disk2/tpg1/portals/
delete 0.0.0.0 3260
create 192.168.121.161  # IP of eth0
create 192.168.131.100  # IP of eth1
cd /iscsi/iqn.2015-10.local.iscsi:disk1/tpg1/portals/
create 192.168.121.161  # IP of eth0
create 192.168.131.100  # IP of eth1
  # Set up authentication. I'm being brave here and using no authentication, because this is controlled enviroment.
  # It is possible to setup regular authentication, allowing only selected clients, with username and password.
cd /iscsi/iqn.2015-10.local.iscsi:disk1/tpg1/
set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=1 cache_dynamic_acls=1
cd /iscsi/iqn.2015-10.local.iscsi:disk2/tpg1/
set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=1 cache_dynamic_acls=1
exit
```

Start and enable `target` service:
```
systemctl restart target
systemctl enable target
```

### Clients

On both clients, install required packages:
```
yum install iscsi-initiator-utils device-mapper-multipath
```

Because there is currently bug in CentOS 7.1, where `fast_io_fail_tmo 5` option in `/etc/multipath.conf` is ignored (more info [BZ#980139](https://bugzilla.redhat.com/show_bug.cgi?id=980139)), we need to edit `/etc/iscsi/iscsid.conf` file and change `node.session.timeo.replacement_timeout` from value `120` to, for example, `5`, otherwise when one path in multipath setup stops working, process accessing the multipath device might be blocked for 2 minutes before path is evaluated as broken.

Discover target:
```
iscsiadm --mode discovery --type sendtargets --portal 192.168.121.161  # IP of the controller
```

Login to one of the targets:
```
iscsiadm --mode node --login --targetname iqn.2015-10.local.iscsi:disk1
```

Enable multipath:
```
mpathconf --enable --with_multipathd y
```

Configure multipath `/etc/multipath.conf`:
```
blacklist {
  devnode "^vd[a-z]"
}

defaults {
  user_friendly_names yes
  find_multipaths yes
  path_grouping_policy multibus  # So both paths are actively used
}

multipaths {
  multipath {
    wwid   36001405f4812b956f2e4f56b527da9d5  # Needs to be changed to actual value
    alias  mpatha
  }
}
```

Restart multipath service:
```
systemctl restart multipathd
```

To check actual state of multipath:
```
multipath -ll
multipathd -k"show paths"
```

Use multipath device:
```
echo -e "n\np\n1\n\n\nw" | fdisk /dev/mapper/mpatha
  # Reload partition table
partprobe
mkfs.xfs /dev/mapper/mpatha1
mkdir -p /mnt/iscsi
echo '/dev/mapper/mpatha1  /mnt/iscsi  xfs  defaults,_netdev  0 0' >> /etc/fstab
mount -a
```

## Simulating fail-over

To simulate fail-over, disable one network interface on controller:
```
ifdown eth1
```

Multipath can be monitored on clients with:
```
multipath -ll
multipathd -k"show paths"
```

## Automatic deployment

As I wrote in the beginning, I'm using [Vagrant](https://www.vagrantup.com/) with [oh-my-vagrant](https://github.com/purpleidea/oh-my-vagrant) to quickly deploy these virtual machines. Quick how-to (this should work for Fedora, probably CentOS/RHEL 7):

Download proper repo file from [https://copr.fedoraproject.org/coprs/purpleidea/oh-my-vagrant/](https://copr.fedoraproject.org/coprs/purpleidea/oh-my-vagrant/) or:
```
dnf copr enable purpleidea/oh-my-vagrant
```

Install oh-my-vagrant:
```
yum install oh-my-vagrant
```

Add yourself to the `vagrant` group:
```
usermod -aG vagrant $(whoami)
```

Init oh-my-vagrant (omv) in some temp directory, so it downloads all needed plugins:
```
mkdir /tmp/omv
cd /tmp/omv
omv init
cd -
rm -rf /tmp/omv
```

Use my repo:
```
git clone https://github.com/pschiffe/haiscsisimulator.git
cd haiscsisimulator/omv
omv up
```

`omv` is just a wrapper around `vagrant` binary, so it accepts all the `vagrant` commands like `status`, `ssh`, `halt`...

Connect to the controller and configure it together with clients:
```
omv ssh controller
sudo su -
yum install ansible
cd /vagrant/simulator
./distribute-keys.sh
ansible-playbook -i ansible-hosts ansible-playbook.yml
```
