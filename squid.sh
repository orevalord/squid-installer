#!/bin/bash

# === Проверка запуска от root ===
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен от root."
   exit 1
fi

# === Цвета для вывода ===
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# === Функция: ввод с дефолтом ===
ask_with_default() {
    local prompt="$1"
    local default="$2"
    read -p "$prompt [$default]: " input
    echo "${input:-$default}"
}

# === Добавление нового пользователя ===
add_user() {
    if [[ ! -f /etc/squid/passwords ]]; then
        echo "Файл паролей не найден."
        return 1
    fi
    read -p "Введите имя пользователя: " NEW_USER
    while true; do
        read -p "Введите пароль для пользователя: " NEW_PASS
        read -p "Повторите пароль: " NEW_PASS2
        if [[ "$NEW_PASS" == "$NEW_PASS2" ]]; then
            break
        else
            echo "Пароли не совпадают. Повторите ввод."
        fi
    done
    htpasswd -b /etc/squid/passwords $NEW_USER "$NEW_PASS"
    systemctl reload squid
    echo -e "${GREEN}[✓] Пользователь $NEW_USER добавлен.${NC}"
}

# === Удаление пользователя ===
remove_user_by_name() {
    local DEL_USER="$1"
    if grep -q "^$DEL_USER:" /etc/squid/passwords; then
        htpasswd -D /etc/squid/passwords $DEL_USER
        systemctl reload squid
        echo -e "${GREEN}[✓] Пользователь $DEL_USER удалён.${NC}"
    else
        echo "Пользователь не найден."
    fi
}

# === Смена пароля пользователя ===
change_password_by_name() {
    local CH_USER="$1"
    if grep -q "^$CH_USER:" /etc/squid/passwords; then
        while true; do
            read -p "Введите новый пароль для пользователя $CH_USER: " NEW_PASS
            read -p "Повторите пароль: " NEW_PASS2
            if [[ "$NEW_PASS" == "$NEW_PASS2" ]]; then
                break
            else
                echo "Пароли не совпадают. Повторите ввод."
            fi
        done
        htpasswd -b /etc/squid/passwords "$CH_USER" "$NEW_PASS"
        systemctl reload squid
        echo -e "${GREEN}[✓] Пароль пользователя $CH_USER изменён.${NC}"
    else
        echo "Пользователь не найден."
    fi
}

# === Меню управления пользователем ===
manage_user() {
    local SELECTED_USER="$1"
    while true; do
        echo -e "\nУправление пользователем: $SELECTED_USER"
        echo "1) Удалить пользователя"
        echo "2) Сменить пароль"
        echo "3) Назад"
        read -p "Выберите действие: " action
        case $action in
            1) remove_user_by_name "$SELECTED_USER"; break ;;
            2) change_password_by_name "$SELECTED_USER"; break ;;
            3) break ;;
            *) echo "Неверный ввод. Попробуйте снова." ;;
        esac
    done
}

# === Просмотр всех пользователей и выбор ===
list_users() {
    if [[ ! -f /etc/squid/passwords ]]; then
        echo "Файл паролей не найден."
        return 1
    fi

    echo -e "\nТекущие пользователи Squid:"
    mapfile -t users < <(cut -d: -f1 /etc/squid/passwords)

    if [[ ${#users[@]} -eq 0 ]]; then
        echo "Нет пользователей."
        return
    fi

    for i in "${!users[@]}"; do
        echo "$((i+1))) ${users[$i]}"
    done

    echo "0) Назад"
    read -p "Выберите пользователя для управления: " idx

    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#users[@]} )); then
        manage_user "${users[$((idx-1))]}"
    fi
}

# === Установка Squid ===
install_squid() {
    echo -e "${GREEN}[+] Установка Squid...${NC}"

    current_port=$(grep "^http_port" /etc/squid/squid.conf 2>/dev/null | awk '{print $2}')
    PROXY_PORT=$(ask_with_default "Введите порт для прокси" "${current_port:-3128}")
    PROXY_USER=$(ask_with_default "Введите имя пользователя для прокси" "proxyuser")

    while true; do
        read -p "Введите пароль для пользователя: " PROXY_PASS
        read -p "Повторите пароль: " PROXY_PASS2
        if [[ "$PROXY_PASS" == "$PROXY_PASS2" ]]; then
            break
        else
            echo "Пароли не совпадают. Повторите ввод."
        fi
    done

    apt update && DEBIAN_FRONTEND=noninteractive apt install -y squid apache2-utils

    echo "[+] Создание файла с логином и паролем..."
    htpasswd -b -c /etc/squid/passwords $PROXY_USER "$PROXY_PASS"

    echo "[+] Резервное копирование конфигурации..."
    cp /etc/squid/squid.conf "/etc/squid/squid.conf.bak.$(date +%F_%T)"

    echo "[+] Генерация новой конфигурации..."
    cat <<EOF > /etc/squid/squid.conf
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwords
auth_param basic realm Proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
http_access deny all
http_port $PROXY_PORT
visible_hostname my-squid-proxy
EOF

    echo "[+] Перезапуск службы..."
    systemctl restart squid
    systemctl enable squid

    echo -e "${GREEN}[✓] Установка завершена!${NC}"
    echo "=================================="
    PUBLIC_IP=$(curl -s ifconfig.me || curl -s api.ipify.org || echo "IP недоступен")
    echo "Прокси: http://$PUBLIC_IP:${PROXY_PORT}"
    echo "Логин: $PROXY_USER"
    echo "Пароль: $PROXY_PASS"
    echo "=================================="
}

# === Удаление Squid ===
uninstall_squid() {
    echo -e "${GREEN}[!] Удаление Squid...${NC}"

    systemctl stop squid
    apt purge -y squid apache2-utils
    apt autoremove -y
    rm -f /etc/squid/passwords
    rm -f /etc/squid/squid.conf
    rm -f /etc/squid/squid.conf.bak*

    echo -e "${GREEN}[✓] Squid удалён полностью.${NC}"
    exit 0
}

# === Главное меню ===
main_menu() {
    clear
    if dpkg -l | grep -q squid; then
        while true; do
            echo -e "${GREEN}Squid уже установлен.${NC}"
            echo "=================================="
            echo "Что вы хотите сделать?"
            echo "1) Переустановить Squid"
            echo "2) Удалить Squid"
            echo "3) Показать и управлять пользователями"
            echo "4) Добавить пользователя"
            echo "5) Выйти"
            echo "=================================="
            read -p "Введите номер опции: " choice
            case $choice in
                1) uninstall_squid && install_squid ;;
                2) uninstall_squid ;;
                3) list_users ;;
                4) add_user ;;
                5) exit 0 ;;
                *) echo "Неверный ввод. Попробуйте снова." ;;
            esac
        done
    else
        install_squid
    fi
}

main_menu
