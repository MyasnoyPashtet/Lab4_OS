#!/usr/bin/env bash
set -euo pipefail

if (($# > 1)) || [[ -n ${1-} && $1 != --real ]]; then
    printf 'Использование: bash tests/run-tests.sh [--real]\n' >&2
    exit 2
fi

# Фиксируем порядок имён для нумерации в меню и сравнения отчётов.
export LC_ALL=C
root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
synthetic="$root/tests/data/synthetic/labfiles-3-26"
real="$root/data/labfiles-3-26"
if [[ ! -f $root/lab4.sh || ! -d $synthetic/students/groups ||
      ( ${1-} == --real && ! -d $real/students/groups ) ]]; then
    printf 'Для проверки нужны lab4.sh и выбранные наборы данных.\n' >&2
    exit 2
fi
for tool in timeout diff mktemp; do
    if ! command -v "$tool" >/dev/null; then
        printf 'Для проверки нужна утилита %s.\n' "$tool" >&2
        exit 2
    fi
done

temp_base=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
scratch=$(mktemp -d -- "$temp_base/lab4-qa.XXXXXXXX")
cleanup() {
    if [[ $scratch == "$temp_base"/lab4-qa.???????? && -d $scratch && ! -L $scratch ]]; then
        rm -r -- "$scratch"
    fi
}
trap cleanup EXIT

passed=0 failed=0 skipped=0
start_case() {
    id=$1
    case_dir="$scratch/$id"
    project="$case_dir/Рабочая копия"
    data="$project/data/labfiles-3-26"
    stdin="$case_dir/stdin"
    stdout="$case_dir/stdout"
    stderr="$case_dir/stderr"
    problem=0
    error_expected=0

    mkdir -p -- "$project"
    cp -- "$root/lab4.sh" "$project/lab4.sh"
    : > "$stdin"
    case ${2:-synthetic} in
        synthetic)
            mkdir -- "$project/data"
            cp -a -- "$synthetic" "$data"
            ;;
        real)
            mkdir -- "$project/data"
            cp -a -- "$real" "$data"
            ;;
        empty) mkdir -- "$project/data" ;;
        none) ;;
        *) printf 'Неизвестный режим теста %s.\n' "$2" >&2; exit 2 ;;
    esac
}

fail() {
    problem=1
    printf '%s — %s\n' "$id" "$*" >&2
}

run_lab() {
    local expected_code=$1 code=0
    shift
    # Снимок делаем после подготовки кейса. Запускаем из другой директории.
    if [[ -d $project/data ]]; then
        # В Git Bash сохраняем ссылки как ссылки и в снимке.
        MSYS=winsymlinks:sys cp -a -- "$project/data" "$case_dir/before"
    fi
    (cd -- "$case_dir" && timeout 20s bash "$project/lab4.sh" "$@") \
        < "$stdin" > "$stdout" 2> "$stderr" || code=$?
    if ((code != expected_code)); then
        fail "Код завершения $code, ожидался $expected_code."
    fi
    if [[ -d $case_dir/before ]]; then
        diff -r --no-dereference -- "$case_dir/before" "$project/data" ||
            fail 'Программа изменила данные.'
    elif [[ -e $project/data ]]; then
        fail 'Программа создала каталог данных.'
    fi
    cmp -s -- "$root/lab4.sh" "$project/lab4.sh" || fail 'Скрипт изменился во время прогона.'
}

menu() {
    printf '%s\n' "$@" > "$stdin"
    run_lab 0
}

expect_text() {
    grep -Fq -- "$1" "$stdout" || fail "В stdout нет текста «$1»."
}

reject_text() {
    if grep -Fq -- "$1" "$stdout"; then
        fail "В stdout найден лишний текст «$1»."
    fi
}

expect_error() {
    error_expected=1
    grep -Fq -- "$1" "$stderr" || fail "В stderr нет текста «$1»."
}

