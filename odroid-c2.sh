#!/usr/bin/env bash
#
# Kali Linux ARM build-script for ODROID-C2 (64-bit)
# https://gitlab.com/kalilinux/build-scripts/kali-arm
#
# This is a supported device - which you can find pre-generated images for
# More information: https://www.kali.org/docs/arm/odroid-c2/
#

# Stop on error
set -e

# shellcheck disable=SC2154
# Load general functions
# shellcheck source=/dev/null
source ./common.d/functions.sh

# Hardware model
hw_model=${hw_model:-"odroid-c2"}
# Architecture
architecture=${architecture:-"arm64"}
# Variant name for image and dir build
variant=${variant:-"${architecture}"}
# Desktop manager (xfce, gnome, i3, kde, lxde, mate, e17 or none)
desktop=${desktop:-"xfce"}

# Load common variables
include variables
# Checks script environment
include check
# Packages build list
include packages
# Load automatic proxy configuration
include proxy_apt
# Execute initial debootstrap
debootstrap_exec http://http.kali.org/kali
# Enable eatmydata in compilation
include eatmydata
# debootstrap second stage
systemd-nspawn_exec eatmydata /debootstrap/debootstrap --second-stage
# Define sources.list
include sources.list
# APT options
include apt_options
# So X doesn't complain, we add kali to hosts
include hosts
# Set hostname
set_hostname "${hostname}"
# Network configs
include network
add_interface eth0
# Copy directory bsp into build dir
cp -rp bsp "${work_dir}"

# Disable RESUME (suspend/resume is currently broken anyway!) which speeds up boot massively
mkdir -p ${work_dir}/etc/initramfs-tools/conf.d/
cat << EOF > ${work_dir}/etc/initramfs-tools/conf.d/resume
RESUME=none
EOF

# Third stage
cat <<EOF >"${work_dir}"/third-stage
#!/bin/bash -e

export DEBIAN_FRONTEND=noninteractive
eatmydata apt-get update
eatmydata apt-get -y install ${third_stage_pkgs}

eatmydata apt-get install -y ${packages} || eatmydata apt-get install -y --fix-broken
eatmydata apt-get install -y ${desktop_pkgs} ${extra} || eatmydata apt-get install -y --fix-broken

eatmydata apt-get -y --purge autoremove

# Linux console/Keyboard configuration
echo 'console-common console-data/keymap/policy select Select keymap from full list' | debconf-set-selections
echo 'console-common console-data/keymap/full select en-latin1-nodeadkeys' | debconf-set-selections

# Copy all services
cp -p /bsp/services/all/*.service /etc/systemd/system/
cp -p /bsp/services/odroid-c2/*.service /etc/systemd/system/

# For some reason the latest modesetting driver (part of xorg server)
# seems to cause a lot of jerkiness.  Using the fbdev driver is not
# ideal but it's far less frustrating to work with
mkdir -p /etc/X11/xorg.conf.d
cp -p /bsp/xorg/20-meson.conf /etc/X11/xorg.conf.d/

# Install the kernel packages
eatmydata apt-get install -y dkms linux-image-arm64 u-boot-menu

# Run u-boot-update to generate the extlinux.conf file - we will replace this later, via sed, to point to the correct root partition (hopefully?)
u-boot-update

# Copy script rpi-resizerootfs
install -m755 /bsp/scripts/rpi-resizerootfs /usr/sbin/

# Enable rpi-resizerootfs first boot
systemctl enable rpi-resizerootfs

# Generate SSH host keys on first run
systemctl enable regenerate_ssh_host_keys

# Allow users to use NM over ssh
install -m644 /bsp/polkit/10-NetworkManager.pkla /var/lib/polkit-1/localauthority/50-local.d

cd /root
apt download -o APT::Sandbox::User=root ca-certificates 2>/dev/null

# Set a REGDOMAIN.  This needs to be done or wireless doesn't work correctly on the RPi 3B+
sed -i -e 's/REGDOM.*/REGDOMAIN=00/g' /etc/default/crda

