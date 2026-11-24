#!/usr/bin/env bash
# =============================================================================
#  omarchy-cachyos.sh — перевод свежей Omarchy на репозитории CachyOS
#
#  Проверено на Omarchy 4.5.0 (VM): 911 пакетов, 707 из CachyOS,
#  Hyprland 0.56.2-4 и quickshell из [omarchy], shell и лаунчер работают,
#  `pacman -Syu` закреплённый стек не трогает.
#
#  Что делает apply:
#    1. проверяет систему и выбирает ISA: znver4 / x86-64-v4 / x86-64-v3;
#    2. делает снапшот snapper и бэкап /etc/pacman.conf + mirrorlist;
#    3. закрепляет (IgnorePkg) штатный Hyprland-стек и сборки Omarchy;
#    4. ставит официальные репозитории CachyOS;
#    5. прописывает явный Architecture и приоритет репозиториев;
#    6. ранжирует зеркала через cachyos-rate-mirrors;
#    7. обновляет систему штатным `omarchy update` (снапшот + миграции),
#       заводя в карантин зеркала, которые залипли на загрузке пакетов;
#    8. ставит linux-cachyos и делает его ядром по умолчанию;
#    9. проверяет зависимости, пины, shell и загрузочную запись.
#
#  Почему именно так (грабли из теста):
#    * `Architecture = auto` у установщика CachyOS схлопывается в x86_64 и
#      v4/znver4-пакеты не ставятся — нужен явный список архитектур. Свой
#      `pacman -Syu` установщика при этом пропускается: иначе он качал бы
#      ~1.7 ГБ с ещё не отранжированного зеркала и базовым x86_64. Порядок
#      теперь такой: установщик только добавляет репозитории → зеркала →
#      полный апгрейд через `omarchy update`.
#    * Omarchy ставит alpm-хук против прямого `pacman -Syu`. Установщику
#      CachyOS он не мешает (у pacman другой родитель), но разрешение
#      выставляется явно, а следом всё равно идёт штатный `omarchy update`.
#    * omarchy-hyprland-titlebars требует конкретную версию hyprland, поэтому
#      весь Hyprland-стек и libjxl закрепляются ДО первого апгрейда.
#    * quickshell, limine-mkinitcpio-hook, limine-snapper-sync, ghostty, walker
#      CachyOS тоже публикует: без пина он подменит омрачные сборки.
#    * limine-entry-tool — не пакет, а бинарник внутри limine-mkinitcpio-hook.
#    * Ядро делается дефолтным через `omarchy kernel set`, а не правкой
#      limine.conf: ручная правка сбрасывается при регенерации.
#    * Миграция Omarchy 1791403252 ставит [omarchy] сразу после [options].
#      Запускается она один раз на пользователя (маркер в
#      ~/.local/state/omarchy/migrations), но если маркера нет (новый
#      пользователь, перенесённый home), то при обновлении переставит
#      репозитории и сразу сделает свой `pacman -Syu` — поэтому порядок
#      проверяется после `omarchy update`, а --priority cachyos
#      восстанавливается. Набор пакетов [omarchy] узкий, так что
#      «омрачные поверх качиосовских» это не приводит: см. пины.
#    * znver4-бинарники не переносимы на Intel/Skylake-X: только для Zen 4/5.
#    * cachyos-rate-mirrors ранжирует по .db, а она мелкая и часто уже в кэше
#      зеркала. Хост может мгновенно отдать базу и «встать» на 1.7 ГБ пакетов.
#      Поэтому после ранжирования топ-3 проверяются настоящим пакетом, а если
#      pacman всё равно споткнётся — виновное зеркало уходит в карантин
#      (commented Server) и `omarchy update` повторяется: докачка из кэша дешёвая.
#
#  Запуск (от обычного пользователя, не от root):
#      ./omarchy-cachyos.sh            # сразу apply: всё до конца, без вопросов
#      ./omarchy-cachyos.sh check      # только диагностика
#      ./omarchy-cachyos.sh verify
#      ./omarchy-cachyos.sh revert
#
#  apply не задаёт вопросов: один раз спрашивает пароль sudo в начале,
#  на время работы делает кэш sudo глобальным (временный dropin удаляется
#  на выходе) и идёт до самой проверки.
#  Прервать можно Ctrl+C — снапшот к этому моменту уже создан.
#
#  После apply нужен перезагруз, чтобы загрузилось ядро CachyOS
#  (или запустите с --reboot).
# =============================================================================
set -Eeuo pipefail

# SSH-команды и cron не читают /etc/profile.d/omarchy.sh, а `omarchy update`
# без OMARCHY_PATH падает с «OMARCHY_PATH does not match this Omarchy command».
if [[ -r /usr/share/omarchy/default/bash/env-bootstrap ]]; then
  . /usr/share/omarchy/default/bash/env-bootstrap
fi
export OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}

VERSION="2.9"

CMD=apply
KERNEL=linux-cachyos
ARCH=auto
PRIORITY=omarchy
YES=0
DRY=0
REBOOT=0
WITH_NVIDIA=0
NO_KERNEL=0
NO_MIRRORS=0
NO_SNAPSHOT=0
SUDO_KEEPALIVE=""
PROGRESS_PID=""
SUDO_DROPIN=""
TEE_PID=""
UPDATE_WATCH_PID=""
VERIFY_RC=0

PACMAN_CONF=${OMARCHY_CACHYOS_PACMAN_CONF:-/etc/pacman.conf}
BACKUP_ROOT=${OMARCHY_CACHYOS_BACKUP_ROOT:-/var/backups/omarchy-cachyos}
CACHYOS_REPO_URL="https://mirror.cachyos.org/cachyos-repo.tar.xz"

SNAP_ID=""
BK=""
BK_PRE=""

# Пакеты, которые обязаны остаться омрачными (или совместимыми с ними).
PIN_CANDIDATES=(
  hyprland
  hyprland-guiutils
  hyprtoolkit
  aquamarine
  hyprgraphics
  hyprutils
  hyprlang
  hyprcursor
  hyprwayland-scanner
  xdg-desktop-portal-hyprland
  quickshell
  walker
  omarchy-hyprland-titlebars
  limine-mkinitcpio-hook
  limine-snapper-sync
  ghostty
)

# ---------------------------------------------------------------------------
# вывод и лог
# ---------------------------------------------------------------------------
LOG=/dev/null
if [[ -t 1 ]]; then
  c_reset=$'\e[0m'; c_bold=$'\e[1m'; c_green=$'\e[32m'
  c_yel=$'\e[33m'; c_red=$'\e[31m'; c_cya=$'\e[36m'
else
  c_reset=''; c_bold=''; c_green=''; c_yel=''; c_red=''; c_cya=''
fi

say()  { printf '%s\n' "$*"; }
msg()  { say "${c_green}==>${c_reset} ${c_bold}$*${c_reset}"; }
info() { say "${c_yel} -->${c_reset} $*"; }
warn() { say "${c_red} !!${c_reset} $*"; }
die()  { warn "$*"; exit 1; }
sect() { say ""; say "${c_cya}── $* ──${c_reset}"; }

# Приглашение sudo заканчивается переводом строки: иначе фоновый индикатор
# приклеивается к нему и весь вывод выглядит «съехавшим».
export SUDO_PROMPT=$'[sudo] пароль для %u: \n'

have() { command -v "$1" >/dev/null 2>&1; }
pkg_installed() { pacman -Q "$1" >/dev/null 2>&1; }
pkg_ver() { pacman -Q "$1" 2>/dev/null | awk '{print $2}' || true; }
pconf() { pacman-conf --config "$PACMAN_CONF" "$@"; }

# /boot закрыт для обычного пользователя (700/600), поэтому проверки идут
# через sudo -n: в check/verify это не должно ничего спрашивать.
boot_grep() {
  [[ -r /boot/limine.conf ]] && grep -q -- "$1" /boot/limine.conf ||
    sudo -n grep -q -- "$1" /boot/limine.conf 2>/dev/null
}
boot_file() {
  [[ -e $1 ]] || sudo -n test -e "$1" 2>/dev/null
}
boot_dir() {
  [[ -d $1 ]] || sudo -n test -d "$1" 2>/dev/null
}
can_check_boot() {
  [[ -r /boot/limine.conf ]] || sudo -n true 2>/dev/null
}
as_root() { if (( EUID == 0 )); then "$@"; else sudo "$@"; fi; }

# sudo по умолчанию привязывает кэш пароля к tty. omarchy update запускает
# свой pty через script(1), поэтому второй раз спрашивает пароль даже после
# sudo -v в исходном терминале. На время apply кэш делается глобальным —
# пароль вводится один раз, привилегии не расширяются. Файл удаляется
# в on_exit даже при ошибке.
# вызывается ПОСЛЕ sudo -v: пароль уже введён, поэтому dropin ставится
# без пароля (sudo -n) и второго запроса не будет.
setup_global_sudo_timestamp() {
  (( EUID == 0 )) && return 0
  local f="/etc/sudoers.d/omarchy-cachyos-$$"
  if ! sudo -n sh -c 'umask 022; printf "Defaults timestamp_type=global\n" > "$1"' _ "$f" 2>/dev/null; then
    warn "не удалось сделать кэш sudo глобальным — omarchy update может спросить пароль ещё раз"
    return 0
  fi
  SUDO_DROPIN=$f
  sudo -n true >/dev/null 2>&1 ||
    warn "глобальный кэш sudo не подтверждён — повторный запрос пароля возможен"
}

