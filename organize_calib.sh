#!/bin/bash

# Скрипт для организации калибровочных данных камер
# Рекурсивно сканирует папки, находит файлы калибровки по серийному номеру камеры
# и создает структуру: CAMSN/calib_CAMSN_DATE.txt и CAMSN/SRC/ с остальными файлами

set -e

SOURCE_DIR=""
OUTPUT_DIR=""
ARCHIVE_DIR=""
FILE_ACTION=""
DRY_RUN=false
DEBUG=false

usage() {
    echo "Использование: $0 --in <путь> (--copy|--move) [--out <путь>] [--arc <путь>] [--dry-run] [--debug]"
    echo "  --in <путь>   - обязательно, исходная папка для сканирования"
    echo "  --copy        - обязательно (одно из двух), копировать найденные файлы в выходную папку"
    echo "  --move        - обязательно (одно из двух), перемещать найденные файлы в выходную папку"
    echo "  --out <путь>  - опционально, куда складывать результаты."
    echo "                  Если не указано, создается папка CAMS_CALIB рядом с исходной."
    echo "  --arc <путь>  - опционально, корневая папка архива проектов."
    echo "                  Если рядом с калибровкой нет *.bmp, project.txt и project.bin,"
    echo "                  файлы ищутся в подпапке <архив>/<серийный_номер>/."
    echo "  --dry-run     - показать, что будет сделано, без реальных изменений"
    echo "  --debug       - включить подробный вывод отладочной информации"
}

# Проверка аргументов
if [ $# -lt 1 ]; then
    usage
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --in)
            if [ -z "${2:-}" ] || [[ "$2" == --* ]]; then
                echo "Ошибка: --in требует путь" >&2
                exit 1
            fi
            if [ -n "$SOURCE_DIR" ]; then
                echo "Ошибка: --in указан повторно" >&2
                exit 1
            fi
            SOURCE_DIR="$2"
            shift 2
            ;;
        --out)
            if [ -z "${2:-}" ] || [[ "$2" == --* ]]; then
                echo "Ошибка: --out требует путь" >&2
                exit 1
            fi
            if [ -n "$OUTPUT_DIR" ]; then
                echo "Ошибка: --out указан повторно" >&2
                exit 1
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --arc)
            if [ -z "${2:-}" ] || [[ "$2" == --* ]]; then
                echo "Ошибка: --arc требует путь" >&2
                exit 1
            fi
            if [ -n "$ARCHIVE_DIR" ]; then
                echo "Ошибка: --arc указан повторно" >&2
                exit 1
            fi
            ARCHIVE_DIR="$2"
            shift 2
            ;;
        --copy)
            if [ -n "$FILE_ACTION" ]; then
                echo "Ошибка: --copy и --move взаимоисключающие" >&2
                exit 1
            fi
            FILE_ACTION="copy"
            shift
            ;;
        --move)
            if [ -n "$FILE_ACTION" ]; then
                echo "Ошибка: --copy и --move взаимоисключающие" >&2
                exit 1
            fi
            FILE_ACTION="move"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            echo "Режим сухого запуска (без реальных изменений)"
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Ошибка: неизвестный аргумент '$1'" >&2
            usage
            exit 1
            ;;
    esac
done

if [ -z "$SOURCE_DIR" ]; then
    echo "Ошибка: обязательный параметр --in не указан" >&2
    usage
    exit 1
fi

if [ -z "$FILE_ACTION" ]; then
    echo "Ошибка: обязательный параметр --copy или --move не указан" >&2
    usage
    exit 1
fi

SOURCE_DIR="${SOURCE_DIR%/}"

# Если выходная папка не указана, используем папку CAMS_CALIB рядом с исходной
if [ -z "$OUTPUT_DIR" ]; then
    PARENT_DIR=$(dirname "$SOURCE_DIR")
    OUTPUT_DIR="$PARENT_DIR/CAMS_CALIB"
fi

OUTPUT_DIR="${OUTPUT_DIR%/}"
if [ -n "$ARCHIVE_DIR" ]; then
    ARCHIVE_DIR="${ARCHIVE_DIR%/}"
fi

# Проверка существования исходной директории
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Ошибка: Директория '$SOURCE_DIR' не существует"
    exit 1
fi

if [ -n "$ARCHIVE_DIR" ] && [ ! -d "$ARCHIVE_DIR" ]; then
    echo "Ошибка: Директория архива проектов '$ARCHIVE_DIR' не существует"
    exit 1