# Берём строки под заголовком. Поля отделены двумя и более пробелами.
# Одиночные пробелы внутри имени группы, предмета или теста сохраняются.
table_rows() {
    local header=$1 line reading=0
    while IFS= read -r line; do
        if ((reading)); then
            [[ -n $line ]] || break
            printf '%s\n' "$line"
        elif [[ $line =~ $header ]]; then
            reading=1
        fi
    done < "$stdout" | sed -E 's/^[[:blank:]]+//; s/[[:blank:]]{2,}/|/g'
}

expect_table() {
    local header=$1
    shift
    expect_rows "$@" < <(table_rows "$header")
}

expect_rows() {
    cat > "$case_dir/actual"
    printf '%s\n' "$@" > "$case_dir/expected"
    diff -u -- "$case_dir/expected" "$case_dir/actual" || fail 'Строки отчёта или их порядок отличаются.'
}

finish_case() {
    if ((!error_expected)) && [[ -s $stderr ]]; then
        fail 'Неожиданное сообщение в stderr.'
    fi
    if ((problem)); then
        printf 'FAIL %s\n' "$id"
        printf '%s\n' '--- stdout ---' >&2
        tail -n 45 -- "$stdout" >&2
        printf '%s\n' '--- stderr ---' >&2
        cat -- "$stderr" >&2
        ((++failed))
    else
        printf 'PASS %s\n' "$id"
        ((++passed))
    fi
}

attendance_header='^Логин +Посещено$'
failed_header='^Логин +Статус$'
top_header='^Место +Логин +Группа +Средний балл +Успешных попыток$'
first_header='^Логин +Предмет +Тест +Оценка$'
circus='Цирковое_Дело'
retakes='Пересдачеведение'
attendance_rows=('AlekseevAA|3' 'SokolovSS|3' 'BorisovBB|1' 'ZorinZZ|1' 'VolkovVV|0' 'AntonovAV|Нет записи')
retakes_attendance_rows=('AlekseevAA|1' 'AntonovAV|Нет записи' 'BorisovBB|Нет записи'
    'SokolovSS|Нет записи' 'VolkovVV|Нет записи' 'ZorinZZ|Нет записи')
failed_rows=('AntonovAV|Не проходил' 'BorisovBB|Не сдал' 'VolkovVV|Не проходил' 'ZorinZZ|Не проходил')
retakes_failed_rows=('AlekseevAA|Не проходил' 'AntonovAV|Не сдал' 'BorisovBB|Не проходил'
    'SokolovSS|Не проходил' 'VolkovVV|Не сдал' 'ZorinZZ|Не проходил')
top_rows=('1|SokolovSS|Ae-21-23|5.00|1' '2|AlekseevAA|A-06-23|4.00|3'
    '3|SokolovSS|A-06-23|4.00|1' '4|VolkovVV|A-06-23|4.00|1' '5|ZorinZZ|A-06-23|4.00|1'
    '6|DenisovDD|Ae-21-23|4.00|2' '7|BorisovBB|A-06-23|3.00|1')

# В основном наборе группа A-06-23 имеет номер 2, предметы идут
# в порядке «Пересдачеведение», «Цирковое_Дело».
start_case G-01
bash -n "$root/lab4.sh" && bash -n "$root/tests/run-tests.sh" || fail 'Ошибка синтаксиса Bash.'
menu 1 0
expect_text '1. labfiles-3-26'
expect_text 'АНАЛИЗ УСПЕВАЕМОСТИ СТУДЕНТОВ'
finish_case

start_case G-02
other="$project/data/labfiles-4-26 второй набор"
mkdir -p -- "$other/students/groups" "$other/Новый предмет" "$project/data/backup" \
    "$project/data/.hidden/students/groups"
printf 'KuznetsovKK\n' > "$other/students/groups/A-07-24"
printf 'KuznetsovKK 101\n' > "$other/Новый предмет/A-07-24-attendance"
printf 'заметки\n' > "$project/data/notes.txt"
menu 2 1 1 1 0
expect_text '1. labfiles-3-26'
expect_text '2. labfiles-4-26 второй набор'
expect_text '1. A-07-24'
expect_text '1. Новый предмет'
reject_text 'backup'
reject_text '.hidden'
reject_text 'notes.txt'
reject_text 'A-06-23'
expect_table "$attendance_header" 'KuznetsovKK|2'
finish_case