cleanup_sudo_dropin() {
  [[ -n ${SUDO_DROPIN:-} ]] || return 0
  as_root rm -f "$SUDO_DROPIN" 2>/dev/null || true
  SUDO_DROPIN=""
}

on_exit() {
  stop_sudo_keepalive
  stop_progress
  stop_update_watch
  cleanup_sudo_dropin
  # Возвращаем исходный stdout и закрываем конец pipe process substitution.
  exec >&3 3>&- 2>/dev/null || true
  [[ -n ${TEE_PID:-} ]] && wait "$TEE_PID" 2>/dev/null || true
}

confirm() {
  local prompt=${1:-Продолжить?} answer
  (( YES )) && return 0
  [[ -t 0 ]] || die "Нет терминала для подтверждения — используйте --yes"
  read -r -p "$prompt [y/N] " answer || true
  [[ ${answer,,} == y* ]]
}

# ---------------------------------------------------------------------------
# запуск без вопросов
# ---------------------------------------------------------------------------
countdown() {
  (( YES || DRY )) && return 0
  (( TTY )) || return 0
  local i
  for i in 5 4 3 2 1; do
    printf '\r%sНачинаю через %s… Ctrl+C — отмена%s ' "$c_yel" "$i" "$c_reset"
    sleep 1
  done
  printf '\r%70s\r' ''
}

# Пароль sudo спрашивается один раз; таймстамп продлевается в фоне,
# чтобы длинный апгрейд не остановился на запросе пароля.
start_sudo_keepalive() {
  (( EUID == 0 )) && return 0
  ( while sleep 50; do sudo -n -v 2>/dev/null || exit 0; done ) &
  SUDO_KEEPALIVE=$!
}

stop_sudo_keepalive() {
  [[ -n ${SUDO_KEEPALIVE:-} ]] && kill "$SUDO_KEEPALIVE" 2>/dev/null || true
  SUDO_KEEPALIVE=""
}

# Раз в 30 секунд показываем размер кэша пакетов: вывод pacman идёт через
# tee (не терминал), поэтому прогресс-бар скрыт и кажется, что всё встало.
start_progress() {
  (( DRY )) && return 0
  (
    # set -E наследует ERR-ловушку в подоболочки, а pacman во время загрузки
    # создаёт каталоги 700 root: du получает permission denied и «падает».
    # Здесь ошибки не интересны — глушим ловушку и не даём du ронять цикл.
    set +E
    trap - ERR
    while sleep 30; do
      local size
      size=$(du -sh /var/cache/pacman/pkg 2>/dev/null | cut -f1 || true)
      # В терминале pacman/omarchy рисуют прогресс через \r; стираем текущую
      # строку, чтобы наша строка не приклеивалась к их выводу.
      if (( TTY )); then
        printf '\r\033[2K%s    … идёт загрузка/установка, кэш пакетов: %s%s\n' \
          "$c_yel" "${size:-?}" "$c_reset"
      else
        printf '%s    … идёт загрузка/установка, кэш пакетов: %s%s\n' \
          "$c_yel" "${size:-?}" "$c_reset"
      fi
    done
  ) &
  PROGRESS_PID=$!
}

stop_progress() {
  [[ -n ${PROGRESS_PID:-} ]] && kill "$PROGRESS_PID" 2>/dev/null || true
  PROGRESS_PID=""
}

# omarchy update может встать на приглашении sudo (свой pty через script).
# Следим за логом: появился запрос пароля — завершаем обновление, чтобы
# скрипт не висел часами и сразу показал понятную причину.
start_update_watch() {
  local log=$1 pid=$2
  (
    set +E; trap - ERR
    while sleep 5; do
      kill -0 "$pid" 2>/dev/null || break
      if grep -aq '\[sudo\]' "$log"; then
        warn "омarchy update ждёт пароль sudo — прерываю (проверьте настройки sudo)"
        pkill -TERM -P "$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        break
      fi
    done
  ) &
  UPDATE_WATCH_PID=$!
}

stop_update_watch() {
  [[ -n ${UPDATE_WATCH_PID:-} ]] && kill "$UPDATE_WATCH_PID" 2>/dev/null || true
  UPDATE_WATCH_PID=""
}

# ---------------------------------------------------------------------------
# аргументы
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
omarchy-cachyos.sh — Omarchy + репозитории и ядро CachyOS

Использование:
  omarchy-cachyos.sh <команда> [опции]

Команды:
  apply     выполнить переход (по умолчанию, если команда не указана)
  check     диагностика и план; ничего не меняет
  verify    проверить результат (до и после перезагрузки)
  status    краткий статус системы
  revert    убрать репозитории CachyOS и вернуть штатное ядро
  help      эта справка

Опции:
  --arch LEVEL        znver4 | v4 | v3 | auto (по умолчанию auto)
  --kernel NAME       ядро CachyOS (по умолчанию linux-cachyos)
  --priority WHO      omarchy | cachyos — кто выше при РАВНЫХ версиях
                      (по умолчанию omarchy, как задумано в Omarchy)
  --with-nvidia       поставить nvidia-модули для выбранного ядра
  --no-kernel         не устанавливать/не переключать ядро
  --no-mirrors        не ранжировать зеркала
  --no-snapshot       не создавать снапшот snapper (не рекомендуется)
  --reboot            перезагрузиться сразу после успешного verify
  --yes, -y           не ждать 5-секундную паузу перед стартом
  --dry-run, -n       показать, что будет сделано, ничего не меняя
  -h, --help          эта справка

Примеры:
  ./omarchy-cachyos.sh                  # полный переход, без вопросов
  ./omarchy-cachyos.sh --dry-run        # посмотреть план
  ./omarchy-cachyos.sh check            # диагностика
  ./omarchy-cachyos.sh --arch v4        # не-Zen4/5
  ./omarchy-cachyos.sh --reboot         # переход + перезагрузка
  ./omarchy-cachyos.sh verify
  ./omarchy-cachyos.sh revert

Что закрепляется (IgnorePkg):
  Hyprland-стек: hyprland hyprland-guiutils hyprtoolkit aquamarine
  hyprgraphics hyprutils hyprlang hyprcursor hyprwayland-scanner
  xdg-desktop-portal-hyprland omarchy-hyprland-titlebars libjxl*
  Сборки Omarchy: quickshell walker limine-mkinitcpio-hook
  limine-snapper-sync ghostty
  (* libjxl добавляется, только если hyprgraphics от него зависит;
     из перечисленных закрепляются только реально установленные пакеты.)

Важно:
  * Только x86_64. На aarch64 (Apple Silicon) репозиториев CachyOS нет.
  * znver4 — это Zen 4/5. На Intel используйте v4 или v3.
  * Ядро станет дефолтным через `omarchy kernel set`, limine.conf руками
    не правится.
  * Pinned-пакеты будут видны в `pacman -Qu` как [ignored] — это норма.
    Обновлять их нужно вместе с Omarchy: `sudo pacman -S omarchy/<пакет>`
    (явная установка обходит IgnorePkg) либо снимая пины осознанно.
  * Приоритет репозиториев решает только при РАВНЫХ версиях, и только для
    пакетов, которые есть в обоих репозиториях. [omarchy] — это ~30 своих
    пакетов Omarchy, а не база, поэтому «омрачное поверх CachyOS» не
    происходит; пересекающиеся сборки (quickshell, limine-хуки, ghostty,
    walker) закреплены и pacman их не трогает.
  * Точный откат — снапшот из меню Limine → Snapshots, либо
    `sudo snapper --ambit classic -c root rollback <N>` (в этой системе
    cmdline пинит rootflags=subvol=@, поэтому нужен --ambit classic и
    последующая подмена субтома).
EOF
}

case ${1:-} in
  check|apply|verify|status|revert) CMD=$1; shift ;;
  help|-h|--help) CMD=help; shift ;;
  "") CMD=apply ;;
  -*) CMD=apply ;;
  *) printf 'Неизвестная команда: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

while (( $# )); do
  case $1 in
    --arch)        [[ $# -ge 2 ]] || die "--arch требует значение"; ARCH=$2; shift 2 ;;
    --arch=*)      ARCH=${1#*=}; shift ;;
    --kernel)      [[ $# -ge 2 ]] || die "--kernel требует значение"; KERNEL=$2; shift 2 ;;
    --kernel=*)    KERNEL=${1#*=}; shift ;;
    --priority)    [[ $# -ge 2 ]] || die "--priority требует значение"; PRIORITY=$2; shift 2 ;;
    --priority=*)  PRIORITY=${1#*=}; shift ;;
    --with-nvidia) WITH_NVIDIA=1; shift ;;
    --no-kernel)   NO_KERNEL=1; shift ;;
    --no-mirrors)  NO_MIRRORS=1; shift ;;
    --no-snapshot) NO_SNAPSHOT=1; shift ;;
    --reboot)      REBOOT=1; shift ;;
    --yes|-y)      YES=1; shift ;;
    --dry-run|-n)  DRY=1; shift ;;
    -h|--help)     CMD=help; shift ;;
    *)             die "Неизвестный параметр: $1" ;;
  esac
done

if [[ $CMD == help ]]; then
  usage
  exit 0
fi

