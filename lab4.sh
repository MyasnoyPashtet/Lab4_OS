#!/usr/bin/env bash

set -o pipefail

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
    printf 'Ошибка. Требуется Bash 4.3 или новее.\n' >&2
    exit 1
fi

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
declare -a SUBJECTS=() GROUPS_FOUND=()
shopt -s nullglob
CONTROL_PATTERN=$'[\x01-\x1f\x7f]'
GROUP_PATTERN=$'[^;/\x01-\x1f\x7f]+'
LOGIN_PATTERN='[^[:space:][:cntrl:];]+'
ATTEMPT_PATTERN="^($GROUP_PATTERN);$LOGIN_PATTERN;([0-9]{4}-[0-9]{2}-[0-9]{2});[0-9]+;[2-5][+-]*$"

error() {
    printf 'Ошибка. %s\n' "$*" >&2
    return 1
}

choose_data_dir() {
    local data_root="$PROJECT_DIR/data" path name dataset
    local -a datasets=()
    if [[ -L $data_root || ! -d $data_root || ! -r $data_root || ! -x $data_root ]]; then
        error "Не удалось открыть папку наборов данных «$data_root»."
        return 1
    fi
    for path in "$data_root"/*; do
        [[ -d $path/students/groups && ! -L $path ]] || continue
        name=${path##*/}
        [[ $name =~ $CONTROL_PATTERN ]] && continue
        datasets+=("$name")
    done
    if ((${#datasets[@]} == 0)); then
        error "В «$data_root» нет наборов данных с папкой students/groups."
        return 1
    fi

    choose_item dataset 'Выберите набор данных' 'Выход' "${datasets[@]}" || exit 0
    DATA_DIR="$data_root/$dataset"
    GROUPS_DIR="$DATA_DIR/students/groups"
}

# Проверяем ссылки внутри выбранного дерева данных.
check_data_path() {
    local path=$1
    while [[ $path == "${DATA_DIR%/}/"* ]]; do
        if [[ -L $path ]]; then
            error "Символическая ссылка в пути к данным: «$path»."
            return 1
        fi
        path=${path%/*}
    done
}

discover_data() {
    local path name candidate attendance_file
    check_data_path "$GROUPS_DIR" || return 1
    if [[ ! -d $GROUPS_DIR || ! -r $GROUPS_DIR || ! -x $GROUPS_DIR ]]; then
        error "Не удалось открыть списки групп в «$GROUPS_DIR»."
        return 1
    fi
    for path in "$GROUPS_DIR"/*; do
        [[ -L $path || -f $path ]] || continue
        check_data_path "$path" || return 1
        name=${path##*/}
        if [[ ! $name =~ ^$GROUP_PATTERN$ ]]; then
            error "Недопустимое имя группы «$name»."
            return 1
        fi
        GROUPS_FOUND+=("$name")
    done
    if ((${#GROUPS_FOUND[@]} == 0)); then
        error "В «$GROUPS_DIR» не найдены списки групп."
        return 1
    fi

    # У предмета есть папка тестов или файлы посещаемости.
    for path in "${DATA_DIR%/}"/*; do
        [[ -d $path && ${path##*/} != students ]] || continue
        if [[ ! -d $path/tests && ! -L $path/tests ]]; then
            attendance_file=''
            for candidate in "$path"/*-attendance; do
                [[ -f $candidate && ! -L $candidate ]] || continue
                attendance_file=$candidate
                break
            done
            [[ -n $attendance_file ]] || continue
        fi
        check_data_path "$path/tests" || return 1
        name=${path##*/}
        if [[ $name =~ $CONTROL_PATTERN ]]; then
            error "Недопустимый символ в имени папки предмета «$name»."
            return 1
        fi
        SUBJECTS+=("$name")
    done
    if ((${#SUBJECTS[@]} == 0)); then
        error "В «$DATA_DIR» не найдено ни одного предмета."
        return 1
    fi
}

# В папке tests каждый обычный файл считается отдельным тестом.
list_tests() {
    local tests_dir="$1/tests" allow_empty=${3-} path name
    local -n test_names=$2
    test_names=()
    check_data_path "$tests_dir" || return 1
    if [[ ! -d $tests_dir || ! -r $tests_dir || ! -x $tests_dir ]]; then
        error "Не удалось открыть папку тестов «$tests_dir»."
        return 1
    fi
    for path in "$tests_dir"/*; do
        [[ -L $path || -f $path ]] || continue
        check_data_path "$path" || return 1
        name=${path##*/}
        if [[ $name =~ $CONTROL_PATTERN ]]; then
            error "Недопустимый символ в имени теста «$name»."
            return 1
        fi
        test_names+=("$name")
    done
    if ((${#test_names[@]} == 0)) && [[ $allow_empty != allow-empty ]]; then
        error "В папке «$tests_dir» нет файлов тестов."
        return 1
    fi
}

check_data_file() {
    local file=$1
    check_data_path "$file" || return 1
    if [[ ! -f $file || ! -r $file ]]; then
        error "Файл «$file» отсутствует или недоступен для чтения."
        return 1
    fi
}

# Читаем и последнюю строку без LF. BOM удаляем только в начале файла.
read_data_line() {
    local -n text=$1 number=$2
    if ! IFS= read -r text && [[ -z $text ]]; then
        return 1
    fi
    ((++number))
    if ((number == 1)); then
        text=${text#$'\xEF\xBB\xBF'}
    fi
    text=${text%$'\r'}
}

# Для общего индекса передаём префикс «группа;».
read_roster() {
    local file=$1 prefix=${3-} login line_number=0
    local -n output_roster=$2
    check_data_file "$file" || return 1

    while read_data_line login line_number; do
        [[ $login =~ ^[[:blank:]]*$ ]] && continue
        if [[ ! $login =~ ^$LOGIN_PATTERN$ ]]; then
            error "«$file», строка $line_number: ожидался один логин."
            return 1
        fi
        output_roster["$prefix$login"]=1
    done < "$file"
}

# Собирает пары «группа и логин» для отчётов по всем группам.
load_student_index() {
    local group
    for group in "${GROUPS_FOUND[@]}"; do
        read_roster "$GROUPS_DIR/$group" "$1" "$group;" || return 1
    done
}

valid_date() {
    local date=$1
    local -a days_in_month=(0 31 28 31 30 31 30 31 31 30 31 30 31)
    local year=$((10#${date:0:4}))
    local month=$((10#${date:5:2}))
    local day=$((10#${date:8:2}))
    ((year > 0 && month >= 1 && month <= 12 && day >= 1)) || return 1
    local last_day=${days_in_month[month]}
    if ((month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))); then
        last_day=29
    fi
    ((day <= last_day))
}

# Проверяем всю строку, чтобы read не пропустил лишний разделитель.
validate_attempt() {
    local line=$1 file=$2 line_number=$3
    if [[ ! $line =~ $ATTEMPT_PATTERN ]]; then
        error "«$file», строка $line_number: неверный формат попытки тестирования."
        return 1
    fi
    local date=${BASH_REMATCH[2]}
    if ! valid_date "$date"; then
        error "«$file», строка $line_number: неверная календарная дата."
        return 1
    fi
}

print_cell() {
    local LC_ALL=C
    local width=$1 value=$2
    # Считаем символы UTF-8, пропуская байты продолжения.
    local continuation=$'[\x80-\xbf]'
    local characters=${value//$continuation/}
    local spaces=$((width - ${#characters}))
    ((spaces < 2)) && spaces=2
    printf '%s%*s' "$value" "$spaces" ''
}

# Перед последней колонкой идут пары «ширина, значение».
print_row() {
    while (($# > 1)); do
        print_cell "$1" "$2"
        shift 2
    done
    printf '%s\n' "$1"
}

# Считает посещения для студентов выбранной группы.
attendance() {
    local group=$1 subject_dir="${DATA_DIR%/}/$2"

    local -A roster=() visits=()
    local file="$subject_dir/$group-attendance"
    local line line_number=0 login ones visits_count
    local pattern="^($LOGIN_PATTERN)[[:blank:]]+([01]+)$"
    read_roster "$GROUPS_DIR/$group" roster || return 1
    check_data_file "$file" || return 1

    while read_data_line line line_number; do
        [[ $line =~ ^[[:blank:]]*$ ]] && continue
        if [[ ! $line =~ $pattern ]]; then
            error "«$file», строка $line_number: ожидались логин и строка из 0 и 1."
            return 1
        fi
        login=${BASH_REMATCH[1]}
        [[ ${roster[$login]+found} ]] || continue
        if [[ ${visits[$login]+found} ]]; then
            error "«$file», строка $line_number: повторная запись посещаемости для «$login»."
            return 1
        fi

        # Каждая единица обозначает одно посещённое занятие.
        ones=${BASH_REMATCH[2]//0/}
        visits[$login]=${#ones}
    done < "$file" || return 1

    if ((${#roster[@]} == 0)); then
        printf 'Список группы «%s» пуст.\n' "$group"
        return 0
    fi

    local login_width=8
    for login in "${!roster[@]}"; do
        ((${#login} + 2 > login_width)) && login_width=$((${#login} + 2))
    done
    print_row "$login_width" 'Логин' 'Посещено'
    # Значение -1 ставит пропущенные записи после нулей.
    for login in "${!roster[@]}"; do
        printf '%s\t%s\n' "$login" "${visits[$login]:--1}"
    done | LC_ALL=C sort -t $'\t' -k2,2nr -k1,1 |
        while IFS=$'\t' read -r login visits_count; do
            [[ $visits_count == -1 ]] && visits_count='Нет записи'
            print_row "$login_width" "$login" "$visits_count"
        done
}

# Выводит студентов, у которых ещё нет успешной попытки.
failed_tests() {
    local group=$1 test=$3 subject_dir="${DATA_DIR%/}/$2"
    local -A roster=() statuses=()
    local -a rows=()
    local file="$subject_dir/tests/$test"
    local line line_number=0 attempt_group login mark status
    read_roster "$GROUPS_DIR/$group" roster || return 1
    check_data_file "$file" || return 1

    while read_data_line line line_number; do
        [[ $line =~ ^[[:blank:]]*$ ]] && continue
        # Записи с корректным именем другой группы не относятся к отчёту.
        attempt_group=${line%%;*}
        if [[ $line == *';'* && $attempt_group != "$group" ]] &&
            [[ $attempt_group =~ ^$GROUP_PATTERN$ ]]; then
            continue
        fi
        validate_attempt "$line" "$file" "$line_number" || return 1
        IFS=';' read -r attempt_group login _ _ mark <<< "$line"
        [[ ${roster[$login]+found} ]] || continue
        # Поздняя двойка не отменяет уже сданный тест.
        [[ ${statuses[$login]} == 'Сдал' ]] && continue
        if [[ $mark == 2* ]]; then
            statuses[$login]='Не сдал'
        else
            statuses[$login]='Сдал'
        fi
    done < "$file" || return 1

    local login_width=8
    for login in "${!roster[@]}"; do
        status=${statuses[$login]:-Не проходил}
        [[ $status == 'Сдал' ]] && continue
        ((${#login} + 2 > login_width)) && login_width=$((${#login} + 2))
        rows+=("$login"$'\t'"$status")
    done

    if ((${#rows[@]} == 0)); then
        printf 'Студентов без успешной попытки не найдено.\n'
        return 0
    fi
    print_row "$login_width" 'Логин' 'Статус'
    printf '%s\n' "${rows[@]}" | LC_ALL=C sort -t $'\t' -k1,1 |
        while IFS=$'\t' read -r login status; do
            print_row "$login_width" "$login" "$status"
        done
}

find_circus_subject() {
    local -n result=$1
    local subject_name name index
    # Для букв названия задаём регистр явно, чтобы поиск работал и в локали C.
    local -a upper=(В Д Е И К Л О Р Ц)
    local -a lower=(в д е и к л о р ц)
    result=''

    for subject_name in "${SUBJECTS[@]}"; do
        name=${subject_name//[[:blank:]_-]/}
        # Отбрасываем числовой суффикс в имени папки.
        name=${name%"${name##*[!0-9]}"}
        for index in "${!upper[@]}"; do
            name=${name//"${upper[index]}"/"${lower[index]}"}
        done
        [[ $name == цирковоедело ]] || continue
        if [[ -n $result ]]; then
            error "Найдено несколько папок предмета «Цирковое дело»: «$result» и «$subject_name»."
            return 1
        fi
        result=$subject_name
    done
    [[ -n $result ]] || error 'В выбранном наборе не найден предмет «Цирковое дело».'
}

# Считает средний балл по успешным попыткам и выводит рейтинг.
top_students() {
    local subject=$1 limit
    local subject_dir="${DATA_DIR%/}/$subject"
    if [[ $2 =~ ^0*([1-9][0-9]*)$ ]]; then
        # Храним число без ведущих нулей и сравниваем со счётчиком как строку.
        limit=${BASH_REMATCH[1]}
    else
        error 'Количество студентов должно быть положительным целым числом.'
        return 1
    fi

    local -A students=() sums=() counts=() details=()
    local -a tests=()
    local test file line line_number group login date mark grade key count detail max_count=0
    list_tests "$subject_dir" tests || return 1
    load_student_index students || return 1

    for test in "${tests[@]}"; do
        file="$subject_dir/tests/$test"
        check_data_file "$file" || return 1
        line_number=0
        while read_data_line line line_number; do
            [[ $line =~ ^[[:blank:]]*$ ]] && continue
            validate_attempt "$line" "$file" "$line_number" || return 1
            IFS=';' read -r group login date _ mark <<< "$line"
            key="$group;$login"
            [[ ${students[$key]+found} ]] || continue
            grade=${mark:0:1}
            ((grade >= 3)) || continue
            # Каждая успешная попытка участвует в среднем отдельно.
            sums[$key]=$(( ${sums[$key]:-0} + grade ))
            count=$(( ${counts[$key]:-0} + 1 ))
            counts[$key]=$count
            if ((count > max_count)); then
                max_count=$count
            fi
            printf -v detail '  %s  %s  %s\n' "$test" "$date" "$grade"
            details[$key]+=$detail
        done < "$file" || return 1
    done

    if ((${#sums[@]} == 0)); then
        printf 'Успешных попыток по предмету «%s» не найдено.\n' "$subject"
        return 0
    fi

    # Разные средние отличаются хотя бы на 1 / max_count².
    # Умножаем на max_count², чтобы целочисленное деление сохранило порядок.
    local scale=$((max_count * max_count))
    local sum sort_key rank=0 mean mean_text
    local rank_width=7 login_width=8 group_width=8 student_count=${#sums[@]}
    ((${#student_count} + 2 > rank_width)) && rank_width=$((${#student_count} + 2))
    for key in "${!sums[@]}"; do
        group=${key%%;*}
        login=${key#*;}
        ((${#login} + 2 > login_width)) && login_width=$((${#login} + 2))
        ((${#group} + 2 > group_width)) && group_width=$((${#group} + 2))
    done
    print_row "$rank_width" 'Место' "$login_width" 'Логин' "$group_width" 'Группа' \
        15 'Средний балл' 'Успешных попыток'
    for key in "${!sums[@]}"; do
        sum=${sums[$key]}
        count=${counts[$key]}
        sort_key=$((sum * scale / count))
        printf '%d\t%s\n' "$sort_key" "$key"
    done | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 |
        while IFS=$'\t' read -r _ key; do
            [[ $rank == "$limit" ]] && continue
            ((++rank))
            sum=${sums[$key]}
            count=${counts[$key]}
            # До сотых округляем только при выводе.
            mean=$(( (100 * sum + count / 2) / count ))
            printf -v mean_text '%d.%02d' "$((mean / 100))" "$((mean % 100))"
            print_row "$rank_width" "$rank" "$login_width" "${key#*;}" "$group_width" "${key%%;*}" \
                15 "$mean_text" "$count"
            printf '%s' "${details[$key]}"
        done
}

# Собирает отчёт о первых попытках по всем найденным предметам.
first_attempt() {
    local year=$1
    if [[ ! $year =~ ^[0-9]{4}$ || $year == 0000 ]]; then
        error 'Укажите календарный год четырьмя цифрами, например 2026.'
        return 1
    fi

    local subject subject_dir test file line line_number group login date mark grade key row
    local -A students=() earliest=()
    local -a rows=() tests=()
    local login_width=8 subject_width=9 test_width=8 found_tests=0
    load_student_index students || return 1
    for subject in "${SUBJECTS[@]}"; do
        subject_dir="${DATA_DIR%/}/$subject"
        # Общий отчёт включает только предметы с файлами тестов.
        [[ -e $subject_dir/tests || -L $subject_dir/tests ]] || continue
        list_tests "$subject_dir" tests allow-empty || return 1
        ((${#tests[@]} > 0)) || continue
        found_tests=1
        ((${#subject} + 2 > subject_width)) && subject_width=$((${#subject} + 2))
        for test in "${tests[@]}"; do
            ((${#test} + 2 > test_width)) && test_width=$((${#test} + 2))
            file="$subject_dir/tests/$test"
            check_data_file "$file" || return 1
            earliest=()
            line_number=0
            while read_data_line line line_number; do
                [[ $line =~ ^[[:blank:]]*$ ]] && continue
                validate_attempt "$line" "$file" "$line_number" || return 1
                IFS=';' read -r group login date _ mark <<< "$line"
                key="$group;$login"
                [[ ${students[$key]+found} ]] || continue
                # При равных датах оставляем первую запись файла.
                if [[ ! ${earliest[$key]+found} || $date < ${earliest[$key]%%;*} ]]; then
                    earliest[$key]="$date;${mark:0:1}"
                fi
            done < "$file" || return 1

            # Год и оценку проверяем после выбора первой попытки.
            for key in "${!earliest[@]}"; do
                IFS=';' read -r date grade <<< "${earliest[$key]}"
                if [[ ${date:0:4} == "$year" ]] && ((grade >= 3)); then
                    group=${key%%;*}
                    login=${key#*;}
                    ((${#login} + 2 > login_width)) && login_width=$((${#login} + 2))
                    printf -v row '%s\t%s\t%s\t%s\t%s' "$group" "$login" "$subject" "$test" "$grade"
                    rows+=("$row")
                fi
            done
        done
    done
    if ((!found_tests)); then
        error 'В найденных предметах нет файлов тестов.'
        return 1
    fi
    if ((${#rows[@]} == 0)); then
        printf 'Успешных первых попыток за %s год не найдено.\n' "$year"
        return 0
    fi
    print_row "$login_width" 'Логин' "$subject_width" 'Предмет' "$test_width" 'Тест' 'Оценка'
    # Группа нужна для сортировки и разделения студентов с одинаковым логином.
    printf '%s\n' "${rows[@]}" | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 -k3,3 -k4,4 |
        while IFS=$'\t' read -r _ login subject test grade; do
            print_row "$login_width" "$login" "$subject_width" "$subject" "$test_width" "$test" "$grade"
        done
}

print_input_gap() {
    # При вводе из файла терминал не переносит строку после ответа.
    [[ -t 0 ]] || printf '\n'
    printf '\n'
}

read_menu_input() {
    local -n input=$1
    # У последней строки в файле может не быть перевода строки.
    if ! read -r input && [[ -z $input ]]; then
        return 1
    fi
    # При чтении из файла Windows после перевода строки остаётся символ CR.
    input=${input%$'\r'}
    print_input_gap
}

choose_item() {
    local -n selected=$1
    local prompt=$2 cancel_label=$3 choice index number
    shift 3
    local -a items=("$@")

    printf '%s\n' "$prompt"
    for index in "${!items[@]}"; do
        printf '%d. %s\n' "$((index + 1))" "${items[$index]}"
    done
    printf '0. %s\n' "$cancel_label"
    while true; do
        printf 'Номер: '
        read_menu_input choice || return 1
        [[ $choice == 0 ]] && return 1
        for index in "${!items[@]}"; do
            number=$((index + 1))
            if [[ $choice == "$number" ]]; then
                selected=${items[$index]}
                return 0
            fi
        done
        error 'Выберите номер из списка.'
    done
}

interactive_menu() {
    local choice group subject test limit year answer
    local -a tests=()
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
                choose_item group 'Выберите группу' 'Назад' "${GROUPS_FOUND[@]}" || continue
                choose_item subject 'Выберите предмет' 'Назад' "${SUBJECTS[@]}" || continue
                if [[ $choice == 1 ]]; then
                    attendance "$group" "$subject"
                elif list_tests "${DATA_DIR%/}/$subject" tests; then
                    choose_item test 'Выберите тест' 'Назад' "${tests[@]}" || continue
                    failed_tests "$group" "$subject" "$test"
                fi
                ;;
            3)
                find_circus_subject subject || continue
                printf 'Количество студентов [10]: '
                read_menu_input limit || return 0
                top_students "$subject" "${limit:-10}"
                ;;
            4)
                printf 'Календарный год: '
                read_menu_input year || return 0
                first_attempt "$year"
                ;;
            *) error 'Выберите пункт от 0 до 4.' ;;
        esac

        printf '\nEnter — вернуться в меню, 0 — выйти: '
        read_menu_input answer || return 0
        [[ $answer == 0 ]] && return 0
    done
}

if (($# > 0)); then
    error 'Запустите скрипт без аргументов: bash lab4.sh.'
    exit 2
fi
choose_data_dir || exit 1
discover_data || exit 1
interactive_menu
