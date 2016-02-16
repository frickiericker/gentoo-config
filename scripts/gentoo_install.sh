#!/bin/sh -efux
#------------------------------------------------------------------------------
# Minimal installation script of Gentoo Linux with systemd support.
#
# == Note ==
#
# You must change UPPERCASE_VARIABLES defined in this script to match your
# hardware and network.
#
# == Usage ==
#
# Change UPPERCASE_VARIABLES defined in this script to match your hardware and
# network, and put it in a USB thumb drive or something. Then boot livecd with
# nodhcp option. Copy the modified script in the /root of the livecd shell and
# execute it as follows:
#
#   livecd ~ # sh gentoo_install.sh
#
# Then, reboot into the installed Gentoo Linux, login as root and issue
#
#   ~ # sh gentoo_install.sh postinstall
#
# to finish minimal installation. After this, you may want to rebuild kernel,
# add USE flags to make.conf, install portages, enable services, etc. to
# create your own Gentoo Linux environment.
#------------------------------------------------------------------------------
set -efux
export LANG=C LC_ALL=C

# Portage parameters
MIRROR='http://ftp.jaist.ac.jp/pub/Linux/Gentoo'
PORTAGE_PROFILE='default/linux/amd64/13.0/systemd'
PORTAGE_FEATURES='buildpkg'
CPU=haswell
NJOBS=40

# Disk layout
BOOTSIZE=128    # MiB
SWAPSIZE=65536  # MiB

# Network settings
NETIF=enp5s0
HOSTNAME=xeon01
DOMAIN=cse.example.com
IPV4=192.168.100.161/24
GATEWAY=192.168.100.1
DNS=192.168.100.58
SYSTEMD_NETWORK_UNIT='50-labnet.network'

# Locale settings
KEYMAP=us
TIMEZONE=Asia/Tokyo

# Settings used in the installation process
DISK=sda
ROOT='/mnt/gentoo'
STAGE3_BASE="${MIRROR}/releases/amd64/autobuilds/20160204"
STAGE3="${STAGE3_BASE}/stage3-amd64-20160204.tar.bz2"
INSTALLER_NTP=jp.pool.ntp.org

#------------------------------------------------------------------------------
# Entry Points
#------------------------------------------------------------------------------

install() {
    phase1_prepare_stage3
    phase2_install_system
}

postinstall() {
    phase3_postinstall
}

#------------------------------------------------------------------------------
# Phase 1
#
# Phase 1 sets up network connection for installation, formats the target disk,
# and creates stage3 environment on the root filesystem on the target disk.
#------------------------------------------------------------------------------

phase1_prepare_stage3() {
    phase1_setup_network
    phase1_adjust_time
    phase1_initialize_disk
    phase1_mount_root
    phase1_extract_stage3
    phase1_install_configuration_files
}

#
# Sets up network connection for this installation process.
#
phase1_setup_network() {
    # There may already be a working network connection thanks to dhcpcd
    # launched by the installation cd.
    if ! ping -c 1 -nq ${GATEWAY}
    then
        # Set up temporary network using production setting. Requires the
        # nodhcp option on livecd boot.
        address=${IPV4%/*}
        netmask=$(make_netmask ${IPV4#*/})
        service dhcpcd stop || true
        ifconfig ${NETIF} down || true
        ifconfig ${NETIF} ${address} netmask ${netmask} up
        route add default gw ${GATEWAY}
    fi
    echo "nameserver ${DNS}" > /etc/resolv.conf
}

#
# Adjusts system time for installation.
#
phase1_adjust_time() {
    ntpdate ${INSTALLER_NTP}
}

#
# Sets up GPT partition table on ${DISK} as follows:
#
#   ${DISK}1    BIOS GRUB partition (3 MiB)
#   ${DISK}2    Boot partition (${BOOTSIZE} MiB)
#   ${DISK}3    Swap (${SWAPSIZE} MiB)
#   ${DISK}4    Root partition (Rest of the disk)
#
phase1_initialize_disk() {
    # Calculate the layout (begin & end pair for each partition) from partition
    # size.
    bios_beg=1
    bios_end=4
    boot_beg=${bios_end}
    boot_end=$(( ${boot_beg} + ${BOOTSIZE} ))
    swap_beg=${boot_end}
    swap_end=$(( ${swap_beg} + ${SWAPSIZE} ))
    root_beg=${swap_end}
    root_end=-1

    # Create GPT partition table.
    parted -s -- /dev/${DISK} mklabel gpt
    mkpart ${bios_beg}MiB ${bios_end}MiB name 1 grub set 1 bios_grub on
    mkpart ${boot_beg}MiB ${boot_end}MiB name 2 boot set 2 boot on
    mkpart ${swap_beg}MiB ${swap_end}MiB name 3 swap
    mkpart ${root_beg}MiB ${root_end}MiB name 4 root
}