case $ARCH in auto|znver4|v4|v3) ;; *) die "--arch: ожидается auto|znver4|v4|v3" ;; esac
case $PRIORITY in omarchy|cachyos) ;; *) die "--priority: ожидается omarchy|cachyos" ;; esac

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-cachyos"
mkdir -p "$STATE_DIR"
RUN_ID=$(date +%Y%m%d-%H%M%S)
LOG="$STATE_DIR/${CMD}-${RUN_ID}.log"
: >"$LOG"
TTY=0
[[ -t 1 ]] && TTY=1
# Весь вывод (включая pacman/omarchy) пишется в лог и на экран. fd 3 хранит
# настоящий stdout: перед выходом закрываем pipe process substitution, иначе
# wait tee висит (запись в pipe ещё открыта самим shell).
exec 3>&1 > >(tee -a "$LOG") 2>&1
TEE_PID=$!
trap on_exit EXIT

# ---------------------------------------------------------------------------
# определение CPU / ISA
# ---------------------------------------------------------------------------
ld_supports() {
  local ld=/lib/ld-linux-x86-64.so.2
  [[ -x $ld ]] || ld=/lib64/ld-linux-x86-64.so.2
  [[ -x $ld ]] && LC_ALL=C "$ld" --help 2>/dev/null | grep -q "$1 (supported, searched)"
}

cpu_flags() { awk -F': ' '/^flags[[:space:]]*:/{print " "$2" "; exit}' /proc/cpuinfo; }

znver4_ok() {
  local vendor family flags f
  vendor=$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo)
  family=$(awk -F': ' '/^cpu family/{print $2; exit}' /proc/cpuinfo)
  [[ $vendor == AuthenticAMD ]] || return 1
  [[ ${family:-0} =~ ^[0-9]+$ ]] || return 1
  (( family >= 25 )) || return 1
  flags=$(cpu_flags)
  # Отличительные черты Zen 4/5 сверх x86-64-v4.
  for f in avx512f avx512dq avx512cd avx512bw avx512vl avx512ifma \
           avx512vbmi avx512_vbmi2 avx512_vnni avx512_bitalg avx512_vpopcntdq \
           avx512_bf16 gfni vaes; do
    [[ $flags == *" $f "* ]] || return 1
  done
  return 0
}

detect_arch() {
  if znver4_ok; then echo znver4; return; fi
  if ld_supports x86-64-v4; then echo v4; return; fi
  if ld_supports x86-64-v3; then echo v3; return; fi
  die "CPU не поддерживает x86-64-v3 — репозитории CachyOS не подходят"
}

resolve_arch() {
  local level
  if [[ $ARCH == auto ]]; then
    detect_arch
    return
  fi
  case $ARCH in
    znver4) znver4_ok || die "CPU не поддерживает znver4 (нужен AMD Zen 4/5). Используйте --arch v4" ;;
    v4)     ld_supports x86-64-v4 || die "CPU не поддерживает x86-64-v4" ;;
    v3)     ld_supports x86-64-v3 || die "CPU не поддерживает x86-64-v3" ;;
  esac
  echo "$ARCH"
}

arch_value() {
  case $1 in
    v3) echo 'x86_64 x86_64_v3' ;;
    *)  echo 'x86_64 x86_64_v3 x86_64_v4' ;;
  esac
}

build_repo_block() {
  local level=$1 mir
  case $level in
    v3) mir=/etc/pacman.d/cachyos-v3-mirrorlist ;;
    *)  mir=/etc/pacman.d/cachyos-v4-mirrorlist ;;
  esac
  printf '[cachyos-%s]\nInclude = %s\n\n' "$level" "$mir"
  printf '[cachyos-core-%s]\nInclude = %s\n\n' "$level" "$mir"
  printf '[cachyos-extra-%s]\nInclude = %s\n\n' "$level" "$mir"
  printf '[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n\n'
}

# ---------------------------------------------------------------------------
# общие проверки
# ---------------------------------------------------------------------------
preflight() {
  [[ $(uname -m) == x86_64 ]] || die "CachyOS-репозитории существуют только для x86_64 (сейчас $(uname -m))"
  have pacman || die "pacman не найден — это не Arch-based система"
  [[ -r $PACMAN_CONF ]] || die "не читается $PACMAN_CONF"

  # check/verify только читают базу — им можно работать и при db.lck.
  if [[ $CMD == apply && -e /var/lib/pacman/db.lck ]]; then
    (( DRY )) || die "есть /var/lib/pacman/db.lck — дождитесь завершения другого pacman"
  fi

  if ! pkg_installed omarchy; then
    die "пакет omarchy не найден — это не Omarchy"
  fi

  local avail
  avail=$(df -Pk /var 2>/dev/null | awk 'NR==2{print int($4/1048576)}')
  # omarchy update сам отказывается работать при свободном месте <10 GiB —
  # лучше сказать об этом до снапшота и бэкапов, а не после 1.7 ГБ загрузки.
  if [[ ${avail:-0} -lt 10 ]]; then
    if [[ $CMD == apply && ! DRY ]]; then
      die "на /var свободно ${avail:-?} ГБ, а omarchy update требует минимум 10 GiB — освободите место"
    fi
    warn "на /var свободно ${avail:-?} ГБ; omarchy update потребует ≥10 GiB"
  fi
}

has_cachyos_repos() { grep -qE '^\[cachyos' "$PACMAN_CONF"; }

# Соответствует ли порядок репозиториев выбранному приоритету.
# Миграция Omarchy 1791403252 (один раз на пользователя, маркер в
# ~/.local/state/omarchy/migrations) ставит [omarchy] сразу после [options]
# и запускает свой `pacman -Syu`, поэтому порядок перепроверяется после
# обновления. Порядок влияет только на пакеты с РАВНЫМИ версиями в двух
# репозиториях; сам [omarchy] содержит ~30 своих пакетов, а не базу.
repo_order_ok() {
  local -a rl
  mapfile -t rl < <(pconf --repo-list)
  local i om=-1 ca=-1
  for i in "${!rl[@]}"; do
    [[ ${rl[i]} == omarchy && $om -lt 0 ]] && om=$i
    [[ ${rl[i]} == cachyos* && $ca -lt 0 ]] && ca=$i
  done
  if [[ $PRIORITY == cachyos ]]; then
    (( ca >= 0 )) && { (( om < 0 )) || (( ca < om )); }
  else
    (( om >= 0 )) && { (( ca < 0 )) || (( om < ca )); }
  fi
}

# Read-only проверка «есть ли snapper config root»: sudo -n, чтобы check
# не висел на запросе пароля. В apply пароль уже закэширован (или NOPASSWD).
snapper_ready() {
  # Конфиг читается и без root; этого достаточно для check.
  [[ -f /etc/snapper/configs/root ]] && return 0
  local out
  if (( EUID == 0 )); then
    out=$(snapper --csvout list-configs 2>/dev/null) || return 1
  else
    out=$(sudo -n snapper --csvout list-configs 2>/dev/null) || return 1
  fi
  awk -F, 'NR > 1 && $1 == "root" { f=1 } END { exit !f }' <<<"$out"
}

