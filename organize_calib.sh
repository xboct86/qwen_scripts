#!/bin/bash

# Скрипт для организации калибровочных данных камер
# Рекурсивно сканирует папки, находит файлы калибровки по серийному номеру камеры
# и создает структуру: CAMSN/calib_CAMSN_DATE.txt и CAMSN/SRC/ с остальными файлами

set -e

# Проверка аргументов
if [ $# -lt 1 ]; then
    echo "Использование: $0 <путь_к_родительской_папке> [путь_к_выходной_папке] [--dry-run]"
    echo "  путь_к_выходной_папке - опционально, куда складывать результаты."
    echo "                        Если не указано, создается папка CAMS_CALIB рядом с исходной."
    echo "  --dry-run           - показать, что будет сделано, без реальных изменений"
    exit 1
fi

SOURCE_DIR="$1"
OUTPUT_DIR=""
DRY_RUN=false

# Нормализация пути (убираем конечный слэш, если есть, для корректной работы dirname)
SOURCE_DIR="${SOURCE_DIR%/}"

# Обработка остальных аргументов
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            echo "Режим сухого запуска (без реальных изменений)"
            shift
            ;;
        *)
            if [ -z "$OUTPUT_DIR" ]; then
                OUTPUT_DIR="$1"
            fi
            shift
            ;;
    esac
done

# Если выходная папка не указана, используем папку CAMS_CALIB рядом с исходной
if [ -z "$OUTPUT_DIR" ]; then
    PARENT_DIR=$(dirname "$SOURCE_DIR")
    OUTPUT_DIR="$PARENT_DIR/CAMS_CALIB"
fi

# Проверка существования исходной директории
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Ошибка: Директория '$SOURCE_DIR' не существует"
    exit 1
fi

# Получение текущей даты в формате YYYYMMDD
CURRENT_DATE=$(date +%Y%m%d)

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
        # Это файл калибровки
        echo "Найден файл калибровки: $file (Камера: $camera_sn)"
        
        # Создаем целевую папку для камеры в OUTPUT_DIR
        local target_dir="$OUTPUT_DIR/$camera_sn"
        local src_dir="$target_dir/SRC"
        
        if [ "$DRY_RUN" = false ]; then
            mkdir -p "$target_dir"
            echo "  Создана папка камеры: $target_dir"
            mkdir -p "$src_dir"
            echo "  Создана папка SRC: $src_dir"
        else
            echo "  [DRY-RUN] mkdir -p $target_dir"
            echo "  [DRY-RUN] mkdir -p $src_dir"
        fi
        
        # Имя файла калибровки
        local calib_filename="calib_${camera_sn}_${CURRENT_DATE}.txt"
        local target_calib="$target_dir/$calib_filename"
        
        # Копируем файл калибровки в целевую папку
        if [ "$DRY_RUN" = false ]; then
            cp "$file" "$target_calib"
            echo "  Скопирован файл калибровки: $calib_filename"
        else
            echo "  [DRY-RUN] cp $file $target_calib"
        fi
        
        # Находим только определенные файлы в той же папке и копируем их в SRC
        local parent_dir=$(dirname "$file")
        
        # Массив имен файлов для копирования
        local files_to_copy=()
        
        # Ищем файлы вида D.bmp или DD.bmp (одна или две цифры)
        shopt -s nullglob
        for bmp_file in "$parent_dir"/*.bmp; do
            if [ -f "$bmp_file" ]; then
                local bmp_name=$(basename "$bmp_file")
                # Проверяем, что имя состоит из 1 или 2 цифр и .bmp
                if [[ "$bmp_name" =~ ^[0-9]{1,2}\.bmp$ ]]; then
                    files_to_copy+=("$bmp_file")
                fi
            fi
        done
        
        # Ищем project.txt
        if [ -f "$parent_dir/project.txt" ]; then
            files_to_copy+=("$parent_dir/project.txt")
        fi
        
        # Ищем project.bin
        if [ -f "$parent_dir/project.bin" ]; then
            files_to_copy+=("$parent_dir/project.bin")
        fi
        shopt -u nullglob
        
        # Копируем найденные файлы в SRC
        for other_file in "${files_to_copy[@]}"; do
            local other_filename=$(basename "$other_file")
            
            # Пропускаем сам файл калибровки
            if [ "$other_file" == "$file" ]; then
                continue
            fi
            
            if [ "$DRY_RUN" = false ]; then
                cp "$other_file" "$src_dir/"
                echo "  Скопирован файл в SRC: $other_filename"
            else
                echo "  [DRY-RUN] cp $other_file $src_dir/"
            fi
        done
        
    fi
}

echo "Начинаю сканирование директории: $SOURCE_DIR"
echo "Выходная директория: $OUTPUT_DIR"
echo "Текущая дата: $CURRENT_DATE"

# Создаем выходную директорию если не dry-run
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$OUTPUT_DIR"
    echo "Создана выходная директория: $OUTPUT_DIR"
else
    echo "[DRY-RUN] mkdir -p $OUTPUT_DIR"
fi

echo ""

# Находим все файлы рекурсивно и обрабатываем их
while IFS= read -r -d '' file; do
    echo "Проверка файла: $file"
    process_file "$file"
done < <(find "$SOURCE_DIR" -type f -print0)

echo ""
echo "Обработка завершена!"

if [ "$DRY_RUN" = true ]; then
    echo "(Это был сухой запуск, реальные изменения не внесены)"
fi
