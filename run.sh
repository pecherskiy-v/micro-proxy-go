#!/bin/bash

# По умолчанию, вопросы будут задаваться
SILENT=false

# Парсинг флагов командной строки
while getopts "s" OPTION; do
  case $OPTION in
    s)
      SILENT=true
      ;;
    *)
      echo "Неверный флаг"
      exit 1
      ;;
  esac
done

# Определяем дистрибутив и ОС
if [ -f /etc/os-release ]; then
    . /etc/os-release
fi

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
elif [[ "$OSTYPE" == "darwin"* ]]; then
    # Проверяем, установлен ли Homebrew
    if ! command -v brew &> /dev/null; then
        # Устанавливаем Homebrew
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi

    # Проверяем наличие certbot и go
    if ! brew list certbot &>/dev/null; then
        brew install certbot
    fi
    if ! brew list go &>/dev/null; then
        brew install go
    fi
    INIT_SYSTEM="macOS"
else
    echo "Only Ubuntu, Alpine, and macOS are supported"
    exit 1
fi

# Чтение переменных окружения из ini файла
#declare -A config
while IFS="=" read -r key value; do
  eval "config_$key=$value"
done < config.ini

# Если режим не тихий, задаем вопросы
if [ "$SILENT" = false ]; then
  # Устанавливаем значения по умолчанию
  default_domain=${config_YOUR_DOMAIN:-"example.com"}
  default_target_domain=${config_TARGET_DOMAIN:-"target.example.com"}
  default_listen_port=${config_LISTEN_PORT:-"8080"}
  default_cert_path=${config_CERT_PATH:-"/etc/letsencrypt/live/your_domain_name/fullchain.pem"}
  default_key_path=${config_KEY_PATH:-"/etc/letsencrypt/live/your_domain_name/privkey.pem"}

  # Задаем вопросы
  read -p "Введите ваш домен (по умолчанию: $default_domain): " input
  YOUR_DOMAIN=${input:-$default_domain}

  read -p "Введите целевой домен (по умолчанию: $default_target_domain): " input
  TARGET_DOMAIN=${input:-$default_target_domain}

  read -p "Введите порт для прослушивания (по умолчанию: $default_listen_port): " input
  LISTEN_PORT=${input:-$default_listen_port}

  read -p "Введите путь к сертификату (по умолчанию: $default_cert_path): " input
  CERT_PATH=${input:-$default_cert_path}

  read -p "Введите путь к приватному ключу (по умолчанию: $default_key_path): " input
  KEY_PATH=${input:-$default_key_path}

  # Удаляем старые значения из config.ini
  sed -i.bak '/YOUR_DOMAIN/d' config.ini
  sed -i.bak '/TARGET_DOMAIN/d' config.ini
  sed -i.bak '/LISTEN_PORT/d' config.ini
  sed -i.bak '/CERT_PATH/d' config.ini
  sed -i.bak '/KEY_PATH/d' config.ini

  # Удалить бэкап файлы созданные sed на macOS
  rm -f config.ini.bak


  # Записываем новые значения в config.ini
  echo "YOUR_DOMAIN=$YOUR_DOMAIN" >> config.ini
  echo "TARGET_DOMAIN=$TARGET_DOMAIN" >> config.ini
  echo "LISTEN_PORT=$LISTEN_PORT" >> config.ini
  echo "CERT_PATH=$CERT_PATH" >> config.ini
  echo "KEY_PATH=$KEY_PATH" >> config.ini
fi


# Читаем переменные окружения из ini файла
export $(awk -F "=" '{print $1"="$2}' config.ini)

# Получаем сертификат
if [ "$SILENT" = false ]; then
  read -p "Хотите ли вы запустить certbot для получения SSL-сертификата? (y/n): " confirm
fi
if [ "$confirm" = "y" ]; then
  sudo certbot certonly --standalone -d $YOUR_DOMAIN --register-unsafely-without-email --agree-tos
  # Добавляем cron для обновления сертификата
  (crontab -l ; echo "0 3 * * * /usr/bin/certbot renew --quiet") | crontab -
else
  echo "Пропускаем этап получения SSL-сертификата."
fi

# Проверяем наличие Go
if ! command -v go &> /dev/null; then
    echo "Go не установлен. Установите Go и попробуйте снова."
    exit 1
fi

# Если операционная система — macOS
if [[ "$OSTYPE" == "darwin"* ]]; then
    # Используем `which go`, чтобы найти путь к Go
    GO_EXEC_PATH=$(which go)
#    echo "GO_EXEC_PATH=$GO_EXEC_PATH"

    # Получаем реальный путь к Go
    REAL_GO_PATH=$(readlink -f $GO_EXEC_PATH)

    # Ищем libexec относительно найденного пути
    POSSIBLE_GOROOT=$(dirname $(dirname $REAL_GO_PATH))
#    echo "POSSIBLE_GOROOT=$POSSIBLE_GOROOT"

    # Проверяем, существует ли папка libexec
    if [ -d "$POSSIBLE_GOROOT" ]; then
        export GOROOT=$POSSIBLE_GOROOT
#        echo "Установлен GOROOT=$GOROOT"
    else
        echo "Не могу найти папку libexec рядом с Go. Все плохо."
        exit 1
    fi
fi

echo "Тянем зависимости GO."
go mod download
echo "Компилируем Go-скрипт"
# Компилируем Go-скрипт
go build -o $SCRIPT_DIR/proxy $SCRIPT_DIR/main.go

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
    User=root
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
elif [[ "$INIT_SYSTEM" == "macOS" ]]; then
    # Запускаем скомпилированное приложение с флагом -stat на macOS
    $SCRIPT_DIR/proxy -stat -https=off
fi
