#!/usr/bin/env bash
# deploy_wsl.sh - WSL‑ready deployment script for Samsung LHB55ECH Video Wall System
# - Works on native Linux and WSL (with or without systemd)
# - Uses systemd when available; otherwise falls back to Supervisor to manage nginx + app
# - Skips unsupported bits on WSL (ufw, firewalld, fail2ban, logrotate)

set -euo pipefail

# ===== Colors =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ===== Config =====
PROJECT_NAME="video-wall-control"
INSTALL_DIR="/opt/${PROJECT_NAME}"
SERVICE_USER="videowall"
PYTHON_VERSION="3.11"
VENV_DIR="${INSTALL_DIR}/venv"
APP_ENTRY="video_wall_server.py"  # Python entry point expected to exist in repo
SERVICE_NAME="video-wall"

# Derived / runtime\PYTHON_BIN=""
PKG_MANAGER=""
IS_WSL=false
HAS_SYSTEMD=false
INIT_MODE="supervisor"  # supervisor|systemd (decided later)

# ===== Helpers =====
print_status(){ echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error(){ echo -e "${RED}[ERROR]${NC} $1"; }

check_root(){
  if [[ ${EUID} -ne 0 ]]; then
    print_error "This script must be run as root. Try: sudo $0"
    exit 1
  fi
}

detect_wsl(){
  if grep -qi "microsoft" /proc/sys/kernel/osrelease 2>/dev/null; then
    IS_WSL=true
  elif [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -n "${WSL_INTEROP:-}" ]]; then
    IS_WSL=true
  fi
  $IS_WSL && print_status "Detected WSL environment" || print_status "Running on native Linux"
}

detect_os(){
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$NAME; VER=$VERSION_ID
  else
    print_error "Cannot detect operating system"; exit 1
  fi
  print_status "Detected OS: ${OS} ${VER}"

  if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
  elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
  elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
  else
    print_error "No supported package manager found (apt/dnf/yum)."; exit 1
  fi
}

detect_init(){
  if [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; then
    HAS_SYSTEMD=true
  fi
  if $IS_WSL && ! $HAS_SYSTEMD; then
    INIT_MODE="supervisor"
  else
    INIT_MODE=$($HAS_SYSTEMD && echo systemd || echo supervisor)
  fi
  print_status "Init mode: ${INIT_MODE} ($($HAS_SYSTEMD && echo "systemd present" || echo "no systemd"))"
}

maybe_hint_enable_systemd_wsl(){
  if $IS_WSL && ! $HAS_SYSTEMD; then
    cat << 'WSLHINT'
[HINT] WSL without systemd detected. We'll use Supervisor to manage processes.
If you prefer systemd services in WSL, enable it and re-run:
  1) Edit /etc/wsl.conf with:
       [boot]
       systemd=true
  2) From Windows PowerShell (Admin):  wsl --shutdown
  3) Launch your distro again and re-run this installer.
WSLHINT
  fi
}

install_dependencies(){
  print_status "Installing system dependencies..."
  case "$PKG_MANAGER" in
    apt)
      apt-get update
      # Base tooling
      apt-get install -y \ 
        sudo ca-certificates curl wget git net-tools iputils-ping nginx sqlite3 \ 
        python3 python3-venv python3-pip # Always have python3; choose specific later
      # Supervisor for non-systemd
      if [[ "$INIT_MODE" == "supervisor" ]]; then
        apt-get install -y supervisor
      fi
      ;;
    dnf|yum)
      $PKG_MANAGER -y update || true
      $PKG_MANAGER -y install \ 
        ca-certificates curl wget git net-tools iputils nginx sqlite \ 
        python3 python3-venv python3-pip
      if [[ "$INIT_MODE" == "supervisor" ]]; then
        $PKG_MANAGER -y install supervisor || true
      fi
      ;;
  esac
}

select_python(){
  # Try desired version first, else fall back to python3
  if command -v python${PYTHON_VERSION} &>/dev/null; then
    PYTHON_BIN="python${PYTHON_VERSION}"
  elif command -v python3 &>/dev/null; then
    PYTHON_BIN="python3"
    print_warning "python${PYTHON_VERSION} not found; falling back to python3 ($(python3 --version 2>/dev/null || echo unknown))"
  else
    print_error "No Python 3 interpreter found."; exit 1
  fi
  print_status "Using Python: $($PYTHON_BIN --version)"
}

