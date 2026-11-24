#!/usr/bin/env bash
# =============================================================================
#  omarchy-cachyos.sh — перевод свежей Omarchy на репозитории CachyOS
#
#  Проверено на Omarchy 4.5.0 (VM): 848 пакетов, 671 (79%) из CachyOS,
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
#    7. обновляет систему штатным `omarchy update` (снапшот + миграции);
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
#
#  Запуск (от обычного пользователя, не от root):
#      ./omarchy-cachyos.sh            # сразу apply: всё до конца, без вопросов
#      ./omarchy-cachyos.sh check      # только диагностика
#      ./omarchy-cachyos.sh verify
#      ./omarchy-cachyos.sh revert
#
#  apply не задаёт вопросов: один раз спрашивает пароль sudo в начале
#  (дальше таймстамп продлевается в фоне) и идёт до самой проверки.
#  Прервать можно Ctrl+C — снапшот к этому моменту уже создан.
#
#  После apply нужен перезагруз, чтобы загрузилось ядро CachyOS
#  (или запустите с --reboot).
# =============================================================================
set -Eeuo pipefail

VERSION="2.3"

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
    while sleep 30; do
      printf '%s    … идёт загрузка/установка, кэш пакетов: %s%s\n' \
        "$c_yel" "$(du -sh /var/cache/pacman/pkg 2>/dev/null | cut -f1)" "$c_reset"
    done
  ) &
  PROGRESS_PID=$!
}

stop_progress() {
  [[ -n ${PROGRESS_PID:-} ]] && kill "$PROGRESS_PID" 2>/dev/null || true
  PROGRESS_PID=""
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
    --arch)        ARCH=${2:?"--arch требует значение"}; shift 2 ;;
    --arch=*)      ARCH=${1#*=}; shift ;;
    --kernel)      KERNEL=${2:?"--kernel требует значение"}; shift 2 ;;
    --kernel=*)    KERNEL=${1#*=}; shift ;;
    --priority)    PRIORITY=${2:?"--priority требует значение"}; shift 2 ;;
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
# Весь вывод (включая pacman/omarchy) пишется в лог и на экран.
exec > >(tee -a "$LOG") 2>&1

# ---------------------------------------------------------------------------
# определение CPU / ISA
# ---------------------------------------------------------------------------
ld_supports() {
  local ld=/lib/ld-linux-x86-64.so.2
  [[ -x $ld ]] || ld=/lib64/ld-linux-x86-64.so.2
  [[ -x $ld ]] && "$ld" --help 2>/dev/null | grep -q "$1 (supported, searched)"
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

  if [[ -e /var/lib/pacman/db.lck ]]; then
    warn "найден /var/lib/pacman/db.lck — возможно, работает другой pacman"
    (( DRY )) || die "дождитесь завершения другого pacman"
  fi

  if ! pkg_installed omarchy; then
    die "пакет omarchy не найден — это не Omarchy"
  fi

  local avail
  avail=$(df -Pk /var 2>/dev/null | awk 'NR==2{print int($4/1048576)}')
  if [[ ${avail:-0} -lt 6 ]]; then
    warn "на /var свободно ${avail:-?} ГБ; для массового апгрейда желательно ≥6 ГБ"
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
# не висел на запросе пароля. В apply пароль уже закэширован через sudo -v.
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
    { warn "не удалось синхронизировать базы — зеркала не ранжирую"; return; }
  as_root pacman -S --needed --noconfirm cachyos-rate-mirrors ||
    { warn "не удалось поставить cachyos-rate-mirrors"; return; }

  info "ранжирую зеркала (может занять несколько минут)..."
  if ! as_root cachyos-rate-mirrors; then
    warn "cachyos-rate-mirrors завершился с ошибкой — списки остались прежними"
    return
  fi
  as_root systemctl enable --now cachyos-rate-mirrors.timer 2>/dev/null || true
  msg "зеркала отранжированы, таймер включён"
  grep -m3 '^Server' /etc/pacman.d/cachyos-mirrorlist 2>/dev/null | sed 's/^/    /' || true
}

do_update() {
  if (( DRY )); then
    info "[dry-run] omarchy update -y"
    return
  fi
  msg "обновляю систему штатным omarchy update (снапшот + миграции)"
  start_progress
  omarchy update -y || { stop_progress; die "omarchy update завершился с ошибкой — см. вывод выше; скрипт можно запустить повторно"; }
  stop_progress
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

  if pkg_installed "$KERNEL"; then
    info "$KERNEL уже установлен ($(pkg_ver "$KERNEL"))"
  else
    as_root pacman -S --needed --noconfirm "${pkgs[@]}" ||
      die "не удалось установить $KERNEL"
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

  [[ -f /boot/limine.conf ]] &&
    { as_root grep -q "kernel-id=$KERNEL" /boot/limine.conf ||
      warn "в /boot/limine.conf нет записи kernel-id=$KERNEL"; }
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
  pacman -Sl "${repos[@]}" >"$tc" 2>/dev/null || true
  awk '
    NR == FNR { ver[$1]=$2; next }
    ($2 in ver) && ver[$2] == $3 { c[$1]++ }
    END { for (r in c) printf "  %-26s %5d\n", r, c[r] }
  ' "$ti" "$tc" | sort -k2 -nr
  rm -f "$ti" "$tc"
}

