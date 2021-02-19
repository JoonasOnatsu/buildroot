#!/bin/bash

set -e

BOARD_DIR="$(dirname $0)"
BOARD_NAME="$(basename ${BOARD_DIR})"
GENIMAGE_CFG="${BOARD_DIR}/genimage-${BOARD_NAME}.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"

BOOT_WITH_UBOOT=0
BOOT_WITH_INITRAMFS=0
INITRAMFS_NAME_UBOOT="rootfs.cpio.uboot"
INITRAMFS_NAME_BASE="rootfs.cpio.gz"
MKIMAGE_TARGET="arm"

for arg in "$@"
do
	case "${arg}" in
		--add-miniuart-bt-overlay)
		if ! grep -qE '^dtoverlay=' "${BINARIES_DIR}/rpi-firmware/config.txt"; then
			echo "Adding 'dtoverlay=miniuart-bt' to config.txt (fixes ttyAMA0 serial console)."
			cat << __EOF__ >> "${BINARIES_DIR}/rpi-firmware/config.txt"

# fixes rpi (3B, 3B+, 3A+, 4B and Zero W) ttyAMA0 serial console
dtoverlay=miniuart-bt
__EOF__
		fi
		;;
		--aarch64)
		MKIMAGE_TARGET="arm64"
		# Run a 64bits kernel (armv8)
		sed -e '/^kernel=/s,=.*,=Image,' -i "${BINARIES_DIR}/rpi-firmware/config.txt"
		if ! grep -qE '^arm_64bit=1' "${BINARIES_DIR}/rpi-firmware/config.txt"; then
			cat << __EOF__ >> "${BINARIES_DIR}/rpi-firmware/config.txt"

# enable 64bits support
arm_64bit=1
__EOF__
		fi
		;;
		--enable-uart)
		# Enable UART
		if ! grep -qE '^enable_uart=1' "${BINARIES_DIR}/rpi-firmware/config.txt"; then
			cat << __EOF__ >> "${BINARIES_DIR}/rpi-firmware/config.txt"

# enable UART
enable_uart=1
__EOF__
		fi
		;;
		--gpu_mem_256=*|--gpu_mem_512=*|--gpu_mem_1024=*)
		# Set GPU memory
		gpu_mem="${arg:2}"
		sed -e "/^${gpu_mem%=*}=/s,=.*,=${gpu_mem##*=}," -i "${BINARIES_DIR}/rpi-firmware/config.txt"
		;;
		--boot-uboot)
		# Boot with U-Boot
		BOOT_WITH_UBOOT=1
		GENIMAGE_CFG="${BOARD_DIR}/genimage-${BOARD_NAME}-uboot.cfg"
		;;
		--boot-initramfs)
		# Boot with initramfs
		BOOT_WITH_INITRAMFS=1
		;;
	esac

done


if [ -n "$BOOT_WITH_UBOOT" ]; then

	echo "Booting with U-Boot"

	cp "${BOARD_DIR}/uboot.env" "${BINARIES_DIR}/uboot.env"

	KERNEL_IMG="$(sed -n -e 's/^kernel=\(.*\)$/\1/p' "${BINARIES_DIR}/rpi-firmware/config.txt" )"
	sed -e '/^kernel=/s,=.*,=u-boot.bin,' -i "${BINARIES_DIR}/rpi-firmware/config.txt"

	BOOT_CMD_TMP="$(mktemp)"

	if grep -qE '^arm_64bit=1' "${BINARIES_DIR}/rpi-firmware/config.txt"; then
		BOOTCMD="booti"
	else
		BOOTCMD="bootz"
	fi

	if [ -n "$BOOT_WITH_INITRAMFS" ]; then
		cat << __EOF__ >> "$BOOT_CMD_TMP"
fdt addr \${fdt_addr} && fdt get value fdtargs /chosen bootargs
fatload mmc 0:1 \${kernel_addr_r} ${KERNEL_IMG}
fatload mmc 0:1 \${ramdisk_addr_r} ${INITRAMFS_NAME_UBOOT}
setenv bootargs 'coherent_pool=1M 8250.nr_uarts=1 snd_bcm2835.enable_compat_alsa=0 snd_bcm2835.enable_hdmi=1 bcm2708_fb.fbwidth=0 bcm2708_fb.fbheight=0 bcm2708_fb.fbswap=1 smsc95xx.macaddr=DC:A6:32:E0:24:69 vc_mem.mem_base=0x3ec00000 vc_mem.mem_size=0x40000000 console=tty1 console=ttyAMA0,115200 noswap'
${BOOTCMD} \${kernel_addr_r} \${ramdisk_addr_r} \${fdt_addr}
__EOF__
	else
		cat << __EOF__ >> "$BOOT_CMD_TMP"
fdt addr \${fdt_addr} && fdt get value fdtargs /chosen bootargs
fatload mmc 0:1 \${kernel_addr_r} ${KERNEL_IMG}
setenv bootargs 'coherent_pool=1M 8250.nr_uarts=1 snd_bcm2835.enable_compat_alsa=0 snd_bcm2835.enable_hdmi=1 bcm2708_fb.fbwidth=0 bcm2708_fb.fbheight=0 bcm2708_fb.fbswap=1 smsc95xx.macaddr=DC:A6:32:E0:24:69 vc_mem.mem_base=0x3ec00000 vc_mem.mem_size=0x40000000 console=tty1 console=ttyAMA0,115200 noswap root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline rootwait'
${BOOTCMD} \${kernel_addr_r} - \${fdt_addr}
__EOF__
	fi

	# Save boot script source for reference
	cp "$BOOT_CMD_TMP" "${BINARIES_DIR}/boot.cmd"

	# Compile bootscript
	mkimage -A ${MKIMAGE_TARGET} -O linux -T script -C none -n "Boot script" -d "${BOOT_CMD_TMP}" "${BINARIES_DIR}/boot.scr"

else
	echo "Booting with built-in bootloader"
fi


# Pass an empty rootpath. genimage makes a full copy of the given rootpath to
# ${GENIMAGE_TMP}/root so passing TARGET_DIR would be a waste of time and disk
# space. We don't rely on genimage to build the rootfs image, just to insert a
# pre-built one in the disk image.

trap 'rm -rf "${ROOTPATH_TMP}"' EXIT
ROOTPATH_TMP="$(mktemp -d)"

rm -rf "${GENIMAGE_TMP}"

genimage \
	--rootpath "${ROOTPATH_TMP}"   \
	--tmppath "${GENIMAGE_TMP}"    \
	--inputpath "${BINARIES_DIR}"  \
	--outputpath "${BINARIES_DIR}" \
	--config "${GENIMAGE_CFG}"

exit $?
