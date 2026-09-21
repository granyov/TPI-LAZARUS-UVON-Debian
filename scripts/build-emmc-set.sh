#!/bin/bash
# Собирает комплект образов для прошивки всей платы в eMMC: раздел ESP и корень.
# Прошивка (uboot.img) берётся готовая, MiniLoaderAll — тоже.
#
# Раскладка eMMC задана заводской: boot 64 МБ @ 32768, rootfs 6 ГБ @ 491520.
set -euo pipefail

OUT=${1:-/srv/userdata/emmc-set}
ROOTFS_MB=2048
MNT=/mnt/eroot
ESPMNT=/mnt/eesp
LOOPR=""; LOOPE=""

cleanup() {
    mountpoint -q "$MNT/boot/efi" && umount "$MNT/boot/efi" || true
    mountpoint -q "$ESPMNT" && umount "$ESPMNT" || true
    mountpoint -q "$MNT" && umount "$MNT" || true
    [ -n "$LOOPE" ] && losetup -d "$LOOPE" 2>/dev/null || true
    [ -n "$LOOPR" ] && losetup -d "$LOOPR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$OUT" "$MNT" "$ESPMNT"

echo "== rootfs.img =="
rm -f "$OUT/rootfs.img"
truncate -s ${ROOTFS_MB}M "$OUT/rootfs.img"
mkfs.ext4 -F -L tpi-root -m 1 -q "$OUT/rootfs.img"
RUUID=$(blkid -s UUID -o value "$OUT/rootfs.img")
LOOPR=$(losetup --show -f "$OUT/rootfs.img")
mount "$LOOPR" "$MNT"

rsync -aHAX --numeric-ids \
  --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' \
  --exclude='/tmp/*' --exclude='/mnt/*' --exclude='/media/*' \
  --exclude='/srv/*' --exclude='/bootchain/*' --exclude='/boot/efi/*' \
  --exclude='/lost+found' --exclude='/var/tmp/*' \
  --exclude='/var/cache/apt/archives/*.deb' \
  --exclude='/var/lib/apt/lists/*' \
  --exclude='/usr/src/linux-source-*' \
  --exclude='/var/log/journal/*' \
  / "$MNT/"

# вычистка секретов и привязок к экземпляру
rm -f  "$MNT"/etc/ssh/ssh_host_*
rm -rf "$MNT"/var/lib/tailscale/*
rm -f  "$MNT"/root/.ssh/authorized_keys
rm -f  "$MNT"/etc/systemd/network/20-realtek-*.link
rm -f  "$MNT"/root/.bash_history "$MNT"/root/*.sh
rm -rf "$MNT"/var/log/journal/* "$MNT"/var/log/*.log
: > "$MNT/etc/machine-id"
rm -f  "$MNT/var/lib/dbus/machine-id"
for f in wtmp btmp lastlog; do : > "$MNT/var/log/$f" 2>/dev/null || true; done

K=$(basename "$(ls "$MNT"/boot/vmlinuz-* | sort | tail -1)")
I=$(basename "$(ls "$MNT"/boot/initrd.img-* | sort | tail -1)")

# ESP здесь отдельный раздел eMMC, а не файл внутри корня
cat > "$MNT/etc/fstab" <<FSTAB
# <file system>	<mount point>	<type>	<options>		<dump> <pass>
UUID=$RUUID	/		ext4	defaults,noatime	0      1
PARTLABEL=boot	/boot/efi	vfat	umask=0077,noauto	0      2
FSTAB
mkdir -p "$MNT/boot/efi"

# Служба первого запуска. В eMMC раздел уже полного размера, поэтому growpart
# там ничего не меняет — resize2fs должен выполняться в любом случае.
install -m 755 /root/tpi-firstboot "$MNT/usr/local/sbin/tpi-firstboot"
cat > "$MNT/etc/systemd/system/tpi-firstboot.service" <<'UNIT'
[Unit]
Description=Первичная настройка TPI LAZARUS UVON после записи образа
ConditionPathExists=/var/lib/tpi-firstboot-pending
After=local-fs.target
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tpi-firstboot
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/tpi-firstboot.service \
       "$MNT/etc/systemd/system/multi-user.target.wants/tpi-firstboot.service"
touch "$MNT/var/lib/tpi-firstboot-pending"

# Батарейные часы. Номера rtc0/rtc1 не фиксированы: часы внутри PMIC и внешний
# HYM8563 регистрируются наперегонки. Алиас rtc0 в device tree не помогает —
# часы PMIC создаются как устройство без узла DT и занимают нулевой номер
# первыми. Поэтому даём HYM8563 устойчивое имя и берём время из него.
cat > "$MNT/etc/udev/rules.d/60-tpi-rtc.rules" <<'RTCRULE'
SUBSYSTEM=="rtc", ATTR{name}=="rtc-hym8563*", SYMLINK+="rtc-battery"
RTCRULE
cat > "$MNT/etc/systemd/system/tpi-rtc.service" <<'RTCUNIT'
[Unit]
Description=Взять время из батарейных часов платы
DefaultDependencies=no
After=systemd-udev-settle.service
Before=sysinit.target time-set.target
ConditionPathExists=/dev/rtc-battery

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/hwclock --rtc /dev/rtc-battery --hctosys
ExecStop=/usr/sbin/hwclock --rtc /dev/rtc-battery --systohc

[Install]
WantedBy=sysinit.target
RTCUNIT
mkdir -p "$MNT/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/tpi-rtc.service \
       "$MNT/etc/systemd/system/sysinit.target.wants/tpi-rtc.service"
echo "  часы: HYM8563 назначен источником времени"

echo "  корень: $(du -sh --exclude=boot/efi "$MNT" | cut -f1), UUID=$RUUID"
umount "$MNT"; losetup -d "$LOOPR"; LOOPR=""

echo "== boot.img (ESP) =="
rm -f "$OUT/boot.img"
truncate -s 64M "$OUT/boot.img"
mkfs.vfat -F32 -n TPIESP "$OUT/boot.img" >/dev/null
LOOPE=$(losetup --show -f "$OUT/boot.img")
mount "$LOOPE" "$ESPMNT"
mkdir -p "$ESPMNT/EFI/BOOT"

mkdir -p /mnt/liveesp
mount /dev/sda2 /mnt/liveesp
cp /mnt/liveesp/EFI/BOOT/BOOTAA64.EFI "$ESPMNT/EFI/BOOT/"
umount /mnt/liveesp

cat > "$ESPMNT/EFI/BOOT/grub.cfg" <<CFG
# TPI LAZARUS UVON, Debian 13 целиком в eMMC.
# Этот ESP лежит в разделе boot, корень — в разделе rootfs того же eMMC.
set timeout=5
set default=0

menuentry "TPI LAZARUS: Debian 13, kernel mainline (eMMC)" {
    search --no-floppy --fs-uuid --set=root $RUUID
    echo "Loading kernel and device tree from eMMC..."
    linux /boot/$K root=UUID=$RUUID rw rootwait console=ttyS2,115200n8 earlycon=uart8250,mmio32,0xfe660000
    devicetree /boot/dtb/rk3568-tpi-lazarus.dtb
    initrd /boot/$I
}

menuentry "TPI LAZARUS: Debian 13, rescue shell (eMMC)" {
    search --no-floppy --fs-uuid --set=root $RUUID
    linux /boot/$K root=UUID=$RUUID rw rootwait console=ttyS2,115200n8 systemd.unit=rescue.target
    devicetree /boot/dtb/rk3568-tpi-lazarus.dtb
    initrd /boot/$I
}

menuentry "List block devices seen by GRUB" {
    ls
    sleep 20
}
CFG
umount "$ESPMNT"; losetup -d "$LOOPE"; LOOPE=""
echo "  ESP 64 МБ: BOOTAA64.EFI + grub.cfg, корень по UUID=$RUUID"

echo "== остальные части комплекта =="
cp /srv/userdata/TPI-LAZARUS-MiniLoaderAll-v1.0.bin "$OUT/MiniLoaderAll.bin"
cp /srv/userdata/TPI-LAZARUS-U-Boot-2024.04-SATA-UEFI-v3.7.img "$OUT/uboot.img"
echo "  MiniLoaderAll.bin и uboot.img на месте"

ls -l "$OUT" | sed 's/^/  /'