mkpart() {
    parted -s -- /dev/${DISK} mkpart primary "$@"
}

#
# Creates filesystems on the boot and root partitions of ${DISK} and mounts the
# created filesystems on ${ROOT}.
#
# Note: Do not forget to update phase1_install_fstab if you change filesystems.
#
phase1_mount_root() {
    mkfs.ext2 /dev/${DISK}2
    mkswap    /dev/${DISK}3
    mkfs.ext4 /dev/${DISK}4
    mount /dev/${DISK}4 "${ROOT}"
    mkdir               "${ROOT}/boot"
    mount /dev/${DISK}2 "${ROOT}/boot"
}

#
# Downloads and extracts the stage3 archive onto the disk.
#
phase1_extract_stage3() {
    curdir="$(pwd)"
    cd "${ROOT}"
    wget "${STAGE3}"
    tar xjpf "${STAGE3##*/}" --xattrs
    cd "${curdir}"
}

#
# Installs configuration files.
#
phase1_install_configuration_files() {
    phase1_install_makeconf
    phase1_install_localegen
    phase1_install_fstab
    phase1_install_resolvconf
    phase1_install_portage_repos
}

phase1_install_makeconf() {
    cat > "${ROOT}/etc/portage/make.conf" << _END_
# General settings
FEATURES="\${FEATURES} ${PORTAGE_FEATURES}"

# Network
GENTOO_MIRRORS="${MIRROR}"

# Resource
PORTAGE_NICENESS=19
PORTAGE_IONICE_COMMAND="ionice -c 2 -n 7 -p \\\${PID}"
MAKEOPTS="-j ${NJOBS} -l ${NJOBS}"
EMERGE_DEFAULT_OPTS="--jobs=${NJOBS} --load-average=${NJOBS}"

# Compiler flags
CFLAGS='-O2 -pipe -march=${CPU}'
CXXFLAGS="\${CFLAGS}"
FFLAGS="\${CFLAGS}"
FCFLAGS="\${CFLAGS}"
_END_
}

phase1_install_localegen() {
    cat > "${ROOT}/etc/locale.gen" << _END_
en_US		ISO-8859-1
en_US.UTF-8	UTF-8
_END_
}

phase1_install_fstab() {
    cat > "${ROOT}/etc/fstab" << _END_
/dev/sda2	/boot	ext2	defaults,noatime	0 2
/dev/sda3	none	swap	sw			0 0
/dev/sda4	/	ext4	noatime			0 1
_END_
}

phase1_install_resolvconf() {
    # Use the same nameserver settings as that used in this installation
    # process. Do not put network service unit because we do not have systemd
    # installed yet.
    cp /etc/resolv.conf "${ROOT}/etc/resolv.conf"
}

phase1_install_portage_repos() {
    # Use standard portage repository.
    mkdir "${ROOT}/etc/portage/repos.conf"
    cp "${ROOT}/usr/share/portage/config/repos.conf" \
       "${ROOT}/etc/portage/repos.conf/gentoo.conf"
}

#------------------------------------------------------------------------------
# Phase 2
#
# Phase 2 chroots into ${ROOT} and installs world, kernel and bootloader, then
# sets up some compornents needed for boot.
#------------------------------------------------------------------------------

phase2_install_system() {
    phase2_mount_pseudo_filesystems
    phase2_install_world
    phase2_install_kernel
    phase2_install_bootloader
    phase2_install_locale
    phase2_install_hostinfo
    phase2_install_systemd_files
    phase2_set_password
    phase2_install_installer
}

#
# Mounts pseudo filesystems on the target root so that we can chroot into the
# target tree and continue installation.
#
phase2_mount_pseudo_filesystems() {
    mount -t proc proc "${ROOT}/proc"
    mount --rbind /sys "${ROOT}/sys" && mount --make-rslave "${ROOT}/sys"
    mount --rbind /dev "${ROOT}/dev" && mount --make-rslave "${ROOT}/dev"
}

