#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "\e[31m[ERR]\e[0m line $LINENO: $BASH_COMMAND"; exit 1' ERR

# ===========================================================
# GLOBAL CONFIGURATION
# ===========================================================
NETWORK_NAME="tig-network"
INSTALL_DIR="/opt/askme2u"

# ===========================================================
# GLOBAL VARIABLES
# ===========================================================
OS_ID=""
PKG_MGR=""
INIT_SYSTEM=""
INFLUX_TOKEN=""
SELINUX_ENFORCING="0"
INFLUX_ORG=""
INFLUX_BUCKET=""
INFLUX_USERNAME=""
INFLUX_PASSWORD=""

# ===========================================================
# UTILITY FUNCTIONS
# ===========================================================
log()   { echo -e "\e[32m[LOG]\e[0m $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "This script must be run as root. Try using sudo."
    exit 1
  fi
}

create_folder() {
  local dir="$1"
  [[ -d "$dir" ]] || mkdir -p "$dir"
}

# ===========================================================
# DETECT OS / PKG / INIT
# ===========================================================
detect_os() {
  OS_ID=""
  PKG_MGR=""
  INIT_SYSTEM=""

  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-unknown}"
  else
    error "Cannot detect OS (missing /etc/os-release)"
    exit 1
  fi

  if command_exists systemctl; then
    INIT_SYSTEM="systemd"
  elif command_exists rc-service; then
    INIT_SYSTEM="openrc"
  else
    error "Unsupported init system"
    exit 1
  fi

  case "$OS_ID" in
    ubuntu|debian) PKG_MGR="apt" ;;
    centos|rhel|almalinux|fedora|rocky)
      if command_exists dnf; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi
      ;;
    alpine) PKG_MGR="apk" ;;
    *) error "Unsupported OS: $OS_ID"; exit 1 ;;
  esac

  log "Detected OS=$OS_ID | PKG_MGR=$PKG_MGR | INIT_SYSTEM=$INIT_SYSTEM"
}

# ===========================================================
# SELINUX DETECTION
# ===========================================================
detect_selinux() {
  if command_exists getenforce; then
    local mode
    mode="$(getenforce 2>/dev/null || true)"
    if [[ "$mode" == "Enforcing" ]]; then
      SELINUX_ENFORCING="1"
      warn "SELinux is Enforcing. Bind mounts will use :z flag."
    else
      SELINUX_ENFORCING="0"
      log "SELinux mode: $mode"
    fi
  else
    SELINUX_ENFORCING="0"
  fi
}

# ===========================================================
# INSTALL REQUIRED PACKAGES
# ===========================================================
install_required_packages() {
  log "Installing required packages..."

  case "$PKG_MGR" in
    apt)
      apt-get update -y
      apt-get install -y curl wget openssl
      ;;
    dnf|yum)
      "$PKG_MGR" -y install curl wget openssl
      ;;
    apk)
      apk add --no-cache curl wget openssl
      ;;
  esac

  log "Required packages installed."
}

# ===========================================================
# REQUIRED KERNEL + SYSCTL FOR DOCKER
# ===========================================================
enable_kernel_modules_for_docker() {
  log "Enabling kernel modules + sysctl needed for Docker networking..."

  local modules=("br_netfilter" "nf_nat" "overlay" "bridge")
  for mod in "${modules[@]}"; do
    if ! lsmod | grep -q "^${mod}"; then
      modprobe "$mod" 2>/dev/null || warn "Failed to load module: $mod"
    fi
  done

  cat >/etc/modules-load.d/docker.conf <<EOF
br_netfilter
nf_nat
overlay
bridge
EOF

  cat >/etc/sysctl.d/99-docker.conf <<EOF
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

  sysctl --system >/dev/null 2>&1 || true
  log "sysctl net.ipv4.ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo N/A)"
}

