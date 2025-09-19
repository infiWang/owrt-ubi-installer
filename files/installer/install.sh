#!/bin/sh

. /lib/functions.sh
. /lib/upgrade/nand.sh

# Buffalo WXR18000BE10P LED Layout
#
# The LED looks like this:
# (as seen from the front, the dots represent the actual LEDs)
#
# |                                       |   |                 Tri-Band 18000        |
# |-----------------------------------\   |   |   /-----------------------------------|
# |  WIRELESS   INTERNET    ROUTER     \--|   |--/ Wireless 10G Router WXR series [BE10]
# |    [.]        [.]        [.]          [...]                                       |
# |-----------------------------------------------------------------------------------|

LED_POWER_WHITE="/sys/class/leds/white:power"
LED_POWER_AMBER="/sys/class/leds/amber:power"
LED_ROUTER_WHITE="/sys/class/leds/white:status"
LED_ROUTER_AMBER="/sys/class/leds/amber:status"
LED_INTERNET_WHITE="/sys/class/leds/white:wan-online"
LED_INTERNET_AMBER="/sys/class/leds/amber:wan-online"
LED_WIRELESS_WHITE="/sys/class/leds/white:wlan"
LED_WIRELESS_AMBER="/sys/class/leds/amber:wlan"

led_off() {
	echo none > "$1"/trigger
	echo 0 > "$1"/brightness
}

led_on() {
	echo none > "$1"/trigger
	echo 1 > "$1"/brightness
}

led_flash() {
	echo timer > "$1"/trigger
	echo 100 > "$1"/delay_on
	echo 150 > "$1"/delay_off
}

led_heartbeat() {
	echo heartbeat > "$1"/trigger
	echo 0 > "$1"/invert
}

led_heartbeat_inv() {
	echo heartbeat > "$1"/trigger
	echo 1 > "$1"/invert
}

trigger_crash() {
	for LED in "$LED_WIRELESS_AMBER" "$LED_INTERNET_AMBER" "$LED_ROUTER_AMBER"; do
		local ledtrig=$(cat "$LED"/trigger)
		if [ "$ledtrig" = "timer" ] || [ "$ledtrig" = "heartbeat" ]; then
			led_on "$LED"
		fi
	done
	led_off "$LED_POWER_WHITE"
	led_on "$LED_POWER_AMBER"
	echo "INSTALLER: $@" > /dev/kmsg
	sleep 5
	echo "INSTALLER: Triggering crash now!" > /dev/kmsg
	echo c > /proc/sysrq-trigger
}

led_off "$LED_POWER_WHITE"
led_off "$LED_POWER_AMBER"
led_off "$LED_ROUTER_WHITE"
led_off "$LED_ROUTER_AMBER"
led_off "$LED_INTERNET_WHITE"
led_off "$LED_INTERNET_AMBER"
led_off "$LED_WIRELESS_WHITE"
led_off "$LED_WIRELESS_AMBER"

led_flash "$LED_POWER_AMBER"

sleep 1

echo
echo OpenWrt UBI installer for Buffalo WXR18000BE10P
echo

INSTALLER_DIR="/installer"
PRELOADER="$INSTALLER_DIR/mt7988-spim-nand-ubi-comb-bl2.img"
FIP="$INSTALLER_DIR/mt7988_buffalo_wxr18000be10p-u-boot.fip"
RECOVERY="$(ls -1 $INSTALLER_DIR/openwrt-*mediatek-filogic-buffalo_wxr18000be10p-ubootmod-initramfs-recovery.itb)"
HAS_ENV=1
HAS_FIP=1
HAS_FACTORY=1
HAS_ORGDATA=1
HAS_AQUANTIA=1

# Optional
FACTORY="$INSTALLER_DIR/Factory"
AQUANTIA="$INSTALLER_DIR/CUX3410.cld"

if [ ! -s "$PRELOADER" ] || [ ! -s "$FIP" ] || [ ! -s "$RECOVERY" ]; then
	trigger_crash "Missing files. Aborting."
fi

ubi_mknod() {
	local dev="$1"
	dev="${dev##*/}"
	[ -e "/sys/class/ubi/$dev/uevent" ] || return 2
	source "/sys/class/ubi/$dev/uevent"
	mknod "/dev/$dev" c $MAJOR $MINOR
}

install_prepare_mtd_backup() {
	echo "preparing backup of relevant flash areas..."
	mkdir /tmp/backup
	for mtdname in "$@"; do
		echo "backing up $mtdname..."
		local mtdnum="$(find_mtd_index "STOCK-$mtdname")"
		local ebs="$(cat /sys/class/mtd/mtd${mtdnum}/erasesize)"
		dd bs=$ebs if=/dev/mtd${mtdnum} of=/tmp/backup/$mtdname
		[ -s /tmp/backup/$mtdname ] || trigger_crash "Error backing up $mtdname"
	done
}

