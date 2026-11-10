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
readonly -a TEST_NUMBERS=(1 2 3 4)
readonly GROUP_PATTERN='^[^[:space:][:cntrl:];/\\:*?"<>|]+$'
readonly LOGIN_PATTERN='[^[:space:][:cntrl:];]+'
readonly ATTEMPT_PATTERN="^($LOGIN_PATTERN);($LOGIN_PATTERN);([0-9]{4}-[0-9]{2}-[0-9]{2});[0-9]+;([2-5])[+-]*$"

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

parse_attempt() {
    local line=$1 file=$2 line_number=$3
    local -n fields=$4
    if [[ ! $line =~ $ATTEMPT_PATTERN ]]; then
        error "«$file», строка $line_number: неверный формат попытки тестирования."
        return 1
    fi
    # Сохраняем группу, логин, дату и цифру оценки без суффикса.
    fields=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}")
    local group=${fields[0]}
    if [[ ! $group =~ $GROUP_PATTERN || $group == . || $group == .. ]] || ! valid_date "${fields[2]}"; then
        error "«$file», строка $line_number: неверная группа или календарная дата."
        return 1
    fi
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
    local -a lines=() attempt=() rows=()
    local file="$subject_dir/tests/TEST-$test"
    local index line login grade
    load_roster "$group" roster || return 1
    read_data_lines "$file" lines || return 1

    for index in "${!lines[@]}"; do
        line=${lines[$index]%$'\r'}
        [[ $line =~ ^[[:blank:]]*$ ]] && continue
        parse_attempt "$line" "$file" "$((index + 1))" attempt || return 1
        login=${attempt[1]}
        grade=${attempt[3]}
        [[ ${attempt[0]} == "$group" && ${roster[$login]+found} ]] || continue
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

