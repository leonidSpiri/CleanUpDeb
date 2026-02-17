#!/usr/bin/env bash
#
# cleanup.sh — лёгкая утилита очистки системы для Debian 13 (Trixie)
# Автор: GitHub Copilot
# Дата:  2026-02-17
#
# Возможности:
#   • Поиск крупных файлов (порог настраивается)
#   • Очистка системного и пользовательского кеша
#   • Удаление временных файлов
#   • Очистка apt-кеша, старых ядер, журналов
#   • Режим dry-run (по умолчанию — только отчёт)
#
# Использование:
#   sudo ./cleanup.sh              — отчёт без удаления (dry-run)
#   sudo ./cleanup.sh --apply      — реальная очистка
#   sudo ./cleanup.sh --help       — справка
#

set -euo pipefail

# ─── Цвета ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── Настройки по умолчанию ───────────────────────────────
DRY_RUN=true
BIG_FILE_THRESHOLD="100M"       # порог «крупного» файла
JOURNAL_MAX_AGE="7d"            # хранить журналы не старше 7 дней
SEARCH_DIR="/"                  # где искать крупные файлы
LOG_FILE="/tmp/cleanup_$(date +%Y%m%d_%H%M%S).log"
TOTAL_FREED=0

# ─── Функции-помощники ────────────────────────────────────

usage() {
    cat <<EOF
${BOLD}cleanup.sh${NC} — утилита очистки системы для Debian 13

${BOLD}Использование:${NC}
  sudo $0 [ОПЦИИ]

${BOLD}Опции:${NC}
  --apply              Выполнить реальную очистку (без этого флага — только отчёт)
  --threshold РАЗМЕР   Порог крупного файла, напр. 50M, 1G (по умолчанию: ${BIG_FILE_THRESHOLD})
  --search-dir ПУТЬ    Каталог для поиска крупных файлов (по умолчанию: /)
  --journal-age СРОК   Максимальный возраст журналов, напр. 3d, 2w (по умолчанию: ${JOURNAL_MAX_AGE})
  -h, --help           Показать эту справку

${BOLD}Примеры:${NC}
  sudo $0                          # только отчёт
  sudo $0 --apply                  # очистка с настройками по умолчанию
  sudo $0 --threshold 500M --apply # очистка файлов > 500 МБ
EOF
    exit 0
}

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

header() {
    echo ""
    log "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${BOLD}  $1${NC}"
    log "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Возвращает размер каталога/пути в байтах
dir_size_bytes() {
    du -sb "$1" 2>/dev/null | awk '{print $1}' || echo 0
}

# Человекочитаемый размер
human_size() {
    numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "${1} B"
}

# Подсчёт освобождённого места
calc_freed() {
    local before=$1 after=$2
    local freed=$((before - after))
    if (( freed < 0 )); then freed=0; fi
    TOTAL_FREED=$((TOTAL_FREED + freed))
    log "  ${GREEN}↳ Освобождено: $(human_size $freed)${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}✗ Эту утилиту необходимо запускать с правами root (sudo).${NC}"
        exit 1
    fi
}

# ─── Парсинг аргументов ───────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)
            DRY_RUN=false
            shift ;;
        --threshold)
            BIG_FILE_THRESHOLD="$2"
            shift 2 ;;
        --search-dir)
            SEARCH_DIR="$2"
            shift 2 ;;
        --journal-age)
            JOURNAL_MAX_AGE="$2"
            shift 2 ;;
        -h|--help)
            usage ;;
        *)
            echo -e "${RED}Неизвестная опция: $1${NC}"
            usage ;;
    esac
done

check_root

# ─── Начало работы ────────────────────────────────────────

header "🧹 Утилита очистки системы — Debian 13"
log "  Дата запуска : $(date '+%Y-%m-%d %H:%M:%S')"
log "  Режим        : $( $DRY_RUN && echo "${YELLOW}ОТЧЁТ (dry-run)${NC}" || echo "${RED}ОЧИСТКА (apply)${NC}" )"
log "  Порог файлов : ${BIG_FILE_THRESHOLD}"
log "  Лог          : ${LOG_FILE}"

DISK_BEFORE=$(df / --output=used -B1 | tail -1 | tr -d ' ')

# ═══════════════════════════════════════════════════════════
# 1. ПОИСК КРУПНЫХ ФАЙЛОВ
# ═══════════════════════════════════════════════════════════
header "1️⃣  Поиск крупных файлов (≥ ${BIG_FILE_THRESHOLD})"

log "  Поиск в ${SEARCH_DIR} (исключая /proc, /sys, /dev, /run)..."

BIG_FILES=$(find "$SEARCH_DIR" \
    -xdev \
    -path /proc -prune -o \
    -path /sys -prune -o \
    -path /dev -prune -o \
    -path /run -prune -o \
    -type f -size "+${BIG_FILE_THRESHOLD}" -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | head -30) || true

