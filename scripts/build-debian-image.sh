#!/bin/bash
# Собирает распространяемый образ Debian 13 для TPI LAZARUS UVON из работающей
# системы. Всё, что привязано к конкретному экземпляру или является секретом,
# из образа вычищается и заново создаётся при первом запуске.
set -euo pipefail

IMG=${1:-/srv/userdata/tpi-lazarus-uvon-debian13.img}
SIZE_MB=4096
MNT=/mnt/imgroot
ESPMNT=/mnt/imgesp
LOOP=""

cleanup() {
    mountpoint -q "$ESPMNT" && umount "$ESPMNT" || true
    mountpoint -q "$MNT" && umount "$MNT" || true
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

echo "== разметка =="
rm -f "$IMG"
truncate -s ${SIZE_MB}M "$IMG"
sgdisk -Z "$IMG" >/dev/null 2>&1
sgdisk -n 1:2048:+256M -t 1:ef00 -c 1:ESP "$IMG" >/dev/null
sgdisk -n 2:0:0 -t 2:8300 -c 2:rootfs "$IMG" >/dev/null
LOOP=$(losetup --show -fP "$IMG")
echo "  $IMG (${SIZE_MB} МБ) -> $LOOP"

mkfs.vfat -F32 -n TPIESP "${LOOP}p1" >/dev/null
mkfs.ext4 -F -L tpi-root -m 1 -q "${LOOP}p2"
RUUID=$(blkid -s UUID -o value "${LOOP}p2")
EUUID=$(blkid -s UUID -o value "${LOOP}p1")

mkdir -p "$MNT" "$ESPMNT"
mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "${LOOP}p1" "$MNT/boot/efi"

echo "== копирование корня =="
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
echo "  скопировано: $(du -sh --exclude=boot/efi "$MNT" | cut -f1)"

echo "== вычистка секретов и привязок к экземпляру =="
rm -f  "$MNT"/etc/ssh/ssh_host_*
rm -rf "$MNT"/var/lib/tailscale/*
rm -f  "$MNT"/root/.ssh/authorized_keys
rm -f  "$MNT"/etc/systemd/network/20-realtek-*.link
rm -f  "$MNT"/root/.bash_history "$MNT"/root/grubcfg.sh "$MNT"/root/setup-chroot.sh
rm -rf "$MNT"/var/log/journal/* "$MNT"/var/log/*.log
: > "$MNT/etc/machine-id"
rm -f  "$MNT/var/lib/dbus/machine-id"
for f in "$MNT"/var/log/wtmp "$MNT"/var/log/btmp "$MNT"/var/log/lastlog; do : > "$f" 2>/dev/null || true; done
echo "  ключи SSH, состояние Tailscale, authorized_keys, machine-id, MAC-привязки — убраны"

echo "== fstab и меню загрузки =="
cat > "$MNT/etc/fstab" <<FSTAB
# <file system>	<mount point>	<type>	<options>		<dump> <pass>
UUID=$RUUID	/		ext4	defaults,noatime	0      1
UUID=$EUUID	/boot/efi	vfat	umask=0077		0      2
FSTAB

K=$(basename "$(ls "$MNT"/boot/vmlinuz-* | sort | tail -1)")
I=$(basename "$(ls "$MNT"/boot/initrd.img-* | sort | tail -1)")
mkdir -p "$MNT/boot/efi/EFI/BOOT"

# BOOTAA64.EFI берём с рабочего ESP платы — он собран под эту цепочку.
mkdir -p /mnt/liveesp
mount /dev/sda2 /mnt/liveesp
cp /mnt/liveesp/EFI/BOOT/BOOTAA64.EFI "$MNT/boot/efi/EFI/BOOT/"
umount /mnt/liveesp
echo "  BOOTAA64.EFI: $(stat -c %s "$MNT/boot/efi/EFI/BOOT/BOOTAA64.EFI") байт"

cat > "$MNT/boot/efi/EFI/BOOT/grub.cfg" <<CFG
# TPI LAZARUS UVON, Debian 13 с апстримным ядром.
# Ядро, device tree и initramfs читаются с ext4 второго раздела этого же диска.
set timeout=5
set default=0

menuentry "TPI LAZARUS: Debian 13, kernel mainline" {
    search --no-floppy --fs-uuid --set=root $RUUID
    echo "Loading kernel and device tree..."
    linux /boot/$K root=UUID=$RUUID rw rootwait console=ttyS2,115200n8 earlycon=uart8250,mmio32,0xfe660000
    devicetree /boot/dtb/rk3568-tpi-lazarus.dtb
    initrd /boot/$I
}

menuentry "TPI LAZARUS: Debian 13, rescue shell" {
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
echo "  ядро $K, DTB rk3568-tpi-lazarus.dtb, корень UUID=$RUUID"

echo "== первичная настройка при первом запуске =="
cat > "$MNT/usr/local/sbin/tpi-firstboot" <<'FIRST'
#!/bin/bash
# Выполняется один раз после записи образа на носитель.
set -u

echo "TPI: первичная настройка"

# Ключи хоста SSH: из образа они удалены намеренно, иначе все платы
# оказались бы с одними и теми же приватными ключами.
ssh-keygen -A

# Свой machine-id: от него зависят и MAC, которые systemd выводит для карт,
# и идентичность узла Tailscale.
systemd-machine-id-setup

# Корень растягиваем на весь носитель: образ собран под 4 ГБ, а диск больше.
ROOTDEV=$(findmnt -no SOURCE /)
PART=${ROOTDEV##*[!0-9]}
DISK=/dev/$(lsblk -no PKNAME "$ROOTDEV")
if growpart "$DISK" "$PART"; then
    resize2fs "$ROOTDEV"
    echo "TPI: корень растянут на весь носитель"
fi

# MAC для карт RTL8111H: своего EEPROM у них нет, ядро берёт случайный адрес
# каждую загрузку. Продолжаем блок, который U-Boot выводит для встроенного
# порта из идентификатора кристалла, чтобы все адреса платы были связными.
BASE=$(cat /sys/class/net/end0/address 2>/dev/null || true)
if [ -n "$BASE" ]; then
    PFX=${BASE%:*}
    LAST=$(( 0x${BASE##*:} ))
    i=2
    for path in platform-3c0400000.pcie-pci-0001:01:00.0 \
                platform-3c0800000.pcie-pci-0002:01:00.0; do
        printf '[Match]\nPath=%s\nDriver=r8169\n\n[Link]\nMACAddress=%s:%02x\n' \
            "$path" "$PFX" "$(( (LAST + i) & 0xff ))" \
            > "/etc/systemd/network/20-realtek-$i.link"
        i=$((i + 1))
    done
    echo "TPI: MAC для карт выведены из $BASE"
fi

rm -f /var/lib/tpi-firstboot-pending
systemctl disable tpi-firstboot.service >/dev/null 2>&1 || true
echo "TPI: первичная настройка завершена"
FIRST
chmod 755 "$MNT/usr/local/sbin/tpi-firstboot"

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
echo "  служба tpi-firstboot включена, маркер поставлен"

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


sync
echo "== готово =="
df -h "$MNT" | tail -1 | sed 's/^/  /'