top_students() {
    local limit=$1 subject_dir
    if [[ ! $limit =~ ^[0-9]+$ || ! $limit =~ [1-9] ]]; then
        usage_error 'Количество студентов должно быть положительным целым числом.'
        return 2
    fi
    # N нужен только для сравнения со счётчиком строк. Убираем начальные нули
    # и оставляем его строкой, чтобы большие значения не переполняли арифметику.
    limit=${limit#"${limit%%[!0]*}"}
    resolve_subject_dir "$CIRCUS_SUBJECT" subject_dir || return 1

    local -A sums=() counts=() details=() shown=()
    local -a lines=() attempt=()
    local test file index line date grade key

    for test in "${TEST_NUMBERS[@]}"; do
        file="$subject_dir/tests/TEST-$test"
        read_data_lines "$file" lines || return 1
        for index in "${!lines[@]}"; do
            line=${lines[$index]%$'\r'}
            [[ $line =~ ^[[:blank:]]*$ ]] && continue
            parse_attempt "$line" "$file" "$((index + 1))" attempt || return 1
            date=${attempt[2]}
            grade=${attempt[3]}
            ((grade >= 3)) || continue
            # Один логин может встретиться в разных группах. Каждая строка
            # успешной попытки добавляется к сумме и к числу попыток отдельно.
            key="${attempt[0]};${attempt[1]}"
            sums[$key]=$(( ${sums[$key]:-0} + grade ))
            counts[$key]=$(( ${counts[$key]:-0} + 1 ))
            details[$key]+="    TEST-$test  $date  $grade"$'\n'
        done
    done

    if ((${#sums[@]} == 0)); then
        printf 'Успешных попыток по Цирковому делу не найдено.\n'
        return 0
    fi

    local best best_sum best_count sum count mean rank=0
    local LC_ALL=C
    printf 'Место\tЛогин\tГруппа\tСредний балл\tУспешных попыток\n'
    while [[ $rank != "$limit" ]] && ((rank < ${#sums[@]})); do
        best='' best_sum=0 best_count=1
        for key in "${!sums[@]}"; do
            [[ ${shown[$key]+found} ]] && continue
            sum=${sums[$key]} count=${counts[$key]}

            # Сравниваем дроби по перекрёстным произведениям. Округление
            # для вывода не меняет места. При равенстве сравниваем ключи.
            if ((sum * best_count > best_sum * count)) ||
               { ((sum * best_count == best_sum * count)) && [[ $key < $best ]]; }; then
                best=$key best_sum=$sum best_count=$count
            fi
        done

        shown[$best]=1
        ((++rank))
        mean=$(( (100 * best_sum + best_count / 2) / best_count ))
        printf '%d\t%s\t%s\t%d.%02d\t%d\n' "$rank" "${best#*;}" "${best%%;*}" \
            "$((mean / 100))" "$((mean % 100))" "$best_count"
        printf '%s' "${details[$best]}"
    done
}

collect_first_attempts() {
    local subject=$1 subject_dir=$2 test=$3 year=$4
    local -n output_rows=$5
    local -a lines=() attempt=()
    local -A earliest=()
    local file="$subject_dir/tests/TEST-$test"
    local index line date grade key
    read_data_lines "$file" lines || return 1

    for index in "${!lines[@]}"; do
        line=${lines[$index]%$'\r'}
        [[ $line =~ ^[[:blank:]]*$ ]] && continue
        parse_attempt "$line" "$file" "$((index + 1))" attempt || return 1
        date=${attempt[2]}
        grade=${attempt[3]}
        key="${attempt[0]};${attempt[1]}"
        # Даты ГГГГ-ММ-ДД сравниваются как строки. Строгое сравнение
        # сохраняет первую строку файла, если даты совпали.
        if [[ ! ${earliest[$key]+found} || $date < ${earliest[$key]%%;*} ]]; then
            earliest[$key]="$date;$grade"
        fi
    done

    # Фильтруем по году и оценке только после выбора первой попытки.
    for key in "${!earliest[@]}"; do
        IFS=';' read -r date grade <<< "${earliest[$key]}"
        if [[ ${date:0:4} == "$year" ]] && ((grade >= 3)); then
            output_rows+=("${key#*;}"$'\t'"${key%%;*}"$'\t'"$subject"$'\t'"TEST-$test"$'\t'"$date"$'\t'"$grade")
        fi
    done
}

first_attempt() {
    local year=$1
    if [[ ! $year =~ ^[0-9]{4}$ || $year == 0000 ]]; then
        usage_error 'Укажите календарный год четырьмя цифрами, например 2026.'
        return 2
    fi

    local subject subject_dir test
    local -a rows=()
    for subject in "$RETAKES_SUBJECT" "$CIRCUS_SUBJECT"; do
        resolve_subject_dir "$subject" subject_dir || return 1
        for test in "${TEST_NUMBERS[@]}"; do
            collect_first_attempts "$subject" "$subject_dir" "$test" "$year" rows || return 1
        done
    done

    if ((${#rows[@]} == 0)); then
        printf 'Успешных первых попыток за %s год не найдено.\n' "$year"
        return 0
    fi
    printf 'Логин\tГруппа\tПредмет\tТест\tДата\tОценка\n'
    printf '%s\n' "${rows[@]}" | LC_ALL=C sort -t $'\t' -k2,2 -k1,1 -k3,3 -k4,4
}

show_help() {
    cat <<'HELP'
Анализ посещаемости и результатов тестирования студентов

  bash lab4.sh                              Интерактивное меню
  bash lab4.sh attendance ГРУППА ПРЕДМЕТ     Рейтинг посещаемости
  bash lab4.sh failed ГРУППА ПРЕДМЕТ НОМЕР   Студенты, не сдавшие тест
  bash lab4.sh top [N]                      Лучшие по Цирковому делу (по умолчанию 10)
  bash lab4.sh first-attempt ГОД             Успешные первые попытки за календарный год
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
        top)
            if (($# > 1)); then usage_error 'Команда top принимает только количество студентов.'; return 2; fi
            top_students "${1-10}"
            ;;
        first-attempt)
            if (($# != 1)); then usage_error 'Укажите один календарный год.'; return 2; fi
            first_attempt "$1"
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
    local choice group subject test limit year answer
    while true; do
        cat <<'MENU'
========================================
     АНАЛИЗ УСПЕВАЕМОСТИ СТУДЕНТОВ
========================================

1. Рейтинг посещаемости
2. Студенты, не сдавшие тест
3. Лучшие студенты по Цирковому делу
4. Студенты, сдавшие с первой попытки

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
            3)
                printf 'Количество студентов [10]: '
                read_menu_input limit || return 0
                run_command top "${limit:-10}"
                ;;
            4)
                printf 'Календарный год: '
                read_menu_input year || return 0
                run_command first-attempt "$year"
                ;;
            *) error 'Выберите пункт от 0 до 4.' ;;
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
