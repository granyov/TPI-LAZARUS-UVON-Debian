# Debian 13 для платы TPI LAZARUS / UVON

Сборка **Debian 13 (trixie)** с апстримным ядром **6.12** для промышленной
платы LAZARUS/UVON компании TPI: Forlinx FET3568-C/C2, Rockchip RK3568.

Вендорского ядра здесь нет: всё, чем плата пользуется, поддерживается
апстримом. Заодно уходит `rk-fiq-debugger` — консоль становится обычной
`ttyS2`, и пропадает перехват порта на байтах `fiq`.

Прошивка — отдельно: [TPI-LAZARUS-UVON-UEFI](https://github.com/granyov/TPI-LAZARUS-UVON-UEFI).
Она должна быть на плате **до** установки системы, версии **v3.9**: с ней
прошивка, GRUB, ядро и вход в систему говорят на одной скорости консоли —
1 500 000 8N1. Собранная v3.9 есть в комплекте eMMC выпуска.

## Что выбрать

| Задача | Файл релиза |
|---|---|
| Прошить новую плату целиком, прошивка и ОС в eMMC | `tpi-lazarus-uvon-update.img.xz` (RKDevTool) или `tpi-lazarus-uvon-emmc-debian13.tar.xz` (пофайлово) |
| Поставить ОС на SATA или USB-диск | `tpi-lazarus-uvon-debian13.img.xz` (или `.img.zst` — быстрее распаковка) |
| Загрузка с microSD | он же |

## Что работает

Проверено на физической плате:

| Подсистема | Драйвер |
|---|---|
| SATA | `ahci-dwc` + `phy-rockchip-naneng-combphy` |
| Ethernet ×2 (RGMII) | `rk_gmac-dwmac`, 1 Гбит/с |
| Ethernet ×2 (PCIe) | `pcie-rockchip-dw` + штатный `r8169` |
| OP-TEE | `optee` 3.13, `/dev/tee0` |
| eMMC, microSD | `sdhci-dwcmshc`, `dwmmc_rockchip` |
| RTC | `rtc-hym8563` на i2c3, батарейный — `/dev/rtc-battery`, время берётся при загрузке |
| Питание, IO-домены | `rk8xx`, `fan53555` (RK809 + TCS4525) |
| USB, FT4232HL | `ehci`, `ftdi_sio` — RS-422/485 1–8 как `/dev/ttyRS485-1…8` |
| V.24 (UART4, UART5) | `8250_dw` — `/dev/ttyRS232-1`, `-2` через мосты GD32F103, см. [`docs/V24.md`](docs/V24.md) |
| RGA, видеокодеки | `rockchip-rga`, `hantro-vpu` |

Не поддерживается только NPU: апстримного драйвера для RKNN нет.

## Что в образе нет намеренно

Ключи хоста SSH, состояние Tailscale, `authorized_keys`, `machine-id`,
привязка MAC. Всё это создаётся при первом запуске — иначе все платы разошлись
бы с одинаковыми приватными ключами. Следствие: **первый вход только через
последовательную консоль**, 1 500 000 8N1, автоматически под root.

## Имена портов и интерфейсов

Постоянные, не зависят от порядка, в котором ядро нашло устройства:

| Что | Имя |
|---|---|
| Ethernet GMAC0 (`fe2a0000`), GMAC1 (`fe010000`) | `end0`, `end1` — как в U-Boot |
| Ethernet на PCIe (RTL8111H) | `enP1p1s0`, `enP2p1s0` |
| RS-422/485 1–8 | `/dev/ttyRS485-1` … `/dev/ttyRS485-8` |
| V.24 1 и 2 | `/dev/ttyRS232-1`, `/dev/ttyRS232-2` |
| Батарейные часы | `/dev/rtc-battery` |

MAC-адреса всех четырёх портов связные: U-Boot выводит `end0`/`end1` из
идентификатора кристалла, карты PCIe получают следующие два при первом запуске.

## Документация

- [`docs/INSTALL-DISK.md`](docs/INSTALL-DISK.md) — установка на SATA или USB-диск, первый вход, пересборка выпуска
- [`docs/INSTALL-EMMC.md`](docs/INSTALL-EMMC.md) — прошивка платы целиком, `rkdeveloptool` и RKDevTool
- [`docs/V24.md`](docs/V24.md) — порты V.24: мосты GD32F103, имена, прошивка мостов
- [`docs/BUILD.md`](docs/BUILD.md) — как собрана система и грабли с device tree
- [`docs/TEST-REPORT-debian13-20261004.md`](docs/TEST-REPORT-debian13-20261004.md) — испытания выпуска на плате

## Состав

```
os/         device tree платы для апстримного ядра
os/rootfs/  файлы платы в образе: первая настройка, часы, имена портов, консоль
os/emmc/    раскладка eMMC: parameter.txt, gpt.img
scripts/    сборка выпуска: пакеты в chroot, образ диска, комплект eMMC, update.img
docs/       установка, сборка, испытания
```

Собранные образы распространяются релизами; весь выпуск собирается одной
командой `scripts/build-debian-release.sh`, см. [`docs/INSTALL-DISK.md`](docs/INSTALL-DISK.md#пересборка-образа).

## Право использования

Copyright © 2026 Tech Pro Industries LLC. Состав по происхождению и условия —
в [`NOTICE.md`](NOTICE.md).

Коротко: device tree, скрипты и документация наши; система — неизменённая
Debian 13 на своих условиях; образы для eMMC дополнительно содержат прошивку
платы с двоичными payload'ами TF-A и OP-TEE от Rockchip и Forlinx, права на
которые принадлежат правообладателям. Образ для диска прошивки не содержит.