start_case G-03
menu 9 0
expect_error 'Выберите номер из списка.'
expect_text '0. Выход'
reject_text 'АНАЛИЗ УСПЕВАЕМОСТИ СТУДЕНТОВ'
finish_case

start_case G-04
menu 1 9 '' 1 99 0 2 2 2 99 1 '' 4 2024 0
expect_error 'Выберите пункт от 0 до 4.'
expect_error 'Выберите номер из списка.'
expect_table "$failed_header" "${failed_rows[@]}"
expect_table "$first_header" "VolkovVV|$circus|TEST-2|4"
finish_case

start_case G-05 none
run_lab 1
expect_error 'Не удалось открыть папку наборов данных'
finish_case

start_case G-06 empty
mkdir -- "$project/data/backup"
run_lab 1
expect_error 'нет наборов данных с папкой students/groups'
finish_case

start_case G-07 empty
mkdir -p -- "$data/students/groups"
: > "$data/students/groups/.gitkeep"
printf '1\n' > "$stdin"
run_lab 1
expect_error 'не найдены списки групп'
reject_text '.gitkeep'
finish_case

start_case G-08 empty
mkdir -p -- "$data/students/groups" "$data/Резервная папка/не-файл-attendance"
printf 'AlekseevAA\n' > "$data/students/groups/A-06-23"
printf '1\n' > "$stdin"
run_lab 1
expect_error 'не найдено ни одного предмета'
finish_case

start_case G-09
run_lab 2 --help
expect_error 'Запустите скрипт без аргументов: bash lab4.sh.'
reject_text 'Выберите набор данных'
finish_case

start_case G-10
run_lab 0
expect_text 'Выберите набор данных'
reject_text 'АНАЛИЗ УСПЕВАЕМОСТИ СТУДЕНТОВ'
finish_case

start_case G-11
printf 'AlekseevAA\n' > "$data/students/groups/Bad;Group"
printf '1\n' > "$stdin"
run_lab 1
expect_error 'Недопустимое имя группы «Bad;Group»'
finish_case

start_case G-12
link="$data/students/groups/link"
# Ссылку MSYS можно создать в Git Bash без разрешения Windows на нативные ссылки.
if { MSYS=winsymlinks:nativestrict ln -s -- A-06-23 "$link" 2>/dev/null ||
     MSYS=winsymlinks:sys ln -s -- A-06-23 "$link" 2>/dev/null; } && [[ -L $link ]]; then
    printf '1\n' > "$stdin"
    run_lab 1
    expect_error 'Символическая ссылка'
    finish_case
else
    printf 'SKIP %s — среда не позволяет создать символическую ссылку\n' "$id"
    ((++skipped))
fi

start_case G-13
menu 1 1 2
expect_text 'Выберите предмет'
reject_text 'Посещено'
finish_case

start_case F1-01
menu 1 1 2 2 0
expect_text '2. A-06-23'
expect_text "2. $circus"
expect_table "$attendance_header" "${attendance_rows[@]}"
finish_case

start_case F1-02
menu 1 1 3 2 0
expect_text '3. Ae-21-23'
expect_table "$attendance_header" 'SokolovSS|2' 'DenisovDD|0'
finish_case

start_case F1-03
menu 1 1 1 2 0
expect_text 'Список группы «A-06-21» пуст.'
finish_case

start_case F1-04
mv -- "$data/$circus/A-06-23-attendance" "$case_dir/saved-attendance"
menu 1 1 2 2 0
expect_error 'A-06-23-attendance» отсутствует или недоступен для чтения'
finish_case

start_case F1-05
printf 'AlekseevAA 1X1\n' >> "$data/$circus/A-06-23-attendance"
menu 1 1 2 2 0
expect_error 'строка 7: ожидались логин и строка из 0 и 1'
reject_text 'Посещено'
finish_case

