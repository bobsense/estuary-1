#!/bin/bash

###################################################################################
# Global variable
###################################################################################
INSTALL_TYPE=""
ACPI="NO"
ACPI_ARG="acpi=force"

PART_BASE_INDEX=2
BOOT_PARTITION_SIZE=200
DISK_LABEL=""
NFS_ROOT=""

INSTALL_DISK="/dev/sdx"
TARGET_DISK=
BOOT_DEV=

ESTUARY_CFG="/usr/bin/estuary.txt"
PLATFORM=`grep -Po "(?<=PLATFORM=)(.*)" $ESTUARY_CFG`
INSTALL_DISTRO=($(grep -Po "(?<=DISTROS=)(.*)" $ESTUARY_CFG | tr ',' ' '))
DISTRO_CAPACITY=($(grep -Po "(?<=CAPACITY=)(.*)" $ESTUARY_CFG | tr ',' ' '))

###################################################################################
# Create mountpointer
###################################################################################
mkdir /boot 2>/dev/null
mkdir /mnt 2>/dev/null
mkdir /scratch 2>/dev/null

###################################################################################
# Find install disk and mount it to /scratch
###################################################################################
if [ x"$INSTALL_TYPE" = x"NFS" ]; then
	nfs_root=`cat /proc/cmdline | grep -Eo "nfsroot=[^ ]*"`
	NFS_ROOT=`expr "X$nfs_root" : 'X[^=]*=\(.*\)'`
	echo "mount $NFS_ROOT ......"
	mount -o nolock -t nfs $NFS_ROOT /scratch
	echo "mount $NFS_ROOT done ......"
else
	disk_info=`blkid | grep LABEL=\"$DISK_LABEL\"`
	for ((index=0; index<45; index++))
	do
		if [ x"$disk_info" != x"" ]; then
			break
		fi
		sleep 1
		disk_info=`blkid | grep LABEL=\"$DISK_LABEL\"`
	done

	if [ x"$disk_info" = x"" ]; then
		echo "Cann't find install disk!"
		exit 1
	fi

	INSTALL_DISK=`expr "${disk_info}" : '/dev/\([^:]*\):[^:]*'`

	mount /dev/${INSTALL_DISK} /scratch
fi

###################################################################################
# Get all disk info (exclude the install disk)
###################################################################################
clear

disk_list=()
disk_model_info=()
disk_size_info=()
disk_sector_info=()

install_disk_dev=`echo "${INSTALL_DISK}" | sed 's/[0-9]*$//g'`
read -a disk_list <<< $(lsblk -ln -o NAME,TYPE | grep '\<disk\>' | grep -v $install_disk_dev | awk '{print $1}')

