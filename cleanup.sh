#!/usr/bin/env bash
#
# cleanup.sh — утилита очистки системы для Debian/Ubuntu
# Версия: 2.0.0
# Автор: GitHub Copilot
# Дата:  2026-02-18
#
# Возможности:
#   • Интерактивное удаление крупных файлов (TUI меню)
#   • Анализ крупных каталогов (du)
#   • Очистка Docker (локальный + Registry)
#   • Очистка кеша с исключениями
#   • Очистка apt-кеша, журналов, временных файлов
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

# ─── Исключения для очистки кеша ──────────────────────────
# Папки внутри ~/.cache, которые НЕ будут очищаться
CACHE_EXCLUDE_DIRS=(
    "JetBrains"
    "Google/chrome"
    "mozilla/firefox"
    "Code"
    "code-server"
    "JetBrains/RemoteDev"
)

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
    local msg="$1"
    echo -e "$msg"
    echo -e "$msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
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

# ─── Интерактивное меню для выбора файлов ─────────────────
# Функция для интерактивного выбора файлов для удаления
interactive_file_menu() {
    local -n files_array=$1  # массив файлов (size<TAB>path)
    local -a selected_states  # массив состояний (0 - не выбран, 1 - выбран)
    local current_pos=0
    local total_files=${#files_array[@]}
    
    # Инициализация массива состояний
    for ((i=0; i<total_files; i++)); do
        selected_states[$i]=0
    done
    
    # ANSI коды
    local CURSOR_UP='\033[A'
    local CURSOR_DOWN='\033[B'
    local CLEAR_LINE='\033[2K'
    local SAVE_CURSOR='\033[s'
    local RESTORE_CURSOR='\033[u'
    
    # Функция отрисовки меню
    draw_menu() {
        echo -e "\r${CLEAR_LINE}  ${BOLD}Выберите файлы для удаления (↑↓ — навигация, пробел — выбор, Enter — подтвердить, q — отмена):${NC}"
        echo -e "  ─────────────────────────────────────────────────"
        
        for ((i=0; i<total_files; i++)); do
            local file_info="${files_array[$i]}"
            IFS=$'\t' read -r size path <<< "$file_info"
            local checkbox="( )"
            if [[ ${selected_states[$i]} -eq 1 ]]; then
                checkbox="(*)"
            fi
            
            local marker=" "
            if [[ $i -eq $current_pos ]]; then
                marker=">"
            fi
            
            printf "  %s %s %-10s %s\n" "$marker" "$checkbox" "$(human_size "$size")" "$path"
        done
    }
    
    # Сохранение позиции курсора перед началом
    echo -e "${SAVE_CURSOR}"
    
    # Основной цикл
    while true; do
        # Очистка области меню
        for ((i=0; i<=total_files+2; i++)); do
            echo -e "\r${CLEAR_LINE}"
        done
        
        # Возврат к началу меню
        for ((i=0; i<=total_files+2; i++)); do
            echo -ne "${CURSOR_UP}"
        done
        
        draw_menu
        
        # Чтение одного символа
        IFS= read -rsn1 key
        
        # Обработка escape-последовательностей для стрелок
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 key
            case "$key" in
                '[A') # Стрелка вверх
                    if ((current_pos > 0)); then
                        current_pos=$((current_pos - 1))
                    fi
                    ;;
                '[B') # Стрелка вниз
                    if ((current_pos < total_files - 1)); then
                        current_pos=$((current_pos + 1))
                    fi
                    ;;
            esac
        elif [[ "$key" == " " ]]; then
            # Пробел - переключить выбор
            if [[ ${selected_states[$current_pos]} -eq 0 ]]; then
                selected_states[$current_pos]=1
            else
                selected_states[$current_pos]=0
            fi
        elif [[ "$key" == "" ]]; then
            # Enter - подтвердить
            break
        elif [[ "$key" == "q" ]] || [[ "$key" == "Q" ]]; then
            # Отмена
            echo ""
            echo -e "  ${YELLOW}ℹ Удаление отменено пользователем.${NC}"
            return 1
        fi
    done
    
    # Переместить курсор вниз после меню
    for ((i=0; i<=total_files+2; i++)); do
        echo ""
    done
    
    # Собрать выбранные файлы
    local selected_files=()
    for ((i=0; i<total_files; i++)); do
        if [[ ${selected_states[$i]} -eq 1 ]]; then
            selected_files+=("${files_array[$i]}")
        fi
    done
    
    if [[ ${#selected_files[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}ℹ Файлы не выбраны.${NC}"
        return 1
    fi
    
    # Показать выбранные файлы
    echo -e "  ${BOLD}Выбрано файлов для удаления: ${#selected_files[@]}${NC}"
    echo "  ─────────────────────────────────────────────────"
    for file_info in "${selected_files[@]}"; do
        IFS=$'\t' read -r size path <<< "$file_info"
        echo -e "    $(human_size "$size")\t${path}"
    done
    echo ""
    
    # Запрос подтверждения
    echo -ne "  ${RED}${BOLD}Вы уверены? Это действие нельзя отменить! (yes/no):${NC} "
    read -r confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo -e "  ${YELLOW}ℹ Удаление отменено.${NC}"
        return 1
    fi
    
    # Удаление файлов
    local deleted_count=0
    local deleted_size=0
    for file_info in "${selected_files[@]}"; do
        IFS=$'\t' read -r size path <<< "$file_info"
        
        if $DRY_RUN; then
            log "    ${YELLOW}[dry-run] Удаление: ${path}${NC}"
            deleted_count=$((deleted_count + 1))
            deleted_size=$((deleted_size + size))
        else
            if rm -f "$path" 2>/dev/null; then
                log "    ${GREEN}✓ Удалён: ${path}${NC}"
                deleted_count=$((deleted_count + 1))
                deleted_size=$((deleted_size + size))
            else
                log "    ${RED}✗ Ошибка удаления: ${path}${NC}"
            fi
        fi
    done
    
    echo ""
    if $DRY_RUN; then
        log "  ${YELLOW}[dry-run] Файлов к удалению: ${deleted_count} ($(human_size $deleted_size))${NC}"
    else
        TOTAL_FREED=$((TOTAL_FREED + deleted_size))
        log "  ${GREEN}✓ Удалено файлов: ${deleted_count} ($(human_size $deleted_size))${NC}"
    fi
    
    return 0
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

# --- Анализ крупных каталогов ---
log ""
log "  ${BOLD}Крупнейшие каталоги (анализ с помощью du):${NC}"
log "  ─────────────────────────────────────────────────"

# Анализ верхнего уровня от корня
if [[ "$SEARCH_DIR" == "/" ]]; then
    log "  ${CYAN}Верхний уровень (/)${NC}"
    du -h --max-depth=1 / 2>/dev/null | sort -rh | head -15 | while read -r size dir; do
        log "    ${size}\t${dir}"
    done
    
    # Анализ /var если существует
    if [[ -d /var ]]; then
        log ""
        log "  ${CYAN}Детализация /var${NC}"
        du -h --max-depth=1 /var 2>/dev/null | sort -rh | head -15 | while read -r size dir; do
            log "    ${size}\t${dir}"
        done
    fi
    
    # Анализ /home если существует
    if [[ -d /home ]]; then
        log ""
        log "  ${CYAN}Детализация /home${NC}"
        du -h --max-depth=1 /home 2>/dev/null | sort -rh | head -15 | while read -r size dir; do
            log "    ${size}\t${dir}"
        done
    fi
else
    # Если ищем в конкретном каталоге
    du -h --max-depth=1 "$SEARCH_DIR" 2>/dev/null | sort -rh | head -15 | while read -r size dir; do
        log "    ${size}\t${dir}"
    done
fi

log ""

# --- Поиск крупных файлов ---
log "  ${BOLD}Крупнейшие файлы (≥ ${BIG_FILE_THRESHOLD}):${NC}"
log "  Поиск в ${SEARCH_DIR} (исключая /proc, /sys, /dev, /run)..."
log ""

BIG_FILES=$(find "$SEARCH_DIR" \
    -xdev \
    -path /proc -prune -o \
    -path /sys -prune -o \
    -path /dev -prune -o \
    -path /run -prune -o \
    -type f -size "+${BIG_FILE_THRESHOLD}" -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | head -30) || true

if [[ -n "$BIG_FILES" ]]; then
    log "  ${BOLD}Топ крупных файлов:${NC}"
    log "  ─────────────────────────────────────────────────"
    while IFS=$'\t' read -r size path; do
        log "  $(human_size "$size")\t${path}"
    done <<< "$BIG_FILES"
    log ""
    
    # Интерактивное удаление в режиме apply
    if ! $DRY_RUN; then
        echo -ne "  ${BOLD}Хотите удалить некоторые из этих файлов? (y/n):${NC} "
        read -r do_interactive_delete
        
        if [[ "$do_interactive_delete" =~ ^[YyДд]$ ]]; then
            # Преобразуем BIG_FILES в массив для интерактивного меню
            declare -a files_array
            while IFS=$'\t' read -r size path; do
                files_array+=("${size}"$'\t'"${path}")
            done <<< "$BIG_FILES"
            
            interactive_file_menu files_array
        else
            log "  ${YELLOW}ℹ Крупные файлы не удаляются автоматически — проверьте вручную.${NC}"
        fi
    else
        log "  ${YELLOW}ℹ Крупные файлы не удаляются автоматически — проверьте вручную.${NC}"
        log "  ${YELLOW}  В режиме --apply будет доступно интерактивное удаление.${NC}"
    fi
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

# Показать исключения
if [[ ${#CACHE_EXCLUDE_DIRS[@]} -gt 0 ]]; then
    log "  ${BOLD}Исключённые папки:${NC} ${CACHE_EXCLUDE_DIRS[*]}"
    log ""
fi

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
        # Построить аргументы исключения для find
        exclude_args=()
        for exc_dir in "${CACHE_EXCLUDE_DIRS[@]}"; do
            exclude_args+=(-not -path "*/${exc_dir}/*")
        done
        
        # Удаляем содержимое кеша старше 30 дней (безопасно) с исключениями
        old_size=$(find "$user_home/.cache" -mindepth 1 -mtime +30 -type f "${exclude_args[@]}" -printf '%s\n' 2>/dev/null \
                   | awk '{s+=$1} END {print s+0}')
        find "$user_home/.cache" -mindepth 1 -mtime +30 -type f "${exclude_args[@]}" -delete 2>/dev/null || true
        find "$user_home/.cache" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        TOTAL_FREED=$((TOTAL_FREED + old_size))
        log "  ${GREEN}↳ Удалены файлы кеша старше 30 дней (с исключениями).${NC}"
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
# 10. ОЧИСТКА ЛОКАЛЬНОГО DOCKER
# ═══════════════════════════════════════════════════════════
header "🔟 Очистка локального Docker"

# Проверка наличия docker
if ! command -v docker &>/dev/null; then
    log "  ${YELLOW}⚠ Docker не установлен. Секция пропущена.${NC}"
else
    log "  Проверка использования Docker..."
    log ""
    
    # Показать текущее использование
    if docker system df &>/dev/null; then
        log "  ${BOLD}Использование Docker до очистки:${NC}"
        log "  ─────────────────────────────────────────────────"
        docker system df 2>/dev/null | while IFS= read -r line; do
            log "  ${line}"
        done
        log ""
        
        if ! $DRY_RUN; then
            echo -ne "  ${BOLD}Выполнить очистку Docker? (y/n):${NC} "
            read -r do_docker_cleanup
            
            if [[ "$do_docker_cleanup" =~ ^[YyДд]$ ]]; then
                log "  Выполнение очистки Docker..."
                
                # Выполняем очистку
                docker container prune -f &>/dev/null && log "  ${GREEN}✓ Остановленные контейнеры удалены${NC}"
                docker image prune -a -f &>/dev/null && log "  ${GREEN}✓ Неиспользуемые образы удалены${NC}"
                docker volume prune -f &>/dev/null && log "  ${GREEN}✓ Неиспользуемые тома удалены${NC}"
                docker network prune -f &>/dev/null && log "  ${GREEN}✓ Неиспользуемые сети удалены${NC}"
                docker builder prune -a -f &>/dev/null && log "  ${GREEN}✓ Build cache очищен${NC}"
                
                log ""
                log "  ${BOLD}Использование Docker после очистки:${NC}"
                log "  ─────────────────────────────────────────────────"
                docker system df 2>/dev/null | while IFS= read -r line; do
                    log "  ${line}"
                done
            else
                log "  ${YELLOW}ℹ Очистка Docker пропущена пользователем.${NC}"
            fi
        else
            log "  ${YELLOW}[dry-run] В режиме --apply будут выполнены команды:${NC}"
            log "  ${YELLOW}  • docker container prune -f${NC}"
            log "  ${YELLOW}  • docker image prune -a -f${NC}"
            log "  ${YELLOW}  • docker volume prune -f${NC}"
            log "  ${YELLOW}  • docker network prune -f${NC}"
            log "  ${YELLOW}  • docker builder prune -a -f${NC}"
        fi
    else
        log "  ${YELLOW}⚠ Не удалось получить информацию о Docker.${NC}"
    fi
fi

# ═══════════════════════════════════════════════════════════
# 11. ОЧИСТКА DOCKER REGISTRY V2
# ═══════════════════════════════════════════════════════════
header "1️⃣1️⃣ Очистка Docker Registry V2"

# Проверка наличия curl
if ! command -v curl &>/dev/null; then
    log "  ${YELLOW}⚠ curl не установлен. Секция пропущена.${NC}"
    log "  ${YELLOW}  Установите: apt-get install curl${NC}"
else
    # Спросить, хочет ли пользователь выполнить очистку реестра
    echo -n "  Хотите выполнить очистку Docker Registry? (y/n): "
    read -r do_registry_cleanup
    
    if [[ "$do_registry_cleanup" =~ ^[YyДд]$ ]]; then
        # Запросить URL реестра
        echo -n "  Введите URL реестра (например, https://registry.example.com): "
        read -r REGISTRY_URL
        
        # Проверка корректности URL
        if [[ ! "$REGISTRY_URL" =~ ^https?:// ]]; then
            log "  ${RED}✗ Неверный формат URL. Должен начинаться с http:// или https://${NC}"
        else
            # Запросить имя пользователя
            echo -n "  Введите имя пользователя: "
            read -r REGISTRY_USER
            
            # Запросить пароль (без отображения)
            echo -n "  Введите пароль: "
            read -s REGISTRY_PASS
            echo ""
            
            # Проверка доступности реестра
            log "  Проверка доступности реестра..."
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                -u "${REGISTRY_USER}:${REGISTRY_PASS}" \
                "${REGISTRY_URL}/v2/" 2>/dev/null || echo "000")
            
            if [[ "$HTTP_CODE" != "200" ]]; then
                if [[ "$HTTP_CODE" == "401" ]]; then
                    log "  ${RED}✗ Ошибка аутентификации. Проверьте имя пользователя и пароль.${NC}"
                elif [[ "$HTTP_CODE" == "000" ]]; then
                    log "  ${RED}✗ Реестр недоступен. Проверьте URL и сетевое соединение.${NC}"
                else
                    log "  ${RED}✗ Реестр вернул код ${HTTP_CODE}. Ожидался код 200.${NC}"
                fi
            else
                log "  ${GREEN}✓ Подключение к реестру успешно.${NC}"
                
                # Функция для получения всех репозиториев с пагинацией
                get_all_repositories() {
                    local url="${REGISTRY_URL}/v2/_catalog"
                    local all_repos=""
                    local last=""
                    local PAGE_SIZE=100
                    
                    while true; do
                        local request_url="$url"
                        if [[ -n "$last" ]]; then
                            request_url="${url}?n=${PAGE_SIZE}&last=${last}"
                        else
                            request_url="${url}?n=${PAGE_SIZE}"
                        fi
                        
                        local response=$(curl -s -u "${REGISTRY_USER}:${REGISTRY_PASS}" "$request_url" 2>/dev/null)
                        
                        # Парсинг JSON (попробуем jq, если нет — используем grep/sed)
                        if command -v jq &>/dev/null; then
                            local repos=$(echo "$response" | jq -r '.repositories[]?' 2>/dev/null || true)
                        else
                            # Парсинг без jq
                            local repos=$(echo "$response" | grep -oP '(?<="repositories":\[)[^\]]*' | tr -d '"' | tr ',' '\n' | grep -v '^$' || true)
                        fi
                        
                        if [[ -z "$repos" ]]; then
                            break
                        fi
                        
                        all_repos="${all_repos}${repos}"$'\n'
                        
                        # Получить последний элемент для пагинации
                        last=$(echo "$repos" | tail -1)
                        
                        # Проверить, есть ли ещё страницы (если вернулось меньше PAGE_SIZE, то это последняя страница)
                        local count=$(echo "$repos" | wc -l)
                        if (( count < PAGE_SIZE )); then
                            break
                        fi
                    done
                    
                    echo "$all_repos" | grep -v '^$'
                }
                
                # Получить список всех репозиториев
                log "  Получение списка образов..."
                REPOSITORIES=$(get_all_repositories)
                
                if [[ -z "$REPOSITORIES" ]]; then
                    log "  ${YELLOW}ℹ Репозитории не найдены или реестр пуст.${NC}"
                else
                    REPO_COUNT=$(echo "$REPOSITORIES" | wc -l)
                    log "  ${BOLD}Найдено репозиториев: ${REPO_COUNT}${NC}"
                    log ""
                    
                    # Показать список репозиториев
                    log "  ${BOLD}Список образов:${NC}"
                    log "  ─────────────────────────────────────────────────"
                    idx=1
                    while IFS= read -r repo; do
                        log "  ${idx}. ${repo}"
                        idx=$((idx + 1))
                    done <<< "$REPOSITORIES"
                    log ""
                    
                    # Запросить выбор
                    echo -n "  Удалить ВСЕ образы или выбрать конкретные? (all/select/skip): "
                    read -r selection_mode
                    
                    SELECTED_REPOS=""
                    
                    if [[ "$selection_mode" =~ ^[Aa][Ll][Ll]$ ]]; then
                        SELECTED_REPOS="$REPOSITORIES"
                        log "  ${YELLOW}⚠ Выбраны ВСЕ образы для удаления.${NC}"
                    elif [[ "$selection_mode" =~ ^[Ss][Ee][Ll][Ee][Cc][Tt]$ ]]; then
                        echo -n "  Введите номера образов (например, 1,3,5 или 1-5): "
                        read -r selection
                        
                        # Парсинг выбора
                        SELECTED_REPOS=""
                        IFS=',' read -ra PARTS <<< "$selection"
                        for part in "${PARTS[@]}"; do
                            part=$(echo "$part" | xargs) # убрать пробелы
                            if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                                # Диапазон
                                start="${BASH_REMATCH[1]}"
                                end="${BASH_REMATCH[2]}"
                                for ((i=start; i<=end; i++)); do
                                    repo=$(echo "$REPOSITORIES" | sed -n "${i}p")
                                    if [[ -n "$repo" ]]; then
                                        SELECTED_REPOS="${SELECTED_REPOS}${repo}"$'\n'
                                    fi
                                done
                            elif [[ "$part" =~ ^[0-9]+$ ]]; then
                                # Одиночный номер
                                repo=$(echo "$REPOSITORIES" | sed -n "${part}p")
                                if [[ -n "$repo" ]]; then
                                    SELECTED_REPOS="${SELECTED_REPOS}${repo}"$'\n'
                                fi
                            fi
                        done
                        SELECTED_REPOS=$(echo "$SELECTED_REPOS" | grep -v '^$')
                        
                        if [[ -z "$SELECTED_REPOS" ]]; then
                            log "  ${YELLOW}ℹ Образы не выбраны.${NC}"
                        else
                            log "  ${BOLD}Выбрано образов: $(echo "$SELECTED_REPOS" | wc -l)${NC}"
                        fi
                    else
                        log "  ${YELLOW}ℹ Очистка реестра пропущена.${NC}"
                    fi
                    
                    # Если есть выбранные репозитории
                    if [[ -n "$SELECTED_REPOS" ]]; then
                        log ""
                        log "  ${BOLD}Образы для удаления:${NC}"
                        while IFS= read -r repo; do
                            log "    • ${repo}"
                        done <<< "$SELECTED_REPOS"
                        log ""
                        
                        # Подтверждение
                        echo -n "  ${RED}${BOLD}Вы уверены? Это действие нельзя отменить! (yes/no):${NC} "
                        read -r confirm
                        
                        if [[ "$confirm" == "yes" ]]; then
                            deleted_count=0
                            error_count=0
                            
                            while IFS= read -r repo; do
                                log "  Обработка: ${CYAN}${repo}${NC}"
                                
                                # Получить список тегов
                                tags_response=$(curl -s -u "${REGISTRY_USER}:${REGISTRY_PASS}" \
                                    "${REGISTRY_URL}/v2/${repo}/tags/list" 2>/dev/null)
                                
                                if command -v jq &>/dev/null; then
                                    tags=$(echo "$tags_response" | jq -r '.tags[]?' 2>/dev/null || true)
                                else
                                    tags=$(echo "$tags_response" | grep -oP '(?<="tags":\[)[^\]]*' | tr -d '"' | tr ',' '\n' | grep -v '^$' || true)
                                fi
                                
                                if [[ -z "$tags" ]]; then
                                    log "    ${YELLOW}⚠ Теги не найдены${NC}"
                                    continue
                                fi
                                
                                # Удалить каждый тег
                                while IFS= read -r tag; do
                                    [[ -z "$tag" ]] && continue
                                    
                                    # Получить digest манифеста
                                    digest=$(curl -s -I -u "${REGISTRY_USER}:${REGISTRY_PASS}" \
                                        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
                                        "${REGISTRY_URL}/v2/${repo}/manifests/${tag}" 2>/dev/null \
                                        | grep -i "Docker-Content-Digest:" | awk '{print $2}' | tr -d '\r')
                                    
                                    if [[ -z "$digest" ]]; then
                                        log "    ${YELLOW}⚠ ${tag}: не удалось получить digest${NC}"
                                        error_count=$((error_count + 1))
                                        continue
                                    fi
                                    
                                    if $DRY_RUN; then
                                        log "    ${YELLOW}[dry-run] ${tag} (${digest})${NC}"
                                        deleted_count=$((deleted_count + 1))
                                    else
                                        # Удалить манифест
                                        # DELETE возвращает 202 (Accepted) согласно спецификации, но некоторые реестры возвращают 200
                                        delete_code=$(curl -s -o /dev/null -w "%{http_code}" \
                                            -X DELETE \
                                            -u "${REGISTRY_USER}:${REGISTRY_PASS}" \
                                            "${REGISTRY_URL}/v2/${repo}/manifests/${digest}" 2>/dev/null)
                                        
                                        if [[ "$delete_code" == "202" ]] || [[ "$delete_code" == "200" ]]; then
                                            log "    ${GREEN}✓ ${tag} удалён${NC}"
                                            deleted_count=$((deleted_count + 1))
                                        else
                                            log "    ${RED}✗ ${tag}: ошибка удаления (код ${delete_code})${NC}"
                                            error_count=$((error_count + 1))
                                        fi
                                    fi
                                done <<< "$tags"
                                
                            done <<< "$SELECTED_REPOS"
                            
                            log ""
                            if $DRY_RUN; then
                                log "  ${YELLOW}[dry-run] Тегов для удаления: ${deleted_count}${NC}"
                            else
                                log "  ${GREEN}✓ Удалено тегов: ${deleted_count}${NC}"
                                if (( error_count > 0 )); then
                                    log "  ${YELLOW}⚠ Ошибок: ${error_count}${NC}"
                                fi
                                log ""
                                log "  ${YELLOW}ℹ Для освобождения места выполните garbage collection на реестре:${NC}"
                                log "  ${YELLOW}  docker exec <registry-container> bin/registry garbage-collect /etc/docker/registry/config.yml${NC}"
                            fi
                        else
                            log "  ${YELLOW}ℹ Удаление отменено пользователем.${NC}"
                        fi
                    fi
                fi
            fi
        fi
    else
        log "  ${YELLOW}ℹ Очистка Docker Registry пропущена пользователем.${NC}"
    fi
fi

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
    log "  ${YELLOW}   Запустите с флагом ${BOLD}--apply${YELLOW} для реальной очистки.${NC}"
else
    log "  ${GREEN}✓ Фактически освобождено на диске: $(human_size "$ACTUAL_FREED")${NC}"
    log "  ${GREEN}  (расчётно по операциям: $(human_size "$TOTAL_FREED"))${NC}"
fi

log ""
log "  Полный лог сохранён: ${LOG_FILE}"
log ""

exit 0
