#!/bin/bash

set -x
#set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

echo "Script arguments: $@"

if [ $# != 12 ]; then
    echo "Usage: $0 <MasterHostname> <WorkerHostnamePrefix> <WorkerNodeCount> <HPCUserName> <TemplateBaseUrl> <ClusterFilesystem> <ClusterFilesystemStorage> <ImageOffer> <Scheduler> <InstallEasybuild> <NumWorkerProcs> <MasterIP>"
    exit 1
fi

# Set user args
MASTER_HOSTNAME=$1
WORKER_HOSTNAME_PREFIX=$2
WORKER_COUNT=$3
TEMPLATE_BASE_URL="$5"
CFS="$6" # None, BeeGFS
CFS_STORAGE="$7" # None,Storage,SSD
CFS_STORAGE_LOCATION="/data/beegfs/storage"
IMAGE_OFFER="$8"
SCHEDULER="$9"
INSTALL_EASYBUILD="${10}"
WORKER_NPROC="${11}"
MASTER_IP="${12}"
LAST_WORKER_INDEX=$(($WORKER_COUNT - 1))

if [ "$CFS_STORAGE" == "Storage" ]; then
    CFS_STORAGE_LOCATION="/data/beegfs/storage"
elif [ "$CFS_STORAGE" == "SSD" ]; then
    CFS_STORAGE_LOCATION="/mnt/resource/storage"
fi

# Shares
SHARE_NFS=/share/nfs
SHARE_HOME=$SHARE_NFS/home
SHARE_DATA=$SHARE_NFS/data
SHARE_APPS=$SHARE_NFS/apps
SHARE_CFS=/share/cfs
BEEGFS_METADATA=/data/beegfs/meta

# Munged
MUNGE_USER=munge
MUNGE_GROUP=munge
MUNGE_VERSION=0.5.11

# SLURM
SLURM_USER=slurm
SLURM_UID=6006
SLURM_GROUP=slurm
SLURM_GID=6006
SLURM_VERSION=15-08-1-1
SLURM_CONF_DIR=$SHARE_DATA/conf

# Hpc User
HPC_USER=$4
HPC_UID=7007
HPC_GROUP=hpc
HPC_GID=7007


# Returns 0 if this node is the master node.
#
is_master()
{
    hostname | grep "$MASTER_HOSTNAME"
    return $?
}


# Installs all required packages.
#
install_pkgs()
{
    echo "$IMAGE_OFFER" | grep -q 'HPC$'
    if [ $? -eq 0 ]; then
        rpm --rebuilddb
        updatedb
        yum clean all
        yum -y install epel-release
        #yum --exclude WALinuxAgent,intel-*,kernel*,*microsoft-*,msft-* -y update

        sed -i.bak -e '28d' /etc/yum.conf
        sed -i '28i#exclude=kernel*' /etc/yum.conf

        yum -y install zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl openssl-devel openssl-libs \
            nfs-utils rpcbind git libicu libicu-devel make zip unzip mdadm wget gsl bc rpm-build  \
            readline-devel pam-devel libXtst.i686 libXtst.x86_64 make.x86_64 sysstat.x86_64 python-pip automake autoconf \
            binutils.x86_64 compat-libcap1.x86_64 glibc.i686 glibc.x86_64 \
            ksh compat-libstdc++-33 libaio.i686 libaio.x86_64 libaio-devel.i686 libaio-devel.x86_64 \
            libgcc.i686 libgcc.x86_64 libstdc++.i686 libstdc++.x86_64 libstdc++-devel.i686 libstdc++-devel.x86_64 \
            libXi.i686 libXi.x86_64 gcc gcc-c++ gcc.x86_64 gcc-c++.x86_64 glibc-devel.i686 glibc-devel.x86_64 libtool libxml2-devel mpich-3.2 mpich-3.2-devel

        sed -i.bak -e '28d' /etc/yum.conf
        sed -i '28iexclude=kernel*' /etc/yum.conf
    else
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

        # Install Mellanox OFED
        mkdir -p /tmp/mlnxofed
        cd /tmp/mlnxofed
        wget http://www.mellanox.com/downloads/ofed/MLNX_OFED-4.5-1.0.1.0/MLNX_OFED_LINUX-4.5-1.0.1.0-rhel7.6-x86_64.tgz
        tar zxvf MLNX_OFED_LINUX-4.5-1.0.1.0-rhel7.6-x86_64.tgz

        KERNEL=$(uname -r)
        ./MLNX_OFED_LINUX-4.5-1.0.1.0-rhel7.6-x86_64/mlnxofedinstall --kernel-sources /usr/src/kernels/$KERNEL --add-kernel-support --skip-repo

        sed -i 's/LOAD_EIPOIB=no/LOAD_EIPOIB=yes/g' /etc/infiniband/openib.conf
        /etc/init.d/openibd restart
        cd && rm -rf /tmp/mlnxofed

        # # Install WALinuxAgent
        # mkdir -p /tmp/wala
        # cd /tmp/wala
        # wget https://github.com/Azure/WALinuxAgent/archive/v2.2.36.tar.gz
        # tar -xvf v2.2.36.tar.gz
        # cd WALinuxAgent-2.2.36
        # python setup.py install --register-service --force
        sed -i -e 's/# OS.EnableRDMA=y/OS.EnableRDMA=y/g' /etc/waagent.conf
        sed -i -e 's/AutoUpdate.Enabled=y/# AutoUpdate.Enabled=y/g' /etc/waagent.conf
        # systemctl restart waagent
        # cd && rm -rf /tmp/wala

        # Install gcc 8.2
        mkdir -p /tmp/setup-gcc
        cd /tmp/setup-gcc

        wget ftp://gcc.gnu.org/pub/gcc/infrastructure/gmp-6.1.0.tar.bz2
        tar -xvf gmp-6.1.0.tar.bz2
        cd ./gmp-6.1.0
        ./configure && make -j 40 &&  make install
        cd ..

        wget ftp://gcc.gnu.org/pub/gcc/infrastructure/mpfr-3.1.4.tar.bz2
        tar -xvf mpfr-3.1.4.tar.bz2
        cd mpfr-3.1.4
        ./configure && make -j 40 &&  make install
        cd ..

        wget ftp://gcc.gnu.org/pub/gcc/infrastructure/mpc-1.0.3.tar.gz
        tar -xvf mpc-1.0.3.tar.gz
        cd mpc-1.0.3
        ./configure && make -j 40 &&  make install
        cd ..

        # install gcc 8.2
        wget https://ftp.gnu.org/gnu/gcc/gcc-8.2.0/gcc-8.2.0.tar.gz
        tar -xvf gcc-8.2.0.tar.gz
        cd gcc-8.2.0
        ./configure --disable-multilib && make -j 40 && make install

        cd && rm -rf /tmp/setup-gcc

        cp ./modulefiles/gcc-8.2.0 /usr/share/Modules/modulefiles/
        source ~/.bashrc
        module load gcc-8.2.0

        INSTALL_PREFIX=/opt

        mkdir -p /tmp/mpi
        cd /tmp/mpi

        # MVAPICH2 2.3
        wget http://mvapich.cse.ohio-state.edu/download/mvapich/mv2/mvapich2-2.3.tar.gz
        tar -xvf mvapich2-2.3.tar.gz
        cd mvapich2-2.3
        ./configure --prefix=${INSTALL_PREFIX}/mvapich2-2.3 --enable-g=none --enable-fast=yes && make -j 40 && make install
        cd ..

        # UCX 1.5.0 RC1
        wget https://github.com/openucx/ucx/releases/download/v1.5.0-rc1/ucx-1.5.0.tar.gz
        tar -xvf ucx-1.5.0.tar.gz
        cd ucx-1.5.0
        ./contrib/configure-release --prefix=${INSTALL_PREFIX}/ucx-1.5.0 && make -j 40 && make install
        cd ..

        # HPC-X v2.3.0
        cd ${INSTALL_PREFIX}
        wget http://www.mellanox.com/downloads/hpc/hpc-x/v2.3/hpcx-v2.3.0-gcc-MLNX_OFED_LINUX-4.5-1.0.1.0-redhat7.6-x86_64.tbz
        tar -xvf hpcx-v2.3.0-gcc-MLNX_OFED_LINUX-4.5-1.0.1.0-redhat7.6-x86_64.tbz
        HPCX_PATH=${INSTALL_PREFIX}/hpcx-v2.3.0-gcc-MLNX_OFED_LINUX-4.5-1.0.1.0-redhat7.6-x86_64
        HCOLL_PATH=${HPCX_PATH}/hcoll
        rm -rf hpcx-v2.3.0-gcc-MLNX_OFED_LINUX-4.5-1.0.1.0-redhat7.6-x86_64.tbz
        cd /tmp/mpi

        # OpenMPI 4.0.0
        wget https://download.open-mpi.org/release/open-mpi/v4.0/openmpi-4.0.0.tar.gz
        tar -xvf openmpi-4.0.0.tar.gz
        cd openmpi-4.0.0
        ./configure --prefix=${INSTALL_PREFIX}/openmpi-4.0.0 --with-ucx=${INSTALL_PREFIX}/ucx-1.5.0 --enable-mpirun-prefix-by-default && make -j 40 && make install
        cd ..

        # MPICH 3.3
        wget http://www.mpich.org/static/downloads/3.3/mpich-3.3.tar.gz
        tar -xvf mpich-3.3.tar.gz
        cd mpich-3.3
        ./configure --prefix=${INSTALL_PREFIX}/mpich-3.3 --with-ucx=${INSTALL_PREFIX}/ucx-1.5.0 --with-hcoll=${HCOLL_PATH} --enable-g=none --enable-fast=yes --with-device=ch4:ucx   && make -j 8 && make install
        cd ..

        # Intel MPI 2019 (update 2)
        wget http://registrationcenter-download.intel.com/akdlm/irc_nas/tec/15040/l_mpi_2019.2.187.tgz
        wget https://raw.githubusercontent.com/jithinjosepkl/azhpc-images/master/config/IntelMPI-v2019.x-silent.cfg
        tar -xvf l_mpi_2019.2.187.tgz
        cd l_mpi_2019.2.187
        ./install.sh --silent /tmp/mpi/IntelMPI-v2019.x-silent.cfg
        cd ..

        cd && rm -rf /tmp/mpi

        mkdir -p /usr/share/Modules/modulefiles/mpi/
        cp ./modulefiles/mpi/* /usr/share/Modules/modulefiles/mpi/

    fi


}

# Partitions all data disks attached to the VM and creates
# a RAID-0 volume with them.
#
setup_data_disks()
{
    mountPoint="$1"
    filesystem="$2"
    createdPartitions=""

    # Loop through and partition disks until not found
    for disk in sdc sdd sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp sdq sdr; do
        fdisk -l /dev/$disk || break
        fdisk /dev/$disk << EOF
n
p
1


t
fd
w
EOF
        createdPartitions="$createdPartitions /dev/${disk}1"
    done

    sleep 30

    # Create RAID-0 volume
    if [ -n "$createdPartitions" ]; then
        devices=`echo $createdPartitions | wc -w`
        mdadm --create /dev/md10 --level 0 --raid-devices $devices $createdPartitions
        if [ "$filesystem" == "xfs" ]; then
            mkfs -t $filesystem /dev/md10
            echo "/dev/md10 $mountPoint $filesystem rw,noatime,attr2,inode64,nobarrier,sunit=1024,swidth=4096,nofail 0 2" >> /etc/fstab
        else
            mkfs -t $filesystem /dev/md10
            echo "/dev/md10 $mountPoint $filesystem defaults,nofail 0 2" >> /etc/fstab
        fi

        sleep 15

        mount /dev/md10
    fi
}

# Creates and exports two shares on the master nodes:
#
# /share/home (for HPC user)
# /share/data
#
# These shares are mounted on all worker nodes.
#
setup_shares()
{
    mkdir -p $SHARE_NFS
    mkdir -p $SHARE_CFS

    if is_master; then
        yum install -y nfs-server
        if [ "$CFS" == "BeeGFS" ]; then
            mkdir -p $BEEGFS_METADATA
            setup_data_disks $BEEGFS_METADATA "ext4"
        else
            setup_data_disks $SHARE_NFS "ext4"
        fi

        echo "$SHARE_NFS    *(rw,async)" >> /etc/exports
        systemctl enable rpcbind || echo "Already enabled"
        systemctl enable nfs-server || echo "Already enabled"
        systemctl start rpcbind || echo "Already enabled"
        systemctl start nfs-server || echo "Already enabled"

        mount -a
        mount
    else
        if [ "$CFS_STORAGE" == "Storage" ]; then
            # Format CFS mount point
            mkdir -p $CFS_STORAGE_LOCATION
            setup_data_disks $CFS_STORAGE_LOCATION "xfs"
        fi

        # Mount master NFS share
        echo "master:$SHARE_NFS $SHARE_NFS    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        mount -a
        mount | grep "^master:$SHARE_HOME"
    fi
}

# Downloads/builds/installs munged on the node.
# The munge key is generated on the master node and placed
# in the data share.
# Worker nodes copy the existing key from the data share.
#
install_munge()
{
    groupadd $MUNGE_GROUP

    useradd -M -c "Munge service account" -g munge -s /usr/sbin/nologin munge

    wget https://github.com/pnnl/cloudoffice/blob/master/hpc-cluster/rpms/rpms.tar?raw=true -O rpms.tar

    tar xvf rpms.tar

    mkdir -m 700 /etc/munge
    mkdir -m 711 /var/lib/munge
    mkdir -m 700 /var/log/munge
    mkdir -m 755 /var/run/munge

    yum localinstall -y munge*.rpm

    chown -R munge:munge /etc/munge /var/lib/munge /var/log/munge /var/run/munge

    if is_master; then
        dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
        mkdir -p $SLURM_CONF_DIR
        cp /etc/munge/munge.key $SLURM_CONF_DIR
        chmod 0644 $SLURM_CONF_DIR/munge.key
    else
        cp $SLURM_CONF_DIR/munge.key /etc/munge/munge.key
    fi

    chown munge:munge /etc/munge/munge.key
    chmod 0400 /etc/munge/munge.key

    systemctl enable munge.service
    systemctl start munge

    #cd ..
}

# Installs and configures slurm.conf on the node.
# This is generated on the master node and placed in the data
# share.  All nodes create a sym link to the SLURM conf
# as all SLURM nodes must share a common config file.
#
install_slurm_config()
{
    if is_master; then

        mkdir -p $SLURM_CONF_DIR

        if [ -e "$TEMPLATE_BASE_URL/slurm.template.conf" ]; then
            cp "$TEMPLATE_BASE_URL/slurm.template.conf" .
        else
            wget "$TEMPLATE_BASE_URL/slurm.template.conf"
        fi

        cat slurm.template.conf |
        sed 's/__MASTER__/'"$MASTER_HOSTNAME"'/g' |
                sed 's/__WORKER_HOSTNAME_PREFIX__/'"$WORKER_HOSTNAME_PREFIX"'/g' |
                sed 's/__WORKER_NPROC__/'"$WORKER_NPROC"'/g' |
                sed 's/__LAST_WORKER_INDEX__/'"$LAST_WORKER_INDEX"'/g' > $SLURM_CONF_DIR/slurm.conf
    fi

    ln -s $SLURM_CONF_DIR/slurm.conf /etc/slurm/slurm.conf
}

# Downloads, builds and installs SLURM on the node.
# Starts the SLURM control daemon on the master node and
# the agent on worker nodes.
#
install_slurm()
{
    groupadd -g $SLURM_GID $SLURM_GROUP

    useradd -M -u $SLURM_UID -c "SLURM service account" -g $SLURM_GROUP -s /usr/sbin/nologin $SLURM_USER

    mkdir -p /etc/slurm /var/spool/slurmd /var/run/slurmd /var/run/slurmctld /var/log/slurmd /var/log/slurmctld

    chown -R slurm:slurm /var/spool/slurmd /var/run/slurmd /var/run/slurmctld /var/log/slurmd /var/log/slurmctld


    yum localinstall -y slurm*.rpm
    install_slurm_config

    if is_master; then
        #wget $TEMPLATE_BASE_URL/slurmctld.service
        #mv slurmctld.service /usr/lib/systemd/system
        #systemctl daemon-reload
        systemctl enable slurmctld
        systemctl start slurmctld
        systemctl status slurmctld

        mkdir -p $SHARE_APPS/intel
        wget https://dtn2.pnl.gov/data/intel.tar
        tar xf intel.tar -C $SHARE_APPS/intel

        rpm --import https://packages.microsoft.com/keys/microsoft.asc
        sh -c 'echo -e "[azure-cli]\nname=Azure CLI\nbaseurl=https://packages.microsoft.com/yumrepos/azure-cli\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/azure-cli.repo'
        yum -y install azure-cli

        mkdir -p $SHARE_APPS/scripts/
        #wget hpctest.pem
        #mv hpctest.pem $SHARE_APPS/scripts/
        chown slurm:slurm $SHARE_APPS/scripts/hpctest.pem
        chmod 600 $SHARE_APPS/scripts/hpctest.pem
        wget $TEMPLATE_BASE_URL/scripts/resume_HPC_node.sh
        wget $TEMPLATE_BASE_URL/scripts/suspend_HPC_node.sh
        mv resume_HPC_node.sh $SHARE_APPS/scripts/
        mv suspend_HPC_node.sh $SHARE_APPS/scripts/
        chown slurm:slurm $SHARE_APPS/scripts/resume_HPC_node.sh
        chown slurm:slurm $SHARE_APPS/scripts/suspend_HPC_node.sh
        chmod 755 $SHARE_APPS/scripts/resume_HPC_node.sh
        chmod 755 $SHARE_APPS/scripts/suspend_HPC_node.sh

    else
      TEMPLATE_BASE_URL="https://raw.githubusercontent.com/pnnl/cloudoffice/master/hpc-cluster/"
        wget $TEMPLATE_BASE_URL/slurmd.service
        mv -f slurmd.service /usr/lib/systemd/system
        systemctl daemon-reload
        systemctl enable slurmd.service
        systemctl start slurmd
        systemctl status slurmd

        echo "$MASTER_IP master" >> /etc/hosts

    fi
    mkdir -p /share/apps/intel
    ln -s $SHARE_APPS/intel/2018 /share/apps/intel
    #cd ..
}

# Downloads and installs PBS Pro OSS on the node.
# Starts the PBS Pro control daemon on the master node and
# the mom agent on worker nodes.
#
install_pbsoss()
{
    yum install -y gcc make rpm-build libtool hwloc-devel \
      libX11-devel libXt-devel libedit-devel libical-devel \
      ncurses-devel perl postgresql-devel python-devel tcl-devel \
      tk-devel swig expat-devel openssl-devel libXext libXft \
      autoconf automake expat libedit postgresql-server python \
      sendmail tcl tk libical perl-Env perl-Switch

    # Required on 7.2 as the libical lib changed
    ln -s /usr/lib64/libical.so.1 /usr/lib64/libical.so.0

    wget http://wpc.23a7.iotacdn.net/8023A7/origin2/rl/PBS-Open/CentOS_7.zip
    unzip CentOS_7.zip
    cd CentOS_7
    rpm -ivh --nodeps pbspro-server-14.1.0-13.1.x86_64.rpm

    echo 'export PATH=/opt/pbs/default/bin:$PATH' >> /etc/profile.d/pbs.sh
    echo 'export PATH=/opt/pbs/default/sbin:$PATH' >> /etc/profile.d/pbs.sh

    if is_master; then
        cat > /etc/pbs.conf << EOF
PBS_SERVER=$MASTER_HOSTNAME
PBS_START_SERVER=1
PBS_START_SCHED=1
PBS_START_COMM=1
PBS_START_MOM=0
PBS_EXEC=/opt/pbs
PBS_HOME=/var/spool/pbs
PBS_CORE_LIMIT=unlimited
PBS_SCP=/bin/scp
EOF

        /etc/init.d/pbs start

        for i in $(seq 0 $LAST_WORKER_INDEX); do
            nodeName=${WORKER_HOSTNAME_PREFIX}${i}
            /opt/pbs/bin/qmgr -c "c n $nodeName"
        done

        # Enable job history
        /opt/pbs/bin/qmgr -c "s s job_history_enable = true"
        /opt/pbs/bin/qmgr -c "s s job_history_duration = 336:0:0"
    else
        cat > /etc/pbs.conf << EOF
PBS_SERVER=$MASTER_HOSTNAME
PBS_START_SERVER=0
PBS_START_SCHED=0
PBS_START_COMM=0
PBS_START_MOM=1
PBS_EXEC=/opt/pbs
PBS_HOME=/var/spool/pbs
PBS_CORE_LIMIT=unlimited
PBS_SCP=/bin/scp
EOF

        /etc/init.d/pbs start
    fi

    cd ..
}

install_scheduler()
{
    if [ "$SCHEDULER" == "Slurm" ]; then
        install_munge
        install_slurm
    elif [ "$SCHEDULER" == "PBSPro-OS" ]; then
        install_pbsoss
    else
        echo "Invalid scheduler specified: $SCHEDULER"
        exit 1
    fi
}

# Adds a common HPC user to the node and configures public key SSh auth.
# The HPC user has a shared home directory (NFS share on master) and access
# to the data share.
#
setup_hpc_user()
{
    # disable selinux
    sed -i 's/enforcing/disabled/g' /etc/selinux/config
    setenforce permissive

    groupadd -g $HPC_GID $HPC_GROUP

    # Don't require password for HPC user sudo
    echo "$HPC_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

    # Disable tty requirement for sudo
    sed -i 's/^Defaults[ ]*requiretty/# Defaults requiretty/g' /etc/sudoers

    if is_master; then
        mkdir -p $SHARE_HOME

        useradd -c "HPC User" -g $HPC_GROUP -m -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER

        mkdir -p $SHARE_HOME/$HPC_USER/.ssh

        # Configure public key auth for the HPC user
        ssh-keygen -t rsa -f $SHARE_HOME/$HPC_USER/.ssh/id_rsa -q -P ""
        cat $SHARE_HOME/$HPC_USER/.ssh/id_rsa.pub > $SHARE_HOME/$HPC_USER/.ssh/authorized_keys

        echo "Host *" > $SHARE_HOME/$HPC_USER/.ssh/config
        echo "    StrictHostKeyChecking no" >> $SHARE_HOME/$HPC_USER/.ssh/config
        echo "    UserKnownHostsFile /dev/null" >> $SHARE_HOME/$HPC_USER/.ssh/config
        echo "    PasswordAuthentication no" >> $SHARE_HOME/$HPC_USER/.ssh/config

        # Fix .ssh folder ownership
        chown -R $HPC_USER:$HPC_GROUP $SHARE_HOME/$HPC_USER

        # Fix permissions
        chmod 700 $SHARE_HOME/$HPC_USER/.ssh
        chmod 644 $SHARE_HOME/$HPC_USER/.ssh/config
        chmod 644 $SHARE_HOME/$HPC_USER/.ssh/authorized_keys
        chmod 600 $SHARE_HOME/$HPC_USER/.ssh/id_rsa
        chmod 644 $SHARE_HOME/$HPC_USER/.ssh/id_rsa.pub

    else
        useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER
    fi

    chown $HPC_USER:$HPC_GROUP $SHARE_CFS
}

# Sets all common environment variables and system parameters.
#
setup_env()
{
    # Set unlimited mem lock
    echo "$HPC_USER hard memlock unlimited" >> /etc/security/limits.conf
    echo "$HPC_USER soft memlock unlimited" >> /etc/security/limits.conf

    echo "$IMAGE_OFFER" | grep -q 'HPC$'
    if [ $? -eq 0 ]; then
        # Intel MPI config for IB
        echo "# IB Config for MPI" > /etc/profile.d/mpi.sh
        echo "export I_MPI_FABRICS=shm:dapl" >> /etc/profile.d/mpi.sh
        echo "export I_MPI_DAPL_PROVIDER=ofa-v2-ib0" >> /etc/profile.d/mpi.sh
        echo "export I_MPI_DYNAMIC_CONNECTION=0" >> /etc/profile.d/mpi.sh
    else
        yum install -y nfs-utils
        sed -i 's/GSS_USE_PROXY="yes"/GSS_USE_PROXY="no"/g' /etc/sysconfig/nfs

        # Enable reclaim mode
        cp /etc/sysctl.conf /tmp/sysctl.conf
        echo "vm.zone_reclaim_mode = 1" >> /tmp/sysctl.conf
        cp /tmp/sysctl.conf /etc/sysctl.conf
        sysctl -p

        # disable firewall
        systemctl stop firewalld
    fi
}

install_easybuild()
{
    if [ "$INSTALL_EASYBUILD" != "Yes" ]; then
        echo "Skipping EasyBuild install..."
        return 0
    fi

    yum -y install Lmod python-devel python-pip gcc gcc-c++ patch unzip tcl tcl-devel libibverbs libibverbs-devel
    pip install vsc-base

    EASYBUILD_HOME=$SHARE_HOME/$HPC_USER/EasyBuild

    if is_master; then
        su - $HPC_USER -c "pip install --install-option --prefix=$EASYBUILD_HOME https://github.com/hpcugent/easybuild-framework/archive/easybuild-framework-v2.5.0.tar.gz"

        # Add Lmod to the HPC users path
        echo 'export PATH=/usr/lib64/openmpi/bin:/usr/share/lmod/6.0.15/libexec:$PATH' >> $SHARE_HOME/$HPC_USER/.bashrc

        # Setup Easybuild configuration and paths
        echo 'export PATH=$HOME/EasyBuild/bin:$PATH' >> $SHARE_HOME/$HPC_USER/.bashrc
        echo 'export PYTHONPATH=$HOME/EasyBuild/lib/python2.7/site-packages:$PYTHONPATH' >> $SHARE_HOME/$HPC_USER/.bashrc
        echo "export MODULEPATH=$EASYBUILD_HOME/modules/all" >> $SHARE_HOME/$HPC_USER/.bashrc
        echo "export EASYBUILD_MODULES_TOOL=Lmod" >> $SHARE_HOME/$HPC_USER/.bashrc
        echo "export EASYBUILD_INSTALLPATH=$EASYBUILD_HOME" >> $SHARE_HOME/$HPC_USER/.bashrc
        echo "export EASYBUILD_DEBUG=1" >> $SHARE_HOME/$HPC_USER/.bashrc
        echo "source /usr/share/lmod/6.0.15/init/bash" >> $SHARE_HOME/$HPC_USER/.bashrc
    fi
}

install_cfs()
{
    if [ "$CFS" == "BeeGFS" ]; then
        wget -O beegfs-rhel7.repo http://www.beegfs.com/release/latest-stable/dists/beegfs-rhel7.repo
        mv beegfs-rhel7.repo /etc/yum.repos.d/beegfs.repo
        rpm --import http://www.beegfs.com/release/latest-stable/gpg/RPM-GPG-KEY-beegfs

        yum install -y beegfs-client beegfs-helperd beegfs-utils

        sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MASTER_HOSTNAME'/g' /etc/beegfs/beegfs-client.conf
        sed -i  's/Type=oneshot.*/Type=oneshot\nRestart=always\nRestartSec=5/g' /etc/systemd/system/multi-user.target.wants/beegfs-client.service
        echo "$SHARE_CFS /etc/beegfs/beegfs-client.conf" > /etc/beegfs/beegfs-mounts.conf

        if is_master; then
            yum install -y beegfs-mgmtd beegfs-meta
            mkdir -p /data/beegfs/mgmtd
            sed -i 's|^storeMgmtdDirectory.*|storeMgmtdDirectory = /data/beegfs/mgmt|g' /etc/beegfs/beegfs-mgmtd.conf
            sed -i 's|^storeMetaDirectory.*|storeMetaDirectory = '$BEEGFS_METADATA'|g' /etc/beegfs/beegfs-meta.conf
            sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MASTER_HOSTNAME'/g' /etc/beegfs/beegfs-meta.conf
            /etc/init.d/beegfs-mgmtd start
            /etc/init.d/beegfs-meta start
        else
            yum install -y beegfs-storage
            sed -i 's|^storeStorageDirectory.*|storeStorageDirectory = '$CFS_STORAGE_LOCATION'|g' /etc/beegfs/beegfs-storage.conf
            sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MASTER_HOSTNAME'/g' /etc/beegfs/beegfs-storage.conf
            /etc/init.d/beegfs-storage start
        fi

        systemctl daemon-reload
    fi
}

install_pkgs
setup_shares
setup_hpc_user
install_cfs
install_scheduler
setup_env
install_easybuild
shutdown -r +1 &
exit 0
