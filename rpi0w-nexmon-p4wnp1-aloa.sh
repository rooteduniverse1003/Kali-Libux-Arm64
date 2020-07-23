#!/bin/bash
set -e

######
# This is a work in progress script for P4wnP1 A.L.O.A. based on @binkybear's built script for P4wnP1
#
##########

# Doesn't currently work, so lets just exit.
echo "This script is currently in need of work, porting to the new URLs, as well as the new setup."
exit 1

# Uncomment to activate debug
# debug=true

if [ "$debug" = true ]; then
  exec > >(tee -a -i "${0%.*}.log") 2>&1
  set -x
fi

# Architecture
architecture=${architecture:-"armel"}
# Generate a random machine name to be used.
machine=$(tr -cd 'A-Za-z0-9' < /dev/urandom | head -c16 ; echo)
# Custom hostname variable
hostname=${2:-kali}
# Custom image file name variable - MUST NOT include .img at the end.
imagename=${3:-kali-linux-$1-rpi0w-p4wnp1}
# Suite to use, valid options are:
# kali-rolling, kali-dev, kali-bleeding-edge, kali-dev-only, kali-experimental, kali-last-snapshot
suite=${suite:-"kali-rolling"}
# Free space rootfs in MiB
free_space="300"
# /boot partition in MiB
bootsize="128"
# If you have your own preferred mirrors, set them here.
mirror="http://kali.download/kali"
# Gitlab url Kali repository
kaligit="https://gitlab.com/kalilinux"
# Github raw url
githubraw="https://raw.githubusercontent.com"

# Check EUID=0 you can run any binary as root.
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

