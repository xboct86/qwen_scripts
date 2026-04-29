#!/bin/bash

# Скрипт для организации калибровочных данных камер
# Рекурсивно сканирует папки, находит файлы калибровки по серийному номеру камеры
# и создает структуру: CAMSN/calib_CAMSN_DATE.txt и CAMSN/SRC/ с остальными файлами

set -e

# Проверка аргументов
if [ $# -lt 1 ]; then
    echo "Использование: $0 <путь_к_родительской_папке> [--dry-run]"
    echo "  --dry-run - показать, что будет сделано, без реальных изменений"
    exit 1
fi

SOURCE_DIR="$1"
DRY_RUN=false

if [ "$2" == "--dry-run" ]; then
    DRY_RUN=true
    echo "Режим сухого запуска (без реальных изменений)"
fi

# Проверка существования исходной директории
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Ошибка: Директория '$SOURCE_DIR' не существует"
    exit 1
fi

# Получение текущей даты в формате YYYYMMDD
CURRENT_DATE=$(date +%Y%m%d)

# Временный файл для отслеживания обработанных файлов калибровки
declare -A PROCESSED_CALIB_FILES

# Функция для проверки, является ли строка строкой калибровки
# Строка калибровки должна заканчиваться серийным номером (набор букв и цифр)
is_calibration_line() {
    local line="$1"
    # Проверяем формат: числа в начале, серийный номер (буквы+цифры) в конце
    # Пример: "10148.78... 2448 2048 FAM23010016 "
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
    local dir=$(dirname "$file")
    
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
        
        # Создаем целевую папку для камеры
        local target_dir="$SOURCE_DIR/$camera_sn"
        local src_dir="$target_dir/SRC"
        
        if [ "$DRY_RUN" = false ]; then
            mkdir -p "$target_dir"
            mkdir -p "$src_dir"
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
        else
            echo "  [DRY-RUN] cp $file $target_calib"
        fi
        
        # Находим все остальные файлы в той же папке (кроме файлов калибровки)
        # и копируем их в SRC
        local parent_dir=$(dirname "$file")
        for other_file in "$parent_dir"/*; do
            if [ -f "$other_file" ]; then
                local other_filename=$(basename "$other_file")
                
                # Пропускаем скрытые файлы
                if [[ "$other_filename" == .* ]]; then
                    continue
                fi
                
                # Пропускаем сам файл калибровки (если он уже обработан)
                if [ "$other_file" == "$file" ]; then
                    continue
                fi
                
                # Проверяем, не является ли другой файл тоже файлом калибровки
                local other_is_calib=false
                while IFS= read -r other_line || [ -n "$other_line" ]; do
                    other_line=$(echo "$other_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    if [ -n "$other_line" ] && is_calibration_line "$other_line"; then
                        other_is_calib=true
                        break
                    fi
                done < "$other_file"
                
                if [ "$other_is_calib" = false ]; then
                    # Это не файл калибровки, копируем в SRC
                    if [ "$DRY_RUN" = false ]; then
                        cp "$other_file" "$src_dir/"
                    else
                        echo "  [DRY-RUN] cp $other_file $src_dir/"
                    fi
                fi
            fi
        done
        
        # Помечаем файл как обработанный
        PROCESSED_CALIB_FILES["$file"]=1
    fi
}

echo "Начинаю сканирование директории: $SOURCE_DIR"
echo "Текущая дата: $CURRENT_DATE"
echo ""

# Находим все файлы рекурсивно (исключая файлы > 1 КБ) и обрабатываем их
while IFS= read -r -d '' file; do
    echo "Проверка файла: $file"
    process_file "$file"
done < <(find "$SOURCE_DIR" -type f -size -1k -print0)

echo ""
echo "Обработка завершена!"

if [ "$DRY_RUN" = true ]; then
    echo "(Это был сухой запуск, реальные изменения не внесены)"
fi
