# Debian 13 с апстримным ядром

Плата умеет загружать не только заводскую систему Forlinx. Поскольку наш U-Boot
является UEFI-прошивкой и передаёт управление GRUB, ядро, device tree и корневая
файловая система меняются независимо друг от друга и без единого касания
прошивки в eMMC.

На стенде так поставлен **Debian 13 (trixie) с ядром 6.12** — обычным
дистрибутивным, не вендорским. Заводская Ubuntu остаётся на eMMC нетронутой,
выбор системы — пункт меню GRUB.

## Зачем это может понадобиться

Заводская система построена на Ubuntu 20.04 и ядре Forlinx 5.10.160 (сборка
сентября 2024). Focal вышел из стандартной поддержки в апреле 2025, а вендорское
ядро апстримных исправлений не получает в принципе. Апстримное ядро снимает обе
проблемы сразу.

Плата работает без дисплея, и всё, что она реально использует, апстрим
поддерживает. Проверено на железе:

| Подсистема | Драйвер | Состояние |
|---|---|---|
| SATA | `ahci-dwc` + `phy-rockchip-naneng-combphy` | `SATA link up 6.0 Gbps`, корень отсюда |
| Ethernet ×2 (RGMII) | `rk_gmac-dwmac` | 1 Гбит/с, DHCP |
| Ethernet ×2 (PCIe) | `pcie-rockchip-dw` + `r8169` | оба линка `Gen.1 x1`, вендорский `r8168` не нужен |
| OP-TEE | `optee` | `revision 3.13`, `/dev/tee0`, `/dev/teepriv0` |
| eMMC | `sdhci-dwcmshc` | все 8 разделов |
| microSD | `dwmmc_rockchip` | `/dev/mmcblk1` |
| RTC | `rtc-hym8563` | на i2c3, адрес `0x51` |
| Питание, IO-домены | `rk8xx`, `fan53555`, `rockchip-iodomain` | RK809 + TCS4525 |
| Термодатчики | `rockchip-thermal` | cpu и gpu зоны |
| USB, FT4232H | `dwc3`, `xhci`, `ftdi_sio` | 8 × `ttyUSB` |
| RGA, видеокодеки | `rockchip-rga`, `hantro-vpu` | `/dev/video0..2` |

Вендорским остаётся только то, чем плата не пользуется: NPU и вендорский DVFS
(`rockchip-dmc`, `dfi`, `pvtm`). Заодно исчезает `rk-fiq-debugger` — консоль
становится обычной `ttyS2`, и пропадает перехват порта на байтах `fiq`
(см. документации стенда).

## Раскладка на стенде

```
/dev/mmcblk0   eMMC, 29.1 ГБ
  p1 uboot     прошивка (две копии FIT) — НЕ ТРОГАТЬ
  p6 uvon-data /srv/emmc, 5.9 ГБ
  p7 oem       заводские демо-файлы, ФС 15 МБ в разделе 128 МБ
  p8 userdata  /srv/userdata, 22.5 ГБ (ФС пересоздана с блоком 4 КБ)
/dev/sda       SATA SSD, 119.2 ГБ
  sda1 ext4    Debian 13, ядро 6.12, здесь же /bootchain
  sda2 vfat    ESP: BOOTAA64.EFI, grub.cfg, ubootefi.var
```

Раздел `p6` раньше нёс заводскую Ubuntu; после отказа от неё он переформатирован
под данные. Перед этим с него сохранены заводские конфиги и прошивки в
`/bootchain/vendor-ubuntu/` — заводские ядро и оба device tree и так лежали в
`/bootchain/boot/`.

Прошивку в `p1` менять можно только через `rockusb`, обычными средствами ОС
туда писать нельзя. GPT переразбивать не стоит: `rkdeveloptool` работает с
разделами по именам, и порча таблицы отрежет канал обновления прошивки.

Заводской образ создал файловые системы заметно меньше самих разделов: в `p8`
под 22.8 ГБ было размечено всего 467 МБ. Расширяется это на месте, без
переразбивки и без потери содержимого:

