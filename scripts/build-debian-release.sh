#!/bin/bash
# Выпуск Debian 13 для TPI LAZARUS UVON целиком — из образа предыдущего
# выпуска: обновление пакетов, образ диска, комплект для eMMC, update.img для
# RKDevTool, архивы и контрольные суммы.
#
#   build-debian-release.sh -d DTB -u uboot.img -m MiniLoaderAll.bin БАЗА.img КАТАЛОГ [ПАКЕТ.deb …]
#
#   -d        device tree, собранный из os/rk3568-tpi-lazarus.dts
#   -u, -m    прошивка TPI v3.9 и загрузчик Rockchip для комплекта eMMC —
#             оба есть в комплекте eMMC выпуска, см. build-emmc-set.sh
#   БАЗА.img  распакованный образ предыдущего выпуска, сам он не меняется
#   ПАКЕТ.deb локальные пакеты для образа, если нужны
#
# Запускается на arm64 от root. Нужно около 15 ГБ свободного места в КАТАЛОГЕ.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

DTB=""
UBOOT=""
LOADER=""
while getopts "d:u:m:" o; do
    case $o in
        d) DTB=$OPTARG ;;
        u) UBOOT=$(realpath "$OPTARG") ;;
        m) LOADER=$(realpath "$OPTARG") ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
BASE=${1:?укажите базовый образ}
OUT=${2:?укажите каталог выпуска}
shift 2
[ -n "$DTB" ] && [ -s "$DTB" ] || { echo "укажите -d DTB" >&2; exit 1; }
[ -s "$UBOOT" ] && [ -s "$LOADER" ] || { echo "укажите -u uboot.img и -m MiniLoaderAll.bin" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "нужна arm64-система: пакеты ставятся через chroot" >&2; exit 1; }

mkdir -p "$OUT/work/base"
OUT=$(cd "$OUT" && pwd)
W=$OUT/work
LOOP=""
cleanup() {
    mountpoint -q "$W/base/boot/efi" && umount "$W/base/boot/efi" || true
    mountpoint -q "$W/base" && umount "$W/base" || true
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

NAME=tpi-lazarus-uvon-debian13
EMMC=tpi-lazarus-uvon-emmc-debian13
UPD=tpi-lazarus-uvon-update

echo "=== база: $BASE ($(sha256sum "$BASE" | cut -c1-12)…)"
cp --sparse=always "$BASE" "$W/base.img"
LOOP=$(losetup --show -fP "$W/base.img")
mount "${LOOP}p2" "$W/base"
mount "${LOOP}p1" "$W/base/boot/efi"

echo "=== пакеты"
"$HERE/update-debian-root.sh" "$W/base" "$@"

echo "=== образ диска"
"$HERE/build-debian-image.sh" -s "$W/base" -d "$DTB" "$OUT/$NAME.img"

echo "=== комплект eMMC"
rm -rf "${W:?}/$EMMC"
"$HERE/build-emmc-set.sh" -s "$W/base" -d "$DTB" -u "$UBOOT" -m "$LOADER" "$W/$EMMC"
python3 "$HERE/build-update-img.py" "$W/$EMMC" "$OUT/$UPD.img"

echo "=== упаковка"
# xz -6, а не -9: при -9 каждому потоку нужно около 670 МБ, и на плате с 4 ГБ
# xz урезал бы число потоков до одного. zstd -15: -19 на ядрах A55 жмёт образ
# больше получаса, а выигрывает в размере несколько процентов.
cp "$DTB" "$OUT/rk3568-tpi-lazarus.dtb"
xz -T0 -6 -k -f "$OUT/$NAME.img"
zstd -T0 -15 -q -f "$OUT/$NAME.img" -o "$OUT/$NAME.img.zst"
tar -C "$W" --owner=0 --group=0 --numeric-owner -cf - "$EMMC" | xz -T0 -6 > "$OUT/$EMMC.tar.xz"
xz -T0 -6 -k -f "$OUT/$UPD.img"
# В SHA256SUMS — только выкладываемые файлы; суммы распакованных образов
# печатаются отдельно, для описания выпуска.
(cd "$OUT" && sha256sum "$NAME.img.xz" "$NAME.img.zst" "$EMMC.tar.xz" "$UPD.img.xz" \
                        rk3568-tpi-lazarus.dtb > SHA256SUMS-debian13)
sed 's/^/  /' "$OUT/SHA256SUMS-debian13"
echo "  распакованные:"
(cd "$OUT" && sha256sum "$NAME.img" "$UPD.img" && stat -c '%n %s' "$NAME.img" "$UPD.img") | sed 's/^/    /'
ls -l "$OUT" | sed 's/^/  /'