start_case F1-06
printf 'AlekseevAA 01\n' >> "$data/$circus/A-06-23-attendance"
menu 1 1 2 2 0
expect_error 'строка 7: повторная запись посещаемости для «AlekseevAA»'
finish_case

start_case F1-07
printf '\357\273\277AlekseevAA\r\nBorisovBB\r\n\r\nSokolovSS\r\nVolkovVV\r\nAntonovAV\r\nZorinZZ' \
    > "$data/students/groups/A-06-23"
printf '\357\273\277AlekseevAA\t1011\r\nSokolovSS 111\r\nBorisovBB 100\r\nZorinZZ 01\r\nVolkovVV 000' \
    > "$data/$circus/A-06-23-attendance"
printf '1\r\n1\r\n2\r\n2\r\n0' > "$stdin"
run_lab 0
expect_table "$attendance_header" "${attendance_rows[@]}"
finish_case

start_case F1-08
menu 1 1 2 1 0
expect_table "$attendance_header" "${retakes_attendance_rows[@]}"
finish_case

start_case F1-09
printf 'два логина\n' >> "$data/students/groups/A-06-23"
menu 1 1 2 2 0
expect_error 'строка 7: ожидался один логин'
finish_case

start_case F1-10
: > "$data/$circus/Ae-21-23-attendance"
menu 1 1 3 2 0
expect_table "$attendance_header" 'DenisovDD|Нет записи' 'SokolovSS|Нет записи'
finish_case

start_case F1-11
mv -- "$data/$circus" "$data/Цирковое дело 1"
menu 1 1 2 2 0
expect_text '2. Цирковое дело 1'
expect_table "$attendance_header" "${attendance_rows[@]}"
finish_case

start_case F2-01
menu 1 2 2 2 1 0
expect_text '1. TEST-1'
expect_table "$failed_header" "${failed_rows[@]}"
finish_case

start_case F2-02
menu 1 2 3 2 1 0
expect_text 'Студентов без успешной попытки не найдено.'
finish_case

start_case F2-03
menu 1 2 2 2 3 0
expect_table "$failed_header" 'AlekseevAA|Не проходил' 'AntonovAV|Не проходил' 'BorisovBB|Не проходил' \
    'SokolovSS|Не проходил' 'VolkovVV|Не проходил' 'ZorinZZ|Не проходил'
finish_case

start_case F2-04
printf 'Ae-21-23;DenisovDD;2026-02-30;1;2\n' >> "$data/$circus/tests/TEST-1"
menu 1 2 2 2 1 0
expect_table "$failed_header" "${failed_rows[@]}"
finish_case

start_case F2-05
printf 'A-06-23;BorisovBB;2026-02-30;1;2\n' >> "$data/$circus/tests/TEST-1"
menu 1 2 2 2 1 0
expect_error 'строка 10: неверная календарная дата'
finish_case

start_case F2-06
mv -- "$data/$circus/tests" "$case_dir/saved-tests"
mkdir -- "$data/$circus/tests"
: > "$data/$circus/tests/.gitkeep"
menu 1 2 2 2 0
expect_error 'нет файлов тестов'
reject_text '.gitkeep'
finish_case

start_case F2-07
printf '\357\273\277A-06-23;AlekseevAA;2026-01-01;3;3--\r\nA-06-23;AlekseevAA;2026-01-02;1;2+\r\nA-06-23;BorisovBB;2026-01-02;1;2' \
    > "$data/$circus/tests/TEST-1"
menu 1 2 2 2 1 0
expect_table "$failed_header" 'AntonovAV|Не проходил' 'BorisovBB|Не сдал' 'SokolovSS|Не проходил' \
    'VolkovVV|Не проходил' 'ZorinZZ|Не проходил'
finish_case

start_case F2-08
printf 'A-06-23;BorisovBB;2026-01-01;X;2\n' >> "$data/$circus/tests/TEST-1"
menu 1 2 2 2 1 0
expect_error 'строка 10: неверный формат попытки тестирования'
finish_case

