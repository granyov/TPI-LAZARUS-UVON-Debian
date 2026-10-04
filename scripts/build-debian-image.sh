#!/bin/bash
# Собирает распространяемый образ Debian 13 для TPI LAZARUS UVON (SATA, USB,
# microSD). Всё, что привязано к конкретному экземпляру или является секретом,
# из образа вычищается и заново создаётся при первом запуске.
#
#   build-debian-image.sh [-s КОРЕНЬ] [-d DTB] [-b BOOTAA64.EFI] ОБРАЗ.img
#
#   -s  откуда брать систему: / (по умолчанию — работающая система) или
#       смонтированный корень другого образа, см. build-debian-release.sh
#   -d  device tree платы; без ключа остаётся тот, что в источнике
#   -b  GRUB для ESP; по умолчанию КОРЕНЬ/boot/efi/EFI/BOOT/BOOTAA64.EFI
#
# Образ — только ОС: ESP начинается с 1 МиБ, поверх загрузчика eMMC его писать
# нельзя. Для eMMC — build-emmc-set.sh.
set -euo pipefail
. "$(dirname "$0")/debian-common.sh"

SRC=/
DTB=""
BOOTEFI=""
while getopts "s:d:b:" o; do
    case $o in
        s) SRC=$OPTARG ;;
        d) DTB=$OPTARG ;;
        b) BOOTEFI=$OPTARG ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
IMG=${1:?укажите файл образа}
BOOTEFI=${BOOTEFI:-${SRC%/}/boot/efi/EFI/BOOT/BOOTAA64.EFI}
[ -s "$BOOTEFI" ] || { echo "нет $BOOTEFI; укажите -b" >&2; exit 1; }
[ -z "$DTB" ] || [ -s "$DTB" ] || { echo "нет $DTB" >&2; exit 1; }

SIZE_MB=4096
MNT=$(mktemp -d /tmp/tpi-imgroot.XXXXXX)
LOOP=""

cleanup() {
    mountpoint -q "$MNT/boot/efi" && umount "$MNT/boot/efi" || true
    mountpoint -q "$MNT" && umount "$MNT" || true
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "== разметка =="
rm -f "$IMG"
truncate -s ${SIZE_MB}M "$IMG"
sgdisk -Z "$IMG" >/dev/null 2>&1 || true
sgdisk -n 1:2048:+256M -t 1:ef00 -c 1:ESP "$IMG" >/dev/null
sgdisk -n 2:0:0 -t 2:8300 -c 2:rootfs "$IMG" >/dev/null
LOOP=$(losetup --show -fP "$IMG")
echo "  $IMG (${SIZE_MB} МБ) -> $LOOP"

mkfs.vfat -F32 -n TPIESP "${LOOP}p1" >/dev/null
"${TPI_MKFS_EXT4[@]}" "${LOOP}p2"
RUUID=$(blkid -s UUID -o value "${LOOP}p2")
EUUID=$(blkid -s UUID -o value "${LOOP}p1")

mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "${LOOP}p1" "$MNT/boot/efi"

echo "== копирование корня из $SRC =="
copy_root "$SRC" "$MNT"
echo "  скопировано: $(du -sh --exclude=boot/efi "$MNT" | cut -f1)"

echo "== вычистка секретов и привязок к экземпляру =="
scrub_root "$MNT"
echo "  ключи SSH, состояние Tailscale, authorized_keys, machine-id, MAC-привязки — убраны"

echo "== файлы платы =="
install_overlay "$MNT"
[ -z "$DTB" ] || install_dtb "$MNT" "$DTB"
check_root "$MNT"
echo "  первая настройка, часы, имена портов, консоль 1 500 000; DTB $(sha256sum "$MNT/boot/dtb/rk3568-tpi-lazarus.dtb" | cut -c1-12)…"

echo "== fstab и меню загрузки =="
cat > "$MNT/etc/fstab" <<FSTAB
# <file system>	<mount point>	<type>	<options>		<dump> <pass>
UUID=$RUUID	/		ext4	defaults,noatime	0      1
UUID=$EUUID	/boot/efi	vfat	umask=0077		0      2
FSTAB
mkdir -p "$MNT/boot/efi/EFI/BOOT"
cp "$BOOTEFI" "$MNT/boot/efi/EFI/BOOT/BOOTAA64.EFI"
write_grub_cfg "$MNT/boot/efi/EFI/BOOT/grub.cfg" "$RUUID" "SATA, USB или microSD"
echo "  BOOTAA64.EFI $(stat -c %s "$BOOTEFI") байт, ядро $(readlink "$MNT/vmlinuz"), корень UUID=$RUUID"

sync
echo "== готово =="
df -h "$MNT" | tail -1 | sed 's/^/  /'