# Enable login over serial
echo "T0:23:respawn:/sbin/agetty -L ttyAMA0 115200 vt100" >> /etc/inittab

# Try and make the console a bit nicer
# Set the terminus font for a bit nicer display
sed -i -e 's/FONTFACE=.*/FONTFACE="Terminus"/' /etc/default/console-setup
sed -i -e 's/FONTSIZE=.*/FONTSIZE="6x12"/' /etc/default/console-setup

# Fix startup time from 5 minutes to 15 secs on raise interface wlan0
sed -i 's/^TimeoutStartSec=5min/TimeoutStartSec=15/g' "/usr/lib/systemd/system/networking.service"

# Enable runonce
install -m755 /bsp/scripts/runonce /usr/sbin/
cp -rf /bsp/runonce.d /etc
systemctl enable runonce

# Clean up dpkg.eatmydata
rm -f /usr/bin/dpkg
dpkg-divert --remove --rename /usr/bin/dpkg
EOF

# Run third stage
chmod 0755 "${work_dir}"/third-stage
systemd-nspawn_exec /third-stage

# Choose a locale
set_locale "$locale"
# Clean system
include clean_system
# Define DNS server after last running systemd-nspawn
echo "nameserver 8.8.8.8" >"${work_dir}"/etc/resolv.conf
# Disable the use of http proxy in case it is enabled
disable_proxy
# Mirror & suite replacement
restore_mirror
# Reload sources.list
#include sources.list

# 1366x768 is sort of broken on the ODROID-C2, not sure where the issue is, but
# we can work around it by setting the resolution to 1360x768
# This requires 2 files, a script and then something for lightdm to use
# I do not have anything set up for the console though, so that's still broken for now
mkdir -p ${work_dir}/usr/local/bin
cat << 'EOF' > ${work_dir}/usr/local/bin/xrandrscript.sh
#!/usr/bin/env bash

resolution=$(xdpyinfo | awk '/dimensions:/ { print $2; exit }')

if [[ "$resolution" == "1366x768" ]]; then
    xrandr --newmode "1360x768_60.00"   84.75  1360 1432 1568 1776  768 771 781 798 -hsync +vsync
    xrandr --addmode HDMI-1 1360x768_60.00
    xrandr --output HDMI-1 --mode  1360x768_60.00
fi
EOF
chmod 0755 ${work_dir}/usr/local/bin/xrandrscript.sh

mkdir -p ${work_dir}/usr/share/lightdm/lightdm.conf.d/
cat << EOF > ${work_dir}/usr/share/lightdm/lightdm.conf.d/60-xrandrscript.conf
[SeatDefaults]
display-setup-script=/usr/local/bin/xrandrscript.sh
session-setup-script=/usr/local/bin/xrandrscript.sh
EOF

cd ${current_dir}

# Calculate the space to create the image and create
make_image

# Create the disk partitions it
parted -s ${current_dir}/${imagename}.img mklabel msdos
parted -s -a minimal ${current_dir}/${imagename}.img mkpart primary $fstype 32MiB 100%

# Set the partition variables
loopdevice=$(losetup --show -fP "${current_dir}/${imagename}.img")
rootp="${loopdevice}p1"

# Create file systems
log "Formatting partitions" green
if [[ "$fstype" == "ext4" ]]; then
  features="^64bit,^metadata_csum"
elif [[ "$fstype" == "ext3" ]]; then
  features="^64bit"
fi
mkfs -O "$features" -t "$fstype" -L ROOTFS "${rootp}"

# Create the dirs for the partitions and mount them
mkdir -p "${basedir}"/root/
mount "${rootp}" "${basedir}"/root

# We do this here because we don't want to hardcode the UUID for the partition during creation
# systemd doesn't seem to be generating the fstab properly for some people, so let's create one
cat <<EOF >"${work_dir}"/etc/fstab
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
proc            /proc           proc    defaults          0       0
UUID=$(blkid -s UUID -o value ${rootp})  /               $fstype    defaults,noatime  0       1
EOF

