# shellcheck shell=bash
# Общие шаги сборки Debian 13 для TPI LAZARUS UVON. Подключается из
# build-debian-image.sh и build-emmc-set.sh, сам не запускается.

TPI_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TPI_OVERLAY=$TPI_REPO/os/rootfs

# Корень ext4 без orphan_file: эту возможность понимают только e2fsprogs 1.47+,
# а e2fsck и tune2fs старее (Astra 4.7, Ubuntu 22.04) отказываются работать с
# такой ФС — например, когда установщик выдаёт копии образа новые UUID.
# shellcheck disable=SC2034  # используется в build-*.sh
TPI_MKFS_EXT4=(mkfs.ext4 -F -L tpi-root -m 1 -q -O ^orphan_file)

# Консоль платы: UART2, та же скорость, что у прошивки v3.9.
TPI_CONSOLE="console=ttyS2,1500000n8"
TPI_EARLYCON="earlycon=uart8250,mmio32,0xfe660000"

# copy_root ИСТОЧНИК КУДА — копия корня без виртуальных ФС, кешей и журналов.
# ИСТОЧНИК — / (работающая система) или смонтированный корень другого образа.
copy_root() {
    local src=${1%/} dst=$2
    rsync -aHAX --numeric-ids \
      --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' \
      --exclude='/tmp/*' --exclude='/mnt/*' --exclude='/media/*' \
      --exclude='/srv/*' --exclude='/bootchain/*' --exclude='/boot/efi/*' \
      --exclude='/lost+found' --exclude='/var/tmp/*' \
      --exclude='/var/cache/apt/archives/*.deb' \
      --exclude='/var/lib/apt/lists/*' \
      --exclude='/usr/src/linux-source-*' \
      --exclude='/var/log/journal/*' \
      "$src/" "$dst/"
}

# scrub_root КОРЕНЬ — убирает секреты и всё, что привязано к экземпляру;
# при первом запуске это создаётся заново.
scrub_root() {
    local r=$1 f
    rm -f  "$r"/etc/ssh/ssh_host_*
    rm -rf "$r"/var/lib/tailscale/*
    rm -f  "$r"/root/.ssh/authorized_keys
    rm -f  "$r"/etc/systemd/network/20-realtek-*.link "$r"/etc/systemd/network/20-tpi-realtek-*.link
    # В /root образа — только .bashrc, .profile и пустой .ssh: рабочие файлы,
    # история и настройки программ остаются на машине сборки.
    find "$r/root" -mindepth 1 -maxdepth 1 ! -name .bashrc ! -name .profile ! -name .ssh \
         -exec rm -rf {} +
    # Затравка генератора случайных чисел у каждой платы должна быть своей.
    rm -f  "$r/var/lib/systemd/random-seed"
    rm -rf "$r"/var/log/journal/* "$r"/var/log/*.log
    rm -f  "$r"/var/lib/wtmpdb/wtmp.db "$r"/var/lib/lastlog/lastlog2.db
    for f in wtmp btmp lastlog; do
        if [ -e "$r/var/log/$f" ]; then : > "$r/var/log/$f"; fi
    done
    : > "$r/etc/machine-id"
    rm -f  "$r/var/lib/dbus/machine-id"
}

# install_overlay КОРЕНЬ — файлы платы из os/rootfs: первая настройка, часы,
# имена портов, автовход на консоли. Права берутся из репозитория, каталоги
# корня не трогаются.
install_overlay() {
    local r=$1 f rel
    while IFS= read -r f; do
        rel=${f#"$TPI_OVERLAY"/}
        install -D -o root -g root -m "$(stat -c %a "$f")" "$f" "$r/$rel"
    done < <(find "$TPI_OVERLAY" -type f | sort)
    mkdir -p "$r/etc/systemd/system/multi-user.target.wants"
    ln -sfn /etc/systemd/system/tpi-firstboot.service \
            "$r/etc/systemd/system/multi-user.target.wants/tpi-firstboot.service"
    # tpi-rtc запускает udev по появлению часов; прежняя привязка к sysinit.target
    # (из снимка работающей системы) не нужна.
    rm -f "$r/etc/systemd/system/sysinit.target.wants/tpi-rtc.service"
    touch "$r/var/lib/tpi-firstboot-pending"
}

# install_dtb КОРЕНЬ DTB — device tree платы в /boot/dtb.
install_dtb() {
    install -D -m 644 "$2" "$1/boot/dtb/rk3568-tpi-lazarus.dtb"
}

# write_grub_cfg ФАЙЛ UUID-КОРНЯ ПОДПИСЬ — меню GRUB на ESP. Ядро и initramfs
# берутся по ссылкам /vmlinuz и /initrd.img, которые Debian сам переставляет
# при обновлении ядра: после apt upgrade grub.cfg править не нужно.
write_grub_cfg() {
    local cfg=$1 ruuid=$2 where=$3
    cat > "$cfg" <<CFG
# TPI LAZARUS UVON, Debian 13 с апстримным ядром ($where).
# Ядро, device tree и initramfs читаются с ext4-корня, найденного по UUID.
# /vmlinuz и /initrd.img — ссылки, которые Debian ведёт сам.
set timeout=5
set default=0

menuentry "TPI LAZARUS: Debian 13" {
    search --no-floppy --fs-uuid --set=root $ruuid
    echo "Loading kernel and device tree..."
    linux /vmlinuz root=UUID=$ruuid rw rootwait $TPI_CONSOLE $TPI_EARLYCON
    devicetree /boot/dtb/rk3568-tpi-lazarus.dtb
    initrd /initrd.img
}

menuentry "TPI LAZARUS: Debian 13, rescue shell" {
    search --no-floppy --fs-uuid --set=root $ruuid
    linux /vmlinuz root=UUID=$ruuid rw rootwait $TPI_CONSOLE systemd.unit=rescue.target
    devicetree /boot/dtb/rk3568-tpi-lazarus.dtb
    initrd /initrd.img
}

menuentry "List block devices seen by GRUB" {
    ls
    sleep 20
}
CFG
}

# check_root КОРЕНЬ — то, без чего образ не загрузится.
check_root() {
    local r=$1
    [ -e "$r/vmlinuz" ] && [ -e "$r/initrd.img" ] ||
        { echo "в корне нет ссылок /vmlinuz и /initrd.img" >&2; return 1; }
    [ -s "$r/boot/dtb/rk3568-tpi-lazarus.dtb" ] ||
        { echo "в корне нет /boot/dtb/rk3568-tpi-lazarus.dtb" >&2; return 1; }
}
