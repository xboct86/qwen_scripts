#!/bin/bash
#
# Главный скрипт для распределения материалов, сформированных ПО, по папкам долгосрочного хранения и выгрузки
# - проверяет переопределение параметров выгрузки в ServiceDesk и вносит оперативные изменения в сервисы выгрузки
# - создаёт списки, кэш, логи для последующей работы
# - перемещает все найденные /home/comp1/ptolemey_out/tar_outp материалы в долгосрочное хранилище на ssd (/srv/tar_outp)
# - получает valid.txt из Андромеды для выгрузки с предобработкой
# - копирует все нарушения и проезды по установленныму проценту в папки выгрузки в Андромеду
# - копирует материалы, при необходимости - с учетом предобработки, в папки выгрузки:
#   - Duplo
#   - Doris
#   - локальный ftp server
#   - ftp client (с возможностью конвертирования формата материала)
# - копирует материалы КП в долгосрочное хранилище (/home/comp1/shared-files/kp_old) и папку выгрузки
#
# Копирование материалов происходит через жёсткую ссылку для уменьшения износа SSD


fldsync_version=1.20261020

# Эти переменные будут меняться с помощью script.sh
ANDROMEDA_MASTER_ENABLE=false
ANDROMEDA_SLAVE_ENABLE=false
ANDROMEDA_UPLOAD_PASSAGE=false
ANDROMEDA_UPLOAD_PERCENTAGE=0
ANDROMEDA_UPLOAD_OVERWEIGHT_NOT_REC=false
ANDROMEDA_VALID=(93.189.150.42 10.0.20.253:2201)
DORIS=false
DORIS_CONTROLLED=false
DORIS_SORT_OLDEST=false
DORIS_ONLY_FVF=false
DORIS_UPLOAD_PASSAGE=false
DUPLO=false
DUPLO_CONTROLLED=false
DUPLO_SORT_OLDEST=false
DUPLO_ONLY_FVF=false
DUPLO_UPLOAD_PASSAGE=false
DUPLO_UPLOAD_OVERWEIGHT_NOT_REC=false
FORTKA_ENABLE=false
FORTKA_UPLOAD_PASSAGE=false
FTP_CLIENT_ALL_IN_HEAP=false
FTP_CLIENT_CONTROLLED=false
FTP_CLIENT_ONLY_WEIGHT=false
FTP_CLIENT_UPLOAD_ENABLE=false
FTP_CLIENT_UPLOAD_OVERWEIGHT_NOT_REC=true
FTP_CLIENT_UPLOAD_PASSAGE=false
FTP_CLIENT_XML=false
FTP_SERVER_CONTROLLED=false
FTP_SERVER_ONLY_WEIGHT=false
FTP_SERVER_UPLOAD_DIRS=()
FTP_SERVER_UPLOAD_ENABLE=false
FTP_SERVER_UPLOAD_PASSAGE=false

CPS_INI="/opt/ptolemey/Complex/ProcessingServer/crossroad_server_properties.ini"
PROXY="http://apt-proxy.ptolemey.net:59008"
SD_TOKEN="1b5f2778274f7ce77afbf956c7c8c0e214f0bda4"
VGK_TAR_CONVERTER="/srv/tmp/vgk_tar_converter/VgkTarConverter.py"

# Корневые переменные, из которых формируются дочерние
controlled_upload_logs="/srv/tmp/logs"
diagdir="/var/log/ptolemey/script-diag"
hollowpoke_compose_dir="/usr/local/docker/hollowpoke"
logdir="/var/log/ptolemey"
temp_list_dir="/run/shm/fldsync_files"

# Дочерние и прочие переменные
andromeda_in_dir="/srv/tmp/tar_outp"
andromeda_slave_in_dir="/srv/tmp/tar_slave_outp"
diagfile="${diagdir}/fldsync.log"
doris_in_dir="/srv/tmp/doris/in"
doris_uploaded_log="${controlled_upload_logs}/doris_uploaded_"
doris_violations_in_dir="/srv/tmp/doris_violations/in"
doris_violations_out_dir="/srv/tmp/doris_violations/out"
duplo_in_dir="/srv/tmp/duplo/in"
duplo_uploaded_log="${controlled_upload_logs}/duplo_uploaded_"
duplo_violations_in_dir="/srv/tmp/duplo_violations/in"
duplo_violations_out_dir="/srv/tmp/duplo_violations/out"
fortka_in_dir="/srv/tmp/fortka/in"
fortka_violations_in_dir="/srv/tmp/fortka_violations/in"
fortka_violations_out_dir="/srv/tmp/fortka_violations/out"
ftp_client_in_dir="/srv/tmp/ftp_out"
ftp_client_uploaded_log="${controlled_upload_logs}/ftp_client_uploaded_"
ftp_server_in_dir="/srv/ftp"
ftp_server_uploaded_log="${controlled_upload_logs}/ftp_server_uploaded_"
hollowpoke_compose_file="${hollowpoke_compose_dir}/docker-compose.yml"
kp_in_dir="/srv/tmp/kp"
kp_longterm_dir="/home/comp1/shared-files/kp_old"
kp_source_dir="/home/comp1/shared-files/kp"
logfile="${logdir}/fldsync.log"
longterm_dir="/srv/tar_outp"
pidfile="/var/run/fldsync.pid"
source_dir="/home/comp1/ptolemey_out/tar_outp"
variables_file="/opt/ptolemey/complex-init/env/env"
zabbix_triggers_dir="/usr/local/complex-init"

Serial=$(cat $CPS_INI | grep 'deviceSerial' | awk {'print $3'}) #_valid.txt.bz2
valid_text="${Serial}_valid.txt"

_andromeda_upload_counter=0
_andromeda_slave_upload_counter=0
_duplo_upload_counter=0
_doris_upload_counter=0
_ftp_server_upload_counter=0
_ftp_client_upload_counter=0
_fortka_upload_counter=0
_longterm_upload_counter=0
_kp_upload_counter=0


# Используется в get_config_from_exteral_source()
restart_hollowpoke_compose(){
    cd "$hollowpoke_compose_dir"
    docker-compose down
    docker-compose up -d --remove-orphans
    cd - > /dev/null
}

# Используется в get_config_from_exteral_source(). Создаёт файл для триггера zabbix
function set_zabbix_trigger_file(){
    [[ ! -d "$zabbix_triggers_dir" ]] && mkdir -p "$zabbix_triggers_dir"

    if [[ -f "${zabbix_triggers_dir}/${1}" ]]; then
        local val="$(cat ${zabbix_triggers_dir}/${1})"
        if [[ "$val" != "$2" ]]; then
            echo "$2" > "${zabbix_triggers_dir}/${1}"
        fi
    else
        echo "$2" > "${zabbix_triggers_dir}/${1}"
    fi
}