ignore_list_from_conf() {
  awk -F'=' '
    /^[[:space:]]*IgnorePkg[[:space:]]*=/ {
      n = split($2, a, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
    }
  ' "$1"
}

compute_pins() {
  local p
  for p in "${PIN_CANDIDATES[@]}"; do
    pkg_installed "$p" && printf '%s\n' "$p"
  done
  # libjxl нужен, только пока hyprgraphics собран под его конкретный soname.
  if pkg_installed hyprgraphics && pacman -Qi hyprgraphics 2>/dev/null | grep -q 'libjxl\.so'; then
    printf 'libjxl\n'
  fi
}

install_conf() {
  local src=$1
  if (( DRY )); then
    info "[dry-run] обновить $PACMAN_CONF"
    return
  fi
  if [[ $PACMAN_CONF == /etc/pacman.conf ]]; then
    as_root install -m 0644 -o root -g root "$src" "$PACMAN_CONF"
  else
    install -m 0644 "$src" "$PACMAN_CONF"
  fi
}

verify_conf() {
  local repos arch
  repos=$(pacman-conf --config "$PACMAN_CONF" --repo-list 2>/dev/null | tr '\n' ' ')
  arch=$(pacman-conf --config "$PACMAN_CONF" Architecture 2>/dev/null | tr '\n' ' ')
  info "репозитории: ${repos:-?}"
  info "Architecture: ${arch:-?}"
  [[ $repos == *cachyos* ]] || die "в pacman.conf нет ни одного репозитория CachyOS"
  if [[ $ARCH != v3 && $arch != *x86_64_v4* ]]; then
    warn "Architecture не содержит x86_64_v4 — v4/znver4-пакеты не выберутся"
  fi
}

# ---------------------------------------------------------------------------
# шаги apply
# ---------------------------------------------------------------------------
create_snapshot() {
  if (( NO_SNAPSHOT )); then
    warn "снапшот отключён (--no-snapshot)"
    return
  fi
  if (( DRY )); then
    info "[dry-run] snapper -c root create -d before-cachyos"
    return
  fi
  if ! have snapper || ! snapper_ready; then
    die "snapper не настроен (нужен btrfs + config root). Осознанный запуск без снапшота: --no-snapshot"
  fi
  local out
  out=$(as_root snapper -c root create -d "before-cachyos" --userdata important=yes --print-number 2>&1) || {
    warn "не удалось создать снапшот: $out"
    die "остановлено, чтобы не менять систему без точки отката (обходится --no-snapshot)"
  }
  SNAP_ID=$(printf '%s\n' "$out" | grep -oE '[0-9]+' | tail -1)
  msg "снапшот создан: #${SNAP_ID:-?}"
}

do_backup() {
  BK="$BACKUP_ROOT/$RUN_ID"
  BK_PRE="$BACKUP_ROOT/pre-conversion"
  if (( DRY )); then
    info "[dry-run] бэкап конфигов в $BK"
    return
  fi
  as_root install -d -m 0700 "$BK" "$BK_PRE"

  # Бэкап «до перехода» создаётся один раз и больше не перезаписывается.
  if ! as_root test -e "$BK_PRE/pacman.conf"; then
    as_root cp -a "$PACMAN_CONF" "$BK_PRE/pacman.conf"
    ignore_list_from_conf "$PACMAN_CONF" >"$STATE_DIR/ignore-before.txt" || true
    as_root cp "$STATE_DIR/ignore-before.txt" "$BK_PRE/ignore-before.txt"
  fi

  as_root cp -a "$PACMAN_CONF" "$BK/pacman.conf"
  local f
  for f in /etc/pacman.d/mirrorlist \
           /etc/pacman.d/cachyos-mirrorlist \
           /etc/pacman.d/cachyos-v3-mirrorlist \
           /etc/pacman.d/cachyos-v4-mirrorlist; do
    [[ -e $f ]] && as_root cp -a "$f" "$BK/$(basename "$f")"
  done

  pacman -Q >"$STATE_DIR/packages-before.txt" 2>/dev/null || true
  as_root cp "$STATE_DIR/packages-before.txt" "$BK/packages-before.txt"
  {
    echo "run_id=$RUN_ID"
    echo "kernel=$KERNEL"
    echo "arch=$ARCH"
    echo "priority=$PRIORITY"
    echo "snapshot=${SNAP_ID:-}"
  } >"$STATE_DIR/meta.env"
  as_root cp "$STATE_DIR/meta.env" "$BK/meta.env"

  msg "бэкап: $BK"
  info "эталон для revert: $BK_PRE/pacman.conf"
}

apply_pins() {
  local tmp merged=() pins=() existing=()
  mapfile -t pins < <(compute_pins)
  mapfile -t existing < <(ignore_list_from_conf "$PACMAN_CONF")
  mapfile -t merged < <(printf '%s\n' "${existing[@]}" "${pins[@]}" | awk 'NF && !seen[$0]++')

  if (( ${#merged[@]} == 0 )); then
    warn "нечего закреплять — ни один из пакетов не установлен"
    return
  fi

  if (( DRY )); then
    info "[dry-run] IgnorePkg = ${merged[*]}"
    return
  fi

  tmp=$(mktemp)
  sed -E '/^[[:space:]]*IgnorePkg[[:space:]]*=/d' "$PACMAN_CONF" >"$tmp"
  local line="IgnorePkg = ${merged[*]}"
  if grep -qE '^[[:space:]]*Architecture[[:space:]]*=' "$tmp"; then
    sed -i "/^[[:space:]]*Architecture[[:space:]]*=/a $line" "$tmp"
  else
    sed -i "/^\[options\]/a $line" "$tmp"
  fi
  install_conf "$tmp"
  rm -f "$tmp"

  printf '%s\n' "${pins[@]}" >"$STATE_DIR/pins.txt"
  as_root cp "$STATE_DIR/pins.txt" "$BK/pins.txt"
  msg "закреплено (${#pins[@]}): ${pins[*]}"
  info "IgnorePkg не мешает явной установке: pacman -S omarchy/<пакет> работает"
}

# Установщик CachyOS в конце сам запускает `pacman -Syu`, а перед этим
# прописывает `Architecture = auto`. Тогда первый массовый апгрейд идёт под
# базовый x86_64, и пакеты, у которых версия в znver4-репозитории не выше
# установленной (например, lib32-mesa), навсегда остаются базовыми.
# Поэтому список архитектур пишется ДО установщика — в форме с двойным
# пробелом, которую его awk не узнаёт (иначе заменит на auto). После
# установщика normalize_repos приводит строку к каноническому виду.
preset_arch_for_installer() {
  local av tmp
  av=$(arch_value "$ARCH")
  av=${av/ /  }
  tmp=$(mktemp)
  if grep -qE '^[[:space:]]*Architecture[[:space:]]*=' "$PACMAN_CONF"; then
    sed -E "s|^[[:space:]]*Architecture[[:space:]]*=.*|Architecture = ${av}|" \
      "$PACMAN_CONF" >"$tmp"
  else
    sed "/^\[options\]/a Architecture = ${av}" "$PACMAN_CONF" >"$tmp"
  fi
  install_conf "$tmp"
  rm -f "$tmp"
  info "Architecture на время установки: ${av/  / }"
}

install_repos() {
  if has_cachyos_repos; then
    info "репозитории CachyOS уже добавлены — установщик пропущен"
    return
  fi
  if (( DRY )); then
    info "[dry-run] скачать $CACHYOS_REPO_URL и выполнить cachyos-repo.sh --install"
    info "[dry-run] до установщика: Architecture = $(arch_value "$ARCH")"
    return
  fi

  # Установщик определяет znver4 через `gcc -march=native`; без gcc он
  # откатится на v4 (работоспособно, но не то, что просили).
  if ! have gcc; then
    info "ставлю gcc: установщик CachyOS использует его для выбора znver4"
    as_root pacman -S --needed --noconfirm gcc || warn "gcc не установился — установщик может выбрать v4"
  fi

  preset_arch_for_installer

  local tmp
  tmp=$(mktemp -d)
  info "скачиваю официальный установщик CachyOS"
  if ! curl -fsSL --retry 3 "$CACHYOS_REPO_URL" -o "$tmp/repo.tar.xz"; then
    rm -rf "$tmp"
    die "не удалось скачать $CACHYOS_REPO_URL"
  fi
  tar -xf "$tmp/repo.tar.xz" -C "$tmp"
  [[ -x $tmp/cachyos-repo/cachyos-repo.sh ]] || { rm -rf "$tmp"; die "в архиве нет cachyos-repo.sh"; }

  # Установщик в конце делает `pacman -U` (keyring, mirrorlists, свой pacman)
  # и затем `pacman -Syu`. Два подводных камня:
  #   * CachyOS-pacman собран против libcrypto.so=4, которого на свежей
  #     Omarchy ещё нет — pacman спрашивает «skip the above package?».
  #     Отвечаем y: keyring/mirrorlists ставятся, зависимость разрешится
  #     позже в полном апгрейде.
  #   * Его `pacman -Syu` качал бы ~1.7 ГБ с ещё не отранжированного
  #     зеркала и молча (вывод идёт через tee, прогресс-бар скрыт).
  #     Поэтому этот Syu мы перехватываем шимом и пропускаем: сначала
  #     синхронизация, установка и запуск cachyos-rate-mirrors, а большой
  #     апгрейд делает `omarchy update` уже с быстрых зеркал.
  # alpm-хук Omarchy против прямых апгрейдов здесь не срабатывает
  # (родитель — скрипт), но разрешение выставляем явно.
  local shim="$tmp/shim"
  mkdir -p "$shim"
  cat >"$shim/pacman" <<'SHIM'
#!/bin/bash
# Пропускаем только системный апгрейд установщика; всё остальное — настоящему pacman.
sync=0 up=0
for a in "$@"; do
  case $a in
    --sync) sync=1 ;;
    --sysupgrade) up=1 ;;
    --*) ;;
    -*) [[ $a == *S* ]] && sync=1; [[ $a == *u* ]] && up=1 ;;
  esac
done
if (( sync && up )); then
  echo "[omarchy-cachyos] pacman -Syu установщика пропущен: апгрейд сделает omarchy update после ранжирования зеркал" >&2
  exit 0
fi
exec /usr/bin/pacman "$@"
SHIM
  chmod +x "$shim/pacman"

  if ! ( cd "$tmp/cachyos-repo" &&
         { for _ in {1..50}; do echo y; done; } |
           as_root env PATH="$shim:$PATH" OMARCHY_ALLOW_DIRECT_PACMAN=1 ./cachyos-repo.sh --install ); then
    rm -rf "$tmp"
    die "установщик CachyOS завершился с ошибкой"
  fi
  rm -rf "$tmp"
  has_cachyos_repos || die "установщик не добавил репозитории CachyOS"
  msg "ключи и mirrorlist установлены"
}