create_user(){
  print_status "Ensuring service user exists: ${SERVICE_USER}"
  if id -u "$SERVICE_USER" &>/dev/null; then
    print_warning "User ${SERVICE_USER} already exists"
  else
    useradd -r -s /usr/sbin/nologin -d "$INSTALL_DIR" "$SERVICE_USER" || useradd -r -s /bin/false -d "$INSTALL_DIR" "$SERVICE_USER"
    print_status "User ${SERVICE_USER} created"
  fi
}

create_directories(){
  print_status "Creating directory structure under ${INSTALL_DIR}..."
  mkdir -p "$INSTALL_DIR"/{static_content,uploads,logs,config,backups}
  mkdir -p /var/log/video-wall
  mkdir -p /etc/video-wall
  chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" /var/log/video-wall
  chmod 755 "$INSTALL_DIR"
  chmod 750 "$INSTALL_DIR"/{uploads,logs,config,backups}
}

install_application(){
  print_status "Setting up Python virtual environment..."
  "$PYTHON_BIN" -m venv "$VENV_DIR"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$VENV_DIR"
  sudo -u "$SERVICE_USER" "$VENV_DIR/bin/pip" install --upgrade pip wheel

  print_status "Installing Python dependencies..."
  sudo -u "$SERVICE_USER" "$VENV_DIR/bin/pip" install \
    Flask==2.3.3 Flask-CORS==4.0.0 Flask-SocketIO==5.3.6 python-socketio==5.8.0 \
    requests==2.31.0 aiohttp==3.8.5 pyserial==3.5 schedule==1.2.0 PyYAML==6.0 \
    pandas==2.0.3 matplotlib==3.7.2 seaborn==0.12.2

  # Copy application files if present in current dir
  if [[ -f "$APP_ENTRY" ]]; then
    cp -f ./*.py "$INSTALL_DIR/" || true
    [[ -f requirements.txt ]] && cp -f requirements.txt "$INSTALL_DIR/" || true
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
    print_status "Application files copied to ${INSTALL_DIR}"
  else
    print_warning "${APP_ENTRY} not found in current directory. Place your app files into ${INSTALL_DIR} later."
  fi
}

configure_systemd_service(){
  print_status "Configuring systemd service ${SERVICE_NAME}.service"
  cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Samsung LHB55ECH Video Wall Control System
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
Environment=PATH=${VENV_DIR}/bin
Environment=PYTHONPATH=${INSTALL_DIR}
ExecStart=${VENV_DIR}/bin/python ${APP_ENTRY}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${INSTALL_DIR} /var/log/video-wall

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ${SERVICE_NAME}
}

configure_supervisor(){
  print_status "Configuring Supervisor for nginx + ${SERVICE_NAME}"
  # Ensure log dir exists
  mkdir -p /var/log/video-wall
  # Program: app
  cat > /etc/supervisor/conf.d/${SERVICE_NAME}.conf << EOF
[program:${SERVICE_NAME}]
directory=${INSTALL_DIR}
command=${VENV_DIR}/bin/python ${APP_ENTRY}
user=${SERVICE_USER}
autostart=true
autorestart=true
startsecs=3
redirect_stderr=true
stdout_logfile=/var/log/video-wall/${SERVICE_NAME}.log
environment=PYTHONPATH="${INSTALL_DIR}",PATH="${VENV_DIR}/bin:/usr/bin:/bin"
EOF
  # Program: nginx run in foreground
  cat > /etc/supervisor/conf.d/nginx.conf << 'EOF'
[program:nginx]
command=/usr/sbin/nginx -g 'daemon off;'
autostart=true
autorestart=true
startsecs=3
stdout_logfile=/var/log/video-wall/nginx_foreground.log
redirect_stderr=true
EOF
  supervisorctl reread
  supervisorctl update
}

configure_nginx(){
  print_status "Configuring Nginx..."
  if [[ -f /etc/nginx/sites-available/default ]]; then
    cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default.backup || true
  fi
  cat > /etc/nginx/sites-available/${SERVICE_NAME} << EOF
server {
    listen 80;
    server_name localhost _;

    client_max_body_size 100M;

    location /static/ {
        alias ${INSTALL_DIR}/static_content/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    location /uploads/ {
        alias ${INSTALL_DIR}/uploads/;
        expires 1h;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location /socket.io/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
}
EOF
  ln -sf /etc/nginx/sites-available/${SERVICE_NAME} /etc/nginx/sites-enabled/${SERVICE_NAME}
  [[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default || true
  nginx -t
  if [[ "$INIT_MODE" == "systemd" ]]; then
    systemctl enable nginx
  fi
  print_status "Nginx configured"
}

configure_firewall(){
  if $IS_WSL; then
    print_warning "WSL detected: skipping Linux firewall (ufw/firewalld). Use Windows Defender Firewall to open ports 80 and 5000."
  else
    if command -v ufw &>/dev/null; then
      ufw --force enable
      ufw default deny incoming
      ufw default allow outgoing
      ufw allow ssh
      ufw allow 80/tcp
      ufw allow 443/tcp
      ufw allow 5000/tcp
      print_status "UFW configured"
    elif command -v firewall-cmd &>/dev/null; then
      systemctl enable firewalld || true
      systemctl start firewalld || true
      firewall-cmd --permanent --add-service=ssh
      firewall-cmd --permanent --add-service=http
      firewall-cmd --permanent --add-service=https
      firewall-cmd --permanent --add-port=5000/tcp
      firewall-cmd --reload
      print_status "Firewalld configured"
    else
      print_warning "No supported firewall found; skipping"
    fi
  fi
}

configure_logging_and_security_extras(){
  if $IS_WSL; then
    print_warning "WSL: skipping logrotate and fail2ban setup"
    return
  fi
  # Optional: logrotate
  cat > /etc/logrotate.d/${SERVICE_NAME} << EOF
/var/log/video-wall/*.log {
  daily
  missingok
  rotate 30
  compress
  delaycompress
  notifempty
  create 0644 ${SERVICE_USER} ${SERVICE_USER}
}
EOF
  # Optional: fail2ban (only if installed already)
  if command -v fail2ban-server &>/dev/null; then
    cat > /etc/fail2ban/jail.d/${SERVICE_NAME}.local << EOF
[${SERVICE_NAME}]
enabled = true
logpath = /var/log/video-wall/${SERVICE_NAME}.log
maxretry = 10
findtime = 600
bantime = 3600
EOF
    systemctl enable fail2ban || true
    systemctl restart fail2ban || true
  fi
}

create_default_config(){
  print_status "Creating default config.yaml"
  cat > "${INSTALL_DIR}/config.yaml" << EOF
# Samsung LHB55ECH Video Wall Configuration
# Edit this file to match your setup

displays:
  1: { name: "Display 1 - Main",  ip: "192.168.1.101", port: 1515, protocol: "tcp", model: "LHB55ECH", location: "Main Hall",      mac_address: "" }
  2: { name: "Display 2 - Left",  ip: "192.168.1.102", port: 1515, protocol: "tcp", model: "LHB55ECH", location: "Left Wing",      mac_address: "" }
  3: { name: "Display 3 - Right", ip: "192.168.1.103", port: 1515, protocol: "tcp", model: "LHB55ECH", location: "Right Wing",     mac_address: "" }
  4: { name: "Display 4 - Bottom",ip: "192.168.1.104", port: 1515, protocol: "tcp", model: "LHB55ECH", location: "Information Desk", mac_address: "" }

magicinfo:
  enabled: false
  server_url: "http://192.168.1.200:7001"
  username: "admin"
  password: "admin123"
  api_key: ""

optisigns:
  enabled: false
  server_url: "http://192.168.1.201:8080"
  api_key: ""
  username: "admin"
  password: "admin123"

content:
  static_path: "${INSTALL_DIR}/static_content/"
  upload_path: "${INSTALL_DIR}/uploads/"
  max_file_size: 100  # MB
  allowed_extensions: [".jpg", ".jpeg", ".png", ".gif", ".mp4", ".avi", ".mov", ".webm"]
  streaming_sources: { rtmp_server: "", youtube_api_key: "" }

server:
  host: "0.0.0.0"
  port: 5000
  debug: false
  ssl_enabled: false
  ssl_cert: ""
  ssl_key: ""

logging:
  level: "INFO"
  file: "/var/log/video-wall/video_wall.log"
  max_size: 10  # MB
  backup_count: 5

network:
  discovery_range: "192.168.1."
  timeout: 5
  retry_attempts: 3

maintenance:
  health_check_interval: 300
  temperature_warning: 55
  temperature_critical: 65
  auto_restart_on_error: true
  backup_interval: 86400
EOF
  chown ${SERVICE_USER}:${SERVICE_USER} "${INSTALL_DIR}/config.yaml"
  chmod 640 "${INSTALL_DIR}/config.yaml"
}

create_sample_content(){
  print_status "Creating sample static content..."
  cat > "${INSTALL_DIR}/static_content/welcome.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Welcome</title>
  <style>
    body { margin:0; padding:0; background:linear-gradient(135deg,#667eea 0%,#764ba2 100%); color:#fff; font-family:Arial,sans-serif; display:flex; justify-content:center; align-items:center; height:100vh; text-align:center; }
    .welcome-container { max-width:800px; padding:50px; }
    h1 { font-size:4rem; margin-bottom:20px; text-shadow:2px 2px 4px rgba(0,0,0,.3); }
    p { font-size:1.5rem; opacity:.9; }
    .time { font-size:2rem; margin-top:30px; font-weight:bold; }
  </style>
</head>
<body>
  <div class="welcome-container">
    <h1>🖥️ Video Wall System</h1>
    <p>Samsung LHB55ECH Business Display</p>
    <p>System Online and Ready</p>
    <div class="time" id="current-time"></div>
  </div>
  <script>
    function updateTime(){ document.getElementById('current-time').textContent = new Date().toLocaleString(); }
    setInterval(updateTime, 1000); updateTime();
  </script>
</body>
</html>
EOF
  chown -R ${SERVICE_USER}:${SERVICE_USER} "${INSTALL_DIR}/static_content/"
}

create_management_script(){
  print_status "Creating management helper at ${INSTALL_DIR}/manage.sh and /usr/local/bin/video-wall"
  cat > "${INSTALL_DIR}/manage.sh" << 'EOF'
#!/usr/bin/env bash
SERVICE_NAME="video-wall"
INSTALL_DIR="/opt/video-wall-control"
LOG_FILE="/var/log/video-wall/video_wall.log"

is_systemd(){ [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; }

start(){
  if is_systemd; then
    systemctl start nginx ${SERVICE_NAME}
  else
    supervisorctl start nginx ${SERVICE_NAME}
  fi
}
stop(){
  if is_systemd; then
    systemctl stop ${SERVICE_NAME} nginx
  else
    supervisorctl stop ${SERVICE_NAME} nginx
  fi
}
restart(){
  if is_systemd; then
    systemctl restart ${SERVICE_NAME} nginx
  else
    supervisorctl restart ${SERVICE_NAME} nginx
  fi
}
status(){
  if is_systemd; then
    echo "=== ${SERVICE_NAME} ==="; systemctl status ${SERVICE_NAME} --no-pager -l || true
    echo "=== nginx ==="; systemctl status nginx --no-pager -l || true
  else
    echo "=== Supervisor status ==="; supervisorctl status || true
  fi
}
logs(){ tail -f "$LOG_FILE"; }
health(){ cd "$INSTALL_DIR" && ./venv/bin/python lhb55ech_utilities.py health; }
backup(){
  BACKUP_DIR="$INSTALL_DIR/backups/$(date +%Y%m%d_%H%M%S)"; mkdir -p "$BACKUP_DIR"
  cp -r "$INSTALL_DIR/config.yaml" "$BACKUP_DIR/"
  [[ -f "$INSTALL_DIR/video_wall.db" ]] && cp -r "$INSTALL_DIR/video_wall.db" "$BACKUP_DIR/" || true
  cp -r "$INSTALL_DIR/static_content" "$BACKUP_DIR/"
  echo "Backup created: $BACKUP_DIR"
}
update(){
  if is_systemd; then systemctl stop ${SERVICE_NAME}; fi
  cd "$INSTALL_DIR"
  git pull 2>/dev/null || echo "Git not available - manual update required"
  ./venv/bin/pip install -r requirements.txt || true
  if is_systemd; then systemctl start ${SERVICE_NAME}; else supervisorctl restart ${SERVICE_NAME}; fi
}
case "$1" in
  start) start;; stop) stop;; restart) restart;; status) status;; logs) logs;; health) health;; backup) backup;; update) update;;
  *) echo "Usage: $0 {start|stop|restart|status|logs|health|backup|update}"; exit 1;;
esac
EOF
  chmod +x "${INSTALL_DIR}/manage.sh"
  ln -sf "${INSTALL_DIR}/manage.sh" /usr/local/bin/video-wall
  chown -R ${SERVICE_USER}:${SERVICE_USER} "${INSTALL_DIR}"
}

start_services(){
  print_status "Starting services..."
  if [[ "$INIT_MODE" == "systemd" ]]; then
    systemctl start nginx ${SERVICE_NAME}
    sleep 2
    systemctl is-active --quiet ${SERVICE_NAME} && print_status "✅ ${SERVICE_NAME} is running" || { print_error "❌ ${SERVICE_NAME} failed"; systemctl status ${SERVICE_NAME} --no-pager || true; }
    systemctl is-active --quiet nginx && print_status "✅ nginx is running" || { print_error "❌ nginx failed"; systemctl status nginx --no-pager || true; }
  else
    supervisorctl start nginx ${SERVICE_NAME} || true
    sleep 2
    supervisorctl status || true
  fi
}

run_wizard(){
  print_status "Running configuration wizard (if available)..."
  if [[ -f "${INSTALL_DIR}/samsung_lhb55ech_adapter.py" ]]; then
    sudo -u ${SERVICE_USER} ${VENV_DIR}/bin/python -c "from samsung_lhb55ech_adapter import run_configuration_wizard; run_configuration_wizard()"
  else
    print_warning "Configuration wizard module not found; skipping"
  fi
}

show_completion(){
  echo
  echo "🎉 ================================"
  echo "🎉  INSTALLATION COMPLETED!"
  echo "🎉 ================================"
  echo
  local IP=$(hostname -I | awk '{print $1}')
  echo "Web:            http://${IP}"
  echo "Direct API:     http://${IP}:5000"
  echo "Dashboard:      http://${IP}/dashboard"
  echo
  echo "Commands:       video-wall start|stop|restart|status|logs|health|backup|update"
  echo "Config file:    ${INSTALL_DIR}/config.yaml"
  echo "Logs:           /var/log/video-wall/"
  echo
  if $IS_WSL; then
    echo "WSL note: open Windows Firewall for ports 80 and 5000 if accessing from LAN."
  fi
}

main(){
  echo -e "${BLUE}🚀 Samsung LHB55ECH Video Wall Deployment (WSL‑ready)${NC}"
  check_root
  detect_wsl
  detect_os
  detect_init
  maybe_hint_enable_systemd_wsl

  print_status "Install dir: ${INSTALL_DIR}"
  print_status "Service user: ${SERVICE_USER}"

  read -p "Continue with installation? (y/N) " -n 1 -r; echo
  [[ $REPLY =~ ^[Yy]$ ]] || { echo "Installation cancelled."; exit 1; }

  install_dependencies
  select_python
  create_user
  create_directories
  install_application
  configure_nginx
  configure_firewall
  configure_logging_and_security_extras
  create_default_config
  create_sample_content
  create_management_script

  if [[ "$INIT_MODE" == "systemd" ]]; then
    configure_systemd_service
  else
    configure_supervisor
  fi

  start_services

  echo
  read -p "Run the configuration wizard now (if available)? (y/N) " -n 1 -r; echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    run_wizard
  else
    print_warning "Remember to edit ${INSTALL_DIR}/config.yaml with your display IPs."
  fi

  show_completion
}

case "${1:-install}" in
  install) main ;;
  uninstall)
    print_status "Uninstalling Video Wall System..."
    if [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; then
      systemctl stop ${SERVICE_NAME} nginx 2>/dev/null || true
      systemctl disable ${SERVICE_NAME} nginx 2>/dev/null || true
      rm -f "/etc/systemd/system/${SERVICE_NAME}.service" || true
      systemctl daemon-reload || true
    else
      supervisorctl stop ${SERVICE_NAME} nginx 2>/dev/null || true
      rm -f /etc/supervisor/conf.d/${SERVICE_NAME}.conf /etc/supervisor/conf.d/nginx.conf || true
      supervisorctl reread || true
      supervisorctl update || true
    fi
    rm -f /etc/nginx/sites-enabled/${SERVICE_NAME} /etc/nginx/sites-available/${SERVICE_NAME} || true
    rm -f /usr/local/bin/video-wall || true
    id -u ${SERVICE_USER} &>/dev/null && userdel ${SERVICE_USER} 2>/dev/null || true
    read -p "Remove installation directory ${INSTALL_DIR}? (y/N) " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && rm -rf "${INSTALL_DIR}"
    print_status "Uninstallation completed"
    ;;
  update)
    print_status "Updating Python dependencies..."
    cd "${INSTALL_DIR}"
    ${VENV_DIR}/bin/pip install --upgrade -r requirements.txt || true
    if [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; then
      systemctl restart ${SERVICE_NAME}
    else
      supervisorctl restart ${SERVICE_NAME}
    fi
    print_status "Update completed"
    ;;
  *)
    echo "Usage: $0 {install|uninstall|update}"; exit 1 ;;
esac


# ==============================
# 🐳 Dockerization (compose setup)
# ==============================
# Files below: place them in a new project folder.
# Structure:
#   ./Dockerfile
#   ./docker-compose.yml
#   ./docker-entrypoint.sh
#   ./nginx/default.conf
#   ./app/ (your Python files incl. video_wall_server.py)
#   ./data/ (created on first run for persistent content & config)

# ---------- Dockerfile ----------
# filename: Dockerfile
# Build the Flask/Socket.IO app image (runs `python video_wall_server.py`)
FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 INSTALL_DIR=/app DATA_DIR=/data
WORKDIR /app

# OS deps (build-essential only if you need scientific libs to compile)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl && rm -rf /var/lib/apt/lists/*

# Requirements (use your own requirements.txt if you have one)
COPY requirements.txt /tmp/requirements.txt
RUN pip install --upgrade pip wheel && pip install -r /tmp/requirements.txt

# Copy your app code (expects video_wall_server.py in ./app)
COPY app/ /app/

# Copy entrypoint + default config template
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 5000
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]


# ---------- requirements.txt ----------
# filename: requirements.txt
Flask==2.3.3
Flask-CORS==4.0.0
Flask-SocketIO==5.3.6
python-socketio==5.8.0
requests==2.31.0
aiohttp==3.8.5
pyserial==3.5
schedule==1.2.0
PyYAML==6.0
pandas==2.0.3
matplotlib==3.7.2
seaborn==0.12.2
# For websockets performance when running via python script
eventlet==0.33.3
# Optional if you later switch to Gunicorn
# gunicorn==21.2.0


# ---------- docker-compose.yml ----------
# filename: docker-compose.yml
version: "3.8"
services:
  app:
    build: .
    container_name: video-wall-app
    environment:
      - INSTALL_DIR=/app
      - DATA_DIR=/data
    volumes:
      - ./data:/data
      # Mount your source for live dev; remove in prod if you prefer immutable image
      - ./app:/app
    ports:
      - "5000:5000"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000/"]
      interval: 30s
      timeout: 5s
      retries: 5

  nginx:
    image: nginx:alpine
    container_name: video-wall-nginx
    depends_on:
      - app
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ./data:/data:ro
    ports:
      - "80:80"

networks:
  default:
    name: video-wall-net


# ---------- docker-entrypoint.sh ----------
# filename: docker-entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail
: "${INSTALL_DIR:=/app}"
: "${DATA_DIR:=/data}"

mkdir -p "$DATA_DIR/static_content" "$DATA_DIR/uploads" "$DATA_DIR/backups"
mkdir -p /var/log/video-wall

# Create default config if missing (paths point to /data)
if [[ ! -f "$DATA_DIR/config.yaml" ]]; then
  cat > "$DATA_DIR/config.yaml" << 'EOF'
# Samsung LHB55ECH Video Wall Configuration (container default)
displays:
  1: { name: "Display 1 - Main",  ip: "192.168.1.101", port: 1515, protocol: "tcp", model: "LHB55ECH", location: "Main Hall",      mac_address: "" }
  2: { name: "Display 2 - Left",  ip: "192.168.1.102", port: 1515, protocol: "tcp", model: "LHB55ECH", location: "Left Wing",      mac_address: "" }
  3: { name: "Display 3 - Right", ip: "192.168.1.103", port: 1515, protocol: "tcp", model: "LHB55ECH", location: "Right Wing",     mac_address: "" }
  4: { name: "Display 4 - Bottom",ip: "192.168.1.104", port: 1515, protocol: "tcp", model: "LHB55ECH", location: "Information Desk", mac_address: "" }
content:
  static_path: "/data/static_content/"
  upload_path: "/data/uploads/"
  max_file_size: 100
  allowed_extensions: [".jpg", ".jpeg", ".png", ".gif", ".mp4", ".avi", ".mov", ".webm"]
server:
  host: "0.0.0.0"
  port: 5000
  debug: false
logging:
  level: "INFO"
  file: "/var/log/video-wall/video_wall.log"
network:
  discovery_range: "192.168.1."
  timeout: 5
  retry_attempts: 3
maintenance:
  health_check_interval: 300
  temperature_warning: 55
  temperature_critical: 65
  auto_restart_on_error: true
  backup_interval: 86400
EOF
fi

# Sample welcome page
if [[ ! -f "$DATA_DIR/static_content/welcome.html" ]]; then
  cat > "$DATA_DIR/static_content/welcome.html" << 'EOF'
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1"/><title>Welcome</title><style>body{margin:0;padding:0;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:#fff;font-family:Arial,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;text-align:center}.welcome-container{max-width:800px;padding:50px}h1{font-size:4rem;margin-bottom:20px;text-shadow:2px 2px 4px rgba(0,0,0,.3)}p{font-size:1.5rem;opacity:.9}.time{font-size:2rem;margin-top:30px;font-weight:700}</style></head><body><div class="welcome-container"><h1>🖥️ Video Wall System</h1><p>Samsung LHB55ECH Business Display</p><p>System Online and Ready</p><div class="time" id="current-time"></div></div><script>function u(){document.getElementById('current-time').textContent=new Date().toLocaleString()}setInterval(u,1000);u()</script></body></html>
EOF
fi

# Export path-like env for the app if it reads from config
export CONFIG_PATH="$DATA_DIR/config.yaml"

# Prefer running the script directly (lets Flask-SocketIO pick eventlet if installed)
exec python "$INSTALL_DIR/video_wall_server.py"


# ---------- nginx/default.conf ----------
# filename: nginx/default.conf
server {
  listen 80;
  server_name _;

  client_max_body_size 100M;

  # Serve static & uploads from shared /data volume
  location /static/ { alias /data/static_content/;  expires 1y; add_header Cache-Control "public, immutable"; }
  location /uploads/ { alias /data/uploads/;       expires 1h; }

  # API proxy
  location /api/ {
    proxy_pass http://app:5000;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_connect_timeout 60s; proxy_send_timeout 60s; proxy_read_timeout 60s;
  }

  # WebSocket (Socket.IO)
  location /socket.io/ {
    proxy_pass http://app:5000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }

  # Fallback to app
  location / {
    proxy_pass http://app:5000;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }

  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header X-XSS-Protection "1; mode=block" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Referrer-Policy "no-referrer-when-downgrade" always;
  add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
}