start_case F2-09
printf 'A-06-23;BorisovBB;2026-01-01;5;6\n' >> "$data/$circus/tests/TEST-1"
menu 1 2 2 2 1 0
expect_error 'строка 10: неверный формат попытки тестирования'
finish_case

start_case F2-10
menu 1 2 2 1 2 0
expect_table "$failed_header" "${retakes_failed_rows[@]}"
finish_case

start_case F2-11
menu 1 2 1 2 1 0
expect_text 'Студентов без успешной попытки не найдено.'
reject_text 'Статус'
finish_case

start_case F2-12
mv -- "$data/$retakes/tests/TEST-2" "$data/$retakes/tests/Зачёт 2"
menu 1 2 2 1 4 0
expect_text '4. Зачёт 2'
expect_table "$failed_header" "${retakes_failed_rows[@]}"
finish_case

start_case F3-01
menu 1 3 '' 0
expect_text 'Лучшие студенты по Цирковому делу'
reject_text 'Выберите предмет'
expect_table "$top_header" \
    "${top_rows[0]}" 'TEST-1|2026-02-01|5' \
    "${top_rows[1]}" 'TEST-1|2026-03-02|5' 'TEST-2|2026-03-10|3' 'TEST-2|2026-03-11|4' \
    "${top_rows[2]}" 'TEST-1|2026-02-01|4' \
    "${top_rows[3]}" 'TEST-2|2024-02-29|4' \
    "${top_rows[4]}" 'TEST-2|2026-03-10|4' \
    "${top_rows[5]}" 'TEST-1|2026-02-01|3' 'TEST-2|2026-03-10|5' \
    "${top_rows[6]}" 'TEST-2|2026-03-10|3'
finish_case

start_case F3-02
mv -- "$data/$circus" "$data/ЦИРКОВОЕ дело-1"
mv -- "$data/ЦИРКОВОЕ дело-1/tests/TEST-1" "$data/ЦИРКОВОЕ дело-1/tests/Входной тест"
menu 1 3 01 0
expect_table "$top_header" "${top_rows[0]}" 'Входной тест|2026-02-01|5'
finish_case

start_case F3-03
printf 'ALow\nZHigh\n' >> "$data/students/groups/A-06-23"
mv -- "$data/$circus" "$case_dir/saved-circus"
close_test="$data/Цирковое_Дело1/tests/TEST-1"
mkdir -p -- "${close_test%/*}"
{
    printf 'A-06-23;ALow;2026-01-01;5;5\nA-06-23;ZHigh;2026-01-01;5;5\n'
    for ((i=0; i<204; i++)); do
        printf 'A-06-23;ALow;2026-01-02;4;4\nA-06-23;ZHigh;2026-01-02;4;4\n'
    done
    printf 'A-06-23;ALow;2026-01-02;4;4\n'
} > "$close_test"
menu 1 3 2 0
expect_rows '1|ZHigh|A-06-23|4.00|205' '2|ALow|A-06-23|4.00|206' \
    < <(table_rows "$top_header" | grep -E '^[0-9]+\|')
finish_case

start_case F3-04
mv -- "$data/$circus" "$data/Цирковое дело"
menu 1 3 0 0
expect_error 'Количество студентов должно быть положительным целым числом'
finish_case

start_case F3-05
mv -- "$data/$circus/tests" "$case_dir/saved-tests"
menu 1 3 5 0
expect_error 'Не удалось открыть папку тестов'
finish_case

start_case F3-06
mv -- "$data/$circus/tests" "$case_dir/saved-tests"
mkdir -- "$data/$circus/tests"
printf 'A-06-23;BorisovBB;2026-04-01;1;2\n' > "$data/$circus/tests/TEST-1"
menu 1 3 5 0
expect_text "Успешных попыток по предмету «$circus» не найдено."
finish_case

start_case F3-07
mv -- "$data/$circus/tests" "$case_dir/saved-tests"
mkdir -- "$data/$circus/tests"
for ((i=1; i<=12; i++)); do
    printf 'Rank%02d\n' "$i"
done > "$data/students/groups/A-06-23"
for ((i=1; i<=12; i++)); do
    printf 'A-06-23;Rank%02d;2026-01-01;5;5\n' "$i"