strip_cachyos_sections() {
  awk '
    /^\[/ { skip = ($0 ~ /^\[cachyos(-[a-z0-9]+)*\]$/) }
    !skip { print }
  ' "$1"
}

insert_repo_block() {
  local file=$1 block=$2 anchor="" prev out
  if [[ $PRIORITY == cachyos ]]; then
    anchor=$(awk '/^\[/ && $0 != "[options]" {print NR; exit}' "$file")
  else
    local start
    start=$(awk '/^\[omarchy\]/ {print NR; exit}' "$file")
    if [[ -n ${start:-} ]]; then
      anchor=$(awk -v s="$start" 'NR > s && /^\[/ {print NR; exit}' "$file")
    else
      anchor=$(awk '/^\[/ && $0 != "[options]" {print NR; exit}' "$file")
    fi
  fi

  if [[ -z ${anchor:-} ]]; then
    [[ -s $file ]] && printf '\n' >>"$file"
    printf '%s\n\n' "$block" >>"$file"
    return
  fi

  prev=$(sed -n "$((anchor - 1))p" "$file")
  out=$(mktemp)
  head -n "$((anchor - 1))" "$file" >"$out"
  [[ -z $prev ]] || printf '\n' >>"$out"
  printf '%s\n\n' "$block" >>"$out"
  tail -n "+$anchor" "$file" >>"$out"
  cat "$out" >"$file"
  rm -f "$out"
}

normalize_repos() {
  local level=$1 tmp block av
  block=$(build_repo_block "$level")
  av=$(arch_value "$level")

  if (( DRY )); then
    info "[dry-run] Architecture = $av"
    info "[dry-run] вставить репозитории CachyOS ($level) в $PACMAN_CONF"
    return
  fi

  tmp=$(mktemp)
  strip_cachyos_sections "$PACMAN_CONF" >"$tmp"

  if grep -qE '^[[:space:]]*Architecture[[:space:]]*=' "$tmp"; then
    sed -i -E "s|^[[:space:]]*Architecture[[:space:]]*=.*|Architecture = ${av}|" "$tmp"
  else
    sed -i "/^\[options\]/a Architecture = ${av}" "$tmp"
  fi

  insert_repo_block "$tmp" "$block"
  install_conf "$tmp"
  rm -f "$tmp"
  verify_conf
}

do_mirrors() {
  if (( NO_MIRRORS )); then
    info "ранжирование зеркал пропущено (--no-mirrors)"
    return
  fi
  if (( DRY )); then
    info "[dry-run] pacman -Sy; pacman -S cachyos-rate-mirrors; cachyos-rate-mirrors"
    return
  fi
  # После установщика базы ещё не синхронизированы под новый Architecture;
  # без -Sy пакет cachyos-rate-mirrors не найдётся.
  as_root pacman -Sy --noconfirm ||
    die "не удалось синхронизировать базы — ранжирование зеркал невозможно"
  as_root pacman -S --needed --noconfirm cachyos-rate-mirrors ||
    die "не удалось поставить cachyos-rate-mirrors"

  info "ранжирую зеркала (может занять несколько минут)..."
  as_root cachyos-rate-mirrors ||
    die "не удалось ранжировать зеркала — продолжать с неотранжированными списками небезопасно"
  rank_variant_mirrorlist
  as_root systemctl enable --now cachyos-rate-mirrors.timer 2>/dev/null || true
  msg "зеркала отранжированы, таймер включён"
  grep -m3 '^Server' /etc/pacman.d/cachyos-mirrorlist 2>/dev/null | sed 's/^/    /' || true
  probe_slow_mirrors || warn "проба зеркал не удалась — иду дальше без неё"
}

# --- карантин медленных зеркал ---------------------------------------------
# Зеркало, которое «залипает» на пакетах, валит всю транзакцию: pacman ждёт
# 10 секунд без байтов, объявляет хост битым и в итоге отказывается коммитить
# («failed to commit transaction»), хотя часть пакетов уже скачана. Поэтому
# проблемный хост комментируем в mirrorlist и повторяем — докачка дешёвая.
# Важно: znver4/v4-пакеты идут через cachyos-v4-mirrorlist, v3 — через
# cachyos-v3-mirrorlist; карантить только общий cachyos-mirrorlist бесполезно.
ALL_MIRRORLISTS=(
  /etc/pacman.d/mirrorlist
  /etc/pacman.d/cachyos-mirrorlist
  /etc/pacman.d/cachyos-v3-mirrorlist
  /etc/pacman.d/cachyos-v4-mirrorlist
)

variant_mirrorlist() {
  [[ $ARCH == v3 ]] && echo /etc/pacman.d/cachyos-v3-mirrorlist ||
    echo /etc/pacman.d/cachyos-v4-mirrorlist
}

# cachyos-rate-mirrors ранжирует только cachyos-mirrorlist ($arch). Списки
# v3/v4 ($arch_v3/$arch_v4) остаются в порядке «как пришли» — а именно оттуда
# качается основная масса znver4-пакетов. Переносим отранжированный порядок
# на вариант, сохраняя его подстановку $arch_v4/$arch_v3.
rank_variant_mirrorlist() {
  local generic=/etc/pacman.d/cachyos-mirrorlist target line tmp n
  [[ -f $generic ]] || return 0
  target=$(variant_mirrorlist)
  [[ -f $target ]] || return 0
  tmp=$(mktemp)
  {
    printf '## omarchy-cachyos: порядок от cachyos-rate-mirrors\n\n'
    while IFS= read -r line; do
      [[ $line == 'Server = '* ]] || continue
      if [[ $ARCH == v3 ]]; then
        printf '%s\n' "${line//'$arch'/'$arch_v3'}"
      else
        printf '%s\n' "${line//'$arch'/'$arch_v4'}"
      fi
    done <"$generic"
  } >"$tmp"
  n=$(grep -c '^Server = ' "$tmp" || true)
  if (( n < 3 )); then
    warn "в $(basename "$target") меньше 3 зеркал после переноса ранжирования — оставляю список как был"
    rm -f "$tmp"
    return 0
  fi
  as_root install -m 0644 "$tmp" "$target" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  info "порядок $(basename "$target") приведён к отранжированным зеркалам ($n)"
}

quarantine_host() {
  local host=$1 esc f enabled hit=1
  esc=${host//./\\.}
  for f in "${ALL_MIRRORLISTS[@]}"; do
    [[ -f $f ]] || continue
    as_root grep -qE "^[[:space:]]*Server = https?://${esc}/" "$f" || continue
    enabled=$(grep -cE '^[[:space:]]*Server = ' "$f" || true)
    if (( enabled <= 1 )); then
      warn "не трогаю $host: последнее активное зеркало в $(basename "$f")"
      continue
    fi
    as_root sed -i -E "s|^([[:space:]]*)Server = (https?://${esc}/)|\1#Server = \2|" "$f"
    info "карантин: $host ($(basename "$f"))"
    hit=0
  done
  return $hit
}

demote_bad_mirrors() {
  local log=$1 hosts host hit=1
  # omarchy update запускается с LC_ALL=C, поэтому сообщения pacman английские.
  hosts=$(grep -aE 'failed retrieving file|too many errors' "$log" 2>/dev/null |
            grep -aoE 'from [A-Za-z0-9._-]+' | awk '{print $2}' | sort -u || true)
  [[ -n $hosts ]] || return 1
  while read -r host; do
    [[ -n $host ]] || continue
    if quarantine_host "$host"; then
      hit=0
    fi
  done <<<"$hosts"
  return $hit
}

# cachyos-rate-mirrors меряет скорость по .db, а база маленькая и часто уже в
# кэше зеркала: хост может отдавать её мгновенно и «стоять» на пакетах.
# Проверяем настоящим пакетом активные зеркала (v3/v4 и общий список).
# Порог ОТНОСИТЕЛЬНЫЙ: на медленном канале все зеркала дают 40–50 КиБ/с,
# каратинить их бессмысленно — хуже остаться вообще без зеркал.
probe_slow_mirrors() {
  local repo p url rel file repo_name arch_token srv u code speed size host best=0
  local -a servers=() results=() result hs hv
  for repo in "cachyos-extra-$ARCH" cachyos-extra-znver4 cachyos-extra-v4 \
              cachyos-extra-v3 cachyos; do
    if LC_ALL=C pacman -Sl "$repo" >/dev/null 2>&1; then
      p=$(LC_ALL=C pacman -Sl "$repo" | awk 'NR==1{print $2}')
      [[ -n ${p:-} ]] && break
    fi
  done
  [[ -n ${p:-} ]] || return 0
  # pacman -Sp печатает URL и зависимостей (в том числе Arch). Нужен именно
  # v4/v3-пакет: по его имени видно и архитектуру, и репозиторий. Хост может
  # быть cdn77.cachyos.org/repo/... — искать '/cachyos/repo/' нельзя.
  local want=v4; [[ $ARCH == v3 ]] && want=v3
  url=$(LC_ALL=C pacman -Sp --print-format '%l' "$p" 2>/dev/null |
          grep -m1 "x86_64_${want}\.pkg\.tar\.zst" || true)
  [[ -n $url ]] || url=$(LC_ALL=C pacman -Sp --print-format '%l' "$p" 2>/dev/null |
          grep -m1 -E 'cachyos[^/]*/repo/|/cachyos/repo/' || true)
  [[ -n $url ]] || return 0
  rel=${url#*://}; rel=${rel#*/}
  file=${rel##*/}
  repo_name=${rel%/*}; repo_name=${repo_name##*/}
  arch_token=$(awk -F/ '{for (i = 1; i < NF; i++) if ($i == "repo") { print $(i + 1); exit }}' <<<"$rel")
  [[ -n $arch_token ]] || return 0

  # Сначала вариант (оттуда идут znver4-пакеты), потом общий список.
  while IFS= read -r srv; do servers+=("$srv"); done < <(
    { grep -m3 '^Server = ' "$(variant_mirrorlist)" 2>/dev/null || true
      grep -m2 '^Server = ' /etc/pacman.d/cachyos-mirrorlist 2>/dev/null || true
    } | awk '!seen[$0]++'
  )
  (( ${#servers[@]} )) || return 0

  info "проверяю скорость зеркал на настоящем пакете ($file)..."
  for srv in "${servers[@]}"; do
    srv=${srv#Server = }
    u=${srv//'$arch_v4'/$arch_token}
    u=${u//'$arch_v3'/$arch_token}
    u=${u//'$arch'/$arch_token}
    u=${u//'$repo'/$repo_name}
    u=${u%/}/$file
    read -r code speed size < <(curl -o /dev/null -sS --max-time 8 -r 0-262143 \
      -w '%{http_code} %{speed_download} %{size_download}\n' "$u" 2>/dev/null ||
      printf '000 0 0\n') || true
    case ${code:-000} in 2*) ;; *) continue ;; esac  # 404 — не «медленно»
    [[ ${size:-0} =~ ^[0-9]+$ ]] && (( size > 0 )) || continue
    host=${srv#*://}; host=${host%%/*}
    speed=${speed:-0}
    results+=("$host|$speed")
    awk -v s="$speed" -v b="$best" 'BEGIN{exit !(s > b)}' && best=$speed
  done
  (( ${#results[@]} > 1 )) || return 0
  if awk -v b="$best" 'BEGIN{exit !(b < 100000)}'; then
    info "все зеркала медленные ($(awk -v b="$best" 'BEGIN{printf "%.0f", b/1024}') КиБ/с) — это канал, карантин не применяю"
    return 0
  fi
  for result in "${results[@]}"; do
    IFS='|' read -r hs hv <<<"$result"
    if awk -v s="$hv" -v b="$best" 'BEGIN{exit !(s*2 < b)}'; then
      warn "медленно на пакете: $hs ($(awk -v s="$hv" 'BEGIN{printf "%.0f", s/1024}') КиБ/с)"
      quarantine_host "$hs" || true
    else
      info "быстро: $hs ($(awk -v s="$hv" 'BEGIN{printf "%.0f", s/1024}') КиБ/с)"
    fi
  done
}

do_update() {
  if (( DRY )); then
    info "[dry-run] omarchy update -y"
    return
  fi
  local attempt rc log
  log=$(mktemp "${TMPDIR:-/tmp}/omarchy-update.XXXXXX.log")
  for attempt in 1 2 3; do
    if (( attempt == 1 )); then
      msg "обновляю систему штатным omarchy update (снапшот + миграции)"
    else
      msg "omarchy update, повтор $attempt из 3 (уже скачанное остаётся в кэше)"
    fi
    start_progress
    rc=0
    # Вывод идёт и в терминал, и в лог: по нему видно, на каком зеркале
    # pacman споткнулся, чтобы увести именно его в карантин. LC_ALL=C нужен
    # для парсинга сообщений pacman. Таймаут страхует от вечного ожидания.
    (
      set -o pipefail
      LC_ALL=C timeout --foreground --kill-after=30s \
        "${OMARCHY_CACHYOS_UPDATE_TIMEOUT:-7200}" omarchy update -y 2>&1 | tee "$log"
    ) &
    local upd_pid=$!
    start_update_watch "$log" "$upd_pid"
    wait "$upd_pid" || rc=$?
    stop_update_watch
    stop_progress
    if (( rc == 124 || rc == 137 || rc == 143 )); then
      die "omarchy update прерван таймаутом/ожиданием ввода (код $rc) — см. $LOG"
    fi
    if (( rc == 0 )); then
      rm -f "$log"
      return 0
    fi
    (( attempt < 3 )) || break
    if demote_bad_mirrors "$log"; then
      warn "зеркало(а) в карантине — обновляю базы и повторяю"
      as_root pacman -Sy --noconfirm >/dev/null 2>&1 || true
    else
      warn "в выводе нет проблемных зеркал — повтор ничего не даст"
      break
    fi
  done
  rm -f "$log"
  die "omarchy update завершился с ошибкой — см. вывод выше; скрипт можно запустить повторно"
}

check_pins_after_update() {
  local p before now
  [[ -f $BK/packages-before.txt ]] || return 0
  for p in $(compute_pins); do
    before=$(awk -v p="$p" '$1==p{print $2; exit}' "$BK/packages-before.txt")
    now=$(pkg_ver "$p")
    if [[ -n $before && $before != "$now" ]]; then
      warn "$p изменился: $before -> $now (пин не сработал?)"
    fi
  done
}

do_kernel() {
  if (( NO_KERNEL )); then
    info "ядро не трогаю (--no-kernel)"
    return
  fi

  local pkgs=("$KERNEL")
  if pacman -Si "${KERNEL}-headers" >/dev/null 2>&1; then
    pkgs+=("${KERNEL}-headers")
  fi
  if (( WITH_NVIDIA )); then
    if pkg_installed nvidia-open-dkms || pkg_installed nvidia-open; then
      pkgs+=("${KERNEL}-nvidia-open")
    elif pkg_installed nvidia-dkms || pkg_installed nvidia; then
      pkgs+=("${KERNEL}-nvidia")
    else
      warn "--with-nvidia задан, но nvidia-пакетов не найдено"
    fi
  fi

  if (( DRY )); then
    info "[dry-run] pacman -S --needed ${pkgs[*]}"
    info "[dry-run] omarchy kernel set $KERNEL"
    return
  fi

  local missing=0 p
  for p in "${pkgs[@]}"; do
    pkg_installed "$p" || missing=1
  done
  if (( missing )); then
    # Завершать нужно и headers/nvidia, даже если само ядро уже стоит.
    as_root pacman -S --needed --noconfirm "${pkgs[@]}" ||
      die "не удалось установить $KERNEL и его модули"
  else
    info "$KERNEL и его модули уже установлены ($(pkg_ver "$KERNEL"))"
  fi

  local cur
  cur=$(omarchy kernel get 2>/dev/null || true)
  if [[ $cur != "$KERNEL" ]]; then
    msg "делаю $KERNEL ядром по умолчанию"
    if [[ -t 0 ]]; then
      omarchy kernel set "$KERNEL" || die "omarchy kernel set $KERNEL не сработал"
    else
      as_root /usr/bin/omarchy-kernel set "$KERNEL" ||
        die "omarchy-kernel set $KERNEL не сработал"
      # Корневой путь не выставляет флаг «нужна перезагрузка» — делаем сами.
      have omarchy-state && omarchy-state set reboot-required 2>/dev/null || true
    fi
  else
    info "ядро по умолчанию уже $KERNEL"
  fi

  # Прямой [[ -f /boot/limine.conf ]] под set -e падает, если /boot закрыт.
  if boot_file /boot/limine.conf; then
    as_root grep -q "kernel-id=$KERNEL" /boot/limine.conf ||
      warn "в /boot/limine.conf нет записи kernel-id=$KERNEL"
  else
    info "/boot/limine.conf недоступен для проверки — запись ядра не проверена"
  fi
  # Omarchy грузит ядро либо через limine-entry-tool (path/module_path в /boot),
  # либо через UKI в /boot/EFI/Linux — проверяем UKI, только если он вообще есть.
  if boot_dir /boot/EFI/Linux && ! boot_file "/boot/EFI/Linux/omarchy_${KERNEL}.efi"; then
    warn "нет UKI /boot/EFI/Linux/omarchy_${KERNEL}.efi"
  fi
}

# ---------------------------------------------------------------------------
# проверка результата
# ---------------------------------------------------------------------------
repo_counts() {
  local ti tc
  ti=$(mktemp); tc=$(mktemp)
  pacman -Q >"$ti"
  local -a repos
  mapfile -t repos < <(pconf --repo-list)
  # pacman -Sl печатает репозитории в порядке аргументов: первое совпадение
  # и есть реальный источник пакета, даже если версия есть ещё в двух repo.
  pacman -Sl "${repos[@]}" >"$tc" 2>/dev/null || true
  awk '
    NR == FNR { ver[$1]=$2; next }
    ($2 in ver) && ver[$2] == $3 && !seen[$2]++ { c[$1]++ }
    END { for (r in c) printf "  %-26s %5d\n", r, c[r] }
  ' "$ti" "$tc" | sort -k2 -nr
  rm -f "$ti" "$tc"
}

verify_fail() { warn "$*"; VERIFY_RC=1; }

cmd_verify() {
  preflight
  VERIFY_RC=0
  local level
  level=$(resolve_arch)

  sect "Система"
  info "ОС: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-?}")"
  info "ядро: $(uname -r)"
  info "omarchy: $(pkg_ver omarchy || echo '?')"
  info "ISA: $level (Architecture: $(pconf Architecture | tr '\n' ' '))"

  sect "Репозитории"
  info "порядок: $(pconf --repo-list | tr '\n' ' ')"
  if has_cachyos_repos; then
    msg "репозитории CachyOS на месте"
  else
    verify_fail "репозиториев CachyOS нет"
  fi

  sect "Зависимости"
  if pacman -Dk >/dev/null 2>&1; then
    msg "pacman -Dk: битых зависимостей нет"
  else
    verify_fail "pacman -Dk нашёл проблемы:"
    pacman -Dk 2>&1 | sed 's/^/    /' || true
  fi

  sect "Пины"
  local pins=()
  mapfile -t pins < <(compute_pins)
  if (( ${#pins[@]} == 0 )); then
    warn "ни один пакет из списка пинов не установлен"
  else
    local p v om base req
    for p in "${pins[@]}"; do
      v=$(pkg_ver "$p")
      om=$(pacman -Si "omarchy/$p" 2>/dev/null | awk -F': ' '/^Version/{print $2; exit}') || true
      if [[ -z $om ]]; then
        info "$p: $v (Omarchy не публикует — версия из Arch)"
      elif [[ $v == "$om" ]]; then
        info "$p: $v — сборка Omarchy"
      else
        verify_fail "$p: $v, в [omarchy] $om — возможно, подменён"
      fi
    done

    # omarchy-hyprland-titlebars требует конкретную major/minor hyprland.
    if pkg_installed omarchy-hyprland-titlebars; then
      req=$(pacman -Qi omarchy-hyprland-titlebars | awk -F': ' '/^Depends On/{print $2}' |
            tr ' ' '\n' | grep '^hyprland=' | head -1 | cut -d= -f2) || true
      if [[ -n $req ]]; then
        base=$(pkg_ver hyprland); base=${base%-*}
        if [[ $base == "${req%-*}" ]]; then
          info "titlebars: hyprland $base соответствует требованию $req"
        else
          verify_fail "titlebars требует hyprland=$req, установлен $(pkg_ver hyprland)"
        fi
      fi
    fi
  fi

  sect "Обновления"
  local tmpu
  tmpu=$(mktemp)
  # LC_ALL=C: иначе маркер [ignored] локализуется и проверка пинов ложно срабатывает.
  LC_ALL=C pacman -Qu 2>/dev/null >"$tmpu" || true
  if (( ${#pins[@]} )); then
    printf '%s\n' "${pins[@]}" >"$STATE_DIR/pins-verify.txt"
    local bad
    bad=$(awk 'NR==FNR{p[$1]=1; next} !/\[ignored\]/ && ($1 in p){print}' \
          "$STATE_DIR/pins-verify.txt" "$tmpu")
    if [[ -n $bad ]]; then
      verify_fail "пины предлагаются к обновлению без [ignored]:"
      printf '%s\n' "$bad" | sed 's/^/    /'
    else
      msg "закреплённые пакеты обновляться не будут"
    fi
  fi
  info "всего обновлений: $(wc -l <"$tmpu")"
  rm -f "$tmpu"

  sect "Ядро и загрузка"
  info "ядро по умолчанию: $(omarchy kernel get 2>/dev/null || echo '?')"
  info "установленные ядра: $(omarchy kernel list 2>/dev/null | tr '\n' ' ' || echo '?')"
  if ! can_check_boot; then
    info "/boot закрыт для пользователя и sudo без пароля недоступен — проверьте запись и UKI под sudo:"
    info "  sudo grep -c kernel-id=$KERNEL /boot/limine.conf; sudo ls -l /boot/EFI/Linux/omarchy_${KERNEL}.efi"
  elif boot_grep "kernel-id=$KERNEL"; then
    msg "запись kernel-id=$KERNEL есть в limine.conf"
  else
    warn "в limine.conf нет записи kernel-id=$KERNEL"
  fi
  if can_check_boot && boot_dir /boot/EFI/Linux; then
    boot_file "/boot/EFI/Linux/omarchy_${KERNEL}.efi" &&
      msg "UKI на месте" || warn "нет /boot/EFI/Linux/omarchy_${KERNEL}.efi"
  elif can_check_boot; then
    info "загрузка через limine-entry-tool, без UKI — для этой установки это норма"
  fi

  sect "Сессия"
  if pgrep -x quickshell >/dev/null 2>&1; then
    msg "quickshell запущен ($(pgrep -x quickshell | wc -l) процесс(ов))"
  else
    warn "quickshell не запущен"
  fi
  local failed
  failed=$({ systemctl --failed --no-legend 2>/dev/null || true; } | wc -l)
  (( failed == 0 )) && msg "упавших systemd-юнитов нет" || warn "упавших юнитов: $failed"

  local sig
  sig=$(find "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)
  if [[ -n $sig ]] && have hyprctl; then
    local errs
    # configerrors может вернуть пустоту просто потому, что сокет не ответил:
    # сначала убеждаемся, что hyprctl реально говорит с сессией.
    if HYPRLAND_INSTANCE_SIGNATURE=$(basename "$sig") hyprctl version >/dev/null 2>&1; then
      errs=$(HYPRLAND_INSTANCE_SIGNATURE=$(basename "$sig") hyprctl configerrors 2>&1 || true)
      if [[ -z $errs || $errs == *'Config errors: 0'* ]]; then
        msg "hyprctl configerrors пуст"
      else
        verify_fail "ошибки конфигурации Hyprland:"
        printf '%s\n' "$errs" | sed 's/^/    /'
      fi
    else
      info "hyprctl не отвечает из этого окружения — проверьте из сессии"
    fi
  else
    info "hyprctl недоступен из этого окружения — проверьте из сессии"
  fi

  sect "Откуда пакеты"
  info "всего установлено: $(pacman -Qq | wc -l)"
  info "точное совпадение версий; источник — первый по приоритету репозиторий с такой версией"
  repo_counts

  sect "Итог"
  if [[ $(uname -r) == *cachyos* ]]; then
    msg "загружено ядро CachyOS: $(uname -r)"
  else
    info "сейчас загружено $(uname -r); после перезагрузки будет $KERNEL"
  fi
  return $VERIFY_RC
}

# ---------------------------------------------------------------------------
# команды
# ---------------------------------------------------------------------------
cmd_check() {
  preflight
  local level
  level=$(resolve_arch)

  sect "Система"
  info "ОС: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-?}")"
  info "CPU: $(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)"
  info "виртуалка: $(systemd-detect-virt 2>/dev/null || echo 'нет')"
  info "ядро: $(uname -r)"
  info "омарчи: $(pkg_ver omarchy || echo '?')"

  sect "ISA"
  info "выбрано: $level"
  case $level in
    znver4) info "znver4 = Zen 4/5, надмножество x86-64-v4; быстрее, но не переносимо на Intel" ;;
    v4)     info "x86-64-v4: Skylake-X и новее, переносимо между v4-CPU" ;;
    v3)     info "x86-64-v3: Haswell и новее" ;;
  esac

  sect "Репозитории"
  if has_cachyos_repos; then
    msg "CachyOS уже добавлены"
  else
    info "CachyOS пока нет"
  fi
  info "порядок: $(pconf --repo-list | tr '\n' ' ')"
  info "Architecture: $(pconf Architecture | tr '\n' ' ')"
  if [[ $(pconf Architecture | tr '\n' ' ') == *auto* ]]; then
    warn "Architecture=auto схлопнется в x86_64 — apply это исправит"
  fi
  if has_cachyos_repos && ! repo_order_ok; then
    info "порядок не соответствует приоритету '$PRIORITY' — apply переставит репозитории"
  fi

  sect "Пины"
  local want existing
  want=$(compute_pins | tr '\n' ' ')
  existing=$(ignore_list_from_conf "$PACMAN_CONF" | tr '\n' ' ')
  info "нужно закрепить: ${want:-нет}"
  info "уже закреплено:   ${existing:-нет}"
  if [[ -n $want ]]; then
    local missing
    missing=$(comm -23 <(compute_pins | sort -u) <(ignore_list_from_conf "$PACMAN_CONF" | sort -u) | tr '\n' ' ')
    [[ -z $missing ]] || info "не хватает: $missing"
  fi

  sect "Ядро"
  info "выбрано: $KERNEL"
  info "по умолчанию сейчас: $(omarchy kernel get 2>/dev/null || echo '?')"
  info "установлено: $(omarchy kernel list 2>/dev/null | tr '\n' ' ' || echo '?')"
  [[ -f /etc/default/limine ]] && info "limine: /etc/default/limine есть" ||
    warn "нет /etc/default/limine — Omarchy kernel set может не сработать"

  sect "Снапшоты и место"
  if have snapper && snapper_ready; then
    info "snapper: config root есть ($(findmnt -no FSTYPE /))"
  else
    warn "snapper не настроен или нужен sudo — apply остановится; осознанный обход: --no-snapshot"
  fi
  info "свободно на /var: $(df -Ph /var 2>/dev/null | awk 'NR==2{print $4}')"

  sect "План apply"
  cat <<EOF
  1. снапшот snapper и бэкап /etc/pacman.conf -> $BACKUP_ROOT
  2. IgnorePkg: ${want:-...}
  3. $([[ -n $(grep -E '^\[cachyos' "$PACMAN_CONF") ]] && echo 'репозитории CachyOS уже есть — только нормализация' || echo 'официальный установщик репозиториев CachyOS')
  4. Architecture = $(arch_value "$level"), приоритет: $PRIORITY (после update перепроверяется)
  5. $([[ $NO_MIRRORS == 1 ]] && echo 'зеркала: пропуск' || echo 'ранжирование cachyos-rate-mirrors + перенос порядка на v4/v3-список + проба пакетом')
  6. omarchy update (при ошибке — карантин плохих зеркал и повтор до 3 раз)
  7. $([[ $NO_KERNEL == 1 ]] && echo 'ядро: пропуск' || echo "ядро $KERNEL (+ headers/модули) -> дефолт")
  8. verify (при ошибке apply не считается завершённым и --reboot не выполняется)
EOF
  say ""
  info "ничего не изменено (это check). Для перехода: $0 (apply по умолчанию)"
}

apply_on_error() {
  local rc=$? line=${1:-?}
  # set -E наследует ловушку в подоболочки и подстановки $(…). Оттуда молча
  # выходим: иначе одна неудачная команда печатает «ошибку» из фонового
  # индикатора прогресса, хотя основной скрипт продолжает работу.
  if [[ ${BASHPID:-$$} != $$ ]]; then
    exit "$rc"
  fi
  trap - ERR
  warn "ошибка на строке $line (код $rc)"
  [[ -n $SNAP_ID ]] && warn "снапшот до изменений: #$SNAP_ID — Limine → Snapshots"
  [[ -n $BK ]] && warn "бэкап конфигов: $BK"
  warn "лог: $LOG"
  exit "$rc"
}

cmd_apply() {
  (( EUID == 0 )) && die "Запускайте от обычного пользователя: скрипт сам вызывает sudo (omarchy update не работает от root)"
  preflight
  local level
  level=$(resolve_arch)
  ARCH=$level

  trap 'apply_on_error "$LINENO"' ERR

  sect "План"
  info "ISA: $ARCH    ядро: $KERNEL    приоритет: $PRIORITY"
  info "будет закреплено: $(compute_pins | tr '\n' ' ')"
  info "дальше — без вопросов; пароль sudo спросим один раз сейчас"

  if (( ! DRY )); then
    have curl || die "нужен curl для загрузки установщика CachyOS"
    curl -fsI --max-time 15 "$CACHYOS_REPO_URL" >/dev/null 2>&1 ||
      die "нет доступа к $CACHYOS_REPO_URL — проверьте интернет"
    # sudo -v спрашивает пароль даже при NOPASSWD и без tty падает
    # («a terminal is required»). Сначала проверяем, что sudo работает
    # без пароля; только иначе просим его один раз.
    if ! sudo -n true 2>/dev/null; then
      # Пароль вводится один раз здесь. Затем (уже по кэшу) ставим dropin с
      # timestamp_type=global: omarchy update запускает sudo в своём pty и
      # без этого спросил бы пароль второй раз.
      sudo -v || die "без sudo переход невозможен (нужен tty или NOPASSWD)"
      setup_global_sudo_timestamp
    fi
    start_sudo_keepalive
  fi

  countdown

  create_snapshot
  do_backup
  apply_pins
  install_repos
  normalize_repos "$ARCH"
  do_mirrors
  do_update
  if (( DRY )); then
    info "[dry-run] после omarchy update перепроверить порядок репозиториев (неприменённая миграция ставит [omarchy] первой)"
  elif ! repo_order_ok; then
    info "миграция Omarchy переставила репозитории — возвращаю приоритет '$PRIORITY'"
    normalize_repos "$ARCH"
  fi
  check_pins_after_update
  do_kernel

  if (( ! DRY )); then
    # Ошибку проверки больше не гасим: без неё «переход выполнен» был бы ложью.
    if cmd_verify; then
      VERIFY_RC=0
    else
      VERIFY_RC=$?
      warn "проверка не прошла (код $VERIFY_RC) — переход считается незавершённым"
      warn "лог: $LOG"
    fi
  fi

  sect "Готово"
  if (( DRY )); then
    msg "dry-run завершён: изменения не вносились"
    return 0
  fi
  if (( VERIFY_RC != 0 )); then
    die "переход прерван: проверка не прошла; --reboot отменён"
  fi
  msg "переход выполнен"
  info "лог: $LOG"
  [[ -n $SNAP_ID ]] && info "снапшот до изменений: #$SNAP_ID (Limine → Snapshots)"
  if (( REBOOT )); then
    info "перезагрузка через 10 секунд — Ctrl+C отменит"
    sleep 10
    as_root systemctl reboot
  else
    info "перезагрузитесь, чтобы загрузилось ядро $KERNEL"
    info "после перезагрузки: $0 verify"
  fi
}

cmd_status() {
  echo "ядро:        $(uname -r) (дефолт: $(omarchy kernel get 2>/dev/null || echo '?'))"
  echo "омарчи:      $(pkg_ver omarchy || echo '?')"
  echo "репозитории: $(pconf --repo-list | tr '\n' ' ')"
  echo "архитектура: $(pconf Architecture | tr '\n' ' ')"
  echo "обновлений:  $(LC_ALL=C pacman -Qu 2>/dev/null | wc -l) (из них игнорируется: $(LC_ALL=C pacman -Qu 2>/dev/null | grep -c '\[ignored\]' || true))"
  echo "пины:        $(ignore_list_from_conf "$PACMAN_CONF" | tr '\n' ' ')"
  echo "shell:       $(pgrep -x quickshell >/dev/null && echo 'работает' || echo 'не запущен')"
}

cmd_revert() {
  (( EUID == 0 )) && die "Запускайте от обычного пользователя (скрипт сам вызывает sudo)"
  preflight
  confirm "Убрать репозитории CachyOS и вернуть штатное ядро?" || return 0

  local bk=$BACKUP_ROOT/pre-conversion
  # Каталог бэкапов 0700 root: обычный пользователь не может даже stat-ить.
  as_root test -f "$bk/pacman.conf" ||
    die "нет эталонного бэкапа $bk/pacman.conf — откат делайте снапшотом"

  (( DRY )) || { sudo -n true 2>/dev/null || sudo -v; }

  # Берём из метаданных последнего apply: ядро могло быть не по умолчанию,
  # а снапшот нельзя угадывать из SNAP_ID другого процесса.
  local runbk="" d meta="" revert_kernel=$KERNEL revert_snap=""
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if as_root test -f "$d/meta.env"; then runbk=$d; break; fi
  done < <(as_root find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
  if [[ -n $runbk ]]; then
    meta=$(as_root cat "$runbk/meta.env" 2>/dev/null || true)
    revert_kernel=$(awk -F= '$1=="kernel" && $2 != "" {print $2; exit}' <<<"$meta")
    revert_snap=$(awk -F= '$1=="snapshot" && $2 != "" {print $2; exit}' <<<"$meta")
    [[ -n $revert_kernel ]] || revert_kernel=$KERNEL
  fi

  # Сначала ядро: нельзя удалять пакет, на котором система работает.
  if (( ! NO_KERNEL )); then
    if pkg_installed linux-omarchy; then
      info "возвращаю дефолт на linux-omarchy"
      if (( ! DRY )); then
        as_root /usr/bin/omarchy-kernel set linux-omarchy || warn "omarchy kernel set не сработал"
        have omarchy-state && omarchy-state set reboot-required 2>/dev/null || true
      fi
    else
      warn "linux-omarchy не установлен — пропускаю смену дефолта"
    fi
  fi

  if (( DRY )); then
    info "[dry-run] восстановить $bk/pacman.conf и mirrorlist'ы из $runbk"
  else
    as_root install -m 0644 -o root -g root "$bk/pacman.conf" "$PACMAN_CONF"
    as_root cp -a "$bk/pacman.conf" "$BACKUP_ROOT/pacman.conf.reverted.$(date +%s)"
    msg "pacman.conf восстановлен (репозитории CachyOS и пины убраны)"
    # Без этого карантин останется и таймер снова ранжирует зеркала.
    local f bn
    for f in /etc/pacman.d/mirrorlist /etc/pacman.d/cachyos-mirrorlist \
             /etc/pacman.d/cachyos-v3-mirrorlist /etc/pacman.d/cachyos-v4-mirrorlist; do
      bn=$(basename "$f")
      [[ -n $runbk ]] || continue
      if as_root test -f "$runbk/$bn"; then
        as_root install -m 0644 "$runbk/$bn" "$f" &&
          info "mirrorlist восстановлен: $bn"
      fi
    done
    as_root systemctl disable --now cachyos-rate-mirrors.timer 2>/dev/null || true
    msg "зеркала и карантин сброшены, таймер ранжирования выключен"
  fi

  if pkg_installed "$revert_kernel"; then
    if [[ $(uname -r) == *cachyos* ]]; then
      warn "сейчас загружено CachyOS-ядро; после перезагрузки запустите revert ещё раз, чтобы удалить $revert_kernel"
    else
      if confirm "Удалить пакеты ядра $revert_kernel?"; then
        local -a rm_pkgs=()
        for d in "$revert_kernel" "${revert_kernel}-headers" \
                 "${revert_kernel}-nvidia" "${revert_kernel}-nvidia-open"; do
          pkg_installed "$d" && rm_pkgs+=("$d")
        done
        if (( ${#rm_pkgs[@]} )); then
          if (( DRY )); then
            info "[dry-run] pacman -Rns ${rm_pkgs[*]}"
          elif as_root pacman -Rns --noconfirm "${rm_pkgs[@]}"; then
            msg "ядро и модули удалены: ${rm_pkgs[*]}"
          else
            warn "не удалось удалить ${rm_pkgs[*]} — сделайте это вручную"
          fi
        fi
      fi
    fi
  fi

  info "пакеты, собранные CachyOS, останутся до следующего обновления из Arch"
  info "точный откат: меню Limine → Snapshots → снапшот #${revert_snap:-<номер>}, либо"
  info "  sudo snapper --ambit classic -c root rollback <N>"
  msg "готово"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case $CMD in
    check)  cmd_check ;;
    apply)  cmd_apply ;;
    verify) cmd_verify || exit $? ;;
    status) cmd_status ;;
    revert) cmd_revert ;;
  esac
fi