#
# Emerges world. This will install systemd (if a systemd profile is used).
#
phase2_install_world() {
    chroot "${ROOT}" emerge-webrsync
    chroot "${ROOT}" eselect profile set "${PORTAGE_PROFILE}"
    chroot "${ROOT}" emerge -uDN @world
}

#
# Emerges kernel sources, launches menuconfig, and builds kenrnel.
#
phase2_install_kernel() {
    # Use installer's kernel configuration (plus systemd support)
    kernconf='/root/kernel.conf'
    zcat /proc/config.gz > "${ROOT}${kernconf}"
    cat >> "${ROOT}${kernconf}" << _END_
CONFIG_GENTOO_LINUX_INIT_SYSTEMD=y
CONFIG_AUDIT=y
CONFIG_CGROUPS=y
CONFIG_FANOTIFY=y
CONFIG_AUTOFS4_FS=y
_END_
    #
    chroot "${ROOT}" emerge sys-kernel/gentoo-sources
    chroot "${ROOT}" emerge sys-kernel/genkernel-next
    #
    chroot "${ROOT}" genkernel --kernel-config="${kernconf}" \
                               --makeopts="-j ${NJOBS}"      \
                               all
}

#
# Installs GRUB into the target disk.
#
phase2_install_bootloader() {
    chroot "${ROOT}" emerge sys-boot/grub
    chroot "${ROOT}" grub2-install /dev/${DISK}
    echo 'GRUB_CMDLINE_LINUX="init=/usr/lib/systemd/systemd"' \
         >> "${ROOT}/etc/default/grub"
    chroot "${ROOT}" grub2-mkconfig -o /boot/grub/grub.cfg
}

#
# Installs locale files. The C locale is eselected.
#
phase2_install_locale() {
    chroot "${ROOT}" locale-gen
    chroot "${ROOT}" eselect locale set C
}

#
# Installs hostname-related files.
#
phase2_install_hostinfo() {
    # Set hostname
    echo "${HOSTNAME}" > /etc/hostname

    # Register external IP address of this machine to the hosts database
    cat > /etc/hosts << _END_
${IPV4%/*}	${HOSTNAME} ${HOSTNAME}.${DOMAIN}
128.0.0.1	localhost
::1		localhost
_END_
}

#
# Installs systemd-related files.
#
phase2_install_systemd_files() {
    phase2_install_network_service_unit
}

phase2_install_network_service_unit() {
    cat > "${ROOT}/etc/systemd/network/${SYSTEMD_NETWORK_UNIT}" << _END_
[Match]
Name=${NETIF}

[Network]
Address=${IPV4}
Gateway=${GATEWAY}
DNS=${DNS}
_END_
}

#
# Sets root password of the production system.
#
phase2_set_password() {
    # TODO: automate with chpasswd -e
    chroot "${ROOT}" passwd
}

#
# Copy this script into the production /root so that we can continue to phase
# 3 postionstall after bootup.
#
phase2_install_installer() {
    cp "$0" "${ROOT}/root"
}

#------------------------------------------------------------------------------
# Phase 3
#
# Phase 3 configures some systemd services and parameters in the production
# environment. This postinstallation process is required since livecd does not
# run systemd.
#------------------------------------------------------------------------------

phase3_postinstall() {
    phase3_configure_network
    phase3_configure_misc
}

phase3_configure_network() {
    systemctl enable systemd-networkd.service
    systemctl start systemd-networkd.service
}

phase3_configure_misc() {
    localectl set-locale LANG=C
    localectl set-keymap ${KEYMAP}
    localectl set-x11-keymap ${KEYMAP}

    timedatectl set-timezone ${TIMEZONE}
    timedatectl set-ntp true
}

#------------------------------------------------------------------------------
# Utilities
#------------------------------------------------------------------------------

#
# Prints error message and terminates the script.
#
errx() {
    echo "$@" >&2
    exit 1
}

#
# Returns IPv4 netmask for given prefix length.
#
make_netmask() {
    case $1 in
    16) echo 255.255.0.0    ;;
    24) echo 255.255.255.0  ;;
    *)  errx FIXME
    esac
}

#------------------------------------------------------------------------------

${1:-install}