# ===========================================================
# FIX FIREWALLD BACKEND (RHEL10/EL10 ISSUE)
# ===========================================================
fix_firewalld_backend_if_needed() {
  if ! command_exists firewall-cmd; then
    return
  fi

  local conf="/etc/firewalld/firewalld.conf"
  if [[ -f "$conf" ]]; then
    local backend
    backend="$(grep -E '^FirewallBackend=' "$conf" | cut -d= -f2 || echo "")"

    if [[ "$backend" == "ipv4" || "$backend" == "ipv6" || -z "$backend" ]]; then
      warn "firewalld backend invalid: '$backend' -> switching to nftables"
      sed -i 's/^FirewallBackend=.*/FirewallBackend=nftables/' "$conf"

      if systemctl is-active --quiet firewalld; then
        systemctl restart firewalld || warn "Failed to restart firewalld"
      fi
    fi
  fi
}

# ===========================================================
# INSTALL DOCKER (OFFICIAL REPO)
# ===========================================================
install_docker_repo() {
  if command_exists docker; then
    log "Docker already installed. Version: $(docker --version)"
    return
  fi

  case "$PKG_MGR" in
    apt)
      install_docker_apt
      ;;
    dnf|yum)
      install_docker_rhel
      ;;
    apk)
      install_docker_alpine
      ;;
    *)
      error "Unsupported PKG_MGR: $PKG_MGR"
      exit 1
      ;;
  esac
}

install_docker_apt() {
  log "Installing Docker via APT (official Docker repo)..."

  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings

  local gpg_file="/etc/apt/keyrings/docker.gpg"
  if [[ ! -f "$gpg_file" ]]; then
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o "$gpg_file"
    chmod a+r "$gpg_file"
  fi

  local arch codename
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=${gpg_file}] https://download.docker.com/linux/${OS_ID} ${codename} stable
EOF

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  log "Docker installed successfully (APT)."
}

install_docker_rhel() {
  log "Installing Docker via DNF/YUM (official Docker repo)..."

  "$PKG_MGR" -y install yum-utils ca-certificates curl
  "$PKG_MGR" config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

  "$PKG_MGR" -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  "$PKG_MGR" -y install container-selinux || warn "container-selinux not available"

  systemctl enable --now docker
  log "Docker installed successfully (RHEL repo)."
}

install_docker_alpine() {
  log "Installing Docker via APK (Alpine)..."

  apk update
  apk add --no-cache docker docker-cli docker-compose containerd runc

  rc-update add docker default
  service docker start

  log "Docker installed successfully (Alpine)."
}

# ===========================================================
# ADD USER TO DOCKER GROUP
# ===========================================================
add_user_to_docker_group() {
  if ! getent group docker >/dev/null 2>&1; then
    groupadd docker || true
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    if ! groups "${SUDO_USER}" | grep -q docker; then
      usermod -aG docker "${SUDO_USER}"
      log "Added user ${SUDO_USER} to docker group"
      warn "User must logout/login or run: newgrp docker"
    else
      log "User ${SUDO_USER} already in docker group"
    fi
  fi
}

# ===========================================================
# VERIFY DOCKER
# ===========================================================
verify_docker() {
  log "Verifying Docker installation..."

  unset DOCKER_HOST || true

  if ! docker version >/dev/null 2>&1; then
    error "Docker is not working properly"
    exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    error "Docker Compose is not working properly"
    exit 1
  fi

  docker version
  docker compose version
  log "Docker verification OK."
}

# ===========================================================
# FIX PERMISSIONS FOR BIND MOUNTS
# ===========================================================
fix_bind_mount_permissions() {
  log "Fixing bind mount directory permissions..."

  if [[ -d "${INSTALL_DIR}/grafana-data" ]]; then
    chown -R 472:472 "${INSTALL_DIR}/grafana-data" || warn "Failed to chown grafana-data"
    chmod -R 755 "${INSTALL_DIR}/grafana-data" || warn "Failed to chmod grafana-data"
  fi

  if [[ -d "${INSTALL_DIR}/influxdb" ]]; then
    chown -R 1000:1000 "${INSTALL_DIR}/influxdb" || warn "Failed to chown influxdb"
    chmod -R 755 "${INSTALL_DIR}/influxdb" || warn "Failed to chmod influxdb"
  fi

  if [[ -d "${INSTALL_DIR}/telegraf-config" ]]; then
    chmod -R 755 "${INSTALL_DIR}/telegraf-config" || warn "Failed to chmod telegraf-config"
  fi

  log "Permissions fixed."
}

