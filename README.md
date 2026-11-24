# omarchy-cachyos

Перевод свежей [Omarchy](https://omarchy.org) на репозитории и ядро
[CachyOS](https://cachyos.org): максимум пакетов собирается с оптимизацией
под ваш CPU (`znver4` / `x86-64-v4` / `x86-64-v3`), при этом штатный
Hyprland-стек и сборки Omarchy остаются на месте и не ломаются.

Скрипт запускается один раз, спрашивает пароль `sudo` и дальше идёт до
конца без вопросов: снапшот, пины, репозитории, апгрейд, ядро, проверка.

## Быстрый старт

На свежей Omarchy (обычный пользователь с `sudo`, не root):

```bash
curl -fsSLO https://raw.githubusercontent.com/kichcloud/omarchy-cachyos/main/omarchy-cachyos.sh
chmod +x omarchy-cachyos.sh

./omarchy-cachyos.sh check     # посмотреть, что определилось (ничего не меняет)
./omarchy-cachyos.sh           # переход; через 5 секунд начнётся сам
```

После завершения — перезагрузка (или запустите с `--reboot`), затем:

```bash
./omarchy-cachyos.sh verify
```

## Что делает

1. Проверяет систему: x86_64, Omarchy, место на диске, сеть, ISA процессора.
2. Делает снапшот snapper `before-cachyos` и бэкап `pacman.conf`,
   mirrorlist'ов и списка пакетов в `/var/backups/omarchy-cachyos/`.
3. Закрепляет (`IgnorePkg`) Hyprland-стек, `libjxl`, `quickshell`,
   `walker`, limine-хуки, `ghostty` — до первого апгрейда.
4. Ставит официальные репозитории CachyOS (`cachyos-repo.sh --install`).
   При отсутствии `gcc` сначала ставит его: установщик использует `gcc`,
   чтобы выбрать znver4. На неизбежный вопрос установщика «skip the above
   package?» (его `pacman` требует `libcrypto.so=4`, которого на свежей
   Omarchy ещё нет) ответ `y` подаётся автоматически, а собственный
   `pacman -Syu` установщика пропускается: он качал бы ~1.7 ГБ с ещё не
   отранжированного зеркала, да ещё и в базовом `x86_64`.
5. Прописывает явный `Architecture` (иначе `auto` схлопывается в `x86_64`)
   и правильный порядок репозиториев.
6. Синхронизирует базы, ранжирует зеркала (`cachyos-rate-mirrors`),
   включает таймер.
7. Обновляет систему штатным `omarchy update -y` (свой снапшот, миграции).
   Каждые 30 секунд печатает размер кэша пакетов, чтобы было видно, что
   загрузка идёт.
8. Ставит `linux-cachyos` + headers и делает его ядром по умолчанию через
   `omarchy kernel set`.
9. Проверяет зависимости, пины, версии сборок Omarchy, `configerrors`,
   упавшие юниты, загрузочную запись и UKI.

## Команды и опции

```
./omarchy-cachyos.sh [команда] [опции]

apply     переход; команда по умолчанию
check     диагностика и план, ничего не меняет
verify    проверка результата (до и после перезагрузки)
status    краткий статус
revert    убрать репозитории CachyOS и вернуть linux-omarchy
help      справка

--arch znver4|v4|v3|auto   ISA (по умолчанию auto)
--kernel NAME              ядро CachyOS (по умолчанию linux-cachyos)
--priority omarchy|cachyos кто выше при равных версиях (по умолчанию omarchy)
--with-nvidia              nvidia-модули для выбранного ядра
--no-kernel                не трогать ядро
--no-mirrors               не ранжировать зеркала
--no-snapshot              без снапшота (не рекомендуется)
--reboot                   перезагрузиться после успешного verify
--yes, -y                  не ждать 5-секундную паузу
--dry-run, -n              показать план, ничего не меняя
```

## Требования

- x86_64, свежая Omarchy, btrfs со snapper (конфиг `root`).
- Интернет и желательно ≥ 8 ГБ свободного места: апгрейд массовый.
- `znver4` — только AMD Zen 4/5. На Intel скрипт сам выберет `v4`/`v3`,
  либо укажите `--arch v4`.
- Запуск от обычного пользователя: скрипт сам вызывает `sudo`
  (`omarchy update` не работает от root).

## Что остаётся не-znver4 и почему

- **Hyprland-стек** (`hyprland 0.56.2`, `aquamarine`, `hyprgraphics`,
  `hyprutils`, `hyprlang`, `hyprcursor`, `hyprtoolkit`,
  `hyprland-guiutils`, `xdg-desktop-portal-hyprland`, `libjxl`) —
  Arch-сборки, закреплены: `omarchy-hyprland-titlebars` требует ровно
  `hyprland=0.56.2`. Без пина обновление до 0.57 ломает titlebars.
- **Сборки Omarchy** (`omarchy`, `omarchy-settings`, `quickshell`,
  `limine-*`, `linux-omarchy`, темы и т.д.) — не подменяются CachyOS.
- **Пакеты Arch**, которых нет в CachyOS, и `any`-пакеты (шрифты, темы,
  скрипты) — оптимизировать нечего.
- Часть пакетов CachyOS публикует только в базовом `[cachyos]` без
  ISA-варианта (`limine`, `pacman`, `plymouth` и т.п.).

Порядок репозиториев влияет только на пакеты с **равными** версиями в двух
репозиториях; `[omarchy]` содержит ~30 своих пакетов, а не базу.

## Откат

- **Снапшот:** при загрузке Limine → Snapshots → `before-cachyos`.
  Это самый надёжный путь.
- **Мягкий откат:** `./omarchy-cachyos.sh revert` — вернёт `pacman.conf`,
  уберёт репозитории и вернёт штатное ядро. Пакеты, собранные CachyOS,
  останутся до следующего обновления из Arch.

## Замечания

- Закреплённые пакеты видны в `pacman -Qu` как `[ignored]` — это норма.
  Обновлять их нужно вместе с Omarchy: `sudo pacman -S omarchy/<пакет>`
  (явная установка обходит `IgnorePkg`).
- Если CachyOS уже был добавлен раньше с `Architecture = auto` и система
  успела обновиться базовыми x86_64-сборками, часть пакетов с равной или
  более новой базовой версией останется без ISA-оптимизации. Чистый
  znver4-набор получается на свежей Omarchy.
- Всё, что делает скрипт, пишется в
  `~/.local/state/omarchy-cachyos/<команда>-<дата>.log`.

## Статус

Проверено в VM на Omarchy 4.5.0: `check`, `verify`, `apply --dry-run`,
`revert --dry-run`, нормализация `pacman.conf`, пины, ядро. Полный
end-to-end прогон на чистой системе — в процессе.

## Лицензия

MIT