install_write_backup() {
	echo "writing backup files to ubi volume..."
	ubimkvol /dev/ubi0 -n 7 -s 8MiB -N boot_backup
	ubi_mknod ubi0_7
	mount -t ubifs /dev/ubi0_7 /mnt
	cp /tmp/backup/* /mnt
	umount /mnt
}

install_prepare_ubi() {
	mtddev=$1
	[ -e /sys/class/ubi/ubi0 ] && ubidetach -p $mtddev
	ubiformat -y $mtddev
	sleep 1
	ubiattach -p $mtddev
	sync
	sleep 1
	[ -e /dev/ubi0 ] || ubi_mknod ubi0
	[ "$HAS_FIP" = "1" ] && ubimkvol /dev/ubi0 -n 0 -t static -s $(cat $FIP | wc -c) -N fip && ubi_mknod ubi0_0 && ubiupdatevol /dev/ubi0_0 "$FIP"
	[ "$HAS_FACTORY" = "1" ] && ubimkvol /dev/ubi0 -n 1 -t static -s $(cat "/tmp/factory" | wc -c) -N factory && ubi_mknod ubi0_1 && ubiupdatevol /dev/ubi0_1 "/tmp/factory"
	[ "$HAS_ENV" = "1" ] && ubimkvol /dev/ubi0 -n 2 -s 126976 -N ubootenv && ubimkvol /dev/ubi0 -n 3 -s 126976 -N ubootenv2
	[ "$HAS_AQUANTIA" = "1" ] && ubimkvol /dev/ubi0 -n 6 -s 507904 -N firmware
}

echo "Phase 0: Checks"

[ -c /dev/mtd0 ] || trigger_crash "No MTD device found"
[ "$(cat /sys/class/mtd/mtd0/erasesize)" = "131072" ] || trigger_crash "MTD block has unexpected erasesize"

check_mtds="STOCK-BL2 STOCK-Factory STOCK-FIP STOCK-ORGDATA NEW_UBI"

for mtd in $check_mtds; do
	[ -c /dev/mtd$(find_mtd_index "$mtd") ] || trigger_crash "No $mtd partition found"
done

led_off "$LED_POWER_AMBER"
led_heartbeat_inv "$LED_POWER_WHITE"

echo "Phase 1: Prepare"

led_heartbeat "$LED_ROUTER_AMBER"
echo "Phase 1.1: Prepare stock bootchain"
install_prepare_mtd_backup "BL2" "FIP"

# Buffalo WXR18000BE10P got factory data and device data stored in MTD partition
# Factory [0x180000 - 0x580000) and ORGDATA [0x780000 - 0x800000)
# Thing may be shifted due to MTK NMBM being used previously, we simply
# error out if we cannot find the data at the expected offset

led_flash "$LED_ROUTER_AMBER"
echo "Phase 1.2: Prepare Factory data"
if [ -s "$FACTORY" ]; then
	echo "using provided Factory file"
	[ "$(hexdump -v -s 0x0 -n 2 -e '"%02x"' "$FACTORY")" = "7990" ] || trigger_crash "Invalid Factory file"
	readm_eeprom=$(hexdump -s 0x4 -v -n 6 -e '6/1 "%02x"' "$FACTORY")
	readm=$(hexdump -s 0x0ffff4 -v -n 6 -e '6/1 "%02x"' "$FACTORY")
	if [ "${readm_eeprom:0:6}" != "${readm:0:6}" ]; then
		echo "MAC address prefix mismatch, EEPROM: $readm_eeprom, Factory: $readm"
		trigger_crash "invalid Factory file"
	fi
	dd if="$FACTORY" of=/tmp/factory bs=1048576 count=1
else
	echo "extracting Factory data from flash"

	mtdnum=$(find_mtd_index "STOCK-Factory")
	magic=$(hexdump -v -s 0 -n 2 -e '"%02x"' /dev/mtd$mtdnum)
	[ "$magic" = "7990" ] || trigger_crash "EEPROM not found on expected offset"
	dd if=/dev/mtd$mtdnum bs=131072 count=1 of=/tmp/eeproms

	readm_eeprom=$(hexdump -s 0x4 -v -n 6 -e '6/1 "%02x"' /dev/mtd$mtdnum)
	readm=$(hexdump -s 0xffff4 -v -n 6 -e '6/1 "%02x"' /dev/mtd$mtdnum)
	if [ "${readm_eeprom:0:6}" != "${readm:0:6}" ]; then
		echo "MAC address mismatch, EEPROM: $readm_eeprom, Factory: $readm"
		trigger_crash "cannot find MAC address data"
	fi
	dd if=/dev/mtd$mtdnum of=/tmp/macblock bs=131072 skip=7 count=1

	# Assemble factory blob
	# Stock Factory partition is 0x400000 bytes large
	# Wi-Fi EEPROMs is at the start, Wired MAC at 0x0ffff4
	# [0x100000 - 0x400000) are ff-filled
	# Only first 0x100000 bytes are needed
	dd if=/dev/zero bs=1048576 count=1 | tr '\0' '\377' | dd of=/tmp/factory
	dd if=/tmp/eeproms of=/tmp/factory conv=notrunc
	dd if=/tmp/macblock of=/tmp/factory bs=131072 seek=7 count=1

	cp /tmp/factory /tmp/factory_check
	dd if=/dev/zero bs=1048576 count=3 | tr '\0' '\377' | dd of=/tmp/factory_check bs=1048576 seek=1 conv=notrunc
	sha256sum_factory=$(hexdump -v -s 0x0 -n 32 -e '32/1 "%02x"' /tmp/factory_check)
	sha256sum_stock=$(hexdump -v -s 0x0 -n 32 -e '32/1 "%02x"' /dev/mtd$mtdnum)
	[ "$sha256sum_factory" = "$sha256sum_stock" ] || trigger_crash "Factory data checksum mismatch"
fi
cp /tmp/factory /tmp/Factory

led_heartbeat_inv "$LED_ROUTER_AMBER"
echo "Phase 1.3: Prepare device data"
if [ "$HAS_ORGDATA" = "1" ]; then
	echo "backing up ORGDATA"
	mtdnum=$(find_mtd_index "STOCK-ORGDATA")
	magic=$(hexdump -v -s 0x0 -n 13 -e '13/1 "%02x"' /dev/mtd$mtdnum)
	[ "$magic" = "57585231383030304245313050" ] || trigger_crash "ORGDATA magic not found"
	# Only 64k are used, rest is ff-filled. Backup an 128k block anyway
	dd if=/dev/mtd$mtdnum of=/tmp/backup/ORGDATA bs=131072 count=1

	cp /tmp/backup/ORGDATA /tmp/ORGDATA_check
	dd if=/dev/zero bs=131072 count=3 | tr '\0' '\377' | dd of=/tmp/ORGDATA_check bs=131072 seek=1 conv=notrunc
	sha256sum_orgdata=$(hexdump -v -s 0x0 -n 32 -e '32/1 "%02x"' /tmp/ORGDATA_check)
	sha256sum_stock=$(hexdump -v -s 0x0 -n 32 -e '32/1 "%02x"' /dev/mtd$mtdnum)
	[ "$sha256sum_orgdata" = "$sha256sum_stock" ] || trigger_crash "ORGDATA checksum mismatch"
else
	echo "skipping ORGDATA backup"
fi

led_off "$LED_ROUTER_AMBER"
led_on "$LED_ROUTER_WHITE"

echo "Phase 2: Write bl2"

led_flash "$LED_INTERNET_AMBER"
echo "redundantly write bl2"
for bl2start in 0x0 0x80000 0x100000 0x180000; do
	mtd -p $bl2start write $PRELOADER /dev/mtd0
done

led_off "$LED_INTERNET_AMBER"
led_on "$LED_INTERNET_WHITE"

echo "Phase 3: Write UBI"

led_heartbeat "$LED_WIRELESS_AMBER"
echo "Phase 3.1: Prepare UBI"
install_prepare_ubi /dev/mtd$(find_mtd_index "NEW_UBI")

led_flash "$LED_WIRELESS_AMBER"
echo "Phase 3.2: Write recovery image"
echo "write recovery ubi volume"
RECOVERY_SIZE=$(cat $RECOVERY | wc -c)
ubimkvol /dev/ubi0 -n 4 -s $RECOVERY_SIZE -N recovery
ubi_mknod ubi0_4
ubiupdatevol /dev/ubi0_4 $RECOVERY
ubimkvol /dev/ubi0 -n 5 -s 126976 -N fit

led_heartbeat_inv "$LED_WIRELESS_AMBER"
echo "Phase 3.3: Write firmware and backup"
install_write_backup

if [ "$HAS_AQUANTIA" = "1" ] && [ -s "$AQUANTIA" ]; then
	echo "write Aquantia firmware"
	ubi_mknod ubi0_6
	mount -t ubifs /dev/ubi0_6 /mnt
	mkdir /mnt/marvell
	cp "$AQUANTIA" /mnt/marvell/CUX3410.cld
	umount /mnt
fi

led_off "$LED_WIRELESS_AMBER"
led_on "$LED_WIRELESS_WHITE"

echo "Phase 4: Finishing up"

sync

led_on "$LED_POWER_WHITE"
echo "Reboot countdown..."
sleep 1 && echo "5..."
led_flash "$LED_WIRELESS_WHITE"
sleep 1 && echo "4..."
led_flash "$LED_INTERNET_WHITE"
sleep 1 && echo "3..."
led_flash "$LED_ROUTER_WHITE"
sleep 1 && echo "2..."
led_flash "$LED_POWER_WHITE"
sleep 1 && echo "1..."

reboot -f
