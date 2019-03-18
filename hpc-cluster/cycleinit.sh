TMP_DIR="/mnt/resource"

install_pkgs()
{

  # yum -y install epel-release
  # yum -y install zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl openssl-devel openssl-libs \
  #     gcc gcc-c++ nfs-utils rpcbind mdadm wget python-pip kernel kernel-devel \
  #     mpich-3.2 mpich-3.2-devel automake autoconf
  # Install nfs
  yum -y install nfs-utils rpcbind
  # Install pre-reqs and development tools
  yum groupinstall -y "Development Tools"
  yum install -y numactl numactl-devel libxml2-devel byacc environment-modules
  yum install -y python-devel python-setuptools
  yum install -y gtk2 atk cairo tcl tk
  yum install -y gcc-gfortran gcc-c++
  KERNEL=$(uname -r)
  yum install -y kernel-devel-${KERNEL}
  yum install -y m4 libgcc.i686 glibc-devel.i686
  yum install -y infiniband-diags

  # Install Mellanox OFED
  mkdir -p $TMP_DIR/mlnxofed
  cd $TMP_DIR/mlnxofed
  wget http://www.mellanox.com/downloads/ofed/MLNX_OFED-4.5-1.0.1.0/MLNX_OFED_LINUX-4.5-1.0.1.0-rhel7.6-x86_64.tgz
  tar zxvf MLNX_OFED_LINUX-4.5-1.0.1.0-rhel7.6-x86_64.tgz

  KERNEL=$(uname -r)
  ./MLNX_OFED_LINUX-4.5-1.0.1.0-rhel7.6-x86_64/mlnxofedinstall --kernel-sources /usr/src/kernels/$KERNEL --add-kernel-support --skip-repo

  sed -i 's/LOAD_EIPOIB=no/LOAD_EIPOIB=yes/g' /etc/infiniband/openib.conf
  /etc/init.d/openibd restart
  cd && rm -rf $TMP_DIR/mlnxofed

  # # Install WALinuxAgent
  # mkdir -p $TMP_DIR/wala
  # cd $TMP_DIR/wala
  # wget https://github.com/Azure/WALinuxAgent/archive/v2.2.36.tar.gz
  # tar -xvf v2.2.36.tar.gz
  # cd WALinuxAgent-2.2.36
  # python setup.py install --register-service --force
  sed -i -e 's/# OS.EnableRDMA=y/OS.EnableRDMA=y/g' /etc/waagent.conf
  sed -i -e 's/AutoUpdate.Enabled=y/# AutoUpdate.Enabled=y/g' /etc/waagent.conf
}

# Sets all common environment variables and system parameters.
#
setup_env()
{

  # disable selinux
  sed -i 's/enforcing/disabled/g' /etc/selinux/config
  setenforce permissive
  # Set unlimited mem lock
  echo "$HPC_USER hard memlock unlimited" >> /etc/security/limits.conf
  echo "$HPC_USER soft memlock unlimited" >> /etc/security/limits.conf


  yum install -y nfs-utils
  sed -i 's/GSS_USE_PROXY="yes"/GSS_USE_PROXY="no"/g' /etc/sysconfig/nfs

  # Enable reclaim mode
  cp /etc/sysctl.conf /tmp/sysctl.conf
  echo "vm.zone_reclaim_mode = 1" >> /tmp/sysctl.conf
  cp /tmp/sysctl.conf /etc/sysctl.conf
  sysctl -p

  # disable firewall
  systemctl stop firewalld
}

install_pkgs
setup_env
