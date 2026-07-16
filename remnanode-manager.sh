#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

VERSION="1.0.0"
APP_NAME="RemnaNode Manager"
INSTALL_DIR="/opt/remnanode"
BIN_PATH="/usr/local/bin/remnanode"
CONFIG_FILE="/etc/remnanode-manager.conf"
DEFAULT_NODE_PORT="2222"
DEFAULT_CLIENT_PORTS="443/tcp"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*" >&2; }
error() { printf "${RED}[x]${NC} %s\n" "$*" >&2; }
die() { error "$*"; exit 1; }
pause() { [[ -t 0 ]] && read -r -p "Нажмите Enter для продолжения..." _ || true; }
need_root() { [[ ${EUID} -eq 0 ]] || die "Запустите команду от root или через sudo."; }
installed() { [[ -f "$INSTALL_DIR/docker-compose.yml" && -f "$INSTALL_DIR/.env" ]]; }
need_install() { installed || die "Нода не установлена. Сначала выберите пункт установки."; }
compose() { (cd "$INSTALL_DIR" && docker compose "$@"); }

header() {
  clear 2>/dev/null || true
  printf "${CYAN}${BOLD}====================================================${NC}\n"
  printf "${CYAN}${BOLD}  %s v%s${NC}\n" "$APP_NAME" "$VERSION"
  printf "${CYAN}${BOLD}====================================================${NC}\n"
}

confirm() {
  local prompt="$1" answer
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" =~ ^[YyДд]$ ]]
}

validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
validate_source() { [[ "$1" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]; }
validate_port_list() { [[ "$1" =~ ^[0-9]+/(tcp|udp)(,[0-9]+/(tcp|udp))*$ ]]; }

detect_ssh_port() {
  local port
  port="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')"
  printf '%s' "${port:-22}"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  info "Обновление списка пакетов..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl nftables ufw fail2ban unattended-upgrades jq
  if ! command -v docker >/dev/null 2>&1; then
    info "Установка Docker..."
    curl -fsSL https://get.docker.com | sh
  fi
  docker compose version >/dev/null 2>&1 || die "Docker Compose V2 не найден."
  systemctl enable --now docker
}

write_compose() {
  install -d -m 700 "$INSTALL_DIR"
  cat > "$INSTALL_DIR/docker-compose.yml" <<'YAML'
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    env_file:
      - .env
    logging:
      driver: json-file
      options:
        max-size: 20m
        max-file: "5"
YAML
  chmod 600 "$INSTALL_DIR/docker-compose.yml"
}

save_manager_config() {
  cat > "$CONFIG_FILE" <<EOF
PANEL_IP='$PANEL_IP'
NODE_PORT='$NODE_PORT'
CLIENT_PORTS='$CLIENT_PORTS'
EOF
  chmod 600 "$CONFIG_FILE"
}

load_manager_config() {
  PANEL_IP=""; NODE_PORT="$DEFAULT_NODE_PORT"; CLIENT_PORTS="$DEFAULT_CLIENT_PORTS"
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  elif [[ -f "$INSTALL_DIR/.env" ]]; then
    NODE_PORT="$(awk -F= '$1=="NODE_PORT" {print $2; exit}' "$INSTALL_DIR/.env")"
    NODE_PORT="${NODE_PORT:-$DEFAULT_NODE_PORT}"
  fi
}

configure_firewall() {
  local ssh_port rule port proto
  ssh_port="$(detect_ssh_port)"
  info "Настройка firewall. SSH-порт ${ssh_port} останется доступен."
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow "${ssh_port}/tcp" comment 'SSH' >/dev/null
  ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'Remnawave Panel' >/dev/null
  IFS=',' read -ra rules <<< "$CLIENT_PORTS"
  for rule in "${rules[@]}"; do
    port="${rule%/*}"; proto="${rule#*/}"
    ufw allow "$port/$proto" comment 'Remnawave client' >/dev/null
  done
  ufw --force enable >/dev/null
  ufw reload >/dev/null
}

configure_protection() {
  local ssh_port
  ssh_port="$(detect_ssh_port)"
  cat > /etc/fail2ban/jail.d/remnanode-sshd.local <<EOF
[sshd]
enabled = true
port = ${ssh_port}
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
EOF
  systemctl enable --now fail2ban
  systemctl restart fail2ban
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
}

apply_optimization() {
  need_root
  cat > /etc/sysctl.d/99-remnanode.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=4096
net.ipv4.tcp_mtu_probing=1
fs.file-max=2097152
EOF
  sysctl --system >/dev/null
  info "BBR и безопасные сетевые параметры применены."
  printf 'TCP congestion control: '; sysctl -n net.ipv4.tcp_congestion_control
}

install_command() {
  need_root
  if installed; then
    warn "Нода уже установлена в $INSTALL_DIR."
    confirm "Переустановить с сохранением резервной копии настроек?" || return 0
    cp -a "$INSTALL_DIR" "${INSTALL_DIR}.backup-$(date +%Y%m%d-%H%M%S)"
    compose down || true
  fi

  local secret
  header
  printf "${BOLD}Установка Remnawave Node${NC}\n\n"
  read -r -p "Публичный IP сервера панели: " PANEL_IP
  validate_source "$PANEL_IP" || die "Некорректный IP панели."
  read -r -p "Порт Node API [${DEFAULT_NODE_PORT}]: " NODE_PORT
  NODE_PORT="${NODE_PORT:-$DEFAULT_NODE_PORT}"
  validate_port "$NODE_PORT" || die "Некорректный порт Node API."
  read -r -p "Клиентские порты [${DEFAULT_CLIENT_PORTS}]: " CLIENT_PORTS
  CLIENT_PORTS="${CLIENT_PORTS:-$DEFAULT_CLIENT_PORTS}"
  validate_port_list "$CLIENT_PORTS" || die "Формат: 443/tcp или 443/tcp,8443/udp"
  read -r -s -p "SECRET_KEY из Remnawave Panel: " secret; printf '\n'
  [[ ${#secret} -ge 16 && "$secret" != *$'\n'* ]] || die "SECRET_KEY выглядит некорректно."

  install_packages
  write_compose
  printf 'NODE_PORT=%s\nSECRET_KEY=%s\n' "$NODE_PORT" "$secret" > "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
  save_manager_config
  configure_firewall
  configure_protection
  apply_optimization
  install -m 755 "${BASH_SOURCE[0]}" "$BIN_PATH"

  info "Загрузка и запуск ноды..."
  compose pull
  compose up -d --remove-orphans
  sleep 3
  status_command
  printf '\n${GREEN}${BOLD}Установка завершена.${NC}\n'
  printf 'Теперь добавьте ноду в панели: адрес VDS, порт %s.\n' "$NODE_PORT"
}

update_command() {
  need_root; need_install
  info "Создаю резервную копию конфигурации..."
  tar -czf "/root/remnanode-config-$(date +%Y%m%d-%H%M%S).tar.gz" -C /opt remnanode
  info "Обновляю образ Remnawave Node..."
  compose pull
  compose up -d --remove-orphans
  docker image prune -f >/dev/null
  status_command
}

up_command() { need_root; need_install; compose up -d; status_command; }
down_command() { need_root; need_install; compose down; info "Нода остановлена."; }
restart_command() { need_root; need_install; compose restart; sleep 2; status_command; }

status_command() {
  need_install
  header
  printf "${BOLD}Состояние контейнера${NC}\n"
  compose ps
  printf "\n${BOLD}Процессы внутри ноды${NC}\n"
  docker exec remnanode supervisorctl status 2>/dev/null || warn "Не удалось получить supervisor status."
  printf "\n${BOLD}Ресурсы${NC}\n"
  docker stats --no-stream remnanode 2>/dev/null || true
  printf "\n${BOLD}Слушающие порты${NC}\n"
  load_manager_config
  ss -lntup | grep -E ":(${NODE_PORT}|443|80|61000)\\b" || warn "Ожидаемые порты не найдены."
}

logs_command() {
  need_install
  local choice
  printf '1) Общий журнал ноды\n2) Ошибки Xray\n3) Журнал Xray\n4) Последние 200 строк без слежения\n'
  read -r -p "Выберите: " choice
  case "$choice" in
    1) compose logs -f --tail=100 remnanode ;;
    2) docker exec -it remnanode sh -lc 'tail -n 100 -f /var/log/supervisor/xray.err.log' ;;
    3) docker exec -it remnanode sh -lc 'tail -n 100 -f /var/log/supervisor/xray.out.log' ;;
    4) compose logs --tail=200 remnanode ;;
    *) warn "Неверный пункт." ;;
  esac
}

diagnose_command() {
  need_install
  load_manager_config
  header
  printf "${BOLD}Диагностика Remnawave Node${NC}\n\n"
  printf 'Время: '; date
  printf 'Uptime: '; uptime -p
  printf 'Публичный IPv4: '; curl -4fsS --max-time 8 https://ifconfig.me || printf 'не определён'; printf '\n'
  printf 'DNS: '; getent ahostsv4 google.com | head -n1 || true
  printf 'Интернет по IP: '; ping -c 1 -W 2 1.1.1.1 >/dev/null && echo OK || echo FAIL
  printf 'HTTPS: '; curl -4fsSI --max-time 8 https://www.google.com >/dev/null && echo OK || echo FAIL
  printf 'Docker: '; systemctl is-active docker || true
  printf 'Контейнер: '; docker inspect remnanode --format '{{.State.Status}}, restarts={{.RestartCount}}' 2>/dev/null || echo FAIL
  printf 'Node API %s: ' "$NODE_PORT"; ss -lnt | grep -qE ":${NODE_PORT}\\b" && echo LISTEN || echo CLOSED
  printf 'BBR: '; sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true
  printf '\n${BOLD}Firewall${NC}\n'; ufw status | tail -n 30
  printf '\n${BOLD}Последние ошибки${NC}\n'
  docker logs --tail=300 remnanode 2>&1 | grep -Ei 'error|failed|fatal|panic|refused|timeout|invalid' | tail -n 30 || echo 'Критических ошибок не найдено.'
}