# ===========================================================
# GENERATE ENV FILES AND CONFIGS
# ===========================================================
generate_env_files() {
  log "Generating InfluxDB credential files..."

  cd "${INSTALL_DIR}"

  local token_file=".env.influxdb-admin-token"
  local user_file=".env.influxdb-admin-username"
  local pass_file=".env.influxdb-admin-password"

  if [[ ! -f "$token_file" ]]; then
    if ! command_exists openssl; then
      error "openssl is required but not installed"
      exit 1
    fi
    INFLUX_TOKEN="$(openssl rand -hex 32)"
    echo "$INFLUX_TOKEN" > "$token_file"
    chmod 600 "$token_file"
    log "Generated token file: $token_file"
  else
    INFLUX_TOKEN="$(cat "$token_file")"
    log "Using existing token file: $token_file"
  fi

  if [[ ! -f "$user_file" ]]; then
    read -rp "InfluxDB admin username [admin]: " admuser
    admuser="${admuser:-admin}"
    echo "$admuser" > "$user_file"
    chmod 600 "$user_file"
    INFLUX_USERNAME="$admuser"
  else
    INFLUX_USERNAME="$(cat "$user_file")"
    log "Using existing username file: $user_file"
  fi

  if [[ ! -f "$pass_file" ]]; then
    while true; do
      read -srp "InfluxDB admin password: " admpass
      echo
      if [[ ${#admpass} -lt 8 ]]; then
        error "Password must be at least 8 characters"
        continue
      fi
      read -srp "Confirm password: " admpass2
      echo
      if [[ "$admpass" != "$admpass2" ]]; then
        error "Passwords do not match"
        continue
      fi
      echo "$admpass" > "$pass_file"
      chmod 600 "$pass_file"
      INFLUX_PASSWORD="$admpass"
      break
    done
  else
    INFLUX_PASSWORD="$(cat "$pass_file")"
    log "Using existing password file: $pass_file"
  fi
}

generate_telegraf_config() {
  log "Generating Telegraf configuration..."

  cd "${INSTALL_DIR}"
  create_folder "telegraf-config/telegraf.d"

  if [[ ! -f telegraf-config/telegraf.conf ]]; then
    cat > telegraf-config/telegraf.conf <<'TELEOF'
[agent]
  interval = "30s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  flush_interval = "10s"
  precision = "0s"
  hostname = ""
  omit_hostname = false

[[inputs.cpu]]
  percpu = true
  totalcpu = true
  collect_cpu_time = false
  report_active = false

[[inputs.disk]]
  ignore_fs = ["tmpfs", "devtmpfs", "devfs", "iso9660", "overlay", "aufs", "squashfs"]

[[inputs.diskio]]

[[inputs.kernel]]

[[inputs.mem]]

[[inputs.processes]]

[[inputs.swap]]

[[inputs.system]]

[[inputs.net]]

[[inputs.netstat]]

[[inputs.docker]]
  endpoint = "unix:///var/run/docker.sock"
  gather_services = false
  timeout = "5s"
  perdevice = true
  total = false
TELEOF
  fi

  local existing_org="" existing_bucket=""
  if [[ -f ".env.tig" ]]; then
    existing_org="$(grep '^INFLUX_ORG=' .env.tig 2>/dev/null | cut -d= -f2 || echo "")"
    existing_bucket="$(grep '^INFLUX_BUCKET=' .env.tig 2>/dev/null | cut -d= -f2 || echo "")"
  fi

  read -rp "Organization Name [${existing_org:-myorg}]: " ORG_IN
  read -rp "Bucket Name [${existing_bucket:-mybucket}]: " BUCKET_IN

  INFLUX_ORG="${ORG_IN:-${existing_org:-myorg}}"
  INFLUX_BUCKET="${BUCKET_IN:-${existing_bucket:-mybucket}}"

  cat > .env.tig <<ENVEOF
INFLUX_ORG=${INFLUX_ORG}
INFLUX_BUCKET=${INFLUX_BUCKET}
ENVEOF
  chmod 600 .env.tig

  cat > telegraf-config/telegraf.d/000-influxdb.conf <<OUTEOF
[[outputs.influxdb_v2]]
  urls = ["http://influxdb:8086"]
  token = "${INFLUX_TOKEN}"
  organization = "${INFLUX_ORG}"
  bucket = "${INFLUX_BUCKET}"
OUTEOF

  log "Telegraf configuration generated."
}

generate_docker_compose() {
  log "Generating docker-compose.yml..."

  cd "${INSTALL_DIR}"

  if [[ -f docker-compose.yml ]]; then
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    warn "docker-compose.yml already exists. Backing up to docker-compose.yml.${timestamp}"
    cp docker-compose.yml "docker-compose.yml.${timestamp}"
  fi

  local ZOPT=""
  if [[ "$SELINUX_ENFORCING" == "1" ]]; then
    ZOPT=":z"
  fi

  cat > docker-compose.yml <<DCEOF
services:
  influxdb:
    image: influxdb:latest
    container_name: influxdb
    ports:
      - "8086:8086"
    environment:
      - INFLUXDB_HTTP_AUTH_ENABLED=true
      - DOCKER_INFLUXDB_INIT_MODE=setup
      - DOCKER_INFLUXDB_INIT_USERNAME_FILE=/run/secrets/influxdb-admin-username
      - DOCKER_INFLUXDB_INIT_PASSWORD_FILE=/run/secrets/influxdb-admin-password
      - DOCKER_INFLUXDB_INIT_ADMIN_TOKEN_FILE=/run/secrets/influxdb-admin-token
      - DOCKER_INFLUXDB_INIT_ORG=${INFLUX_ORG}
      - DOCKER_INFLUXDB_INIT_BUCKET=${INFLUX_BUCKET}
    secrets:
      - influxdb-admin-token
      - influxdb-admin-username
      - influxdb-admin-password
    volumes:
      - ./influxdb/data:/var/lib/influxdb2${ZOPT}
      - ./influxdb/config:/etc/influxdb2${ZOPT}
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "influx", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  grafana:
    image: grafana/grafana-oss:latest
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_INSTALL_PLUGINS=
      - GF_SERVER_ROOT_URL=http://localhost:3000
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - ./grafana-data:/var/lib/grafana${ZOPT}
    depends_on:
      influxdb:
        condition: service_healthy
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  telegraf:
    image: telegraf:latest
    container_name: telegraf
    volumes:
      - ./telegraf-config/telegraf.d:/etc/telegraf/telegraf.d/:ro${ZOPT}
      - ./telegraf-config/telegraf.conf:/etc/telegraf/telegraf.conf:ro${ZOPT}
      - /var/run/docker.sock:/var/run/docker.sock:ro
    depends_on:
      influxdb:
        condition: service_healthy
    restart: unless-stopped
    user: telegraf:999

secrets:
  influxdb-admin-token:
    file: .env.influxdb-admin-token
  influxdb-admin-username:
    file: .env.influxdb-admin-username
  influxdb-admin-password:
    file: .env.influxdb-admin-password

networks:
  default:
    name: ${NETWORK_NAME}
DCEOF

  log "docker-compose.yml generated successfully."
}

# ===========================================================
# CREATE SYSTEMD SERVICE
# ===========================================================
create_systemd_service() {
  if [[ "$INIT_SYSTEM" != "systemd" ]]; then
    warn "Systemd not detected, skipping service creation"
    return
  fi

  log "Creating systemd service for TIG stack..."

  cat > /etc/systemd/system/tig-stack.service <<SYSEOF
[Unit]
Description=TIG Stack (Telegraf, InfluxDB, Grafana)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
SYSEOF

  systemctl daemon-reload
  systemctl enable tig-stack.service

  log "Systemd service created and enabled."
}

# ===========================================================
# PREPARE DATA DIRECTORIES
# ===========================================================
prepare_data_dirs() {
  log "Preparing data directories..."

  cd "${INSTALL_DIR}"

  create_folder influxdb/data
  create_folder influxdb/config
  create_folder grafana-data

  fix_bind_mount_permissions
}

# ===========================================================
# RUN STACK
# ===========================================================
run_stack() {
  log "Starting TIG stack using Docker Compose..."

  cd "${INSTALL_DIR}"

  log "Pulling latest Docker images..."
  docker compose pull

  docker compose up -d

  log "TIG stack containers started."
}

# ===========================================================
# GET LOCAL IP
# ===========================================================
get_local_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
  [[ -n "$ip" ]] && echo "$ip" || echo "127.0.0.1"
}

# ===========================================================
# WAIT FOR INFLUXDB
# ===========================================================
wait_for_influxdb() {
  log "Waiting for InfluxDB to be ready..."

  local retries=60
  local count=0

  while [[ $count -lt $retries ]]; do
    if curl -fsS http://localhost:8086/health 2>/dev/null | grep -q '"status":"pass"'; then
      log "InfluxDB is ready!"
      return 0
    fi
    ((count++))
    echo -n "."
    sleep 2
  done

  echo ""
  warn "InfluxDB health check timeout, but may still be initializing..."
  return 0
}

# ===========================================================
# CREATE MANAGEMENT SCRIPTS
# ===========================================================
create_management_scripts() {
  log "Creating management scripts..."

  cd "${INSTALL_DIR}"

  cat > start.sh <<'STARTEOF'
#!/bin/bash
cd /opt/askme2u
docker compose up -d
echo "TIG Stack started"
docker compose ps
STARTEOF
  chmod +x start.sh

  cat > stop.sh <<'STOPEOF'
#!/bin/bash
cd /opt/askme2u
docker compose down
echo "TIG Stack stopped"
STOPEOF
  chmod +x stop.sh

  cat > restart.sh <<'RESTARTEOF'
#!/bin/bash
cd /opt/askme2u
docker compose restart
echo "TIG Stack restarted"
docker compose ps
RESTARTEOF
  chmod +x restart.sh

  cat > status.sh <<'STATUSEOF'
#!/bin/bash
cd /opt/askme2u
docker compose ps
echo ""
echo "Logs (last 20 lines):"
docker compose logs --tail=20
STATUSEOF
  chmod +x status.sh

  cat > update.sh <<'UPDATEEOF'
#!/bin/bash
cd /opt/askme2u
echo "Pulling latest images..."
docker compose pull
echo "Recreating containers..."
docker compose up -d
echo "Update complete"
docker compose ps
UPDATEEOF
  chmod +x update.sh

  cat > backup.sh <<'BACKUPEOF'
#!/bin/bash
BACKUP_DIR="/opt/askme2u/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

echo "Creating backup: $TIMESTAMP"

docker exec influxdb influx backup /tmp/backup -t $(cat /opt/askme2u/.env.influxdb-admin-token)
docker cp influxdb:/tmp/backup "$BACKUP_DIR/influxdb_${TIMESTAMP}"
docker exec influxdb rm -rf /tmp/backup

tar -czf "$BACKUP_DIR/grafana_${TIMESTAMP}.tar.gz" -C /opt/askme2u grafana-data

tar -czf "$BACKUP_DIR/configs_${TIMESTAMP}.tar.gz" -C /opt/askme2u \
  telegraf-config \
  .env.influxdb-admin-token \
  .env.influxdb-admin-username \
  .env.influxdb-admin-password \
  .env.tig \
  docker-compose.yml

echo "Backup completed: $BACKUP_DIR"
ls -lh "$BACKUP_DIR" | tail -n 3
BACKUPEOF
  chmod +x backup.sh

  log "Management scripts created in ${INSTALL_DIR}/"
}

# ===========================================================
# CREATE README FILE
# ===========================================================
create_readme() {
  log "Creating README file..."

  local ip
  ip="$(get_local_ip)"

  cat > "${INSTALL_DIR}/README.md" <<'READMEEOF'
# TIG Stack - AskMe2U

## Quick Start

```bash
cd /opt/askme2u
./start.sh      # Start all services
./stop.sh       # Stop all services  
./restart.sh    # Restart all services
./status.sh     # Check status
./update.sh     # Update to latest
./backup.sh     # Create backup