if [[ ${#disk_list[@]} = 0 ]]; then
	echo "Error! Can't find disk to install distributions!" ; exit 1
fi

for disk in ${disk_list[@]}
do
	disk_model_info[${#disk_model_info[@]}]=`parted -s /dev/$disk print 2>/dev/null | grep "Model: "`
	disk_size_info[${#disk_size_info[@]}]=`parted -s /dev/$disk print 2>/dev/null | grep "Disk /dev/$disk: "`
	disk_sector_info[${#disk_sector_info[@]}]=`parted -s /dev/$disk print 2>/dev/null | grep "Sector size (logical/physical): "`
done

###################################################################################
# Select disk to install
###################################################################################
index=0
disk_number=${#disk_list[@]}
for (( index=0; index<disk_number; index++))
do
	echo "Disk [$index] info: "
	echo ${disk_model_info[$index]}
	echo ${disk_size_info[$index]}
	echo ${disk_sector_info[$index]}
	echo ""
done

read -p "Input disk index to install or q to quit (default 0): " index
if [ x"$index" = x"q" ]; then
	exit 0
fi

if [ x"$index" = x"" ] || [[ $index != [0-9]* ]] \
	|| [[ $index -ge $disk_number ]]; then
	index=0
fi

TARGET_DISK="/dev/${disk_list[$index]}"

echo ""
sleep 1s

###################################################################################
# Select ACPI choice
###################################################################################
read -p "Use ACPI by force? y/n (n by default)" c
if [ x"$c" = x"y" ]; then
	ACPI="YES"
fi

###################################################################################
# Install info check
###################################################################################
if [[ ${#INSTALL_DISTRO[@]} == 0 ]]; then
	echo "Error! Distros are not specified" ; exit 1
fi

if [[ ${#DISTRO_CAPACITY[@]} == 0 ]]; then
	echo "Error! Capacities is not specified!" ; exit 1
fi

echo "" ; sleep 1s

###################################################################################
# Delete all partitions on target disk
###################################################################################
echo "Delete all partitions on $TARGET_DISK ......"
(yes | mkfs.ext4 $TARGET_DISK) >/dev/null 2>&1
echo "Delete all partitions on $TARGET_DISK done!"

###################################################################################
# make gpt label and create EFI System partition
###################################################################################
echo "Create EFI System partition on $TARGET_DISK ......"
(parted -s $TARGET_DISK mklabel gpt) >/dev/null 2>&1

# EFI System
efi_start_address=1
efi_end_address=$(( start_address + BOOT_PARTITION_SIZE))

BOOT_DEV=${TARGET_DISK}1
(parted -s $TARGET_DISK "mkpart UEFI $efi_start_address $efi_end_address") >/dev/null 2>&1
(parted -s $TARGET_DISK set 1 boot on) >/dev/null 2>&1
(yes | mkfs.vfat $BOOT_DEV) >/dev/null 2>&1
echo "Create EFI System partition on $TARGET_DISK done!"

###################################################################################
# Install grub and kernel to EFI System partition
###################################################################################
echo "Install grub and kernel to $BOOT_DEV ......"
pushd /scratch

mount $BOOT_DEV /boot/ >/dev/null 2>&1
# mkdir -p /boot/EFI/GRUB2/
# cp grub*.efi /boot/EFI/GRUB2/grubaa64.efi
grub-install --efi-directory=/boot --target=arm64-efi $BOOT_DEV
cp Image* /boot/

cat > /boot/grub/grub.cfg << EOF
# NOTE: Please remove the unused boot items according to your real condition.
# Sample GRUB configuration file
#

# Boot automatically after 3 secs.
set timeout=3

# By default, boot the Linux
set default=default_menuentry

EOF

popd
sync
umount /boot/
echo "Install grub and kernel to $BOOT_DEV done!"

###################################################################################
# Install all distributions to target disk
###################################################################################
echo "Install distributions to $TARGET_DISK ......"
allocate_address=$((efi_end_address + 1))
start_address=
end_address=

pushd /scratch
index=0
distro_number=${#INSTALL_DISTRO[@]}

for ((index=0; index<distro_number; index++))
do
	# Get necessary info for current distribution.
	part_index=$((PART_BASE_INDEX + index))
	distro_name=${INSTALL_DISTRO[$index]}
	rootfs_package="${distro_name}""_ARM64.tar.gz"
	distro_capacity=${DISTRO_CAPACITY[$index]%G*}
	
	start_address=$allocate_address
	end_address=$((start_address + distro_capacity * 1000))
	allocate_address=$((end_address + 1))
	
	# Create and fromat partition for current distribution.
	echo "Create ${TARGET_DISK}${part_index} for $distro_name ......"
	(parted -s $TARGET_DISK "mkpart ROOT ext4 $start_address $end_address") >/dev/null 2>&1
	(echo -e "t\n$part_index\n13\nw\n" | fdisk $TARGET_DISK) >/dev/null 2>&1
	(yes | mkfs.ext4 ${TARGET_DISK}${part_index}) >/dev/null 2>&1
	echo "Create done!"
	
	# Mount root dev to mnt and uncompress rootfs to root dev
	mount ${TARGET_DISK}${part_index} /mnt/ 2>/dev/null
	echo "Uncompress $rootfs_package to ${TARGET_DISK}${part_index} ......"
	tar xvf $rootfs_package -C /mnt/ 2>/dev/null
	echo "Uncompress $rootfs_package to ${TARGET_DISK}${part_index} done!"

	sync
	umount /mnt/

	echo ""
	sleep 1s
done

popd
echo ""
sleep 1s

###################################################################################
# Update grub configuration file
###################################################################################
echo "Update grub configuration file ......"
PLATFORM=`jq -r ".system.platform" $INSTALL_CFG`
platform=$(echo $PLATFORM | tr "[:upper:]" "[:lower:]")

if [ x"D02" = x"$PLATFORM" ]; then
	cmd_line="rdinit=/init crashkernel=256M@32M console=ttyS0,115200 earlycon=uart8250,mmio32,0x80300000 ip=dhcp"
else
	cmd_line="rdinit=/init console=ttyS0,115200 earlycon=hisilpcuart,mmio,0xa01b0000,0,0x2f8 ip=dhcp"
fi

if [ x"$ACPI" = x"YES" ]; then
	cmd_line="${cmd_line} ${ACPI_ARG}"
fi

boot_dev_info=`blkid -s UUID $BOOT_DEV 2>/dev/null | grep -o "UUID=.*" | sed 's/\"//g'`
boot_dev_uuid=`expr "${boot_dev_info}" : '[^=]*=\(.*\)'`

mount $BOOT_DEV /boot/ >/dev/null 2>&1

pushd /boot/
Image="`ls Image*`"
Dtb="`ls hip*.dtb`"
popd

distro_number=${#INSTALL_DISTRO[@]}
for ((index=0; index<distro_number; index++))
do
	part_index=$((PART_BASE_INDEX + index))
	root_dev="${TARGET_DISK}${part_index}"
	root_dev_info=`blkid -s PARTUUID $root_dev 2>/dev/null | grep -o "PARTUUID=.*" | sed 's/\"//g'`
	root_partuuid=`expr "${root_dev_info}" : '[^=]*=\(.*\)'`

	linux_arg="/$Image root=$root_dev_info rootfstype=ext4 rw $cmd_line"
	device_tree_arg="/$Dtb"

	distro_name=${INSTALL_DISTRO[$index]}
	

cat >> /boot/grub/grub.cfg << EOF
# Booting from SATA with $distro_name rootfs
menuentry "${PLATFORM} $distro_name" --id ${platform}_${distro_name} {
    set root=(hd0,gpt1)
    search --no-floppy --fs-uuid --set=root $boot_dev_uuid
    linux $linux_arg
    # devicetree $device_tree_arg
}

EOF

done

# Set the first distribution to default
default_menuentry_id="${platform}_""${INSTALL_DISTRO[0]}"
sed -i "s/\(set default=\)\(default_menuentry\)/\1$default_menuentry_id/g" /boot/grub/grub.cfg

echo "Update grub configuration file done!"

sync
umount $BOOT_DEV

###################################################################################
# Umount install disk
###################################################################################
cd ~
umount /scratch
echo "The system will restart in 3 seconds ......"
sleep 3
reboot