# Ensure we don't have root=/dev/sda3 in the extlinux.conf which comes from running u-boot-menu in a cross chroot
# We do this down here because we don't know the UUID until after the image is created
sed -i -e "0,/root=.*/s//root=UUID=$(blkid -s UUID -o value ${rootp}) rootfstype=$fstype console=ttyS0,115200 console=tty1 consoleblank=0 rw quiet rootwait/g" ${work_dir}/boot/extlinux/extlinux.conf
# And we remove the "Debian GNU/Linux because we're Kali"
sed -i -e "s/Debian GNU\/Linux/Kali Linux/g" ${work_dir}/boot/extlinux/extlinux.conf

log "Rsyncing rootfs into image file" green
rsync -HPavz -q "${work_dir}"/ "${basedir}"/root/
sync

# We are gonna use as much open source as we can here, hopefully we end up with a nice
# mainline u-boot and signed bootloader - unfortunately, due to the way this is packaged up
# we have to clone two different u-boot repositories - the one from HardKernel which
# has the bootloader binary blobs we need, and the denx mainline u-boot repository
# Let the fun begin

# Unset these because we're building on the host
unset ARCH
unset CROSS_COMPILE

mkdir -p ${basedir}/bootloader
cd ${basedir}/bootloader
git clone https://github.com/afaerber/meson-tools --depth 1
git clone git://git.denx.de/u-boot --depth 1
git clone https://github.com/hardkernel/u-boot -b odroidc2-v2015.01 u-boot-hk --depth 1

# First things first, let's build the meson-tools, of which, we only really need amlbootsig
cd ${basedir}/bootloader/meson-tools/
make
# Now we need to build fip_create
cd ${basedir}/bootloader/u-boot-hk/tools/fip_create
HOSTCC=cc HOSTLD=ld make

cd ${basedir}/bootloader/u-boot/
make ARCH=arm CROSS_COMPILE=aarch64-linux-gnu- odroid-c2_defconfig
make ARCH=arm CROSS_COMPILE=aarch64-linux-gnu-

# Now the real fun... keeping track of file locations isn't fun, and i should probably move them to
# one single directory, but since we're not keeping these things around afterwards, it's fine to
# leave them where they are
# See:
# https://forum.odroid.com/viewtopic.php?t=26833
# https://github.com/nxmyoz/c2-overlay/blob/master/Readme.md
# for the inspirations for it.  Specifically Adrian's posts got us closest

# This is funky, but in the end, it should do the right thing
cd ${basedir}/bootloader/
# Create the fip.bin
./u-boot-hk/tools/fip_create/fip_create --bl30 ./u-boot-hk/fip/gxb/bl30.bin \
--bl301 ./u-boot-hk/fip/gxb/bl301.bin --bl31 ./u-boot-hk/fip/gxb/bl31.bin \
--bl33 u-boot/u-boot.bin fip.bin

# Create the stage2 bootloader thingie?
cat ./u-boot-hk/fip/gxb/bl2.package fip.bin > boot_new.bin
# Now sign it, and call it u-boot.bin
./meson-tools/amlbootsig boot_new.bin u-boot.bin
# Now strip a portion of it off, and put it in the sd_fuse directory
dd if=u-boot.bin of=./u-boot-hk/sd_fuse/u-boot.bin bs=512 skip=96
# Finally, write it to the loopdevice so we have our bootloader on the card
cd ./u-boot-hk/sd_fuse
./sd_fusing.sh ${loopdevice}
sync

cd ${current_dir}

# Umount filesystem
umount -l "${rootp}"

# Check filesystem
e2fsck -y -f "$rootp"

# Remove loop devices
kpartx -dv "${loopdevice}" 
losetup -d "${loopdevice}"

# Compress image compilation
include compress_img

# Clean up all the temporary build stuff and remove the directories
# Comment this out to keep things around if you want to see what may have gone wrong
clean_build