```sh
umount /dev/mmcblk0p8 2>/dev/null
e2fsck -f /dev/mmcblk0p8
resize2fs /dev/mmcblk0p8
```

### Почему расширения недостаточно

У заводских файловых систем размер блока 1 КБ. Для раздела на пол-гигабайта это
неважно, но при расширении до 22.8 ГБ число inode растёт вместе с числом групп
блоков — и доходит до **5 948 640** штук там, где нужны единицы тысяч. Таблицы
inode занимают при этом около 1.4 ГБ: из 22.8 ГБ раздела остаётся доступен
21.3 ГБ.

`resize2fs` размер блока менять не умеет, поэтому файловая система пересоздана:

```sh
umount /srv/userdata
mkfs.ext4 -F -b 4096 -m 0 -i 65536 -L userdata /dev/mmcblk0p8
mount /srv/userdata
```

`-i 65536` — один inode на 64 КБ: умолчание ext4 (16 КБ) дало бы 1.4 млн inode
и около 370 МБ таблиц, а так их 375 тысяч, чего с запасом хватает и для
множества мелких файлов. `-m 0` отменяет резерв 5 % под root, который на
разделе с данными не нужен.

Результат: накладные расходы **264 МБ вместо 1469**, доступно 22.5 ГБ, и блок
4 КБ вместо 1 КБ — для крупных файлов это ещё и заметно быстрее.

Содержимое раздела при этом теряется. Здесь терять было нечего: 456 МБ
вендорских сэмплов для проверки кодеков. Всё мельче 5 МБ, включая заводские
скрипты прогона GPIO и логи recovery, сохранено в
`/bootchain/vendor-ubuntu/userdata-small.tar.gz`.

Раздел `p6` пересоздавать не стали: там умолчания ext4 дают 184 МБ расходов на
6 ГБ, то есть 3 %, и возиться ради восьмидесяти мегабайт незачем.

## Установка базовой системы

Разворачивается прямо с платы — она aarch64, эмуляция не нужна. `debootstrap`
из Ubuntu 20.04 не знает `trixie` и может напутать с объединённым `/usr`,
поэтому ставится настоящий, из Debian, вместе со свежей связкой ключей
(в версии Ubuntu ключа `trixie` нет):

```sh
curl -sSLO http://deb.debian.org/debian/pool/main/d/debootstrap/debootstrap_1.0.145_all.deb
curl -sSLO http://deb.debian.org/debian/pool/main/d/debian-archive-keyring/debian-archive-keyring_2025.1_all.deb
dpkg -i debian-archive-keyring_2025.1_all.deb debootstrap_1.0.145_all.deb

mount /dev/sda1 /mnt/sata
debootstrap --arch=arm64 \
  --include=ca-certificates,openssh-server,sudo,curl,less,locales,dbus,systemd-timesyncd \
  trixie /mnt/sata http://deb.debian.org/debian
```

Дальше обычная настройка в chroot: `sources.list`, `fstab` по UUID, hostname,
ключи в `/root/.ssh/authorized_keys`, `systemd-networkd` и ядро:

```sh
apt-get install --no-install-recommends \
    linux-image-arm64 initramfs-tools firmware-realtek \
    systemd-resolved systemd-timesyncd pciutils usbutils ethtool \
    i2c-tools device-tree-compiler
systemctl enable systemd-networkd systemd-resolved ssh serial-getty@ttyS2
```

Два момента, которые легко упустить.

**DHCP по MAC.** `systemd-networkd` по умолчанию представляется DUID, а
NetworkManager в заводской системе — MAC-адресом, поэтому маршрутизатор выдаёт
другую аренду и адрес платы меняется. Лечится строкой в `.network`:

```ini
[DHCPv4]
ClientIdentifier=mac
```

**Консоль.** После `debootstrap` пароль root заблокирован, и войти через
последовательный порт невозможно — при отказе сети система окажется
недоступной. Нужен автологин, как и в заводской системе:

```ini
# /etc/systemd/system/serial-getty@ttyS2.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 %I $TERM
```