# Получаем данные из SD о типе серийника для камер, проценте выгрузки проездов в Андромеду, и кастомном адресе для Паутины
function get_config_from_exteral_source(){

    rand=$(($RANDOM % 20))

    if [ "$rand" -ne 0 ]; then
        return
    fi

    echo "$(date +"%F %T") [$$]: Проверяем параметры выгрузки в ServiceDesk" | tee -a "$logfile"
    local deviceSerial=$(grep "deviceSerial" "$CPS_INI" | awk -F '=' '{print $2}' | xargs)

    if [[ -z "$deviceSerial" ]]; then
        echo "$(date +"%F %T") [$$]: Не удалось распарсить имя комплекса в cps.ini" | tee -a "$logfile"
        return
    fi

    local COMPLEX_URL="https://divisionlabs.okdesk.ru/api/v1/maintenance_entities/?api_token=${SD_TOKEN}&search_string=${deviceSerial}"
    local resp=$(curl -k --connect-timeout 10 -s "$COMPLEX_URL")
    if [[ $? -ne 0 ]] || [[ -z "$resp" ]]; then
        echo "$(date +"%F %T") [$$]: Проверка без прокси не прошла, пробуем через прокси." | tee -a "$logfile"
        local PROXY_CONFIG="--proxy $PROXY"
        local resp=$(curl -k --connect-timeout 10 -s $PROXY_CONFIG "$COMPLEX_URL")
        if [[ $? -ne 0 ]] || [[ -z "$resp" ]]; then
            echo "$(date +"%F %T") [$$]: ServiceDesk недоступен также через прокси. Отмена проверки" | tee -a "$logfile"
            return
        fi
    fi

    # Формируем локальные переменные из КЗ объекта
    local object_serial_value=$(echo "$resp" | jq -r '.[0].parameters[] | select(.code=="tip_serial_paytina") | .value')
    local custom_hollowpoke_value=$(echo "$resp" | jq -r '.[0].parameters[] | select(.code=="Web_upload_address") | .value')
    local object_percent=$(echo "$resp" | jq -r '.[0].parameters[] | select(.code=="Percentage_of_unloading_passages_to_Andromeda") | .value')

    # Определяем id главного договора
    # В SD у объекта могут быть несколько договоров. Какой номер больше - тот и главный
    local agreement_resps=()
    local agreement_ids=()
    local agreement_ids_numbers=()
    local AGREEMENT_URL agreement_resp agreement_number agreement_serial_value agreement_percent agreement_id serial_value percent
    local max_number=0
    local agreement_ids_str=$(echo "$resp" | jq -r '.[0].agreements[].id')
    mapfile -t agreement_ids <<< "$agreement_ids_str"

    for agreement_id in "${agreement_ids[@]}"; do
        AGREEMENT_URL="https://divisionlabs.okdesk.ru/api/v1/agreements/${agreement_id}?api_token=${SD_TOKEN}"
        agreement_resp=$(curl -k --connect-timeout 10 -s $PROXY_CONFIG "$AGREEMENT_URL")
        # Кэшируем в массив json'ы КЗ договоров для сокращения обращений к API
        agreement_resps+=( "$agreement_resp" )
        agreement_number=$(echo "$agreement_resp" | jq -r '.title' | cut -d'_' -f1 | sed 's/^ID//' | sed 's/^0*//')
        agreement_ids_numbers+=( "${agreement_id} ${agreement_number}" )
    done

    for i in "${agreement_ids_numbers[@]}"; do
        id=$(echo "$i" | cut -d' ' -f1)
        number=$(echo "$i" | cut -d' ' -f2)
        if (( number > max_number )); then
            max_number="$number"
            agreement_id="$id"
        fi
    done

    # Формируем локальные переменные из КЗ договора
    for agreement_resp in "${agreement_resps[@]}"; do
        agreement_id_to_check=$(echo "$agreement_resp" | jq -r '.id')
        if [[ "$agreement_id_to_check" == "$agreement_id" ]]; then
            agreement_serial_value=$(echo "$agreement_resp" | jq -r '.parameters[] | select(.code=="registration_on_the_Web") | .value')
            agreement_percent=$(echo "$agreement_resp" | jq -r '.parameters[] | select(.code=="Percentage_of_unloading_passages_to_Andromeda_id") | .value')
            break
        fi
    done

    # Устанавливаем тип серийника камер
    if [[ -n "$object_serial_value" ]] && [[ ! "$object_serial_value" =~ "з договора" ]]; then
        serial_value="$object_serial_value"
        echo "$(date +"%F %T") [$$]: Тип серийного номера камер из КЗ комплекса: ${serial_value}" | tee -a "$logfile"
    elif [[ -n "$agreement_serial_value" ]]; then
        serial_value="$agreement_serial_value"
        echo "$(date +"%F %T") [$$]: Тип серийного номера камер из КЗ договора: ${serial_value}" | tee -a "$logfile"
    else
        echo "$(date +"%F %T") [$$]: Тип серийного номера камер не найден, используем установленный в env" | tee -a "$logfile"
    fi

    # Изменяем тип серийника в compose файле и перезагружаем контейнер
    if [[ "$serial_value" =~ "изический" || \
        "$serial_value" =~ "етрологический" || \
        "$serial_value" =~ "ез номера" || \
        "$serial_value" =~ "олько система" ]] && \
        [[ "$DUPLO" == "true" || "$DORIS" == "true" ]]; then

        if [[ "$serial_value" =~ "ез номера" ]] && ! grep -q "DSNC=false" "$hollowpoke_compose_file"; then
            sed -i "s/- DSNC=.*/- DSNC=false/" "$hollowpoke_compose_file"
            cd "$hollowpoke_compose_dir"
            docker-compose down
            docker-compose up -d --remove-orphans
            cd - > /dev/null
        elif [[ "$serial_value" =~ "етрологический" ]]; then
            if ! grep -q "CIDS=tCameraSerial" "$hollowpoke_compose_file" || \
                ! grep -q "DSNC=true" "$hollowpoke_compose_file"; then
                sed -i "s/- CIDS=.*/- CIDS=tCameraSerial/" "$hollowpoke_compose_file"
                sed -i "s/- DSNC=.*/- DSNC=true/" "$hollowpoke_compose_file"
                restart_hollowpoke_compose
            fi
        elif [[ "$serial_value" =~ "изический" ]]; then
            if ! grep -q "CIDS=cameraIds" "$hollowpoke_compose_file" || \
                ! grep -q "DSNC=true" "$hollowpoke_compose_file"; then
                sed -i "s/- CIDS=.*/- CIDS=cameraIds/" "$hollowpoke_compose_file"
                sed -i "s/- DSNC=.*/- DSNC=true/" "$hollowpoke_compose_file"
                restart_hollowpoke_compose
            fi
        elif [[ "$serial_value" =~ "олько система" ]]; then
            if ! grep -q "CIDS=tDeviceSerial" "$hollowpoke_compose_file" || \
                ! grep -q "DSNC=true" "$hollowpoke_compose_file"; then
                sed -i "s/- CIDS=.*/- CIDS=tDeviceSerial/" "$hollowpoke_compose_file"
                sed -i "s/- DSNC=.*/- DSNC=true/" "$hollowpoke_compose_file"
                restart_hollowpoke_compose
            fi
        fi

        set_zabbix_trigger_file "cam_serial_type" "$serial_value"
    else
        # При ОТКЛЮЧЕНИИ переопределенных параметров через SD - запускем script.sh, чтобы правильно настроить всё заново
        if [[ -f "${zabbix_triggers_dir}/cam_serial_type" ]]; then
            cd /opt/ptolemey/complex-init/script && ./script.sh && cd - > /dev/null
        fi
    fi

    # Устанавливаем процент выгрузки проездов в Андромеду
    if [[ -n "$object_percent" ]] && [[ ! "$object_percent" =~ "з договора" ]]; then
        percent="$object_percent"
        echo "$(date +"%F %T") [$$]: Установлен процент выгрузки материалов в Андромеду из КЗ комплекса: ${percent}" | tee -a "$logfile"
    elif [[ -n "$agreement_percent" ]]; then
        percent="$agreement_percent"
        echo "$(date +"%F %T") [$$]: Установлен процент выгрузки материалов в Андромеду из КЗ договора: ${percent}" | tee -a "$logfile"
    fi

    # Устанавливаем значение для переменной ANDROMEDA_UPLOAD_PERCENTAGE в данном скрипте
    if [[ "$percent" =~ ^[0-9]+$ ]] && \
        [ "$percent" -ge 0 ] && \
        [ "$percent" -le 100 ] && \
        [ "$percent" -ne 0 ]; then
        if ! grep -q "^ANDROMEDA_UPLOAD_PERCENTAGE=${percent}" "$0"; then
            sed -i "1,/^ANDROMEDA_UPLOAD_PERCENTAGE=/s/^ANDROMEDA_UPLOAD_PERCENTAGE=.*/ANDROMEDA_UPLOAD_PERCENTAGE=${percent}/" "$0"
        fi

        if grep -q "^ANDROMEDA_UPLOAD_PASSAGE=false" "$0"; then
            sed -i "1,/^ANDROMEDA_UPLOAD_PASSAGE=/s/^ANDROMEDA_UPLOAD_PASSAGE=.*/ANDROMEDA_UPLOAD_PASSAGE=true/" "$0"
        fi

        if grep -q "^FORTKA_UPLOAD_PASSAGE=false" "$0"; then
            sed -i "1,/^FORTKA_UPLOAD_PASSAGE=/s/^FORTKA_UPLOAD_PASSAGE=.*/FORTKA_UPLOAD_PASSAGE=true/" "$0"
        fi

        set_zabbix_trigger_file "andromeda_upload_percentage" "$percent"
    else
        # При ОТКЛЮЧЕНИИ переопределенных параметров через SD - запускем script.sh, чтобы правильно настроить всё заново
        if [[ -f "${zabbix_triggers_dir}/andromeda_upload_percentage" ]]; then
            cd /opt/ptolemey/complex-init/script && ./script.sh && cd - > /dev/null
        fi
    fi

    # Устанавливаем кастомный адрес выгрузки в Паутину
    if [[ -n "$custom_hollowpoke_value" ]]; then
        echo "$(date +"%F %T") [$$]: Обнаружен кастомный адрес выгрузки в Паутину в КЗ комплекса: ${custom_hollowpoke_value}" | tee -a "$logfile"
        if ! grep -q "DUPLO=${custom_hollowpoke_value}" "$hollowpoke_compose_file" && \
            [[ "$DUPLO" == "true" || "$DORIS" == "true" ]]; then

            sed -i "s|- DUPLO=.*|- DUPLO=${custom_hollowpoke_value}|" "$hollowpoke_compose_file"
            restart_hollowpoke_compose
        fi

        set_zabbix_trigger_file "custom_hollowpoke_address" "$custom_hollowpoke_value"
    else
        # При ОТКЛЮЧЕНИИ переопределенных параметров через SD - запускем script.sh, чтобы правильно настроить всё заново
        if [[ -f "${zabbix_triggers_dir}/custom_hollowpoke_address" ]]; then
            cd /opt/ptolemey/complex-init/script && ./script.sh && cd - > /dev/null
        fi
    fi
}

# Создаём все необходимые каталоги
function create_dirs(){
    echo "$(date +"%F %T") [$$]: Убеждаемся что нужные директории созданы" | tee -a "$logfile"
    [ ! -d "$logdir" ] && mkdir -p "$logdir" && chown comp1:comp1 "$logdir"
    [ ! -d "$diagdir" ] && mkdir -p "$diagdir" && chown comp1:comp1 "$diagdir"
    [ ! -d "$controlled_upload_logs" ] && mkdir -p "$controlled_upload_logs" && chown comp1:comp1 "$controlled_upload_logs"
    [ ! -d "$temp_list_dir" ] && mkdir -p "$temp_list_dir" && chown comp1:comp1 "$temp_list_dir"
}