if [[ -n "$BIG_FILES" ]]; then
    log ""
    log "  ${BOLD}Топ крупных файлов:${NC}"
    log "  ─────────────────────────────────────────────────"
    while IFS=$'\t' read -r size path; do
        log "  $(human_size "$size")\t${path}"
    done <<< "$BIG_FILES"
    log ""
    log "  ${YELLOW}ℹ Крупные файлы не удаляются автоматически — проверьте вручную.${NC}"
else
    log "  ${GREEN}✓ Крупных файлов не найдено.${NC}"
fi

# ═══════════════════════════════════════════════════════════
# 2. ОЧИСТКА APT-КЕША
# ═══════════════════════════════════════════════════════════
header "2️⃣  Очистка APT-кеша"

APT_CACHE="/var/cache/apt/archives"
if [[ -d "$APT_CACHE" ]]; then
    size_before=$(dir_size_bytes "$APT_CACHE")
    log "  Текущий размер: $(human_size $size_before)"

    if ! $DRY_RUN; then
        apt-get clean -y 2>/dev/null
        apt-get autoclean -y 2>/dev/null
        size_after=$(dir_size_bytes "$APT_CACHE")
        calc_freed "$size_before" "$size_after"
    else
        log "  ${YELLOW}↳ [dry-run] apt-get clean / autoclean${NC}"
    fi
else
    log "  ${GREEN}✓ Каталог APT-кеша не найден.${NC}"
fi

# ═══════════════════════════════════════════════════════════
# 3. УДАЛЕНИЕ НЕИСПОЛЬЗУЕМЫХ ПАКЕТОВ
# ═══════════════════════════════════════════════════════════
header "3️⃣  Удаление неиспользуемых пакетов (autoremove)"

ORPHANS=$(apt-get --dry-run autoremove 2>/dev/null | grep -c "^Remv" || true)
log "  Пакетов к удалению: ${ORPHANS}"

if ! $DRY_RUN && (( ORPHANS > 0 )); then
    size_before=$(df / --output=used -B1 | tail -1 | tr -d ' ')
    apt-get autoremove -y --purge 2>/dev/null
    size_after=$(df / --output=used -B1 | tail -1 | tr -d ' ')
    calc_freed "$size_before" "$size_after"
else
    log "  ${YELLOW}↳ [dry-run] apt-get autoremove --purge${NC}"
fi

# ═══════════════════════════════════════════════════════════
# 4. ОЧИСТКА ВРЕМЕННЫХ ФАЙЛОВ
# ═══════════════════════════════════════════════════════════
header "4️⃣  Очистка временных файлов"

TMP_DIRS=(/tmp /var/tmp)

for dir in "${TMP_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        # Файлы старше 7 дней
        old_count=$(find "$dir" -mindepth 1 -mtime +7 -type f 2>/dev/null | wc -l)
        old_size=$(find "$dir" -mindepth 1 -mtime +7 -type f -printf '%s\n' 2>/dev/null \
                   | awk '{s+=$1} END {print s+0}')
        log "  ${dir}: ${old_count} файлов старше 7 дней ($(human_size "$old_size"))"

        if ! $DRY_RUN && (( old_count > 0 )); then
            find "$dir" -mindepth 1 -mtime +7 -type f -delete 2>/dev/null || true
            find "$dir" -mindepth 1 -mtime +7 -type d -empty -delete 2>/dev/null || true
            TOTAL_FREED=$((TOTAL_FREED + old_size))
            log "  ${GREEN}↳ Удалено.${NC}"
        fi
    fi
done

# ═══════════════════════════════════════════════════════════
# 5. ОЧИСТКА ПОЛЬЗОВАТЕЛЬСКОГО КЕША
# ═══════════════════════════════════════════════════════════
header "5️⃣  Очистка пользовательского кеша (~/.cache)"