Опцию `-o "-p -- \u"` из штатного юнита надо именно **убрать**, а не дополнить
`--autologin`. Вместе они дают `/bin/login -p --` с пустым именем пользователя
вместо `/bin/login -- root`, и вместо автоматического входа получается обычное
приглашение. Признак — `login -p --` в `systemctl show ... -p MainPID` вместо
`login -- root`.

Доступ к последовательному порту при этом равносилен root — ровно как в
заводской системе, но учитывать это надо.

## Device tree

Своего описания этой платы в апстриме нет: среди 38 файлов `rk3568*` Forlinx
отсутствует. Наше — `os/rk3568-tpi-lazarus.dts`, написано поверх `rk3568.dtsi`
по схеме Э3 и сверено с заводским device tree.

Собирается на самой плате, исходниками именно того ядра, которое будет его
исполнять:

```sh
apt-get install linux-source-6.12
cd /usr/src
tar xf linux-source-6.12.tar.xz --wildcards \
    'linux-source-6.12/arch/arm64/boot/dts/*' \
    'linux-source-6.12/include/dt-bindings/*'
cd linux-source-6.12
cp /path/to/rk3568-tpi-lazarus.dts arch/arm64/boot/dts/rockchip/

cpp -nostdinc -I include -I arch/arm64/boot/dts -I arch/arm64/boot/dts/rockchip \
    -undef -D__DTS__ -x assembler-with-cpp \
    arch/arm64/boot/dts/rockchip/rk3568-tpi-lazarus.dts -o /tmp/pre.dts
dtc -I dts -O dtb -@ -o /boot/dtb/rk3568-tpi-lazarus.dtb /tmp/pre.dts
```

Распаковывать всё дерево незачем: нужны только dts и биндинги, это около 31 МБ.

### Три места, где легко ошибиться

**RTC живёт на i2c3, а не на i2c5.** В заводском device tree он на
`i2c@fe5c0000`, и это именно i2c3 — i2c5 имел бы адрес `fe5e0000`. Ошибка тихая:
дерево собирается, система грузится, просто часов нет.

**PHY PCIe 3.0 надо явно развести на две линии.** Без `data-lanes = <1 2>` на
`&pcie30phy` драйвер агрегирует обе линии в `pcie3x2`, и тогда не обучается ни
один линк — в журнале `Phy link never came up`.

**Линии PERST# приходится скрестить относительно их имён в схеме.** По схеме
`GPIO0_C3` — это `PCIE30X1_PERSTn_M0` и идёт к карте на линии 0, `GPIO0_C6` —
`PCIE30X2_PERSTn_M0` к карте на линии 1; заводской драйвер так их и расписывает.
Апстримный в режиме разделения сажает `pcie3x1` на линию 1, а `pcie3x2` на
линию 0, то есть наоборот. Это установлено опытом, а не выведено: с «прямой»
раскладкой поднимается ровно один линк из двух, со скрещенной — оба.

## Пункт меню GRUB

`grub.cfg` лежит на ESP (`/dev/sda2`, `EFI/BOOT/grub.cfg`). Ядро, initramfs и
DTB читаются с ext4 того же диска:

```text
menuentry 'TPI LAZARUS: Debian 13, kernel 6.12 mainline (rootfs on SATA)' {
    search --no-floppy --fs-uuid --set=root <UUID sda1>
    linux /boot/vmlinuz-6.12.107+deb13-arm64 root=UUID=<UUID sda1> rw rootwait \
          console=ttyS2,115200n8 earlycon=uart8250,mmio32,0xfe660000
    devicetree /boot/dtb/rk3568-tpi-lazarus.dtb
    initrd /boot/initrd.img-6.12.107+deb13-arm64
}
```

Консоль здесь `ttyS2`, а не вендорская `ttyFIQ0`, и вендорский параметр
`storagemedia=emmc` не нужен. Ядро Debian для arm64 — несжатый PE32+ EFI, GRUB
берёт его напрямую.

Заводская система из меню убрана: её ядро вешает плату (см. ниже), так что
пункт был не запасным вариантом, а миной. Вместо него — аварийный вход тем же
ядром, но без служб:

