#!/bin/bash
# Собирает комплект для прошивки всей платы в eMMC: прошивка, ESP и корень
# Debian 13 по заводской раскладке (см. docs/EMMC-IMAGE.md).
#
#   build-emmc-set.sh [-s КОРЕНЬ] [-d DTB] [-b BOOTAA64.EFI] -u uboot.img
#                     -m MiniLoaderAll.bin КАТАЛОГ
#
#   -s  откуда брать систему: / (по умолчанию) или смонтированный корень образа
#   -d  device tree платы; без ключа остаётся тот, что в источнике
#   -b  GRUB для ESP; по умолчанию КОРЕНЬ/boot/efi/EFI/BOOT/BOOTAA64.EFI
#   -u  прошивка TPI v3.9 (uboot.img)
#   -m  загрузчик Rockchip для MaskROM (MiniLoaderAll.bin)
#
# Прошивки в репозитории нет: в ней заводские payload'ы TF-A и OP-TEE. Оба
# файла есть в комплекте eMMC выпуска (tpi-lazarus-uvon-emmc-debian13.tar.xz);
# прошивка собирается и из исходников, см. TPI-LAZARUS-UVON-UEFI.
#
# Таблица разделов (parameter.txt, gpt.img), перечень для сборщиков Rockchip
# (package-file) и README.txt берутся из os/emmc: раскладка заводская и от ОС
# не зависит.
set -euo pipefail
. "$(dirname "$0")/debian-common.sh"

SRC=/
DTB=""
BOOTEFI=""
UBOOT=""
LOADER=""
while getopts "s:d:b:u:m:" o; do
    case $o in
        s) SRC=$OPTARG ;;
        d) DTB=$OPTARG ;;
        b) BOOTEFI=$OPTARG ;;
        u) UBOOT=$OPTARG ;;
        m) LOADER=$OPTARG ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
OUT=${1:?укажите каталог комплекта}
[ -n "$UBOOT" ] && [ -n "$LOADER" ] ||
    { echo "укажите -u uboot.img и -m MiniLoaderAll.bin (есть в комплекте eMMC выпуска)" >&2; exit 2; }
BOOTEFI=${BOOTEFI:-${SRC%/}/boot/efi/EFI/BOOT/BOOTAA64.EFI}
for f in "$BOOTEFI" "$UBOOT" "$LOADER" ${DTB:+"$DTB"}; do
    [ -s "$f" ] || { echo "нет $f" >&2; exit 1; }
done

ROOTFS_MB=2048
MNT=$(mktemp -d /tmp/tpi-eroot.XXXXXX)
ESPMNT=$(mktemp -d /tmp/tpi-eesp.XXXXXX)
LOOPR=""; LOOPE=""

cleanup() {
    mountpoint -q "$ESPMNT" && umount "$ESPMNT" || true
    mountpoint -q "$MNT" && umount "$MNT" || true
    [ -n "$LOOPE" ] && losetup -d "$LOOPE" 2>/dev/null || true
    [ -n "$LOOPR" ] && losetup -d "$LOOPR" 2>/dev/null || true
    rmdir "$MNT" "$ESPMNT" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$OUT"

echo "== rootfs.img =="
rm -f "$OUT/rootfs.img"
truncate -s ${ROOTFS_MB}M "$OUT/rootfs.img"
"${TPI_MKFS_EXT4[@]}" "$OUT/rootfs.img"
RUUID=$(blkid -s UUID -o value "$OUT/rootfs.img")
LOOPR=$(losetup --show -f "$OUT/rootfs.img")
mount "$LOOPR" "$MNT"

copy_root "$SRC" "$MNT"
scrub_root "$MNT"
install_overlay "$MNT"
[ -z "$DTB" ] || install_dtb "$MNT" "$DTB"
check_root "$MNT"

# ESP здесь отдельный раздел eMMC, а не часть образа корня.
cat > "$MNT/etc/fstab" <<FSTAB
# <file system>	<mount point>	<type>	<options>		<dump> <pass>
UUID=$RUUID	/		ext4	defaults,noatime	0      1
PARTLABEL=boot	/boot/efi	vfat	umask=0077,noauto	0      2
FSTAB
mkdir -p "$MNT/boot/efi"
echo "  корень: $(du -sh --exclude=boot/efi "$MNT" | cut -f1), UUID=$RUUID, ядро $(readlink "$MNT/vmlinuz")"
umount "$MNT"; losetup -d "$LOOPR"; LOOPR=""

echo "== boot.img (ESP) =="
rm -f "$OUT/boot.img"
truncate -s 64M "$OUT/boot.img"
mkfs.vfat -F32 -n TPIESP "$OUT/boot.img" >/dev/null
LOOPE=$(losetup --show -f "$OUT/boot.img")
mount "$LOOPE" "$ESPMNT"
mkdir -p "$ESPMNT/EFI/BOOT"
cp "$BOOTEFI" "$ESPMNT/EFI/BOOT/BOOTAA64.EFI"
write_grub_cfg "$ESPMNT/EFI/BOOT/grub.cfg" "$RUUID" "eMMC: ESP в разделе boot, корень в разделе rootfs"
umount "$ESPMNT"; losetup -d "$LOOPE"; LOOPE=""
echo "  ESP 64 МБ: BOOTAA64.EFI + grub.cfg, корень по UUID=$RUUID"

echo "== прошивка и таблица разделов =="
cp "$LOADER" "$OUT/MiniLoaderAll.bin"
cp "$UBOOT" "$OUT/uboot.img"
cp "$TPI_REPO"/os/emmc/parameter.txt "$TPI_REPO"/os/emmc/package-file \
   "$TPI_REPO"/os/emmc/gpt.img "$TPI_REPO"/os/emmc/README.txt "$OUT/"
echo "  uboot.img: $(basename "$UBOOT") ($(sha256sum "$UBOOT" | cut -c1-12)…)"

ls -l "$OUT" | sed 's/^/  /'