fi

# Текущая дата — запасной вариант, если stat недоступен
CURRENT_DATE=$(date +%Y%m%d)

# Счётчики для итоговой статистики
CALIB_FILES_FOUND=0
declare -A UNIQUE_CAMERAS=()
declare -A CAMERAS_WITH_SRC=()

# Копирует или перемещает файл в зависимости от FILE_ACTION
transfer_file() {
    local src="$1"
    local dest="$2"

    if [ "$DRY_RUN" = true ]; then
        if [ "$FILE_ACTION" = "move" ]; then
            echo "  [DRY-RUN] mv $src $dest"
        else
            echo "  [DRY-RUN] cp $src $dest"
        fi
        return
    fi

    if [ "$FILE_ACTION" = "move" ]; then
        mv "$src" "$dest"
    else
        cp "$src" "$dest"
    fi
}

# Текст для отладочного сообщения о переносе файла
transfer_action_label() {
    if [ "$FILE_ACTION" = "move" ]; then
        echo "Перемещён"
    else
        echo "Скопирован"
    fi
}

# Функция для получения даты последнего изменения файла в формате YYYYMMDD
get_file_mod_date() {
    local file="$1"
    # Получаем дату изменения в формате YYYY-MM-DD HH:MM:SS и извлекаем только дату
    local mod_date
    mod_date=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1 | tr -d '-')
    echo "${mod_date:-$CURRENT_DATE}"
}

# Функция для проверки, является ли строка строкой калибровки
# Строка калибровки должна заканчиваться серийным номером (набор букв и цифр)
is_calibration_line() {
    local line="$1"
    # Проверяем формат: много чисел с плавающей точкой, затем два целых (размеры), затем серийник
    # Пример: "10148.78... 2448 2048 FAM23010016"
    if [[ $line =~ ^[0-9\.\-]+\ +[0-9\.\-]+\ +[0-9\.\-]+\ +[0-9\.\-]+\ +[0-9\.\-]+\ +[0-9\.\-]+\ +[0-9\.\-]+\ +[0-9\.\-]+\ +[0-9\.\-]+\ +[0-9\.\-]+\ +[0-9\.\-]+\ +[0-9\.\-]+\ +[0-9]+\ +[0-9]+\ +[A-Za-z0-9]+\ *$ ]]; then
        return 0
    fi
    return 1
}

# Функция для извлечения серийного номера из строки калибровки
get_camera_sn() {
    local line="$1"
    # Извлекаем последнее слово (серийный номер)
    echo "$line" | awk '{print $NF}'
}