for user_home in /home/* /root; do
    [[ -d "$user_home/.cache" ]] || continue
    user=$(basename "$user_home")
    cache_size=$(dir_size_bytes "$user_home/.cache")

    # Пропускаем если кеш меньше 10 МБ
    if (( cache_size < 10485760 )); then
        continue
    fi

    log "  ${user}: $(human_size $cache_size)"

    if ! $DRY_RUN; then
        # Удаляем содержимое кеша старше 30 дней (безопасно)
        old_size=$(find "$user_home/.cache" -mindepth 1 -mtime +30 -type f -printf '%s\n' 2>/dev/null \
                   | awk '{s+=$1} END {print s+0}')
        find "$user_home/.cache" -mindepth 1 -mtime +30 -type f -delete 2>/dev/null || true
        find "$user_home/.cache" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        TOTAL_FREED=$((TOTAL_FREED + old_size))
        log "  ${GREEN}↳ Удалены файлы кеша старше 30 дней.${NC}"
    fi
done

# ═══════════════════════════════════════════════════════════
# 6. ОЧИСТКА ЖУРНАЛОВ SYSTEMD
# ═══════════════════════════════════════════════════════════
header "6️⃣  Очистка журналов systemd (старше ${JOURNAL_MAX_AGE})"

if command -v journalctl &>/dev/null; then
    journal_size=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+\s*[KMGT]i?B' || echo "?")
    log "  Текущий размер журналов: ${journal_size}"

    if ! $DRY_RUN; then
        size_before=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo 0)
        journalctl --vacuum-time="${JOURNAL_MAX_AGE}" 2>/dev/null
        size_after=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo 0)
        log "  ${GREEN}↳ Журналы очищены.${NC}"
    else
        log "  ${YELLOW}↳ [dry-run] journalctl --vacuum-time=${JOURNAL_MAX_AGE}${NC}"
    fi
else
    log "  ${YELLOW}ℹ journalctl не найден.${NC}"
fi

# ═══════════════════════════════════════════════════════════
# 7. ОЧИСТКА СТАРЫХ ЛОГОВ
# ═══════════════════════════════════════════════════════════
header "7️⃣  Очистка архивных логов (/var/log/*.gz, *.old)"

old_logs=$(find /var/log -type f \( -name "*.gz" -o -name "*.old" -o -name "*.1" \) 2>/dev/null)
old_logs_size=$(echo "$old_logs" | xargs -r du -cb 2>/dev/null | tail -1 | awk '{print $1}' || echo 0)
old_logs_count=$(echo "$old_logs" | grep -c '.' || true)

log "  Найдено архивных логов: ${old_logs_count} ($(human_size "$old_logs_size"))"

if ! $DRY_RUN && (( old_logs_count > 0 )); then
    find /var/log -type f \( -name "*.gz" -o -name "*.old" -o -name "*.1" \) -delete 2>/dev/null || true
    TOTAL_FREED=$((TOTAL_FREED + old_logs_size))
    log "  ${GREEN}↳ Удалено.${NC}"
else
    log "  ${YELLOW}↳ [dry-run] Удаление архивных логов${NC}"
fi

# ═══════════════════════════════════════════════════════════
# 8. ОЧИСТКА THUMBNAIL-КЕША
# ═══════════════════════════════════════════════════════════
header "8️⃣  Очистка миниатюр (thumbnails)"

for user_home in /home/* /root; do
    thumb_dir="$user_home/.cache/thumbnails"
    [[ -d "$thumb_dir" ]] || continue

    user=$(basename "$user_home")
    thumb_size=$(dir_size_bytes "$thumb_dir")
    log "  ${user}: $(human_size $thumb_size)"

    if ! $DRY_RUN && (( thumb_size > 0 )); then
        rm -rf "${thumb_dir:?}"/*
        TOTAL_FREED=$((TOTAL_FREED + thumb_size))
        log "  ${GREEN}↳ Миниатюры удалены.${NC}"
    fi
done

# ═══════════════════════════════════════════════════════════
# 9. ОЧИСТКА МУСОРНОЙ КОРЗИНЫ
# ═══════════════════════════════════════════════════════════
header "9️⃣  Очистка корзины (Trash)"

for user_home in /home/* /root; do
    trash_dir="$user_home/.local/share/Trash"
    [[ -d "$trash_dir" ]] || continue

    user=$(basename "$user_home")
    trash_size=$(dir_size_bytes "$trash_dir")

    if (( trash_size > 0 )); then
        log "  ${user}: $(human_size $trash_size)"

        if ! $DRY_RUN; then
            rm -rf "${trash_dir:?}"/{files,info}/* 2>/dev/null || true
            TOTAL_FREED=$((TOTAL_FREED + trash_size))
            log "  ${GREEN}↳ Корзина очищена.${NC}"
        fi
    fi
done

# ═══════════════════════════════════════════════════════════
# ИТОГОВЫЙ ОТЧЁТ
# ═══════════════════════════════════════════════════════════
DISK_AFTER=$(df / --output=used -B1 | tail -1 | tr -d ' ')
ACTUAL_FREED=$((DISK_BEFORE - DISK_AFTER))
if (( ACTUAL_FREED < 0 )); then ACTUAL_FREED=0; fi

header "📊 Итоговый отчёт"

log ""
log "  Диск (/) до очистки  : $(human_size "$DISK_BEFORE") занято"
log "  Диск (/) после       : $(human_size "$DISK_AFTER") занято"
log ""

if $DRY_RUN; then
    log "  ${YELLOW}⚠  Режим отчёта — ничего не удалено.${NC}"
    log "  ${YELLOW}   Запустите с флагом ${BOLD}--apply${NC}${YELLOW} для реальной очистки.${NC}"
else
    log "  ${GREEN}✓ Фактически освобождено на диске: $(human_size "$ACTUAL_FREED")${NC}"
    log "  ${GREEN}  (расчётно по операциям: $(human_size "$TOTAL_FREED"))${NC}"
fi

log ""
log "  Полный лог сохранён: ${LOG_FILE}"
log ""

exit 0
