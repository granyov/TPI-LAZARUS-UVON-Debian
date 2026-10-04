#!/bin/bash
# Обновляет пакеты в смонтированном корне Debian 13 (через chroot) и ставит
# то, что нужно образу платы сверх базовой системы.
#
#   update-debian-root.sh КОРЕНЬ [ПАКЕТ.deb …]
#
# ПАКЕТ.deb — локальные пакеты, если нужны.
# Службы внутри chroot не запускаются: /run — пустой tmpfs, а policy-rc.d
# запрещает invoke-rc.d что-либо стартовать.
set -euo pipefail

R=$(cd "${1:?укажите корень}" && pwd)
shift
[ "$R" != / ] || { echo "корень работающей системы обновляйте обычным apt" >&2; exit 1; }

# util-linux-extra — hwclock для батарейных часов (tpi-rtc.service), в
# минимальной Debian его нет; openocd — прошивка мостов GD32F103 портов V.24
# программатором ST-Link, воткнутым в USB самой платы; picocom — проверка
# портов после прошивки.
EXTRA=(util-linux-extra openocd picocom)

MOUNTS=()
RESOLV_LINK=""
cleanup() {
    local i
    for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
        umount "${MOUNTS[$i]}" 2>/dev/null || umount -l "${MOUNTS[$i]}" || true
    done
    rm -f "$R/usr/sbin/policy-rc.d"
    rm -rf "$R/tmp/tpi-debs"
    if [ -n "$RESOLV_LINK" ]; then
        rm -f "$R/etc/resolv.conf"
        ln -s "$RESOLV_LINK" "$R/etc/resolv.conf"
    fi
}
trap cleanup EXIT

# Простые bind без rbind, и каждый — rslave: при общей (shared) propagation,
# которую ставит systemd, монтирование и отмонтирование внутри chroot иначе
# отражались бы на /dev хоста.
mount -t proc proc "$R/proc";        MOUNTS+=("$R/proc")
mount -t sysfs sysfs "$R/sys";       MOUNTS+=("$R/sys")
mount --bind /dev "$R/dev";          MOUNTS+=("$R/dev")
mount --make-rslave "$R/dev"
mount --bind /dev/pts "$R/dev/pts";  MOUNTS+=("$R/dev/pts")
mount --make-rslave "$R/dev/pts"
mount -t tmpfs tmpfs "$R/run";       MOUNTS+=("$R/run")

# Сеть: resolv.conf образа — ссылка на заглушку systemd-resolved, которой в
# chroot нет. На время работы кладём настоящий файл хоста.
if [ -L "$R/etc/resolv.conf" ]; then
    RESOLV_LINK=$(readlink "$R/etc/resolv.conf")
    rm -f "$R/etc/resolv.conf"
fi
cat /etc/resolv.conf > "$R/etc/resolv.conf"

printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"
chmod 755 "$R/usr/sbin/policy-rc.d"

DEBS=()
if [ $# -gt 0 ]; then
    mkdir -p "$R/tmp/tpi-debs"
    for d in "$@"; do
        cp "$d" "$R/tmp/tpi-debs/"
        DEBS+=("/tmp/tpi-debs/$(basename "$d")")
    done
fi

in_root() {
    chroot "$R" env DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}
APT=(apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "== обновление пакетов =="
in_root apt-get update
in_root "${APT[@]}" full-upgrade
echo "== дополнительные пакеты: ${EXTRA[*]} ${DEBS[*]} =="
in_root "${APT[@]}" install --no-install-recommends "${EXTRA[@]}" "${DEBS[@]}"

# Исходники ядра в образ не идут (copy_root их исключает), а пакет остался бы
# «установленным» без своего архива, и apt тянул бы 150 МБ при каждом
# обновлении ядра. Для сборки device tree на плате — apt install linux-source-6.12.
mapfile -t SRCPKGS < <(in_root dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'linux-source-*' 2>/dev/null |
                       awk '$1 == "ii" {print $2}')
if [ ${#SRCPKGS[@]} -gt 0 ]; then
    echo "== удаляю исходники ядра: ${SRCPKGS[*]} =="
    in_root "${APT[@]}" purge "${SRCPKGS[@]}"
fi

# Старые ядра: остаётся одно, новейшее, — на него указывает /vmlinuz.
mapfile -t KERNELS < <(in_root dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'linux-image-[0-9]*' |
                       awk '$1 == "ii" {print $2}' | sort -V)
if [ ${#KERNELS[@]} -gt 1 ]; then
    echo "== удаляю старые ядра: ${KERNELS[*]:0:${#KERNELS[@]}-1} =="
    in_root "${APT[@]}" purge "${KERNELS[@]:0:${#KERNELS[@]}-1}"
fi
in_root "${APT[@]}" autoremove --purge
in_root apt-get clean

echo "== итог =="
in_root dpkg-query -W -f '${Package} ${Version}\n' 'linux-image-[0-9]*' "${EXTRA[@]}" 2>/dev/null | sed 's/^/  /' || true
ls -l "$R/vmlinuz" "$R/initrd.img" | sed 's/^/  /'
