#!/usr/bin/env bash

set -o pipefail

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
    printf 'Ошибка. Требуется Bash 4.3 или новее.\n' >&2
    exit 1
fi

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
readonly PROJECT_DIR
readonly DATA_DIR="$PROJECT_DIR/data/labfiles-3-26"

readonly CIRCUS_SUBJECT='Цирковое_Дело'
readonly RETAKES_SUBJECT='Пересдачеведение'
readonly GROUP_PATTERN='^[^[:space:][:cntrl:];/\\:*?"<>|]+$'
readonly LOGIN_PATTERN='[^[:space:][:cntrl:];]+'

error() {
    printf 'Ошибка. %s\n' "$*" >&2
    return 1
}

usage_error() {
    error "$* Подсказка: bash lab4.sh --help."
    return 2
}

validate_group_subject() {
    local group=$1 requested=${2//[[:blank:]_-]/}
    local circus=${CIRCUS_SUBJECT//_/}
    local -n selected_subject=$3
    if [[ ! $group =~ $GROUP_PATTERN || $group == . || $group == .. ]]; then
        usage_error 'Укажите имя группы, например A-06-23.'
        return 2
    fi
    case ${requested,,} in
        "${circus,,}") selected_subject=$CIRCUS_SUBJECT ;;
        "${RETAKES_SUBJECT,,}") selected_subject=$RETAKES_SUBJECT ;;
        *) usage_error "Выберите предмет «$CIRCUS_SUBJECT» или «$RETAKES_SUBJECT»." ;;
    esac
}

resolve_subject_dir() {
    local subject=$1
    local -n found_dir=$2
    if [[ ! -d $DATA_DIR ]]; then
        error "Не найден каталог данных «$DATA_DIR». Поместите labfiles-3-26 в папку data."
        return 1
    fi
    found_dir="$DATA_DIR/$subject"
    [[ -d $found_dir ]] || error "В «$DATA_DIR» не найден каталог предмета «$subject»."
}