firewall_command() {
  need_root; load_manager_config
  printf '1) Показать правила\n2) Применить безопасные правила заново\n3) Разблокировать IP в Fail2Ban\n'
  read -r -p "Выберите: " choice
  case "$choice" in
    1) ufw status numbered; fail2ban-client status sshd 2>/dev/null || true ;;
    2) configure_firewall; info "Правила применены." ;;
    3) read -r -p "IP для разблокировки: " ip; validate_source "$ip" || die "Некорректный IP"; fail2ban-client set sshd unbanip "$ip" || true ;;
    *) warn "Неверный пункт." ;;
  esac
}

backup_command() {
  need_root; need_install
  local file="/root/remnanode-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$file" -C /opt remnanode
  chmod 600 "$file"
  info "Резервная копия: $file"
}

auto_restart_command() {
  need_root
  cat > /etc/systemd/system/remnanode-restart.service <<'EOF'
[Unit]
Description=Scheduled Remnawave Node restart
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/usr/bin/docker restart remnanode
EOF
  cat > /etc/systemd/system/remnanode-restart.timer <<'EOF'
[Unit]
Description=Restart Remnawave Node weekly
[Timer]
OnCalendar=Sun *-*-* 05:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now remnanode-restart.timer
  systemctl list-timers remnanode-restart.timer --no-pager
}

uninstall_command() {
  need_root
  confirm "Удалить контейнер и файлы ноды? Резервная копия будет сохранена" || return 0
  if installed; then backup_command; compose down || true; fi
  rm -rf -- "$INSTALL_DIR"
  rm -f -- "$CONFIG_FILE" "$BIN_PATH"
  systemctl disable --now remnanode-restart.timer 2>/dev/null || true
  rm -f /etc/systemd/system/remnanode-restart.{service,timer}
  systemctl daemon-reload
  info "Remnawave Node удалена. Docker, UFW и системная защита оставлены."
}

menu() {
  need_root
  while true; do
    header
    if installed; then printf "Статус установки: ${GREEN}УСТАНОВЛЕНА${NC}\n\n"; else printf "Статус установки: ${YELLOW}НЕ УСТАНОВЛЕНА${NC}\n\n"; fi
    cat <<'EOF'
  1) Установить или переустановить ноду
  2) Статус ноды
  3) Запустить ноду
  4) Остановить ноду
  5) Перезапустить ноду
  6) Обновить ноду
  7) Посмотреть журналы
  8) Полная диагностика
  9) Firewall и Fail2Ban
 10) Применить оптимизацию BBR
 11) Создать резервную копию
 12) Еженедельный автоперезапуск
 13) Удалить ноду
  0) Выход
EOF
    printf '\n'
    read -r -p "Выберите действие: " choice
    case "$choice" in
      1) install_command ;; 2) status_command ;; 3) up_command ;; 4) down_command ;;
      5) restart_command ;; 6) update_command ;; 7) logs_command ;; 8) diagnose_command ;;
      9) firewall_command ;; 10) apply_optimization ;; 11) backup_command ;;
      12) auto_restart_command ;; 13) uninstall_command ;; 0) exit 0 ;;
      *) warn "Неверный пункт." ;;
    esac
    pause
  done
}

usage() {
  cat <<EOF
$APP_NAME v$VERSION
Использование: remnanode [команда]

Без команды открывается русское меню.
Команды: install, status, up, down, restart, update, logs, diagnose,
         firewall, optimize, backup, auto-restart, uninstall, help
EOF
}

case "${1:-menu}" in
  menu) menu ;; install) install_command ;; status) status_command ;; up) up_command ;;
  down) down_command ;; restart) restart_command ;; update) update_command ;;
  logs) logs_command ;; diagnose|doctor) diagnose_command ;; firewall) firewall_command ;;
  optimize) apply_optimization ;; backup) backup_command ;; auto-restart) auto_restart_command ;;
  uninstall) uninstall_command ;; help|-h|--help) usage ;; *) usage; exit 1 ;;
esac