cmd_verify() {
  preflight
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
    warn "репозиториев CachyOS нет"
  fi

  sect "Зависимости"
  if pacman -Dk >/dev/null 2>&1; then
    msg "pacman -Dk: битых зависимостей нет"
  else
    warn "pacman -Dk нашёл проблемы:"
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
        warn "$p: $v, в [omarchy] $om — возможно, подменён"
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
          warn "titlebars требует hyprland=$req, установлен $(pkg_ver hyprland)"
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
      warn "пины предлагаются к обновлению без [ignored]:"
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
  failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
  (( failed == 0 )) && msg "упавших systemd-юнитов нет" || warn "упавших юнитов: $failed"

  local sig
  sig=$(find "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)
  if [[ -n $sig ]] && have hyprctl; then
    local errs
    errs=$(HYPRLAND_INSTANCE_SIGNATURE=$(basename "$sig") hyprctl configerrors 2>/dev/null || true)
    if [[ -z $errs ]]; then
      msg "hyprctl configerrors пуст"
    else
      warn "ошибки конфигурации Hyprland:"
      printf '%s\n' "$errs" | sed 's/^/    /'
    fi
  else
    info "hyprctl недоступен из этого окружения — проверьте из сессии"
  fi

  sect "Откуда пакеты"
  info "всего установлено: $(pacman -Qq | wc -l)"
  info "точное совпадение версий; при равных версиях в двух репозиториях пакет считается дважды"
  repo_counts

  sect "Итог"
  if [[ $(uname -r) == *cachyos* ]]; then
    msg "загружено ядро CachyOS: $(uname -r)"
  else
    info "сейчас загружено $(uname -r); после перезагрузки будет $KERNEL"
  fi
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
    warn "snapper не настроен или нужен sudo — apply попросит подтверждение без снапшота"
  fi
  info "свободно на /var: $(df -Ph /var 2>/dev/null | awk 'NR==2{print $4}')"

  sect "План apply"
  cat <<EOF
  1. снапшот snapper и бэкап /etc/pacman.conf -> $BACKUP_ROOT
  2. IgnorePkg: ${want:-...}
  3. $([[ -n $(grep -E '^\[cachyos' "$PACMAN_CONF") ]] && echo 'репозитории CachyOS уже есть — только нормализация' || echo 'официальный установщик репозиториев CachyOS')
  4. Architecture = $(arch_value "$level"), приоритет: $PRIORITY
  5. $([[ $NO_MIRRORS == 1 ]] && echo 'зеркала: пропуск' || echo 'ранжирование зеркал cachyos-rate-mirrors')
  6. omarchy update
  7. $([[ $NO_KERNEL == 1 ]] && echo 'ядро: пропуск' || echo "ядро $KERNEL -> дефолт")
  8. verify
EOF
  say ""
  info "ничего не изменено (это check). Для перехода: $0 (apply по умолчанию)"
}

apply_on_error() {
  local rc=$? line=${1:-?}
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
    sudo -v || die "без sudo переход невозможен"
    start_sudo_keepalive
    trap 'stop_sudo_keepalive; stop_progress' EXIT
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
    cmd_verify || true
  fi

  sect "Готово"
  if (( DRY )); then
    msg "dry-run завершён: изменения не вносились"
    return 0
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
  confirm "Убрать репозитории CachyOS и вернуть штатное ядро?" || exit 0

  local bk=$BACKUP_ROOT/pre-conversion
  [[ -f $bk/pacman.conf ]] || die "нет эталонного бэкапа $bk/pacman.conf — откат делайте снапшотом"

  (( DRY )) || sudo -v

  # Сначала ядро: нельзя удалять пакет, на котором система работает.
  if (( ! NO_KERNEL )); then
    if pkg_installed linux-omarchy; then
      info "возвращаю дефолт на linux-omarchy"
      if (( ! DRY )); then
        # Как в apply: не полагаемся на tty/pkexec, root-путь предсказуем.
        as_root /usr/bin/omarchy-kernel set linux-omarchy || warn "omarchy kernel set не сработал"
        have omarchy-state && omarchy-state set reboot-required 2>/dev/null || true
      fi
    else
      warn "linux-omarchy не установлен — пропускаю смену дефолта"
    fi
  fi

  if (( DRY )); then
    info "[dry-run] восстановить $bk/pacman.conf"
  else
    as_root install -m 0644 -o root -g root "$bk/pacman.conf" "$PACMAN_CONF"
    as_root cp -a "$bk/pacman.conf" "$BACKUP_ROOT/pacman.conf.reverted.$(date +%s)"
    msg "pacman.conf восстановлен (репозитории CachyOS и пины убраны)"
  fi

  if pkg_installed "$KERNEL"; then
    if [[ $(uname -r) == *cachyos* ]]; then
      warn "сейчас загружено CachyOS-ядро; после перезагрузки запустите revert ещё раз, чтобы удалить $KERNEL"
    else
      confirm "Удалить пакеты ядра $KERNEL?" && {
        (( DRY )) || as_root pacman -Rns --noconfirm "$KERNEL" "${KERNEL}-headers" 2>/dev/null || true
      }
    fi
  fi

  info "пакеты, собранные CachyOS, останутся до следующего обновления из Arch"
  info "точный откат: меню Limine → Snapshots → снапшот #${SNAP_ID:-<номер>}, либо"
  info "  sudo snapper --ambit classic -c root rollback <N>"
  msg "готово"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case $CMD in
    check)  cmd_check ;;
    apply)  cmd_apply ;;
    verify) cmd_verify ;;
    status) cmd_status ;;
    revert) cmd_revert ;;
  esac
fi