read_data_lines() {
    local file=$1
    local -n output_lines=$2
    if [[ ! -f $file || ! -r $file ]]; then
        error "Файл «$file» отсутствует или недоступен для чтения."
        return 1
    fi
    mapfile -t output_lines < "$file" || { error "Не удалось прочитать «$file»."; return 1; }
    if ((${#output_lines[@]})); then
        output_lines[0]=${output_lines[0]#$'\xEF\xBB\xBF'}
    fi
}

load_roster() {
    local group=$1
    local -n output_roster=$2
    local file line index
    # Windows открывает файл даже при неверном регистре. Для поиска
    # попыток нужно точное имя группы, поэтому сверяем его со списком файлов.
    for file in "$DATA_DIR/students/groups/"*; do
        [[ ${file##*/} == "$group" ]] && break
    done
    if [[ ${file##*/} != "$group" ]]; then
        error "Группа «$group» не найдена. Проверьте имя файла и регистр букв."
        return 1
    fi
    local -a lines=()
    read_data_lines "$file" lines || return 1
    output_roster=()

    for index in "${!lines[@]}"; do
        line=${lines[$index]%$'\r'}
        [[ $line =~ ^[[:blank:]]*$ ]] && continue
        if [[ ! $line =~ ^$LOGIN_PATTERN$ ]]; then
            error "«$file», строка $((index + 1)): ожидался один логин."
            return 1
        fi
        output_roster[$line]=1
    done
}

valid_date() {
    local date=$1
    local year=$((10#${date:0:4})) month=$((10#${date:5:2})) day=$((10#${date:8:2}))
    local -a days_in_month=(0 31 28 31 30 31 30 31 31 30 31 30 31)
    ((year > 0 && month >= 1 && month <= 12 && day >= 1)) || return 1
    if ((month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))); then
        days_in_month[2]=29
    fi
    ((day <= days_in_month[month]))
}

attendance() {
    local group=$1 subject subject_dir
    validate_group_subject "$group" "$2" subject || return 2
    resolve_subject_dir "$subject" subject_dir || return 1

    local -A roster=() visits=()
    local -a lines=()
    local file="$subject_dir/$group-attendance"
    local index line login ones
    local pattern="^($LOGIN_PATTERN)[[:blank:]]+([01]+)$"
    load_roster "$group" roster || return 1
    read_data_lines "$file" lines || return 1

    for index in "${!lines[@]}"; do
        line=${lines[$index]%$'\r'}
        [[ $line =~ ^[[:blank:]]*$ ]] && continue
        if [[ ! $line =~ $pattern ]]; then
            error "«$file», строка $((index + 1)): ожидались логин и строка из 0 и 1."
            return 1
        fi
        login=${BASH_REMATCH[1]}
        [[ ${roster[$login]+found} ]] || continue
        if [[ ${visits[$login]+found} ]]; then
            error "«$file», строка $((index + 1)): повторная запись посещаемости для «$login»."
            return 1
        fi

        # Каждая единица обозначает одно посещённое занятие.
        ones=${BASH_REMATCH[2]//0/}
        visits[$login]=${#ones}
    done

    if ((${#roster[@]} == 0)); then
        printf 'Список группы «%s» пуст.\n' "$group"
        return 0
    fi

    printf 'Логин\tПосещено\n'
    for login in "${!roster[@]}"; do
        printf '%s\t%s\n' "$login" "${visits[$login]:-0}"
    done | LC_ALL=C sort -t $'\t' -k2,2nr -k1,1
}

failed_tests() {
    local group=$1 test=$3 subject subject_dir
    validate_group_subject "$group" "$2" subject || return 2
    if [[ ! $test =~ ^[1-4]$ ]]; then
        usage_error 'Номер теста должен быть от 1 до 4.'
        return 2
    fi
    resolve_subject_dir "$subject" subject_dir || return 1

    local -A roster=() status=()
    local -a lines=() rows=()
    local file="$subject_dir/tests/TEST-$test"
    local index line attempt_group login date grade
    local pattern="^($LOGIN_PATTERN);($LOGIN_PATTERN);([0-9]{4}-[0-9]{2}-[0-9]{2});[0-9]+;([2-5])[+-]*$"
    load_roster "$group" roster || return 1
    read_data_lines "$file" lines || return 1

    for index in "${!lines[@]}"; do
        line=${lines[$index]%$'\r'}
        [[ $line =~ ^[[:blank:]]*$ ]] && continue
        if [[ ! $line =~ $pattern ]]; then
            error "«$file», строка $((index + 1)): неверный формат попытки тестирования."
            return 1
        fi
        # Регулярное выражение выделяет цифру оценки без суффикса.
        attempt_group=${BASH_REMATCH[1]}
        login=${BASH_REMATCH[2]}
        date=${BASH_REMATCH[3]}
        grade=${BASH_REMATCH[4]}
        if [[ ! $attempt_group =~ $GROUP_PATTERN || $attempt_group == . || $attempt_group == .. ]] || ! valid_date "$date"; then
            error "«$file», строка $((index + 1)): неверная группа или календарная дата."
            return 1
        fi
        [[ $attempt_group == "$group" && ${roster[$login]+found} ]] || continue
        # После успешной попытки следующие оценки статус не меняют.
        [[ ${status[$login]} == 'Сдал' ]] && continue
        if ((grade >= 3)); then
            status[$login]='Сдал'
        else
            status[$login]='Не сдал'
        fi
    done

    for login in "${!roster[@]}"; do
        [[ ${status[$login]} == 'Сдал' ]] && continue
        rows+=("$login"$'\t'"${status[$login]:-Не проходил}")
    done

    if ((${#rows[@]} == 0)); then
        printf 'Студентов без успешной попытки не найдено.\n'
        return 0
    fi
    printf 'Логин\tСтатус\n'
    printf '%s\n' "${rows[@]}" | LC_ALL=C sort -t $'\t' -k1,1
}

show_help() {
    cat <<'HELP'
Анализ посещаемости и результатов тестирования студентов

  bash lab4.sh                              Интерактивное меню
  bash lab4.sh attendance ГРУППА ПРЕДМЕТ     Рейтинг посещаемости
  bash lab4.sh failed ГРУППА ПРЕДМЕТ НОМЕР   Студенты, не сдавшие тест
  bash lab4.sh --help                       Эта справка

Предметы: Пересдачеведение, Цирковое_Дело. Номера тестов: 1–4.
Данные: data/labfiles-3-26 рядом с lab4.sh.
HELP
}

run_command() {
    local command=$1
    shift
    case $command in
        attendance)
            if (($# != 2)); then usage_error 'Нужны группа и предмет.'; return 2; fi
            attendance "$1" "$2"
            ;;
        failed)
            if (($# != 3)); then usage_error 'Нужны группа, предмет и номер теста.'; return 2; fi
            failed_tests "$1" "$2" "$3"
            ;;
        --help)
            if (($# != 0)); then usage_error 'У справки нет дополнительных параметров.'; return 2; fi
            show_help
            ;;
        *) usage_error "Неизвестная команда «$command»." ;;
    esac
}

read_menu_input() {
    local -n input=$1
    read -r input || return 1
    # При чтении из файла Windows после перевода строки остаётся символ CR.
    input=${input%$'\r'}
}

interactive_menu() {
    local choice group subject test answer
    while true; do
        cat <<'MENU'
========================================
     АНАЛИЗ УСПЕВАЕМОСТИ СТУДЕНТОВ
========================================

1. Рейтинг посещаемости
2. Студенты, не сдавшие тест

0. Выход

MENU
        printf 'Выберите действие: '
        read_menu_input choice || return 0
        case $choice in
            0) return 0 ;;
            1|2)
                printf 'Группа (например, A-06-23): '
                read_menu_input group || return 0
                printf 'Предмет (%s или %s): ' "$RETAKES_SUBJECT" "$CIRCUS_SUBJECT"
                read_menu_input subject || return 0
                if [[ $choice == 1 ]]; then
                    run_command attendance "$group" "$subject"
                else
                    printf 'Номер теста (1–4): '
                    read_menu_input test || return 0
                    run_command failed "$group" "$subject" "$test"
                fi
                ;;
            *) error 'Выберите 0, 1 или 2.' ;;
        esac

        printf '\nEnter — вернуться в меню, 0 — выйти: '
        read_menu_input answer || return 0
        [[ $answer == 0 ]] && return 0
        printf '\n'
    done
}

if (($# == 0)); then
    interactive_menu
else
    run_command "$@"
fi