# Pass version number
if [[ $# -eq 0 ]] ; then
  echo "Please pass version number, e.g. $0 2.0, and (if you want) a hostname, default is kali"
  exit 0
fi

# Check exist bsp directory.
if [ ! -e "bsp" ]; then
  echo "Error: missing bsp directory structure"
  echo "Please clone the full repository ${kaligit}/build-scripts/kali-arm"
  exit 255
fi

# Current directory
current_dir="$(pwd)"
# Base directory
basedir=${current_dir}/rpi0w-p4wnp1-"$1"
# Working directory
work_dir="${basedir}/kali-${architecture}"

# Check directory build
if [ -e "${basedir}" ]; then
  echo "${basedir} directory exists, will not continue"
  exit 1
elif [[ ${current_dir} =~ [[:space:]] ]]; then
  echo "The directory "\"${current_dir}"\" contains whitespace. Not supported."
  exit 1
else
  echo "The basedir thinks it is: ${basedir}"
  mkdir -p ${basedir}
fi

components="main,contrib,non-free"
arm="fake-hwclock ntpdate u-boot-tools"
tools="aircrack-ng crunch cewl dnsrecon dnsutils ethtool exploitdb hydra medusa metasploit-framework ncrack nmap passing-the-hash proxychains recon-ng sqlmap tcpdump theharvester tor tshark usbutils whois windows-binaries winexe wpscan"
base="apt-transport-https apt-utils console-setup e2fsprogs firmware-linux firmware-realtek firmware-atheros ifupdown initramfs-tools iw kali-defaults man-db mlocate netcat-traditional net-tools parted psmisc rfkill screen snmpd snmp tftp tmux unrar usbutils vim wget zerofree"
services="apache2 atftpd openssh-server openvpn"
# haveged: assure enough entropy data for hostapd on startup
# avahi-daemon: allow mDNS resolution (apple bonjour) by remote hosts
# dhcpcd5: REQUIRED (P4wnP1 A.L.O.A. currently wraps this binary if a DHCP client is needed)
# dnsmasq: REQUIRED (P4wnP1 A.L.O.A. currently wraps this binary if a DHCP server is needed, currently not used for DNS)
# genisoimage: allow creation of CD-Rom iso images for CD-Rom USB gadget from existing folders on the fly
# iodine: allow DNS tunneling
# dosfstools: contains fatlabel (used to label FAT32 iamges for UMS)
# Note on Go: The golang package is version 1.10, so we are missing support for current gopherjs (webclient couldn't be build on Pi) and go modules (replacement for dep)
extras="autossh avahi-daemon bash-completion bluez bluez-firmware dhcpcd5 dnsmasq dosfstools genisoimage golang haveged hostapd i2c-tools iodine policykit-1 python3-configobj python3-dev python3-pip python3-requests python3-smbus wpasupplicant"

packages="${arm} ${base} ${services} ${extras}"

# Check to ensure that the architecture is set to ARMEL since the RPi is the
# only board that is armel.
if [[ ${architecture} != "armel" ]] ; then
    echo "The Raspberry Pi cannot run Debian armhf binaries"
    exit 0
fi

# Automatic configuration to use an http proxy, such as apt-cacher-ng.
# You can turn off automatic settings by uncommenting apt_cacher=off.
# apt_cacher=off
# By default the proxy settings are local, but you can define an external proxy.
# proxy_url="http://external.intranet.local"
apt_cacher=${apt_cacher:-"$(lsof -i :3142|cut -d ' ' -f3 | uniq | sed '/^\s*$/d')"}
if [ -n "$proxy_url" ]; then
  export http_proxy=$proxy_url
elif [ "$apt_cacher" = "apt-cacher-ng" ] ; then
  if [ -z "$proxy_url" ]; then
    proxy_url=${proxy_url:-"http://127.0.0.1:3142/"}
    export http_proxy=$proxy_url
  fi
fi

# create the rootfs - not much to modify here, except maybe throw in some more packages if you want.
debootstrap --foreign --keyring=/usr/share/keyrings/kali-archive-keyring.gpg --include=kali-archive-keyring \
  --components=${components} --include=${arm// /,} --arch ${architecture} ${suite} ${work_dir} http://http.kali.org/kali

# systemd-nspawn enviroment
systemd-nspawn_exec(){
  qemu_bin=/usr/bin/qemu-aarch64-static
  LANG=C systemd-nspawn -q --bind-ro ${qemu_bin} -M ${machine} -D ${work_dir} "$@"
}

# debootstrap second stage
systemd-nspawn_exec /debootstrap/debootstrap --second-stage

cat << EOF > ${work_dir}/etc/apt/sources.list
deb ${mirror} ${suite} ${components//,/ }
#deb-src ${mirror} ${suite} ${components//,/ }
EOF

# Set hostname
echo "${hostname}" > ${work_dir}/etc/hostname

# So X doesn't complain, we add kali to hosts
cat << EOF > ${work_dir}/etc/hosts
127.0.0.1       ${hostname}    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# Disable IPv6
cat << EOF > ${work_dir}/etc/modprobe.d/ipv6.conf
# Don't load ipv6 by default
alias net-pf-10 off
EOF

cat << EOF > ${work_dir}/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
EOF

# DNS server
echo "nameserver 8.8.8.8" > ${work_dir}/etc/resolv.conf

# Copy directory bsp into build dir.
cp -rp bsp ${work_dir}

export MALLOC_CHECK_=0 # workaround for LP: #520465

# Enable the use of http proxy in third-stage in case it is enabled.
if [ -n "$proxy_url" ]; then
  echo "Acquire::http { Proxy \"$proxy_url\" };" > ${work_dir}/etc/apt/apt.conf.d/66proxy
fi


# Copy a default config, with everything commented out so people find it when
# they go to add something when they are following instructions on a website.
cp "${basedir}"/../bsp/firmware/rpi/config.txt ${work_dir}/boot/config.txt

# move P4wnP1 in (change to release blob when ready)
git clone  -b 'v0.1.0-alpha2' --single-branch --depth 1  https://github.com/mame82/P4wnP1_aloa ${work_dir}/root/P4wnP1

cat << EOF > kali-${architecture}/third-stage
#!/bin/bash
set -e
dpkg-divert --add --local --divert /usr/sbin/invoke-rc.d.chroot --rename /usr/sbin/invoke-rc.d
cp /bin/true /usr/sbin/invoke-rc.d
echo -e "#!/bin/sh\nexit 101" > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d

apt-get update
apt-get --yes --allow-change-held-packages install locales-all

debconf-set-selections /debconf.set
rm -f /debconf.set
apt-get update
apt-get -y install git-core binutils ca-certificates initramfs-tools u-boot-tools
apt-get -y install locales console-common less nano git
echo "root:toor" | chpasswd
rm -f /etc/udev/rules.d/70-persistent-net.rules
export DEBIAN_FRONTEND=noninteractive
apt-get --yes --allow-change-held-packages -o dpkg::options::=--force-confnew install ${packages} || apt-get --yes --fix-broken install
apt-get --yes --allow-change-held-packages -o dpkg::options::=--force-confnew install ${desktop} ${tools} || apt-get --yes --fix-broken install
apt-get --yes --allow-change-held-packages -o dpkg::options::=--force-confnew dist-upgrade
apt-get --yes --allow-change-held-packages -o dpkg::options::=--force-confnew autoremove

# Because copying in authorized_keys is hard for people to do, let's make the
# image insecure and enable root login with a password.
echo "Allow root login..."
sed -i -e 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# Create monitor mode start/remove
# The script returns an error code if the monitor interface couldn't be started
# Note: Removing this should be considered, as enabling the monitor interface once
# and using wpa_supplicant afterwards, crashs the WiFi firmware (even if the monitor
# interface is removed). Afterwards the 'brcmfmac' module has to be removed and
# loaded again (the driver push the firmware and restarts the fmac chip on init).
# Sometimes only a reboot works
install -m755 /bsp/scripts/monstart /usr/bin/
install -m755 /bsp/scripts/monstop /usr/bin/
install -m755 /bsp/scripts/rpi-resizerootfs /usr/sbin/

install -m644 /bsp/services/all/*.service /etc/systemd/system/
install -m644 /bsp/services/rpi/*.service /etc/systemd/system/

# Bluetooth enabling
install -m644 /bsp/bluetooth/rpi/50-bluetooth-hci-auto-poweron.rules /etc/udev/rules.d/

# Regenerated the shared-mime-info database on the first boot
# since it fails to do so properly in a chroot.
systemctl enable smi-hack

# Resize FS on first run (hopefully)
systemctl enable rpi-resizerootfs

# Generate SSH host keys on first run
systemctl enable regenerate_ssh_host_keys
# Enable sshd
systemctl enable ssh

# Install and hold pi-bluetooth deb package from re4son
dpkg --force-all -i /bsp/bluetooth/rpi/pi-bluetooth+re4son_2.2_all.deb
apt-mark hold pi-bluetooth+re4son

# systemd version 232 and above breaks execution of above bluetooth rule, let's fix that
sed -i 's/^RestrictAddressFamilies=AF_UNIX AF_NETLINK AF_INET AF_INET6.*/RestrictAddressFamilies=AF_UNIX AF_NETLINK AF_INET AF_INET6 AF_BLUETOOTH/' /lib/systemd/system/systemd-udevd.service

# Enable bluetooth
systemctl unmask bluetooth.service
systemctl enable bluetooth
systemctl enable hciuart
# dhcpcd is needed by P4wnP1, but started on demand
# installation of dhcpcd5 package enables a systemd unit starting dhcpcd for all
# interfaces, which results in conflicts with DHCP servers running on created
# bridge interface (especially for the bteth BNEP bridge). To avoid this we
# disable the service. If communication problems occur, although DHCP leases
# are handed out by dnsmasq, dhcpcd should be the first place to look
# (no interface should hava an APIPA addr assigned, unless the DHCP client
# was explcitely enabled by P4wnP1 for this interface)
systemctl disable dhcpcd

# enable fake-hwclock (P4wnP1 is intended to reboot/loose power frequently without getting NTP access in between)
# a clean shutdown/reboot is needed, as fake-hwclock service saves time on stop
systemctl enable fake-hwclock

# Create cmdline.txt file
mkdir -p /boot
echo "dwc_otg.lpm_enable=0 console=serial0,115200 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext3 elevator=deadline fsck.repair=yes rootwait" > /boot/cmdline.txt

# Install P4wnP1 A.L.O.A.
cd /root/P4wnP1
make installkali

# add Designware DUAL role USB driver to loaded modules
echo "dwc2" | tee -a /etc/modules

# allow root login from tyyGS0 (serial device for USB gadget)
echo ttyGS0 >> /etc/securetty

# add minutely cronjob to update fake-hwclock
echo '* * * * * root /usr/sbin/fake-hwclock' >> /etc/crontab

# Turn off kernel dmesg showing up in console since rpi0 only uses console
echo "dmesg -D" > /etc/rc.local
echo "exit 0" >> /etc/rc.local

# Copy bashrc
cp  /etc/skel/.bashrc /root/.bashrc

cd /root
apt download -o APT::Sandbox::User=root ca-certificates 2>/dev/null

# Fix startup time from 5 minutes to 15 secs on raise interface wlan0
sed -i 's/^TimeoutStartSec=5min/TimeoutStartSec=15/g' "/lib/systemd/system/networking.service"

rm -f /usr/sbin/policy-rc.d
rm -f /usr/sbin/invoke-rc.d
dpkg-divert --remove --rename /usr/sbin/invoke-rc.d

rm -f /third-stage
EOF

chmod 755 kali-${architecture}/third-stage
LANG=C systemd-nspawn -M ${machine} -D kali-${architecture} /third-stage
if [[ $? > 0 ]]; then
  echo "Third stage failed"
  exit 1
fi

cat << EOF > kali-${architecture}/cleanup
#!/bin/bash
rm -rf /root/.bash_history
rm -rf /root/P4wnP1_go
apt-get update
apt-get clean
rm -f /0
rm -f /hs_err*
rm -f cleanup
rm -f /usr/bin/qemu*
EOF

chmod 755 kali-${architecture}/cleanup
LANG=C systemd-nspawn -M ${machine} -D kali-${architecture} /cleanup

# Enable login over serial
echo "T0:23:respawn:/sbin/agetty -L ttyAMA0 115200 vt100" >> ${work_dir}/etc/inittab

cat << EOF > ${work_dir}/etc/apt/sources.list
deb http://http.kali.org/kali kali-rolling main non-free contrib
deb-src http://http.kali.org/kali kali-rolling main non-free contrib
EOF

# Uncomment this if you use apt-cacher-ng otherwise git clones will fail.
#unset http_proxy

# Kernel section. If you want to use a custom kernel, or configuration, replace
# them in this section.

cd ${TOPDIR}

# RPI Firmware
git clone --depth 1 https://github.com/raspberrypi/firmware.git rpi-firmware
cp -rf rpi-firmware/boot/* ${work_dir}/boot/
# copy over Pi specific libs (video core) and binaries (dtoverlay,dtparam ...)
cp -rf rpi-firmware/opt/* ${work_dir}/opt/
rm -rf rpi-firmware

# Build nexmon firmware outside the build system, if we can (use repository with driver and firmware for P4wnP1).
cd "${basedir}"
git clone https://github.com/mame82/nexmon_wifi_covert_channel.git -b p4wnp1 "${basedir}"/nexmon --depth 1

# Setup build
cd ${TOPDIR}
# Re4son kernel 4.14.80 with P4wnP1 patches (dwc2 and brcmfmac)
git clone --depth 1 https://github.com/Re4son/re4son-raspberrypi-linux -b rpi-4.14.80-re4son-p4wnp1 ${work_dir}/usr/src/kernel


cd ${work_dir}/usr/src/kernel

# Note: Compiling the kernel in /usr/src/kernel of the target file system is problematic, as the binaries of the compiling host architecture
# get deployed to the /usr/src/kernel/scripts subfolder (in this case linux-x64 binaries), which is symlinked to /usr/src/build later on.
# This would f.e. hinder rebuilding single modules, like nexmon's brcmfmac driver, on the Pi itself (online compilation).
# The cause:building of modules relies on the pre-built binaries in /usr/src/build folder. But the helper binaries are compiled with the
# HOST toolchain and not with the crosscompiler toolchain (f.e. /usr/src/kernel/script/basic/fixdep would end up as x64 binary, as this helper
# is not compiled with the CROSS toolchain). As those scripts are used druing module build, it wouldn't work to build on the pi, later on,
# without recompiling the helper binaries with the proper crosscompiler toolchain.
#
# To account for that, the 'script' subfolder could be rebuild on the target (online) by running `make scripts/` from /usr/src/kernel folder.
# Rebuilding the script, again, depends on additional tooling, like `bc` binary, which has to be installed.
#
# Currently the step of recompiling the kernel/scripts folder has to be done manually online, but it should be possible to do it after kernel
# build, by setting the host compiler (CC) to the gcc of the linaro-arm-linux-gnueabihf-raspbian-x64 toolchain (not only the CROSS_COMPILE).
# The problem is, that the used linaro toolchain builds for armhf (not a problem for kernel, as there're no dependencies on hf librearies),
# but the debian packages (and the provided gcc) are armel.
#
# To clean up this whole "armel" vs "armhf" mess, the kernel should be compiled with a armel toolchain (best choice would be the toolchain
# which is used to build the kali armel packages itself, which is hopefully available for linux-x64)
#
# For now this is left as manual step, as the normal user shouldn't have a need to recompile kernel parts on the Pi itself.


# Set default defconfig
export ARCH=arm
# use hard float with RPi cross compiler toolchain, as described here: https://www.raspberrypi.org/documentation/linux/kernel/building.md
export CROSS_COMPILE=arm-linux-gnueabi-

# Set default defconfig
make re4son_pi1_defconfig

# Build kernel
make -j $(grep -c processor /proc/cpuinfo)

# Make kernel modules
make modules_install INSTALL_MOD_PATH=${work_dir}

# Copy kernel to boot
perl scripts/mkknlimg --dtok arch/arm/boot/zImage ${work_dir}/boot/kernel.img
cp arch/arm/boot/dts/*.dtb ${work_dir}/boot/
cp arch/arm/boot/dts/overlays/*.dtb* ${work_dir}/boot/overlays/
cp arch/arm/boot/dts/overlays/README ${work_dir}/boot/overlays/

make mrproper
make re4son_pi1_defconfig

# Fix up the symlink for building external modules
# kernver is used so we don't need to keep track of what the current compiled
# version is
kernver=$(ls ${work_dir}/lib/modules/)
cd ${work_dir}/lib/modules/${kernver}
rm build
rm source
ln -s /usr/src/kernel build
ln -s /usr/src/kernel source
cd "${basedir}"

# Copy a default config, with everything commented out so people find it when
# they go to add something when they are following instructions on a website.
cp "${basedir}"/../bsp/firmware/rpi/config.txt ${work_dir}/boot/config.txt

cat << EOF >> ${work_dir}/boot/config.txt
dtoverlay=dwc2
EOF

# systemd doesn't seem to be generating the fstab properly for some people, so
# let's create one.
cat << EOF > ${work_dir}/etc/fstab
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
proc            /proc           proc    defaults          0       0
/dev/mmcblk0p1  /boot           vfat    defaults          0       2
/dev/mmcblk0p2  /               ext3    defaults,noatime  0       1
EOF


# rpi-wiggle
mkdir -p ${work_dir}/root/scripts
wget https://raw.github.com/steev/rpiwiggle/master/rpi-wiggle -O ${work_dir}/root/scripts/rpi-wiggle.sh
chmod 755 ${work_dir}/root/scripts/rpi-wiggle.sh

# git clone of nexmon moved in front of kernel compilation, to have poper brcmfmac driver ready
cd "${basedir}"/nexmon
# Make sure we're not still using the armel cross compiler
unset CROSS_COMPILE

# Disable statistics
touch DISABLE_STATISTICS
source setup_env.sh
make
cd buildtools/isl-0.10
CC=$CCgcc
./configure
make
sed -i -e 's/all:.*/all: $(RAM_FILE)/g' ${NEXMON_ROOT}/patches/bcm43430a1/7_45_41_46/nexmon/Makefile
cd ${NEXMON_ROOT}/patches/bcm43430a1/7_45_41_46/nexmon
make clean
# We do this so we don't have to install the ancient isl version into /usr/local/lib on systems.
LD_LIBRARY_PATH=${NEXMON_ROOT}/buildtools/isl-0.10/.libs make ARCH=arm CC=${NEXMON_ROOT}/buildtools/gcc-arm-none-eabi-5_4-2016q2-linux-x86/bin/arm-none-eabi-
# RPi0w->3B firmware
# disable nexmon by default
mkdir -p ${work_dir}/lib/firmware/brcm
cp ${NEXMON_ROOT}/patches/bcm43430a1/7_45_41_46/nexmon/brcmfmac43430-sdio.bin ${work_dir}/lib/firmware/brcm/brcmfmac43430-sdio.nexmon.bin
cp ${NEXMON_ROOT}/patches/bcm43430a1/7_45_41_46/nexmon/brcmfmac43430-sdio.bin ${work_dir}/lib/firmware/brcm/brcmfmac43430-sdio.bin
wget https://raw.githubusercontent.com/RPi-Distro/firmware-nonfree/master/brcm/brcmfmac43430-sdio.txt -O ${work_dir}/lib/firmware/brcm/brcmfmac43430-sdio.txt
# Make a backup copy of the rpi firmware in case people don't want to use the nexmon firmware.
# The firmware used on the RPi is not the same firmware that is in the firmware-brcm package which is why we do this.
wget https://raw.githubusercontent.com/RPi-Distro/firmware-nonfree/master/brcm/brcmfmac43430-sdio.bin -O ${work_dir}/lib/firmware/brcm/brcmfmac43430-sdio.rpi.bin
#cp ${work_dir}/lib/firmware/brcm/brcmfmac43430-sdio.rpi.bin ${work_dir}/lib/firmware/brcm/brcmfmac43430-sdio.bin

cp "${basedir}"/../bsp/firmware/rpi/BCM43430A1.hcd ${work_dir}/lib/firmware/brcm/BCM43430A1.hcd

cd "${basedir}"

sed -i -e 's/^#PermitRootLogin.*/PermitRootLogin yes/' ${work_dir}/etc/ssh/sshd_config

# Calculate the space to create the image.
free_space=$((${free_space}*1024))
bootstart=$((${bootsize}*1024/1000*2*1024/2))
bootend=$((${bootstart}+1024))
rootsize=$(du -s --block-size KiB ${work_dir} --exclude boot | cut -f1)
rootsize=$((${free_space}+${rootsize//KiB/ }/1000*2*1024/2))
raw_size=$((${free_space}+${rootsize}+${bootstart}))

# Create the disk and partition it
echo "Creating image file ${imagename}.img"
dd if=/dev/zero of=${basedir}/${imagename}.img bs=1KiB count=0 seek=${raw_size} && sync
parted "${basedir}"/${imagename}.img --script -- mklabel msdos
parted "${basedir}"/${imagename}.img --script -- mkpart primary fat32 1MiB ${bootstart}KiB
parted "${basedir}"/${imagename}.img --script -- mkpart primary ext3 ${bootend}KiB 100%

# Set the partition variables
bootp="$(losetup -o 1MiB --sizelimit ${bootstart}KiB -f --show ${basedir}/${imagename}.img)"
rootp="$(losetup -o ${bootend}KiB --sizelimit ${raw_size}KiB -f --show ${basedir}/${imagename}.img)"

# Create file systems
mkfs.vfat -n BOOT -F 32 -v ${bootp}
mkfs.ext3 -L ROOTFS -O ^64bit,^flex_bg,^metadata_csum ${rootp}

# Create the dirs for the partitions and mount them
mkdir -p ${basedir}/root/
mount ${rootp} ${basedir}/root
mkdir -p ${basedir}/root/boot
mount ${bootp} ${basedir}/root/boot

# We do this down here to get rid of the build system's resolv.conf after running through the build.
cat << EOF > kali-${architecture}/etc/resolv.conf
nameserver 8.8.8.8
EOF

# Because of the p4wnp1 script, we set the hostname down here, instead of using the machine name.
# Set hostname
echo "${hostname}" > ${work_dir}/etc/hostname

# So X doesn't complain, we add $hostname to hosts
cat << EOF > ${work_dir}/etc/hosts
127.0.0.1       ${hostname}    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

echo "Rsyncing rootfs into image file"
rsync -HPavz -q --exclude boot ${work_dir}/ ${basedir}/root/
rsync -rtx -q ${work_dir}/boot ${basedir}/root
sync

# Unmount partitions
umount ${bootp}
umount ${rootp}
kpartx -dv ${loopdevice}
losetup -d ${loopdevice}

# Don't pixz on 32bit, there isn't enough memory to compress the images.
if [ $(arch) == 'x86_64' ]; then
  echo "Compressing ${imagename}.img"
  cd ${current_dir}
  rand=$(tr -cd 'A-Za-z0-9' < /dev/urandom | head -c4 ; echo) # Randowm name group
  cgcreate -g cpu:/cpulimit-${rand} # Name of group
  cgset -r cpu.shares=800 cpulimit-${rand} # Max 1024
  cgset -r cpu.cfs_quota_us=80000 cpulimit-${rand} # Max 100000
  cgexec -g cpu:cpulimit-${rand} pixz -p 2 "${basedir}"/${imagename}.img ${imagename}.img.xz # -p Nº cpu cores use
  cgdelete cpu:/cpulimit-${rand} # Delete group
fi

# Clean up all the temporary build stuff and remove the directories.
# Comment this out to keep things around if you want to see what may have gone
# wrong.
echo "Cleaning up the temporary build files..."
rm -rf "${basedir}"