# Проверка наличия SRC-файлов (*.bmp, project.txt, project.bin) в указанной папке
local_dir_has_src_files() {
    local dir="$1"

    shopt -s nullglob
    local bmps=("$dir"/*.bmp)
    shopt -u nullglob

    if [ ${#bmps[@]} -gt 0 ]; then
        return 0
    fi
    if [ -f "$dir/project.txt" ] || [ -f "$dir/project.bin" ]; then
        return 0
    fi
    return 1
}

# Собирает пути SRC-файлов из указанной папки в массив files_to_copy
collect_src_files_from_dir() {
    local search_dir="$1"

    shopt -s nullglob
    for bmp_file in "$search_dir"/*.bmp; do
        if [ -f "$bmp_file" ]; then
            files_to_copy+=("$bmp_file")
        fi
    done
    shopt -u nullglob

    if [ -f "$search_dir/project.txt" ]; then
        files_to_copy+=("$search_dir/project.txt")
    fi
    if [ -f "$search_dir/project.bin" ]; then
        files_to_copy+=("$search_dir/project.bin")
    fi
}

# Функция для обработки файла
process_file() {
    local file="$1"
    local filename=$(basename "$file")
    
    # Пропускаем скрытые файлы
    if [[ "$filename" == .* ]]; then
        return
    fi
    
    # Пытаемся найти строку калибровки в файле
    local camera_sn=""
    local is_calib_file=false
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Удаляем ведущие и конечные пробелы
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [ -n "$line" ] && is_calibration_line "$line"; then
            camera_sn=$(get_camera_sn "$line")
            is_calib_file=true
            break
        fi
    done < "$file"
    
    if [ "$is_calib_file" = true ] && [ -n "$camera_sn" ]; then
        CALIB_FILES_FOUND=$((CALIB_FILES_FOUND + 1))
        UNIQUE_CAMERAS["$camera_sn"]=1

        echo "Найден файл калибровки: $file (Камера: $camera_sn)"

        # Создаем целевую папку для камеры в OUTPUT_DIR
        local target_dir="$OUTPUT_DIR/$camera_sn"
        local src_dir="$target_dir/SRC"

        if [ "$DRY_RUN" = false ]; then
            mkdir -p "$src_dir"
            if [ "$DEBUG" = true ]; then
                echo "  Создана папка камеры: $target_dir"
                echo "  Создана папка SRC: $src_dir"
            fi
        else
            echo "  [DRY-RUN] mkdir -p $target_dir"
            echo "  [DRY-RUN] mkdir -p $src_dir"
        fi

        # Получаем дату последнего изменения файла калибровки
        local file_mod_date
        file_mod_date=$(get_file_mod_date "$file")

        # Имя файла калибровки с датой изменения файла
        local calib_filename="calib_${camera_sn}_${file_mod_date}.txt"
        local target_calib="$target_dir/$calib_filename"

        # Переносим файл калибровки в целевую папку
        transfer_file "$file" "$target_calib"
        if [ "$DRY_RUN" = false ] && [ "$DEBUG" = true ]; then
            echo "  $(transfer_action_label) файл калибровки: $calib_filename"
        fi
        
        # Находим SRC-файлы рядом с калибровкой или в архиве проектов
        local parent_dir
        parent_dir=$(dirname "$file")
        local files_to_copy=()

        if local_dir_has_src_files "$parent_dir"; then
            collect_src_files_from_dir "$parent_dir"
        elif [ -n "$ARCHIVE_DIR" ]; then
            local archive_subdir="$ARCHIVE_DIR/$camera_sn"
            if [ -d "$archive_subdir" ]; then
                echo "  SRC не найдены рядом с калибровкой, берём из архива: $archive_subdir"
                collect_src_files_from_dir "$archive_subdir"
            else
                echo "  Предупреждение: SRC не найдены локально, папка архива отсутствует: $archive_subdir" >&2
            fi
        elif [ "$DEBUG" = true ]; then
            echo "  SRC не найдены рядом с калибровкой, архив проектов не указан"
        fi

        # Переносим найденные файлы в SRC
        for other_file in "${files_to_copy[@]}"; do
            local other_filename=$(basename "$other_file")

            # Пропускаем сам файл калибровки
            if [ "$other_file" == "$file" ]; then
                continue
            fi

            CAMERAS_WITH_SRC["$camera_sn"]=1
            transfer_file "$other_file" "$src_dir/"
            if [ "$DRY_RUN" = false ] && [ "$DEBUG" = true ]; then
                echo "  $(transfer_action_label) файл в SRC: $other_filename"
            fi
        done
        
    fi
}

echo "Начинаю сканирование директории: $SOURCE_DIR"
echo "Выходная директория: $OUTPUT_DIR"
if [ "$FILE_ACTION" = "move" ]; then
    echo "Режим: перемещение файлов"
else
    echo "Режим: копирование файлов"
fi
if [ -n "$ARCHIVE_DIR" ]; then
    echo "Архив проектов: $ARCHIVE_DIR"
fi

# Создаем выходную директорию если не dry-run
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$OUTPUT_DIR"
    echo "Создана выходная директория: $OUTPUT_DIR"
else
    echo "[DRY-RUN] mkdir -p $OUTPUT_DIR"
fi

echo ""

# Находим все файлы рекурсивно и обрабатываем их
if [ "$DEBUG" = true ]; then
    while IFS= read -r -d '' file; do
        echo "Проверка файла: $file"
        process_file "$file"
    done < <(find "$SOURCE_DIR" -type f -size -5k -print0)
else
    while IFS= read -r -d '' file; do
        process_file "$file"
    done < <(find "$SOURCE_DIR" -type f -size -5k -print0)
fi

UNIQUE_CAMERA_COUNT=${#UNIQUE_CAMERAS[@]}
CAMERAS_WITH_SRC_COUNT=${#CAMERAS_WITH_SRC[@]}

echo ""
echo "Обработка завершена!"
echo ""
echo "Найдено файлов калибровки всего: $CALIB_FILES_FOUND"
echo "Из них:"
echo "  уникальных камер: $UNIQUE_CAMERA_COUNT"
echo "  камер с исходниками: $CAMERAS_WITH_SRC_COUNT"
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "(Это был сухой запуск, реальные изменения не внесены)"
fi
