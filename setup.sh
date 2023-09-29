#!/bin/bash

# Определяем дистрибутив
. /etc/os-release

# Путь к текущему скрипту
SCRIPT_DIR=$(dirname $(readlink -f $0))

# Устанавливаем зависимости
if [[ "$ID" == "ubuntu" ]]; then
    sudo apt-get update
    sudo apt-get install -y certbot golang
    INIT_SYSTEM="systemd"
elif [[ "$ID" == "alpine" ]]; then
    apk add --no-cache certbot go
    INIT_SYSTEM="openrc"
else
    echo "Only Ubuntu and Alpine are supported"
    exit 1
fi

# Читаем переменные окружения из ini файла
export $(awk -F "=" '{print $1"="$2}' config.ini)

# Получаем сертификат
sudo certbot certonly --standalone -d $YOUR_DOMAIN --register-unsafely-without-email --agree-tos

# Добавляем cron для обновления сертификата
(crontab -l ; echo "0 3 * * * /usr/bin/certbot renew --quiet") | crontab -

# Компилируем Go-скрипт
go build -o $SCRIPT_DIR/proxy $SCRIPT_DIR/proxy.go

# Генерируем файлы сервисов
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    cat <<EOL > /etc/systemd/system/proxy.service
    [Unit]
    Description=My Proxy Service
    After=network.target

    [Service]
    ExecStart=$SCRIPT_DIR/proxy
    Restart=always
    EnvironmentFile=$SCRIPT_DIR/config.ini
    User=nobody
    RestartSec=3
    LimitNOFILE=4096

    [Install]
    WantedBy=multi-user.target
EOL

    sudo systemctl enable /etc/systemd/system/proxy.service
    sudo systemctl start proxy.service

elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
    cat <<EOL > /etc/init.d/proxy
    #!/sbin/openrc-run

    description="My Proxy Service"
    start() {
        ebegin "Starting proxy"
        start-stop-daemon --start --exec $SCRIPT_DIR/proxy
        eend $?
    }

    stop() {
        ebegin "Stopping proxy"
        start-stop-daemon --stop --exec $SCRIPT_DIR/proxy
        eend $?
    }

EOL

    sudo chmod +x /etc/init.d/proxy
    sudo rc-update add proxy default
    sudo rc-service proxy start
fi