done > "$data/$circus/tests/TEST-1"
menu 1 3 '' 0
mapfile -t ranks < <(table_rows "$top_header" | grep -E '^[0-9]+\|')
[[ ${#ranks[@]} -eq 10 && ${ranks[0]-} == '1|Rank01|A-06-23|5.00|1' &&
   ${ranks[9]-} == '10|Rank10|A-06-23|5.00|1' ]] ||
    fail 'При пустом вводе ожидались первые десять мест из двенадцати.'
finish_case

start_case F3-08
mv -- "$data/$circus" "$case_dir/saved-circus"
menu 1 3 1 2 1 0
expect_error 'В выбранном наборе не найден предмет «Цирковое дело».'
reject_text 'Количество студентов'
expect_table "$attendance_header" "${retakes_attendance_rows[@]}"
finish_case

start_case F3-09
mkdir -p -- "$data/Цирковое-Дело_02/tests"
menu 1 3 0
expect_error 'Найдено несколько папок предмета «Цирковое дело»'
expect_error "$circus"
expect_error 'Цирковое-Дело_02'
reject_text 'Количество студентов'
finish_case

start_case F3-10
mv -- "$data/$circus" "$data/Цирковое дело 1"
menu 1 3 99999999999999999999 0
expect_rows "${top_rows[@]}" < <(table_rows "$top_header" | grep -E '^[0-9]+\|')
finish_case

start_case F3-11
menu 1 3 2.5 0
expect_error 'Количество студентов должно быть положительным целым числом'
reject_text 'Средний балл'
finish_case

start_case F3-12
mv -- "$data/$circus/tests" "$case_dir/saved-tests"
mkdir -- "$data/$circus/tests"
: > "$data/$circus/tests/.gitkeep"
menu 1 3 5 0
expect_error 'нет файлов тестов'
reject_text 'Средний балл'
finish_case

start_case F4-01
mkdir -p -- "$data/История" "$data/Химия/tests" "$data/Практика/tests"
printf 'AlekseevAA 01\n' > "$data/История/A-06-23-attendance"
: > "$data/Химия/tests/.gitkeep"
menu 1 4 2026 0
expect_table "$first_header" \
    "AlekseevAA|$circus|TEST-2|3" "BorisovBB|$retakes|TEST-1|5" "BorisovBB|$circus|TEST-2|3" \
    "SokolovSS|$retakes|TEST-1|3" "ZorinZZ|$circus|TEST-2|4" \
    "DenisovDD|$circus|TEST-1|3" "DenisovDD|$circus|TEST-2|5" \
    "SokolovSS|$retakes|TEST-1|3" "SokolovSS|$circus|TEST-1|5"
finish_case

start_case F4-02
menu 1 4 2024 0
expect_table "$first_header" "VolkovVV|$circus|TEST-2|4"
finish_case

start_case F4-03
menu 1 4 2030 0
expect_text 'Успешных первых попыток за 2030 год не найдено.'
finish_case

start_case F4-04
menu 1 4 0000 0
expect_error 'Укажите календарный год четырьмя цифрами'
finish_case

start_case F4-05
printf 'A-06-23;AlekseevAA;2026-02-29;4;4\n' >> "$data/$circus/tests/TEST-2"
menu 1 4 2026 0
expect_error 'строка 7: неверная календарная дата'
reject_text 'Оценка'
finish_case

start_case F4-06
printf 'A-06-23;AlekseevAA;2026-01-01;4;4;лишнее\n' >> "$data/$circus/tests/TEST-2"
menu 1 4 2026 0
expect_error 'строка 7: неверный формат попытки тестирования'
finish_case

start_case F4-07
mv -- "$data/$circus/tests" "$case_dir/circus-tests"
mv -- "$data/$retakes/tests" "$case_dir/retakes-tests"
mkdir -- "$data/$retakes/tests"
: > "$data/$retakes/tests/.gitkeep"
menu 1 4 2026 0
expect_error 'В найденных предметах нет файлов тестов'
finish_case

start_case F4-08
# У двух попыток одна дата. Успешная запись стоит первой.
printf 'A-06-23;AlekseevAA;2026-05-01;4;4+\nA-06-23;AlekseevAA;2026-05-01;1;2' \
    > "$data/$circus/tests/TEST-2"
menu 1 4 2026 0
expect_table "$first_header" \
    "AlekseevAA|$circus|TEST-2|4" "BorisovBB|$retakes|TEST-1|5" "SokolovSS|$retakes|TEST-1|3" \
    "DenisovDD|$circus|TEST-1|3" "SokolovSS|$retakes|TEST-1|3" "SokolovSS|$circus|TEST-1|5"
finish_case

start_case F4-09
printf 'A-06-23;AlekseevAA;2026-06-01;5;5\n' > "$data/$retakes/tests/TEST-5"
menu 1 4 2026 0
table_rows "$first_header" | grep -Fx "AlekseevAA|$retakes|TEST-5|5" >/dev/null ||
    fail 'Файл за пределами первых четырёх тестов пропущен.'
finish_case

start_case F4-10
menu 1 4 2025 0
expect_table "$first_header" "DenisovDD|$retakes|TEST-4|4"
finish_case

start_case F4-11
mkdir -p -- "$data/Лабораторный практикум/tests"
printf 'A-06-23;AntonovAV;2026-06-01;4;4+\n' > "$data/Лабораторный практикум/tests/Зачёт 1"
menu 1 4 2026 0
table_rows "$first_header" | grep -Fx 'AntonovAV|Лабораторный практикум|Зачёт 1|4' >/dev/null ||
    fail 'В отчёте нет первой попытки по дополнительному предмету.'
finish_case

start_case F4-12
printf 'A-06-23;AntonovAV;2026-05-10;5;5\nA-06-23;AntonovAV;2026-05-01;3;3--\n' \
    > "$data/$circus/tests/TEST-3"
menu 1 4 2026 0
expect_rows "AntonovAV|$circus|TEST-3|3" < <(table_rows "$first_header" | grep -F 'AntonovAV|')
finish_case

if [[ ${1-} == --real ]]; then
    # В исходном наборе группа A-06-22 идёт под номером 19, Цирковое дело — 2.
    start_case R-01 real
    menu 1 1 19 2 0
    expect_text '19. A-06-22'
    expect_table "$attendance_header" 'PereskokovDS|17' 'DrozdovSA|16' 'BelousYY|15' 'SenkovskyaIY|15' \
        'UbskyAN|15' 'BatayevAI|14' 'BelogolovskyAA|13' 'BarsukovVV|12' 'ChesnokovDY|12' \
        'GalustianAA|12' 'KorablevNS|11' 'KukushkinAM|11' 'IsmailovTAid|10' 'SazonovAD|9'
    finish_case

    start_case R-02 real
    menu 1 2 19 1 4 0
    expect_table "$failed_header" 'PereskokovDS|Не сдал'
    finish_case

    start_case R-03 real
    menu 1 3 5 0
    mapfile -t ranks < <(table_rows "$top_header" | grep -E '^[0-9]+\|')
    [[ ${#ranks[@]} -eq 5 && ${ranks[0]-} == '1|KozlovskyE|A-06-04|4.75|4' ]] ||
        fail 'Ожидались пять мест и KozlovskyE с 4.75 на первом месте.'
    finish_case

    start_case R-04 real
    menu 1 4 2026 0
    mapfile -t first_rows < <(table_rows "$first_header")
    [[ ${#first_rows[@]} -eq 207 ]] || fail "Ожидались 207 строк, получено ${#first_rows[@]}."
    printf '%s\n' "${first_rows[@]}" | grep -Fx 'GroshevAV|Пересдачеведение|TEST-1|5' >/dev/null ||
        fail 'В отчёте нет контрольной первой попытки.'
    finish_case
fi

printf 'Итого: PASS=%d FAIL=%d SKIP=%d\n' "$passed" "$failed" "$skipped"
((failed == 0))