# Создаём списки проездов и нарушений на выгрузку
function prepare_file_list(){

    # Сортировка по времени создания
    if [[ "$DUPLO_SORT_OLDEST" == "true" ]] || [[ "$DORIS_SORT_OLDEST" == "true" ]]; then
        find "$source_dir" -name '*.tar' -size +0c -size -16M -type f -exec stat --printf '%n %Y\n' {} + | \
            sort -k2 -n | cut -d' ' -f1 | xargs -d '\n' stat --printf '%n %y\n' > "${temp_list_dir}/file_list_sorted.txt"
    fi

    # Списки всех материалов и КП в home/comp1/ptolemey_out/tar_outp
    #
    # !!! Обрати внимание !!! file_list.txt используется ТОЛЬКО ДЛЯ НОРМАЛЕЙ, НАРУШЕНИЙ, НАПРАВЛЯЕМЫХ В АНДРОМЕДУ, И НЕРАСПОЗНАННЫХ
    #
    # /home/comp1/ptolemey_out/tar_outp/normal/09a7a9bd03c34110bcbffa59740f1fdf.tar
    find "$source_dir" -name '*.tar' -size +0c -size -16M -type f > "${temp_list_dir}/file_list.txt"
    # /home/comp1/shared-files/kp/09a7a9bd03c34110bcbffa59740f1fdf.tar
    find "$kp_source_dir" -name '*.tar' -size +0c -size -16M -type f > "${temp_list_dir}/kp_list.txt"

    if [ ! -f "$temp_list_dir/file_list.txt" ]; then
        echo "$(date +"%F %T") [$$]: Не удалось создать список файлов, возможно файловая система в RO" | tee -a "$logfile"
        exit 1
    fi

    # Проверка на актуальности списка файлов
    current_time=$(date +%s)
    file_mod_time=$(stat -c %Y "$temp_list_dir/file_list.txt")
    time_diff=$((current_time - file_mod_time))

    if [ $time_diff -gt 30 ]; then
        echo "$(date +"%F %T") [$$]: Список файлов для выгрузки создался слишком давно, возможно файловая система в RO" | tee -a "$logfile"
        exit 1
    fi

    # !!! Обрати внимание !!! Нормали включают в себя также нераспознанные по оптике и нераспознанные ВГК без radar_unrecognized
    #
    # Нормали при сортировке по времени
    if [[ "$DUPLO_SORT_OLDEST" == "true" ]] || [[ "$DORIS_SORT_OLDEST" == "true" ]]; then
        grep -P "normal|not_rec" "${temp_list_dir}/file_list_sorted.txt" | awk '{print $1}' > "${temp_list_dir}/normal_files_sorted.txt"
    fi

    # Нормали в /home/comp1/ptolemey_out/tar_outp/normal/
    grep -P "normal|not_rec" "${temp_list_dir}/file_list.txt" > "${temp_list_dir}/normal_files.txt"

    # overweight_not_rec по пути матчит not_rec и попадает в проезды.
    # При выгрузке как нарушений — исключаем из списков проездов, чтобы не дублировать.
    if [[ "$ANDROMEDA_UPLOAD_OVERWEIGHT_NOT_REC" == "true" ]] || \
        [[ "$DUPLO_UPLOAD_OVERWEIGHT_NOT_REC" == "true" ]]; then
        grep -v "overweight_not_rec" "${temp_list_dir}/normal_files.txt" > "${temp_list_dir}/normal_files.txt.tmp" && \
            mv "${temp_list_dir}/normal_files.txt.tmp" "${temp_list_dir}/normal_files.txt"
        if [[ -f "${temp_list_dir}/normal_files_sorted.txt" ]]; then
            grep -v "overweight_not_rec" "${temp_list_dir}/normal_files_sorted.txt" > "${temp_list_dir}/normal_files_sorted.txt.tmp" && \
                mv "${temp_list_dir}/normal_files_sorted.txt.tmp" "${temp_list_dir}/normal_files_sorted.txt"
        fi
    fi

    # Нарушения для Андромеды из /home/comp1/ptolemey_out/tar_outp/
    grep -v "normal" "${temp_list_dir}/file_list.txt" | \
        grep -v "not_rec" | \
        grep -v "radar_unrecognized" | \
        grep -v "test_violations" > "${temp_list_dir}/violations_andromeda_files.txt"
    # overweight_not_rec как нарушения для Андромеды/Fortka
    if [[ "$ANDROMEDA_UPLOAD_OVERWEIGHT_NOT_REC" == "true" ]]; then
        grep "overweight_not_rec" "${temp_list_dir}/file_list.txt" >> "${temp_list_dir}/violations_andromeda_files.txt" || true
    fi

    # Все нарушения в долгосрочном хранилище за 30 дней: материалы без нормалей, нераспознанных и test_violations
    #
    # !!! Обрати внимание !!! violations_files.txt используется ТОЛЬКО ДЛЯ ВЫГРУЗКИ С ПРЕДОБРАБОТКОЙ (НЕ В АНДРОМЕДУ)
    #
    # При DUPLO_UPLOAD_OVERWEIGHT_NOT_REC overweight_not_rec не prune — кандидат нарушений для Duplo
    local prune_paths=(
        "${longterm_dir}/normal"
        "${longterm_dir}/radar_unrecognized"
        "${longterm_dir}/not_recognized"
        "${longterm_dir}/normal_weight"
        "${longterm_dir}/test_violations"
    )
    if [[ "$DUPLO_UPLOAD_OVERWEIGHT_NOT_REC" != "true" ]]; then
        prune_paths+=("${longterm_dir}/overweight_not_rec")
    fi

    local find_prune=()
    local p
    for p in "${prune_paths[@]}"; do
        if [[ ${#find_prune[@]} -eq 0 ]]; then
            find_prune+=( -path "$p" )
        else
            find_prune+=( -o -path "$p" )
        fi
    done

    find "$longterm_dir" -type d \
        \( "${find_prune[@]}" \) -prune \
        -o -type f -mtime -30 -size +0c -name "*.tar" -print > "${temp_list_dir}/violations_files.txt"

    # Фильтр материалов ВГК для ftp
    if [[ "$FTP_SERVER_ONLY_WEIGHT" == "true" ]] || [[ "$FTP_CLIENT_ONLY_WEIGHT" == "true" ]]; then
        if [[ "$FTP_CLIENT_UPLOAD_OVERWEIGHT_NOT_REC" == "false" ]]; then
            # Только нормали ВГК
            grep "weight" "${temp_list_dir}/file_list.txt" | grep -P "normal" > "${temp_list_dir}/normal_weight_files.txt"
        else
            # Нормали и нераспознанные ВГК
            grep "weight" "${temp_list_dir}/file_list.txt" | grep -P "normal|not_rec" > "${temp_list_dir}/normal_weight_files.txt"
        fi
        # Нарушения ВГК
        grep "weight" "${temp_list_dir}/violations_files.txt" > "${temp_list_dir}/violations_weight_files.txt"
    fi

    # Фильтр материалов ФВФ для duplo/doris (без нераспознанных)
    if [[ "$DUPLO_ONLY_FVF" == "true" ]] || [[ "$DORIS_ONLY_FVF" == "true" ]]; then
        # Нормали и нераспознанные ФВФ и ВГК (на комплексах ВГК все нормали с распознанным весом летят в normal_weight)
        cat "${temp_list_dir}/normal_files.txt" > "${temp_list_dir}/normal_fvf_files.txt"
        # Нарушения ФВФ
        grep -v "weight" "${temp_list_dir}/violations_files.txt" > "${temp_list_dir}/violations_fvf_files.txt"
        # Для Duplo: overweight_not_rec содержит weight в пути и иначе отсекается ONLY_FVF
        if [[ "$DUPLO_UPLOAD_OVERWEIGHT_NOT_REC" == "true" ]]; then
            cat "${temp_list_dir}/violations_fvf_files.txt" > "${temp_list_dir}/violations_fvf_plus_overweight_not_rec.txt"
            grep "overweight_not_rec" "${temp_list_dir}/violations_files.txt" >> "${temp_list_dir}/violations_fvf_plus_overweight_not_rec.txt" || true
            sort -u -o "${temp_list_dir}/violations_fvf_plus_overweight_not_rec.txt" \
                "${temp_list_dir}/violations_fvf_plus_overweight_not_rec.txt"
        fi
    fi
}

# Создаём жёсткую ссылку на файл, если не получилось, просто копируем его
function copy_or_link(){

    local file="$1"
    local new_path="$2"

    if [ -s "$file" ]; then  # Check if file size is greater than 0 bytes

        [[ ! -d "$(dirname "$new_path")" ]] && mkdir -p "$(dirname "$new_path")" && chown comp1:comp1 "$(dirname "$new_path")" && chmod 755 "$(dirname "$new_path")"

        if [[ -f "$(dirname $new_path)/$(basename $file)" ]] || [[ -L "$(dirname $new_path)/$(basename $file)" ]]; then
            # Файл существует, не копируем
            return
        fi

        if ! ln "$file" "$new_path" 2>/dev/null; then
            rsync -a "$file" "$new_path"
        fi

    else
        echo "$(date +"%F %T") [$$]: Файл $file пустой или не существует, пропускаем. Копировалось в ${new_path}" | tee -a "$logfile"
    fi
}

# Перемещение файлов в долгосрочное хранилище
function longterm_copy(){

    echo "$(date +"%F %T") [$$]: Переносим файлы в долгосрочное хранилище" | tee -a "$logfile"

    while IFS= read -r file; do
        new_path="${file/$source_dir/$longterm_dir}" # меняем /home/comp1/ptolemey_out/tar_outp/normal/*.tar на /srv/tar_outp/normal/*.tar
        copy_or_link "$file" "$new_path"
        _longterm_upload_counter=$((_longterm_upload_counter+1))
    done < "${temp_list_dir}/file_list.txt"
    echo "$(date +"%F %T") [$$]: Файлы переложены в долгосрочное хранилище" | tee -a "$logfile"

    while IFS= read -r file; do
        new_path="${file/$kp_source_dir/$kp_longterm_dir}" # меняем /home/comp1/shared-files/kp/*.tar на /home/comp1/shared-files/kp_old/*.tar
        copy_or_link "$file" "$new_path"
        _longterm_upload_counter=$((_longterm_upload_counter+1))
    done < "${temp_list_dir}/kp_list.txt"
    echo "$(date +"%F %T") [$$]: Материалы КП переложены в долгосрочное хранилище" | tee -a "$logfile"
}

# Получаем valid.txt
function get_controlled_file(){

    echo "$(date +"%F %T") [$$]: Получаем список нарушений из Андромеды." | tee -a "$logfile"
    echo -n "" > $diagfile

    # Процедура с несколькими deviceSerial в lpedemo_*.ini одного комплекса, например LBS07360-LBS07370
    local Serial_rel file
    local Serials=()
    local timestamp=$(date +%s)
    >"/tmp/valid_tmp_${timestamp}"
    Serials+=( "$Serial" )

    # Получаем список deviceSerial из файлов lprdemo_*.ini
    for file in /opt/ptolemey/Complex/Build/lprdemo_*.ini; do
        local SerialOverrided=$(cat "$file" | grep 'deviceSerial' | awk {'print $3'})

        if [[ -n "$SerialOverrided" && "$SerialOverrided" != "$Serial" ]]; then
            Serials+=( "$SerialOverrided" )
        fi
    done

    # Удаляем из списка дубликаты
    Serials=($(printf '%s\n' "${Serials[@]}" | sort -u))

    # Получаем valid.txt для каждого deviceSerial и сливаем во временный файл
    for Serial_rel in "${Serials[@]}"; do
        local valid_text_rel="${Serial_rel}_valid.txt"
        local valid_archive="${Serial_rel}_valid.txt.bz2"
        local valid_server_location="/srv/archive/out_stage_0/valid/${valid_archive}"
        local server server_ip server_port
        local api_url http_code

        rm -f "/tmp/${valid_text_rel}" "/tmp/${valid_archive}"

        for server in "${ANDROMEDA_VALID[@]}"; do
            # Порт в ANDROMEDA_VALID — SSH. Список нарушений отдаёт API на 8090.
            IFS=':' read -r server_ip server_port <<< "$server"
            api_url="http://${server_ip}:8090/v1/valid/?detector=${Serial_rel}"

            http_code=$(curl -sS -o "/tmp/${valid_text_rel}.json" -w "%{http_code}" --connect-timeout 10 --max-time 40 "$api_url") || http_code="000"

            if [[ "$http_code" == "200" ]] && jq -r '.items[] + ".tar"' "/tmp/${valid_text_rel}.json" > "/tmp/${valid_text_rel}"; then
                rm -f "/tmp/${valid_text_rel}.json"
                echo "$(date +"%F %T") [$$]: Список нарушений для $Serial_rel получен с $server" | tee -a "$logfile"
                break
            else
                rm -f "/tmp/${valid_text_rel}" "/tmp/${valid_text_rel}.json"
                local test_ping=$(ping -c 2 ${server_ip} &>/dev/null; echo $?)
                if [ "$test_ping" -ne "0" ]; then
                    echo "$(date +"%F %T") [$$]: Хост андромеды $server_ip недоступен" >> "$diagfile"
                    echo "$(date +"%F %T") [$$]: Хост андромеды ${server_ip} недоступен" | tee -a "$logfile"
                elif [[ "$http_code" == "404" ]]; then
                    echo "$(date +"%F %T") [$$]: На хосте Андромеды ${server_ip} нет списка нарушений для ${Serial_rel}" >> "$diagfile"
                    echo "$(date +"%F %T") [$$]: На хосте Андромеды ${server_ip} нет списка нарушений для ${Serial_rel}" | tee -a "$logfile"
                else
                    echo "$(date +"%F %T") [$$]: Не удалось получить список нарушений для ${Serial_rel} с ${server_ip} (HTTP ${http_code})" >> "$diagfile"
                    echo "$(date +"%F %T") [$$]: Не удалось получить список нарушений для ${Serial_rel} с ${server_ip} (HTTP ${http_code})" | tee -a "$logfile"
                fi
            fi
        done

        # API не отдал список — забираем прежний valid.txt.bz2 по rsync
        if [ ! -f "/tmp/${valid_text_rel}" ]; then
            echo "$(date +"%F %T") [$$]: Список нарушений для $Serial_rel через API не получен, пробуем rsync." | tee -a "$logfile"

            for server in "${ANDROMEDA_VALID[@]}"; do
                IFS=':' read -r server_ip server_port <<< "$server"
                server_port="${server_port:-22}" # Default SSH port is 22 if not specified

                if rsync "syncman@${server_ip}:${valid_server_location}" "/tmp/" --timeout=5 -ae "ssh -i /root/.ssh/andromeda.ru.key -o StrictHostKeyChecking=no -o ConnectTimeout=40 -p $server_port"; then
                    echo "$(date +"%F %T") [$$]: Файл с нарушениями для $Serial_rel скачан с $server" | tee -a "$logfile"
                    break
                else
                    # Запуск диагностики
                    local test_ping=$(ping -c 2 ${server_ip} &>/dev/null; echo $?)
                    if [ "$test_ping" -ne "0" ]; then
                        echo "$(date +"%F %T") [$$]: Хост андромеды $server_ip недоступен" >> "$diagfile"
                        echo "$(date +"%F %T") [$$]: Хост андромеды ${server_ip} недоступен" | tee -a "$logfile"
                    else
                        if ! (ssh -i /root/.ssh/andromeda.ru.key -o StrictHostKeyChecking=no -p $server_port syncman@$server_ip "ls /srv/archive/out_stage_0/valid &>/dev/null"); then
                            echo "$(date +"%F %T") [$$]: На хосте Андромеды ${server_ip} не найден каталог /srv/archive/out_stage_0/valid" >> "$diagfile"
                            echo "$(date +"%F %T") [$$]: На хосте Андромеды ${server_ip} не найден каталог /srv/archive/out_stage_0/valid" | tee -a "$logfile"
                        else
                            if ! (ssh -i /root/.ssh/andromeda.ru.key -o StrictHostKeyChecking=no -p $server_port syncman@$server_ip "ls ${valid_server_location} &>/dev/null"); then
                                echo "$(date +"%F %T") [$$]: На хосте Андромеды ${server_ip} не найден файл ${valid_server_location}" >> "$diagfile"
                                echo "$(date +"%F %T") [$$]: На хосте Андромеды ${server_ip} не найден файл ${valid_server_location}" | tee -a "$logfile"
                            else
                                echo "$(date +"%F %T") [$$]: Файл найден на хосте Андромеды ${server_ip}, но копирование не удалось" >> "$diagfile"
                                echo "$(date +"%F %T") [$$]: Файл найден на хосте Андромеды ${server_ip}, но копирование не удалось" | tee -a "$logfile"
                            fi
                        fi
                    fi
                fi
            done

            if [ -f "/tmp/${valid_archive}" ]; then
                cd /tmp
                bunzip2 -f -k "$valid_archive"
                rm -f "$valid_archive"
                cd - > /dev/null
            fi
        fi

        if [ -f "/tmp/${valid_text_rel}" ]; then
            cat "/tmp/${valid_text_rel}" >> "/tmp/valid_tmp_${timestamp}"
            rm -f "/tmp/${valid_text_rel}"
        else
            echo "$(date +"%F %T") [$$]: Не удалось получить файл для $Serial_rel с нарушениями из Андромеды." | tee -a "$logfile"
        fi

    done

    # Сортируем и чистим от дублей объединенный временный valid.txt
    sort -u "/tmp/valid_tmp_${timestamp}" -o "/tmp/valid_tmp_${timestamp}"

    # Перемещаем временный файл в итоговый valid.txt с deviceSerial, указанным в cps.ini
    [[ -s "/tmp/valid_tmp_${timestamp}" ]] && \
        mv "/tmp/valid_tmp_${timestamp}" "/srv/tmp/${valid_text}" || \
        echo "$(date +"%F %T") [$$]: Ошибка формирования ${valid_text}" | tee -a "$logfile"
}

# Логика выгрузки в Андромеду
function andromeda_copy(){
    echo "$(date +"%F %T") [$$]: Начинаем копировать файлы для Андромеды" | tee -a "$logfile"
    if [ "$ANDROMEDA_MASTER_ENABLE" = "false" ] && [ "$ANDROMEDA_SLAVE_ENABLE" = "false" ]; then
        echo "$(date +"%F %T") [$$]: Выгрузка для Андромеды через скрипт rsync отключена" | tee -a "$logfile"
        return
    fi
    # Выгружаем нарушения в Андромеду
    echo "$(date +"%F %T") [$$]: Выгружаем сначала нарушения в Андромеду" | tee -a "$logfile"
    while IFS= read -r file; do
        new_path="${file/$source_dir/$andromeda_in_dir}" # меняем /home/comp1/ptolemey_out/tar_outp/normal/*.tar на /srv/tmp/tar_outp/*.tar
        copy_or_link "$file" "$new_path"
        _andromeda_upload_counter=$((_andromeda_upload_counter+1))
        if [[ "$ANDROMEDA_SLAVE_ENABLE" == "true" ]]; then
            new_path="${file/$source_dir/$andromeda_slave_in_dir}"
            copy_or_link "$file" "$new_path"
            _andromeda_slave_upload_counter=$((_andromeda_slave_upload_counter+1))
        fi
    done < "$temp_list_dir/violations_andromeda_files.txt"

    if [[ "$ANDROMEDA_UPLOAD_PASSAGE" == "true" ]]; then
        # Выгружаем проезды в Андромеду при необходимости
        echo "$(date +"%F %T") [$$]: Выгружаем проезды Андромеду" | tee -a "$logfile"
        while IFS= read -r file; do
            rand=$((RANDOM % 100)) # Иногда нужно выгружать только часть проездов
            if [ $rand -lt $ANDROMEDA_UPLOAD_PERCENTAGE ]; then
                new_path="${file/$source_dir/$andromeda_in_dir}"
                copy_or_link "$file" "$new_path"
                _andromeda_upload_counter=$((_andromeda_upload_counter+1))
                if [[ "$ANDROMEDA_SLAVE_ENABLE" == "true" ]]; then
                    new_path="${file/$source_dir/$andromeda_slave_in_dir}"
                    copy_or_link "$file" "$new_path"
                    _andromeda_slave_upload_counter=$((_andromeda_slave_upload_counter+1))
                fi
            fi
        done < "$temp_list_dir/normal_files.txt"
    fi
    echo "$(date +"%F %T") [$$]: Копирование файлов для Андромеды завершено" | tee -a "$logfile"
}

# Логика выгрузки через Fortka
function fortka_copy(){
    if [[ "$FORTKA_ENABLE" != "true" ]]; then
        echo "$(date +"%F %T") [$$]: Выгрузка для Fortka отключена" | tee -a "$logfile"
        return
    else
        echo "$(date +"%F %T") [$$]: Начинаем копировать файлы для Fortka" | tee -a "$logfile"
    fi

    # Выгружаем в Fortka нарушения
    echo "$(date +"%F %T") [$$]: Выгружаем нарушения для Fortka" | tee -a "$logfile"
    while IFS= read -r file; do
        new_path="${fortka_violations_in_dir}/$(basename $file)"
        copy_or_link "$file" "$new_path"
        _fortka_upload_counter=$((_fortka_upload_counter+1))
    done < "$temp_list_dir/violations_andromeda_files.txt"

    if [[ "$FORTKA_UPLOAD_PASSAGE" == "true" ]]; then
        echo "$(date +"%F %T") [$$]: Выгружаем проезды для Fortka" | tee -a "$logfile"
        while IFS= read -r file; do
            rand=$((RANDOM % 100)) # Иногда нужно выгружать только часть проездов
            if [ $rand -lt $ANDROMEDA_UPLOAD_PERCENTAGE ]; then
                new_path="${fortka_in_dir}/$(basename $file)"
                copy_or_link "$file" "$new_path"
                _fortka_upload_counter=$((_fortka_upload_counter+1))
            fi
        done < "$temp_list_dir/normal_files.txt"
    fi
    echo "$(date +"%F %T") [$$]: Копирование файлов для Fortka завершено" | tee -a "$logfile"
}

# Формируем список уже выгруженных файлов на основе логов
# На вход принимает шаблон файлов логов (первый аргумент), например "${controlled_upload_logs}/duplo_uploaded_*"
# На выходе формирует файл со списком материалов (второй аргумент), например "${temp_list_dir}/duplo_uploaded_files.txt"
function uploaded_files_parse(){
    # Защита от вызова без аргумента
    [[ -z "$1" || -z "$2" ]] && return

    local count
    local log_pattern="$1"
    local output_file="$2"

    echo "$(date +"%F %T") [$$]: Собираем список выгруженных файлов из логов ${log_pattern}." | tee -a "$logfile"
    local cache=""
    for log_file in $log_pattern; do
        [[ -f "$log_file" ]] && cache+=$(awk '{print $1}' "$log_file")$'\n'
    done
    [[ -z "$cache" ]] && count=0 || count=$(echo "$cache" | wc -l)
    echo "$(date +"%F %T") [$$]: Собрано ${count} имен файлов из логов." | tee -a "$logfile"

    # Сохраняем результат в файл с сортировкой и удалением дублей
    echo "$(date +"%F %T") [$$]: Фильтруем на уникальность, сортируем и сохраняем результат в ${output_file}" | tee -a "$logfile"
    printf "%s" "$cache" | sed '/^$/d' | sort -u > "$output_file"

}

# Ищем был ли файл выгружен при контролируемой выгрузке
# 0 - если файл отсутсвтует в логах выгрузки
# 1- если файл уже был выгружен
function file_in_uploaded(){
    local search_string="$1"
    local log_pattern="$2"

    # Глобальные ассоциативные массивы для кеша (инициализируются один раз)
    if [[ "${cache_init_done}" != "1" ]]; then
        echo "$(date +"%F %T") [$$]: Первый поиск файла в логах. Инициализируем массивы." | tee -a "$logfile"
        declare -gA cache_content cache_loaded
        declare -g cache_init_done=1
    fi

    # Собираем логи в память только при первом обращении к данному паттерну
    if [[ -z "${cache_loaded[$log_pattern]}" ]]; then
        echo "$(date +"%F %T") [$$]: Первый поиск по паттерну ${log_pattern}. Кешируем список файлов из логов." | tee -a "$logfile"
        local cache=""
        for log_file in $log_pattern; do
            [[ -f "$log_file" ]] && cache+=$(awk '{print $1}' "$log_file")$'\n'
        done
        local count=$(echo "$cache" | wc -l)
        echo "$(date +"%F %T") [$$]: Закешировано ${count} имен файлов из логов." | tee -a "$logfile"
        cache_content["$log_pattern"]="$cache"
        cache_loaded["$log_pattern"]=1
    fi

    # Мгновенная проверка в оперативной памяти без запуска grep и доступа к диску
    [[ "${cache_content[$log_pattern]}" == *"$search_string"* ]] && return 0
    return 1
}

# Логика выгрузки в Duplo
function duplo_copy(){

    # При ручном отключении выгрузки в Паутину - не копируем материалы в папки выгрузки
    if [[ ! -f "$hollowpoke_compose_file" ]]; then
        echo "$(date +"%F %T") [$$]: Отсутствует файл $(basename $hollowpoke_compose_file). Возможно, выключена выгрузка в Паутину. Пропускаем копирование материалов" | tee -a "$logfile"
        return 1
    fi

    if [[ "$DUPLO" == "true" ]] && ! cat "$variables_file" | head -n 1 | grep -q "default"; then
        if [[ "$DUPLO_SORT_OLDEST" == "true" ]]; then
            local normal_files="normal_files_sorted.txt"
            local violations_files="violations_files.txt"
        elif [[ "$DUPLO_ONLY_FVF" == "true" ]]; then
            local normal_files="normal_fvf_files.txt"
            # ONLY_FVF отсекает weight; overweight_not_rec нужен отдельным списком
            if [[ "$DUPLO_UPLOAD_OVERWEIGHT_NOT_REC" == "true" ]]; then
                local violations_files="violations_fvf_plus_overweight_not_rec.txt"
            else
                local violations_files="violations_fvf_files.txt"
            fi
        else
            local normal_files="normal_files.txt"
            local violations_files="violations_files.txt"
        fi

        echo "$(date +"%F %T") [$$]: Начинаем копировать файлы для Дупло" | tee -a "$logfile"

        # Безусловно выгружаем все проезды, пока без нарушений
        if [[ "$DUPLO_UPLOAD_PASSAGE" == "true" ]]; then
            echo "$(date +"%F %T") [$$]: Выгружаем проезды в Дупло" | tee -a "$logfile"
            while IFS= read -r file; do
                copy_or_link "$file" "$duplo_in_dir"
                _duplo_upload_counter=$((_duplo_upload_counter+1))
            done < "${temp_list_dir}/${normal_files}"
        fi

        # Парсим логи, формируем список уже выгруженных файлов
        uploaded_files_parse "$duplo_uploaded_log*" "$temp_list_dir/duplo_uploaded_files.txt"

        # Копируем список с нужными файлами с Андромеды, проверяем что не выгрузили их ранее и отдаём Duplo
        if [[ "$DUPLO_CONTROLLED" == "true" ]]; then
            if [ -f "/srv/tmp/${valid_text}" ]; then
                echo "$(date +"%F %T") [$$]: Выгружаем нарушения обозначенные Андромедой в Дупло" | tee -a "$logfile"
                echo "$(date +"%F %T") [$$]: Количество кандидатов до фильтрации по логу выгрузки: $(wc -l < "/srv/tmp/${valid_text}")" | tee -a "$logfile"
                comm -23 <(sort -u "/srv/tmp/${valid_text}") \
                         <({ ls -1 "$duplo_violations_in_dir" "$duplo_violations_out_dir" 2>/dev/null
                             cat "${temp_list_dir}/duplo_uploaded_files.txt" 2>/dev/null
                           } | sort -u) \
                         > "$temp_list_dir/duplo_to_move.txt"
                echo "$(date +"%F %T") [$$]: Количество кандидатов после фильтрации по логу выгрузки: $(wc -l < "$temp_list_dir/duplo_to_move.txt")" | tee -a "$logfile"

                while IFS= read -r file; do
                    found_files=$(grep "$file" "${temp_list_dir}/${violations_files}" | head -n 1)
                    if [ -n "$found_files" ] && [ -f "$found_files" ]; then
                        copy_or_link "$found_files" "$duplo_violations_in_dir/"
                        echo "${file} $(date +'%Y-%m-%d %H:%M:%S.%N %z')" >> "$duplo_uploaded_log$(date '+%Y-%m-%d')"
                        _duplo_upload_counter=$((_duplo_upload_counter+1))
                    fi
                done < "$temp_list_dir/duplo_to_move.txt"
            else
                echo "$(date +"%F %T") [$$]: Файл с нарушениями из Андромеды не найден" | tee -a "$logfile"
            fi
            rm -f "$temp_list_dir/duplo_to_move.txt"
            find "$controlled_upload_logs" -name 'duplo_uploaded_*' -mtime +30 -exec rm {} \;
        else # Выгружаем все нарушения в Дупло с проверкой по логу выгрузки (Исключаем уже выгруженные материалы)
            echo "$(date +"%F %T") [$$]: Выгружаем все новые нарушения в Дупло." | tee -a "$logfile"
            echo "$(date +"%F %T") [$$]: Количество кандидатов до фильтрации по логу выгрузки: $(wc -l < "$temp_list_dir/${violations_files}")" | tee -a "$logfile"
            comm -23 <(sort -u "$temp_list_dir/${violations_files}") \
                     <({ ls -1 "$duplo_violations_in_dir" "$duplo_violations_out_dir" 2>/dev/null
                         cat "${temp_list_dir}/duplo_uploaded_files.txt" 2>/dev/null
                       } | sort -u) \
                     > "$temp_list_dir/duplo_to_move.txt"
            echo "$(date +"%F %T") [$$]: Количество кандидатов после фильтрации по логу выгрузки: $(wc -l < "$temp_list_dir/duplo_to_move.txt")" | tee -a "$logfile"
            while IFS= read -r file; do
                if [ -n "$file" ] && [ -f "$file" ]; then
                    copy_or_link "$file" "$duplo_violations_in_dir/"
                    echo "${file} $(date +'%Y-%m-%d %H:%M:%S.%N %z')" >> "$duplo_uploaded_log$(date '+%Y-%m-%d')"
                    _duplo_upload_counter=$((_duplo_upload_counter+1))
                fi
            done < "$temp_list_dir/duplo_to_move.txt"
        fi
        echo "$(date +"%F %T") [$$]: Копирование файлов для Дупло завершено. Скопировано ${_duplo_upload_counter} файлов." | tee -a "$logfile"
    fi
}

# Логика выгрузки в Doris
function doris_copy(){

    # При ручном отключении выгрузки в Дорис - не копируем материалы в папки выгрузки
    if [[ ! -f "$hollowpoke_compose_file" ]]; then
        echo "$(date +"%F %T") [$$]: Отсутствует файл $(basename $hollowpoke_compose_file). Возможно, выключена выгрузка в Дорис. Пропускаем копирование материалов" | tee -a "$logfile"
        return 1
    fi

    if [[ "$DORIS" == "true" ]] && ! cat "$variables_file" | head -n 1 | grep -q "default"; then
        if [[ "$DORIS_SORT_OLDEST" == "true" ]]; then
            local normal_files="normal_files_sorted.txt"
            local violations_files="violations_files.txt"
        elif [[ "$DORIS_ONLY_FVF" == "true" ]]; then
            local normal_files="normal_fvf_files.txt"
            local violations_files="violations_fvf_files.txt"
        else
            local normal_files="normal_files.txt"
            local violations_files="violations_files.txt"
        fi

        echo "$(date +"%F %T") [$$]: Начинаем копировать файлы для Дорис" | tee -a "$logfile"

        # Безусловно выгружаем все проезды, пока без нарушений
        if [[ "$DORIS_UPLOAD_PASSAGE" == "true" ]]; then
            echo "$(date +"%F %T") [$$]: Выгружаем проезды в Дорис" | tee -a "$logfile"
            while IFS= read -r file; do
                copy_or_link "$file" "$doris_in_dir/"
                _doris_upload_counter=$((_doris_upload_counter+1))
            done < "${temp_list_dir}/${normal_files}"
        fi

        # Парсим логи, формируем список уже выгруженных файлов
        uploaded_files_parse "$doris_uploaded_log*" "$temp_list_dir/doris_uploaded_files.txt"

        # Копируем список с нужными файлами с Адромеды, проверяем что не выгрузили их ранее и отдаём Doris
        if [[ "$DORIS_CONTROLLED" == "true" ]]; then
            if [ -f "/srv/tmp/${valid_text}" ]; then
                echo "$(date +"%F %T") [$$]: Выгружаем нарушения обозначенные Андромедой в Дорис" | tee -a "$logfile"
                echo "$(date +"%F %T") [$$]: Количество кандидатов до фильтрации по логу выгрузки: $(wc -l < "/srv/tmp/${valid_text}")" | tee -a "$logfile"
                comm -23 <(sort -u "/srv/tmp/${valid_text}") \
                         <({ ls -1 "$doris_violations_in_dir" "$doris_violations_out_dir" 2>/dev/null
                             cat "${temp_list_dir}/doris_uploaded_files.txt" 2>/dev/null
                           } | sort -u) \
                         > "$temp_list_dir/doris_to_move.txt"
                echo "$(date +"%F %T") [$$]: Количество кандидатов после фильтрации по логу выгрузки: $(wc -l < "$temp_list_dir/doris_to_move.txt")" | tee -a "$logfile"

                while IFS= read -r file; do
                    found_files=$(grep "$file" "${temp_list_dir}/${violations_files}" | head -n 1)

                    if [ -n "$found_files" ] && [ -f "$found_files" ]; then
                        copy_or_link "$found_files" "$doris_violations_in_dir/"
                        echo "${file} $(date +'%Y-%m-%d %H:%M:%S.%N %z')" >> "$doris_uploaded_log$(date '+%Y-%m-%d')"
                        _doris_upload_counter=$((_doris_upload_counter+1))
                    fi

                done < "$temp_list_dir/doris_to_move.txt"
            else
                echo "$(date +"%F %T") [$$]: Файл с нарушениями из Андромеды не найден" | tee -a "$logfile"
            fi
            rm -f "$temp_list_dir/doris_to_move.txt"
            find "$controlled_upload_logs" -name 'doris_uploaded_*' -mtime +30 -exec rm {} \;
        else # Выгружаем все нарушения в Дорис с проверкой по логу выгрузки (Исключаем уже выгруженные материалы)
            echo "$(date +"%F %T") [$$]: Выгружаем все новые нарушения в Дорис." | tee -a "$logfile"
            echo "$(date +"%F %T") [$$]: Количество кандидатов до фильтрации по логу выгрузки: $(wc -l < "$temp_list_dir/${violations_files}")" | tee -a "$logfile"
            comm -23 <(sort -u "$temp_list_dir/${violations_files}") \
                     <({ ls -1 "$doris_violations_in_dir" "$doris_violations_out_dir" 2>/dev/null
                         cat "${temp_list_dir}/doris_uploaded_files.txt" 2>/dev/null
                       } | sort -u) \
                     > "$temp_list_dir/doris_to_move.txt"
            echo "$(date +"%F %T") [$$]: Количество кандидатов после фильтрации по логу выгрузки: $(wc -l < "$temp_list_dir/doris_to_move.txt")" | tee -a "$logfile"
            while IFS= read -r file; do
                if [ -n "$file" ] && [ -f "$file" ]; then
                    copy_or_link "$file" "$doris_violations_in_dir/"
                    echo "${file} $(date +'%Y-%m-%d %H:%M:%S.%N %z')" >> "$doris_uploaded_log$(date '+%Y-%m-%d')"
                    _doris_upload_counter=$((_doris_upload_counter+1))
                fi
            done < "$temp_list_dir/doris_to_move.txt"
        fi
        echo "$(date +"%F %T") [$$]: Копирование файлов для Дорис завершено. Скопировано ${_doris_upload_counter} файлов." | tee -a "$logfile"
    fi
}

# Используется в ftp_server_copy()
function contains_substring(){
    local needle="$1"
    local hay="$2"
    for hay_string in "${hay[@]}"; do
        if [[ "$needle" == *"$hay_string"* ]]; then
            return 0 # True, found in the stack
        fi
    done
    return 1 # False, not found in the stack
}

# Логика выгрузки на локальный сервер FTP
function ftp_server_copy(){

    if [[ "$FTP_SERVER_ONLY_WEIGHT" == "true" ]]; then
        local normal_files="normal_weight_files.txt"
        local violations_files="violations_weight_files.txt"
    else
        local normal_files="normal_files.txt"
        local violations_files="violations_files.txt"
    fi

    if [[ "$FTP_SERVER_UPLOAD_ENABLE" == "true" ]]; then
        echo "$(date +"%F %T") [$$]: Начинаем копировать файлы для выгрузки с помощью локального сервера FTP" | tee -a "$logfile"

        # Безусловно выгружаем все нормали, пока без нарушений
        if [[ "$FTP_SERVER_UPLOAD_PASSAGE" == "true" ]]; then
            echo "$(date +"%F %T") [$$]: Выгружаем проезды на локальный сервер FTP" | tee -a "$logfile"
            while IFS= read -r file; do
                new_path="${file/$source_dir/$ftp_server_in_dir}"
                copy_or_link "$file" "$new_path"
                _ftp_server_upload_counter=$((_ftp_server_upload_counter+1))
            done < "$temp_list_dir/normal_files.txt"
        fi

        # Парсим логи, формируем список уже выгруженных файлов
        uploaded_files_parse "$ftp_server_uploaded_log*" "$temp_list_dir/ftp_server_uploaded_files.txt"

        # Копируем список с нужными файлами с Адромеды, проверяем что не выгрузили их ранее и отдаём FTP
        if [[ "$FTP_SERVER_CONTROLLED" == "true" ]]; then
            if [ -f "/srv/tmp/${valid_text}" ]; then
                echo "$(date +"%F %T") [$$]: Выгружаем нарушения обозначенные Андромедой на локальный сервер FTP" | tee -a "$logfile"
                echo "$(date +"%F %T") [$$]: Количество кандидатов до фильтрации по логу выгрузки: $(wc -l < "/srv/tmp/${valid_text}")" | tee -a "$logfile"
                comm -23 <(sort -u "/srv/tmp/${valid_text}") \
                         <({ ls -1 "$ftp_server_in_dir" 2>/dev/null
                             cat "${temp_list_dir}/ftp_server_uploaded_files.txt" 2>/dev/null
                           } | sort -u) \
                         > "$temp_list_dir/ftp_server_to_move.txt"
                echo "$(date +"%F %T") [$$]: Количество кандидатов после фильтрации по логу выгрузки: $(wc -l < "$temp_list_dir/ftp_server_to_move.txt")" | tee -a "$logfile"

                while IFS= read -r file; do
                    found_files=$(grep "$file" "${temp_list_dir}/${violations_files}" | head -n 1)
                    if [ -n "$found_files" ] && [ -f "$found_files" ]; then
                        relative_path="${found_files#$longterm_dir/}"

                        # Construct the new path in the ftp_server_in directory
                        new_path="${ftp_server_in_dir}/${relative_path}"

                        if [[ "$FTP_SERVER_ONLY_WEIGHT" == "true" ]] && [[ "$new_path" != *weight* ]]; then
                            continue
                        fi

                        # Use the move_or_link function to process the file
                        copy_or_link "$found_files" "$new_path"
                        echo "${file} $(date +'%Y-%m-%d %H:%M:%S.%N %z')" >> "$ftp_server_uploaded_log$(date '+%Y-%m-%d')"
                        _ftp_server_upload_counter=$((_ftp_server_upload_counter+1))
                    fi
                done < "$temp_list_dir/ftp_server_to_move.txt"
            else
                echo "$(date +"%F %T") [$$]: Файл с нарушениями из Андромеды не найден" | tee -a "$logfile"
            fi

            rm -f "$temp_list_dir/ftp_server_to_move.txt"
            find "$controlled_upload_logs" -name 'ftp_server_uploaded_*' -mtime +30 -exec rm {} \;
        else # Выгружаем все нарушения на ftp с проверкой по логу выгрузки (Исключаем уже выгруженные материалы)
            echo "$(date +"%F %T") [$$]: Выгружаем все нарушения на локальный сервер FTP" | tee -a "$logfile"
            echo "$(date +"%F %T") [$$]: Количество кандидатов до фильтрации по логу выгрузки: $(wc -l < "$temp_list_dir/${violations_files}")" | tee -a "$logfile"
            comm -23 <(sort -u "$temp_list_dir/${violations_files}") \
                     <({ ls -1 "$ftp_server_in_dir" 2>/dev/null
                         cat "${temp_list_dir}/ftp_server_uploaded_files.txt" 2>/dev/null
                       } | sort -u) \
                     > "$temp_list_dir/ftp_server_to_move.txt"
            echo "$(date +"%F %T") [$$]: Количество кандидатов после фильтрации по логу выгрузки: $(wc -l < "$temp_list_dir/ftp_server_to_move.txt")" | tee -a "$logfile"
            while IFS= read -r file; do
                if [ ${#FTP_SERVER_UPLOAD_DIRS[@]} -eq 0 ] || contains_substring "$file" "$FTP_SERVER_UPLOAD_DIRS"; then
                    if [ -n "$file" ] && [ -f "$file" ]; then
                        new_path="${file/$source_dir/$ftp_server_in_dir}"
                        copy_or_link "$file" "$new_path"
                        echo "${file} $(date +'%Y-%m-%d %H:%M:%S.%N %z')" >> "$ftp_server_uploaded_log$(date '+%Y-%m-%d')"
                        _ftp_server_upload_counter=$((_ftp_server_upload_counter+1))
                    fi
                fi
            done < "$temp_list_dir/ftp_server_to_move.txt"
        fi
        echo "$(date +"%F %T") [$$]: Копирование файлов на локальный сервер FTP завершено. Скопировано ${_ftp_server_upload_counter} файлов." | tee -a "$logfile"
    fi
}

# Логика выгрузки через клиент FTP
function ftp_client_copy(){
    if [[ "$FTP_CLIENT_ONLY_WEIGHT" == "true" ]]; then
        local normal_files="normal_weight_files.txt"
        local violations_files="violations_weight_files.txt"
    else
        local normal_files="normal_files.txt"
        local violations_files="violations_files.txt"
    fi

    if [[ "$FTP_CLIENT_UPLOAD_ENABLE" == "true" ]]; then
        echo "$(date +"%F %T") [$$]: Начинаем копировать файлы для выгрузки через клиент FTP" | tee -a "$logfile"

        # Безусловно выгружаем все нормали, пока без нарушений
        if [[ "$FTP_CLIENT_UPLOAD_PASSAGE" == "true" ]]; then
            echo "$(date +"%F %T") [$$]: Выгружаем проезды для выгрузки в FTP" | tee -a "$logfile"

            # $file - полный путь
            while IFS= read -r file; do
                # Заменяем /home/comp1/ptolemey_out/tar_outp/normal/*.tar.gz на /normal/*.tar.gz
                relative_path="${file#$source_dir/}"

                if [[ "$FTP_CLIENT_ALL_IN_HEAP" == "false" ]]; then
                    # Склеиваем пути в единый: /srv/tmp/ftp_out//normal/*.tar.gz
                    new_path="${ftp_client_in_dir}/${relative_path}"
                else
                    if [[ "$FTP_CLIENT_XML" == "false" ]]; then
                        # Склеиваем пути в единый: /srv/tmp/ftp_out/*.tar.gz
                        new_path="${ftp_client_in_dir}/$(basename $file)"
                    else
                        new_path="$ftp_client_in_dir"
                    fi
                fi

                if [[ "$FTP_CLIENT_XML" == false ]]; then
                    copy_or_link "$file" "$new_path"
                    echo "$(basename $file) $(date +'%Y-%m-%d %H:%M:%S.%N %z')" >> "$ftp_client_uploaded_log$(date '+%Y-%m-%d')"
                    _ftp_client_upload_counter=$((_ftp_client_upload_counter+1))
                else
                    cd $(dirname "$VGK_TAR_CONVERTER")
                    python3 $(basename "$VGK_TAR_CONVERTER") "$file"
                    mv *.xml "$new_path"
                    cd - > /dev/null
                    echo "$(basename $file) $(date +'%Y-%m-%d %H:%M:%S.%N %z')" >> "$ftp_client_uploaded_log$(date '+%Y-%m-%d')"
                    _ftp_client_upload_counter=$((_ftp_client_upload_counter+1))
                fi
            done < "${temp_list_dir}/${normal_files}"
        fi

        # Парсим логи, формируем список уже выгруженных файлов
        uploaded_files_parse "$ftp_client_uploaded_log*" "$temp_list_dir/ftp_client_uploaded_files.txt"

        # Копируем список с нужными файлами с Адромеды, проверяем что не выгрузили их и отдаём FTP
        if [[ "$FTP_CLIENT_CONTROLLED" == "true" ]]; then
            if [ -f "/srv/tmp/${valid_text}" ]; then
                echo "$(date +"%F %T") [$$]: Выгружаем нарушения обозначенные Андромедой в FTP" | tee -a "$logfile"
                # Формируем список имён файлов из valid.txt, которые еще не находятся в конечной папке выгрузки и не выгружались ранее
                echo "$(date +"%F %T") [$$]: Количество кандидатов до фильтрации по логу выгрузки: $(wc -l < "/srv/tmp/${valid_text}")" | tee -a "$logfile"
                comm -23 <(sort -u "/srv/tmp/${valid_text}") \
                         <({ ls -1 "$ftp_client_in_dir" 2>/dev/null
                             cat "${temp_list_dir}/ftp_client_uploaded_files.txt" 2>/dev/null
                           } | sort -u) \
                         > "$temp_list_dir/ftp_client_to_move.txt"
                echo "$(date +"%F %T") [$$]: Количество кандидатов после фильтрации по логу выгрузки: $(wc -l < "$temp_list_dir/ftp_client_to_move.txt")" | tee -a "$logfile"

                while IFS= read -r file; do
                    found_file=$(grep "$file" "${temp_list_dir}/${violations_files}" | head -n 1)
                    # Заменяем /srv/tar_outp/red_light/*.tar.gz на /red_light/*.tar.gz
                    relative_path="${found_file#$longterm_dir/}"

                    if [ -n "$found_file" ] && [ -f "$found_file" ]; then
                        if [[ "$FTP_CLIENT_ALL_IN_HEAP" == false ]]; then
                            # Склеиваем пути в единый: /srv/tmp/ftp_out//red_light/*.tar.gz
                            new_path="${ftp_client_in_dir}/${relative_path}"
                        else
                            if [[ "$FTP_CLIENT_XML" == false ]]; then
                                # Склеиваем пути в единый: /srv/tmp/ftp_out/*.tar.gz
                                new_path="${ftp_client_in_dir}/${file}"
                            else
                                new_path="$ftp_client_in_dir"
                            fi
                        fi

                        if [[ "$FTP_CLIENT_XML" == false ]]; then
                            # Если не весовой материал при включенном параметре FTP_CLIENT_ONLY_WEIGHT - пропускаем копирование в папку выгрузки
                            if [[ "$FTP_CLIENT_ONLY_WEIGHT" == "true" ]] && [[ "$relative_path" != *weight* ]]; then
                                continue
                            fi

                            copy_or_link "$found_file" "$new_path"
                            echo "${file} $(date +'%Y-%m-%d %H:%M:%S.%N %z')" >> "$ftp_client_uploaded_log$(date '+%Y-%m-%d')"
                            _ftp_client_upload_counter=$((_ftp_client_upload_counter+1))
                        else
                            # Если не весовой материал при включенном параметре FTP_CLIENT_ONLY_WEIGHT - пропускаем копирование в папку выгрузки
                            if [[ "$FTP_CLIENT_ONLY_WEIGHT" == "true" ]] && [[ "$relative_path" != *weight* ]]; then
                                continue
                            fi

                            cd $(dirname "$VGK_TAR_CONVERTER")
                            python3 $(basename "$VGK_TAR_CONVERTER") "$found_file"
                            mv *.xml "$new_path"
                            cd - > /dev/null
                            echo "${file} $(date +'%Y-%m-%d %H:%M:%S.%N %z')" >> "$ftp_client_uploaded_log$(date '+%Y-%m-%d')"
                            _ftp_client_upload_counter=$((_ftp_client_upload_counter+1))
                        fi
                    fi
                done < "$temp_list_dir/ftp_client_to_move.txt"
            else
                echo "$(date +"%F %T") [$$]: Файл с нарушениями из Андромеды не найден" | tee -a "$logfile"
            fi
            rm -f "$temp_list_dir/ftp_client_to_move.txt"
            find "$controlled_upload_logs" -name 'ftp_client_uploaded_*' -mtime +30 -exec rm {} \;
        else # Выгружаем все нарушения на ftp с проверкой по логу выгрузки (Исключаем уже выгруженные материалы)
            echo "$(date +"%F %T") [$$]: Выгружаем все новые нарушения в FTP" | tee -a "$logfile"
            echo "$(date +"%F %T") [$$]: Количество кандидатов до фильтрации по логу выгрузки: $(wc -l < "${temp_list_dir}/${violations_files}")" | tee -a "$logfile"
            comm -23 <(sort -u "$temp_list_dir/${violations_files}") \
                     <({ ls -1 "$ftp_client_in_dir" 2>/dev/null
                         cat "${temp_list_dir}/ftp_client_uploaded_files.txt" 2>/dev/null
                       } | sort -u) \
                     > "$temp_list_dir/ftp_client_to_move.txt"
            echo "$(date +"%F %T") [$$]: Количество кандидатов после фильтрации по логу выгрузки: $(wc -l < "$temp_list_dir/ftp_client_to_move.txt")" | tee -a "$logfile"

            while IFS= read -r file; do
                if [[ "$FTP_CLIENT_ALL_IN_HEAP" == false ]]; then
                    # меняем /home/comp1/ptolemey_out/tar_outp/over_weight/*.tar на /srv/tmp/ftp_out/over_weight/*.tar
                    new_path="${file/$source_dir/$ftp_client_in_dir}"
                else
                    if [[ "$FTP_CLIENT_XML" == false ]]; then
                        # Склеиваем пути в единый: /srv/tmp/ftp_out/*.tar.gz
                        new_path="${ftp_client_in_dir}/$(basename $file)"
                    else
                        new_path="$ftp_client_in_dir"
                    fi
                fi

                if [ -n "$file" ] && [ -f "$file" ]; then
                    if [[ "$FTP_CLIENT_XML" == false ]]; then
                        copy_or_link "$file" "$new_path"
                        echo "${file} $(date +'%Y-%m-%d %H:%M:%S.%N %z')" >> "$ftp_client_uploaded_log$(date '+%Y-%m-%d')"
                        _ftp_client_upload_counter=$((_ftp_client_upload_counter+1))
                    else
                        cd $(dirname "$VGK_TAR_CONVERTER")
                        python3 $(basename "$VGK_TAR_CONVERTER") "$file"
                        mv *.xml "$new_path"
                        cd - > /dev/null
                        echo "${file} $(date +'%Y-%m-%d %H:%M:%S.%N %z')" >> "$ftp_client_uploaded_log$(date '+%Y-%m-%d')"
                        _ftp_client_upload_counter=$((_ftp_client_upload_counter+1))
                    fi
                fi
            done < "$temp_list_dir/ftp_client_to_move.txt"
        fi
        echo "$(date +"%F %T") [$$]: Копирование файлов с помощью клиента FTP завершено. Скопировано ${_ftp_client_upload_counter} файлов." | tee -a "$logfile"
    fi
}

# Логика выгрузки КП
function kp_copy(){

    echo "$(date +"%F %T") [$$]: Копируем материалы КП" | tee -a "$logfile"

    while IFS= read -r file; do
        new_path="${file/$kp_source_dir/$kp_in_dir}" # меняем /home/comp1/shared-files/kp/*.tar на /srv/tmp/kp/*.tar
        copy_or_link "$file" "$new_path"
        _kp_upload_counter=$((_kp_upload_counter+1))
    done < "$temp_list_dir/kp_list.txt"

    echo "$(date +"%F %T") [$$]: Копирование материалов КП завершено" | tee -a "$logfile"
}

# Cleanup function
function cleanup(){
    echo "$(date +"%F %T") [$$]: Очищаем pidfile после себя..." | tee -a "$logfile"
    [[ -f "$pidfile" ]] && rm "$pidfile"
    echo "$(date +"%F %T") [$$]: Очистка завершена." | tee -a "$logfile"
}

# Проверяем что скрипт не запущен, если работает больше 15 минут, убиваем его мягко
# Если работает больше получаса, убиваем его жёстко
if [ -f "$pidfile" ]; then
    old_pid=$(cat "$pidfile")
    if [ -n "$(ps -p $old_pid -o pid=)" ]; then
        runtime=$(( $(date +%s) - $(date +%s -r "$pidfile") ))
        if [ $runtime -ge 1800 ]; then  # Running for more than half an hour
            echo "$(date +"%F %T") [$$]: Скрипт работает более получаса, убиваем с -9 PID $old_pid." | tee -a "$logfile"
            pgrep -P $old_pid | xargs kill -9
            kill -9 "$old_pid"
            exit 1
        elif [ $runtime -ge 900 ]; then  # Running for more than 15 min
            echo "$(date +"%F %T") [$$]: Скрипт работает более 15 минут, убиваем PID $old_pid." | tee -a "$logfile"
            pgrep -P $old_pid | xargs kill
            kill "$old_pid"
            exit 1
        else
            echo "$(date +"%F %T") [$$]: Скрипт уже запущен с PID: $old_pid. Выходим." | tee -a "$logfile"
            exit 1
        fi
    fi
fi

# Записываем PID
echo $$ > "$pidfile"
# Зачищаем следы при прерывании
trap cleanup INT TERM

get_config_from_exteral_source # Находим переопределенные в SD параметры выгрузки
create_dirs # Создаём нужные нам директории
prepare_file_list # Создаём список файлов готовых для выгрузки
longterm_copy # Сначала копируем файлы в долгосрочное хранилище в /srv/tar_outp/

if [[ "$DUPLO_CONTROLLED" == "true" ]] || \
    [[ "$DORIS_CONTROLLED" == "true" ]] || \
    [[ "$FTP_SERVER_CONTROLLED" == "true" ]] || \
    [[ "$FTP_CLIENT_CONTROLLED" == "true" ]]; then
    get_controlled_file #скачиваем файлы с нарушениями, которые будет отгружать
fi

andromeda_copy
fortka_copy
duplo_copy
doris_copy
ftp_server_copy
ftp_client_copy
kp_copy

# Очищаем папку /home/comp1/ptolemey_out/tar_outp
echo "$(date +"%F %T") [$$]: Очищаем папку ${source_dir}" | tee -a "$logfile"
while IFS= read -r file; do
    unlink "$file"
done < "${temp_list_dir}/file_list.txt"
echo "$(date +"%F %T") [$$]: Файлы из ${source_dir} удалены" | tee -a "$logfile"

# Очищаем папку /home/comp1/shared-files/kp
echo "$(date +"%F %T") [$$]: Очищаем папку ${kp_source_dir}" | tee -a "$logfile"
while IFS= read -r file; do
    unlink "$file"
done < "${temp_list_dir}/kp_list.txt"
echo "$(date +"%F %T") [$$]: Файлы из ${kp_source_dir} удалены" | tee -a "$logfile"

mv "${temp_list_dir}/file_list.txt" "${temp_list_dir}/file_list_previous.txt"
mv "${temp_list_dir}/kp_list.txt" "${temp_list_dir}/kp_list_previous.txt"

echo "$(date +"%F %T") [$$]: Выгружено в Андромеду: ${_andromeda_upload_counter}, в Дупло: ${_duplo_upload_counter}, \
в Дорис: ${_doris_upload_counter}, на локальный FTP сервер: ${_ftp_server_upload_counter}, с помощью FTP клиента: ${_ftp_client_upload_counter}, \
в Fortka: ${_fortka_upload_counter}. В долгосрочное хранилище передано: ${_longterm_upload_counter}, \
материалов КП передано: ${_kp_upload_counter}" | tee -a "$logfile"

# Cleanup at the end of the script
cleanup
#SCRIPT_ENDED - do not delete this tag
