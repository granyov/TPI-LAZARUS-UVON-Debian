# Debian 13 для платы TPI LAZARUS / UVON

Сборка **Debian 13 (trixie)** с апстримным ядром **6.12** для промышленной
платы LAZARUS/UVON компании TPI: Forlinx FET3568-C/C2, Rockchip RK3568.

Вендорского ядра здесь нет: всё, чем плата пользуется, поддерживается
апстримом. Заодно уходит `rk-fiq-debugger` — консоль становится обычной
`ttyS2`, и пропадает перехват порта на байтах `fiq`.

Прошивка — отдельно: [TPI-LAZARUS-UVON-UEFI](https://github.com/granyov/TPI-LAZARUS-UVON-UEFI).
Она должна быть на плате **до** установки системы.

## Что выбрать

| Задача | Файл релиза |
|---|---|
| Прошить новую плату целиком, прошивка и ОС в eMMC | `tpi-lazarus-uvon-update.img.xz` (RKDevTool) или `tpi-lazarus-uvon-emmc-debian13.tar.xz` (пофайлово) |
| Поставить ОС на SATA или USB-диск | `tpi-lazarus-uvon-debian13.img.xz` |
| Аварийная загрузка с microSD | он же |

## Что работает

Проверено на физической плате:

| Подсистема | Драйвер |
|---|---|
| SATA | `ahci-dwc` + `phy-rockchip-naneng-combphy` |
| Ethernet ×2 (RGMII) | `rk_gmac-dwmac`, 1 Гбит/с |
| Ethernet ×2 (PCIe) | `pcie-rockchip-dw` + штатный `r8169` |
| OP-TEE | `optee` 3.13, `/dev/tee0` |
| eMMC, microSD | `sdhci-dwcmshc`, `dwmmc_rockchip` |
| RTC | `rtc-hym8563` на i2c3, батарейный |
| Питание, IO-домены | `rk8xx`, `fan53555` (RK809 + TCS4525) |
| USB, FT4232HL | `dwc3`, `xhci`, `ftdi_sio` — 8 × `ttyUSB` |
| RGA, видеокодеки | `rockchip-rga`, `hantro-vpu` |

Не поддерживается только NPU: апстримного драйвера для RKNN нет.

## Что в образе нет намеренно

Ключи хоста SSH, состояние Tailscale, `authorized_keys`, `machine-id`,
привязка MAC. Всё это создаётся при первом запуске — иначе все платы разошлись
бы с одинаковыми приватными ключами. Следствие: **первый вход только через
последовательную консоль**, 115200 8N1, автоматически под root.

## Документация

- [`docs/INSTALL-DISK.md`](docs/INSTALL-DISK.md) — установка на SATA или USB-диск
- [`docs/INSTALL-EMMC.md`](docs/INSTALL-EMMC.md) — прошивка платы целиком, `rkdeveloptool` и RKDevTool
- [`docs/BUILD.md`](docs/BUILD.md) — как собрана система и грабли с device tree

## Состав

```
os/       device tree платы для апстримного ядра
scripts/  сборщики образов: диск, комплект eMMC, update.img, разборщик RKFW
docs/     установка и сборка
```

Собранные образы распространяются релизами.

## Право использования

Репозиторий предназначен для внутреннего использования TPI.
Copyright © 2026 Tech Pro Industries LLC.

Debian и ядро Linux распространяются на своих условиях. Образы содержат
прошивку платы, в состав которой входят двоичные payload'ы TF-A и OP-TEE от
Rockchip и Forlinx — права на них принадлежат правообладателям.
