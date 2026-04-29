#!/usr/bin/env python3
"""
Скрипт для обработки калибровочных данных камер.

Ищет файлы калибровки во вложенных папках, извлекает серийный номер камеры,
создает структурированную папку с файлом калибровки и исходными данными.

Формат файла калибровки: строка с числами, где последнее слово - серийный номер камеры.
Пример: "10148.78 10148.78 1250.91 907.53 -0.33 13.59 -446.72 0.00 0.00 0.00 -0.002 -0.0004 2448 2048 FAM23010016"
"""

import os
import sys
import shutil
from datetime import datetime
from pathlib import Path


def find_calibration_files(root_path):
    """
    Рекурсивно находит все файлы калибровки в директории и поддиректориях.
    Файл калибровки определяется как файл, содержащий строку с серийным номером камеры
    (последнее слово в строке начинается с префикса, похожего на серийный номер).
    
    Возвращает список кортежей: (путь_к_файлу, серийный_номер, содержимое)
    """
    calibration_data = []
    
    for dirpath, dirnames, filenames in os.walk(root_path):
        # Пропускаем уже созданные папки с серийными номерами
        if any(part.startswith('CAM') or part.startswith('FAM') for part in dirpath.split(os.sep)):
            continue
            
        for filename in filenames:
            filepath = os.path.join(dirpath, filename)
            
            try:
                with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read().strip()
                    
                # Проверяем каждую строку файла
                for line in content.split('\n'):
                    line = line.strip()
                    if not line:
                        continue
                    
                    parts = line.split()
                    if len(parts) >= 2:
                        # Последнее слово - потенциальный серийный номер
                        serial_number = parts[-1]
                        
                        # Проверяем, похоже ли это на серийный номер камеры
                        # Обычно содержит буквы и цифры, длина от 5 символов
                        if (len(serial_number) >= 5 and 
                            any(c.isalpha() for c in serial_number) and
                            any(c.isdigit() for c in serial_number)):
                            
                            calibration_data.append({
                                'filepath': filepath,
                                'serial_number': serial_number,
                                'content': line,
                                'parent_dir': dirpath
                            })
                            break  # Берем первую подходящую строку как калибровку
                            
            except Exception as e:
                print(f"Предупреждение: Не удалось прочитать файл {filepath}: {e}")
                continue
    
    return calibration_data


def organize_calibration_data(root_path, dry_run=False):
    """
    Организует калибровочные данные согласно требованиям:
    - Создает папку с серийным номером камеры
    - Помещает файл калибровки с именем calib_CAMSN_DATE.txt
    - Все остальные файлы помещает в подпапку SRC
    
    Args:
        root_path: Путь к родительской папке с калибровочными данными
        dry_run: Если True, только показывает что будет сделано без реальных изменений
    """
    
    current_date = datetime.now().strftime('%Y%m%d')
    
    print(f"Поиск файлов калибровки в: {root_path}")
    print(f"Текущая дата для именования файлов: {current_date}")
    print("-" * 60)
    
    calibration_files = find_calibration_files(root_path)
    
    if not calibration_files:
        print("Файлы калибровки не найдены!")
        return
    
    print(f"Найдено файлов калибровки: {len(calibration_files)}")
    print("-" * 60)
    
    # Группируем файлы по серийным номерам
    serial_groups = {}
    for calib_info in calibration_files:
        sn = calib_info['serial_number']
        if sn not in serial_groups:
            serial_groups[sn] = []
        serial_groups[sn].append(calib_info)
    
    # Обрабатываем каждую группу
    for serial_number, files in serial_groups.items():
        print(f"\nОбработка камеры: {serial_number}")
        
        # Создаем имя папки и файла калибровки
        camera_folder = os.path.join(root_path, serial_number)
        calib_filename = f"calib_{serial_number}_{current_date}.txt"
        calib_filepath = os.path.join(camera_folder, calib_filename)
        src_folder = os.path.join(camera_folder, 'SRC')
        
        if dry_run:
            print(f"  [DRY RUN] Создать папку: {camera_folder}")
            print(f"  [DRY RUN] Создать файл калибровки: {calib_filepath}")
            print(f"  [DRY RUN] Создать папку SRC: {src_folder}")
            for file_info in files:
                parent_files = os.listdir(file_info['parent_dir'])
                for f in parent_files:
                    src_path = os.path.join(src_folder, f)
                    print(f"  [DRY RUN] Переместить: {os.path.join(file_info['parent_dir'], f)} -> {src_path}")
            continue
        
        # Создаем папку камеры
        os.makedirs(camera_folder, exist_ok=True)
        print(f"  ✓ Создана папка: {camera_folder}")
        
        # Записываем файл калибровки
        with open(calib_filepath, 'w') as f:
            f.write(files[0]['content'] + '\n')
        print(f"  ✓ Создан файл калибровки: {calib_filename}")
        
        # Создаем папку SRC
        os.makedirs(src_folder, exist_ok=True)
        print(f"  ✓ Создана папка SRC: {src_folder}")
        
        # Собираем все файлы из исходных папок для этой камеры
        copied_files = set()
        for file_info in files:
            parent_dir = file_info['parent_dir']
            
            try:
                for filename in os.listdir(parent_dir):
                    src_path = os.path.join(parent_dir, filename)
                    
                    # Пропускаем, если это файл калибровки (уже обработан)
                    if filename == os.path.basename(file_info['filepath']):
                        continue
                    
                    # Пропускаем, если это директория
                    if os.path.isdir(src_path):
                        continue
                    
                    dst_path = os.path.join(src_folder, filename)
                    
                    # Избегаем дублирования имен файлов
                    if filename in copied_files:
                        base, ext = os.path.splitext(filename)
                        counter = 1
                        while f"{base}_{counter}{ext}" in copied_files:
                            counter += 1
                        new_filename = f"{base}_{counter}{ext}"
                        dst_path = os.path.join(src_folder, new_filename)
                        filename = new_filename
                    
                    shutil.copy2(src_path, dst_path)
                    copied_files.add(filename)
                    print(f"  ✓ Скопирован: {filename}")
                    
            except Exception as e:
                print(f"  ✗ Ошибка при копировании файлов из {parent_dir}: {e}")
        
        print(f"  Итого скопировано файлов в SRC: {len(copied_files)}")
    
    print("\n" + "=" * 60)
    print("Обработка завершена!")


def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Организация калибровочных данных камер',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Пример использования:
  python organize_calib.py /path/to/calibration/data
  python organize_calib.py /path/to/calibration/data --dry-run
  
Структура после выполнения:
  parent_folder/
  ├── CAMSERIAL123/
  │   ├── calib_CAMSERIAL123_20250101.txt
  │   └── SRC/
  │       ├── photo1.jpg
  │       ├── project.xml
  │       └── ...
  └── FAM23010016/
      ├── calib_FAM23010016_20250101.txt
      └── SRC/
          └── ...
        """
    )
    
    parser.add_argument('root_path', help='Путь к родительской папке с калибровочными данными')
    parser.add_argument('--dry-run', action='store_true', 
                       help='Показать что будет сделано без реальных изменений')
    
    args = parser.parse_args()
    
    if not os.path.isdir(args.root_path):
        print(f"Ошибка: Директория '{args.root_path}' не существует!")
        sys.exit(1)
    
    organize_calibration_data(args.root_path, dry_run=args.dry_run)


if __name__ == '__main__':
    main()