```text
menuentry "TPI LAZARUS: Debian 13, rescue shell" {
    ...
    linux /boot/<ядро> root=UUID=<UUID> rw rootwait \
          console=ttyS2,115200n8 systemd.unit=rescue.target
    ...
}
```

Раздел с заводской системой при этом цел (`/dev/mmcblk0p6`), и прежний конфиг
сохранён рядом как `grub.cfg.bak-with-ubuntu`. Таймаут меню снижен до 5 секунд:
перехватить его по UART этого хватает, а грузиться быстрее.

## MAC-адреса

Прошитого MAC у платы нет ни у встроенных портов, ни у карт.

Встроенным портам адрес даёт **U-Boot**, выводя его из идентификатора
кристалла: он детерминированный и переживает снятие питания. Ядро считает такой
адрес постоянным (`addr_assign_type` равен нулю).

У карт RTL8111H нет EEPROM, поэтому ядро каждую загрузку берёт случайный адрес —
это видно в журнале: `RTL8168h/8111h, 7e:f6:69:b3:50:0c`, в следующий раз
`6a:fc:d6:a3:08:67` и так далее. Но на интерфейсе адрес при этом **не** скачет:
штатная политика `MACAddressPolicy=persistent` из `99-default.link` заменяет его
на устойчивый, выведенный из `machine-id` (`addr_assign_type` становится 3).

То есть сами по себе адреса уже стабильны. Непредсказуемы они лишь в том смысле,
что заранее неизвестны. Для промышленного изделия — маркировка, резервации DHCP,
инвентаризация — лучше задать их явно и связным блоком, продолжив тот, что
выдаёт U-Boot:

| Интерфейс | Адрес | Откуда |
|---|---|---|
| `end0` (gmac1) | `…:d2` | U-Boot, из идентификатора кристалла |
| `end1` (gmac0) | `…:d3` | U-Boot |
| `enP1p1s0` (pcie3x1) | `…:d4` | `.link`, задан явно |
| `enP2p1s0` (pcie3x2) | `…:d5` | `.link`, задан явно |

```ini
# /etc/systemd/network/20-realtek-pcie3x1.link
[Match]
Path=platform-3c0400000.pcie-pci-0001:01:00.0
Driver=r8169

[Link]
MACAddress=7a:b7:02:4d:94:d4
```

Сопоставление идёт по `Path=`, а не по MAC: аппаратный адрес карты меняется
каждую загрузку и для `[Match]` не годится. Все адреса
локально-администрируемые — зарегистрированного OUI у изделия нет.

Важно: такой `.link` привязан к **конкретному экземпляру**. При серийном
выпуске адреса надо генерировать на каждую плату от её собственного базового
адреса, а не копировать файл как есть.

## Удалённый доступ

Ядро Debian содержит TUN, поэтому Tailscale работает штатно, с собственным
интерфейсом `tailscale0` — обходной режим userspace-networking, необходимый на
заводском ядре, здесь не нужен.

```sh
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
  > /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
  > /etc/apt/sources.list.d/tailscale.list
apt-get update && apt-get install tailscale
systemctl enable --now tailscaled
tailscale up --hostname=uvon-debian --accept-routes
```

Имя узла задаётся явно, чтобы не путать с узлом заводской системы: на плате они
работают по очереди, и по тому, какой из них в сети, сразу видно, какая система
запущена.

Про сам вход есть тонкость: `tailscale up` печатает одноразовую ссылку и ждёт,
пока её откроют. Перезапускать `tailscaled` в этот момент нельзя — уже
состоявшаяся регистрация потеряется, а ссылка станет недействительной
(`http 410: auth path not found`), и всю процедуру придётся повторять.

### Порядок запуска

`tailscaled` поднимается раньше, чем интерфейс получает адрес по DHCP: весь
бутстрап падает с `network is unreachable`. Клиент обычно выбирается из этого
сам, но лучше упорядочить явно. В Debian это делается штатно, потому что
`systemd-networkd-wait-online` здесь не замаскирован:

```ini
# /etc/systemd/system/tailscaled.service.d/network-online.conf
[Unit]
Wants=network-online.target
After=network-online.target
```

По умолчанию `wait-online` дожидается **всех** управляемых интерфейсов, а на
этой плате три порта из четырёх обычно без кабеля — загрузка упёрлась бы в
таймаут. Поэтому ждём любой поднявшийся:

```ini
# /etc/systemd/system/systemd-networkd-wait-online.service.d/any.conf
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=30
```

После этого ошибок `network is unreachable` в журнале не остаётся, ожидание
сети занимает около 6 секунд, полная загрузка — порядка 23 секунд, и плата
возвращается в сеть после перезагрузки сама.

## Известные ограничения

- **Заводское ядро 5.10 после этого перестало запускаться.** Оно падает в
  `Kernel panic - not syncing: panic_on_set_idle` — код доменов питания не
  дожидается перехода домена в idle. Плата после этого виснет намертво: консоль
  молчит, USB-устройство пропадает, FIQ debugger не отвечает; помогает только
  снятие питания. Воспроизводится и после холодного старта. Причина не
  установлена; правдоподобно, что апстримный драйвер PHY PCIe 3.0 оставляет
  домен питания в состоянии, которое тёплый сброс по PSCI не очищает.
  Заводская система признана нерабочей и убрана из меню; разбираться в причине
  смысла нет, пока к ней не собираются возвращаться.
- NPU не поднимается: апстримного драйвера для RKNN здесь нет.
- Вендорский DVFS (`rockchip-dmc`, `dfi`, `pvtm`) отсутствует; обычный
  `cpufreq-dt` работает.
- Загрузка с microSD невозможна в принципе: карта на SDMMC2, а BootROM RK3568
  грузится только с SDMMC0. Это свойство платы, а не системы.

## Часы

На плате двое часов: внутри PMIC RK809 и отдельный HYM8563 с батарейкой на
i2c3. Номера `rtc0`/`rtc1` между ними не закреплены — кто зарегистрируется
первым, тот и станет нулевым, и от загрузки к загрузке это меняется.

Это важно, потому что ядро берёт стартовое время из `rtc0`. Если им окажутся
часы PMIC, а питание снимали, система стартует с мусорным временем: в журнале
это выглядит как

```text
rk808-rtc rk808-rtc.4.auto: setting system clock to 2017-08-05T09:00:21 UTC
rtc-hym8563 3-0051: /aliases ID 0 not available
```

Алиас `rtc0 = &hym8563` в device tree не спасает: часы PMIC создаются как
устройство без узла DT и занимают нулевой номер раньше, чем очередь доходит до
алиасов. Поэтому вопрос решается в userspace — правилом udev, которое даёт
батарейным часам устойчивое имя, и службой, которая берёт время из них:

```
# /etc/udev/rules.d/60-tpi-rtc.rules
SUBSYSTEM=="rtc", ATTR{name}=="rtc-hym8563*", SYMLINK+="rtc-battery"
```

`tpi-rtc.service` выполняет `hwclock --rtc /dev/rtc-battery --hctosys` до
`sysinit.target`, а при остановке записывает в них актуальное время. Нужен
пакет `util-linux-extra` — в минимальной Debian `hwclock` отсутствует.

Обе сборки образов это уже ставят. На стенде проверено, что ссылка
`/dev/rtc-battery` указывает на HYM8563 при любом порядке нумерации, и что
служба отрабатывает на каждой загрузке. Полную проверку — что при снятии
питания время берётся именно из батарейных часов — можно сделать только
физически, обесточив плату.

## Безобидные сообщения в журнале

Два сообщения уровня `err` появляются при каждой загрузке и ничего не значат:

```text
sdhci-dwcmshc fe310000.mmc: Can't reduce the clock below 52MHz in HS200/HS400 mode
rockchip-drm display-subsystem: *ERROR* No available vop found for display-subsystem
```

Первое возникает при подстройке режима eMMC, сам накопитель работает. Второе —
следствие того, что дисплей на этой плате не описан: модуль `rockchipdrm`
всё равно загружается и не находит VOP. Искать здесь неисправность не нужно.
