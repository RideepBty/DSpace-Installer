#!/usr/bin/env bash

set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "ERROR: run with sudo: sudo bash $0" >&2; exit 1; }

log()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

ASSUME_YES="${ASSUME_YES:-0}"

DSPACE_VERSION="${DSPACE_VERSION:-10.0}"
SOLR_VERSION="${SOLR_VERSION:-9.10.1}"
TOMCAT_VERSION="${TOMCAT_VERSION:-10.1.55}"
MAVEN_VERSION="${MAVEN_VERSION:-3.9.9}"
NODE_VERSION="${NODE_VERSION:-22}"

REST_PORT="${REST_PORT:-8080}"
UI_PORT="${UI_PORT:-4000}"
SOLR_PORT="${SOLR_PORT:-8983}"

DSPACE_USER="${DSPACE_USER:-dspace}"
DSPACE_DIR="${DSPACE_DIR:-/dspace}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt}"

DB_NAME="${DB_NAME:-dspace}"
DB_USER="${DB_USER:-dspace}"
DB_PASS="${DB_PASS:-}"

ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ADMIN_FIRST="${ADMIN_FIRST:-DSpace}"
ADMIN_LAST="${ADMIN_LAST:-Administrator}"
ADMIN_PASS="${ADMIN_PASS:-}"

SWAP_SIZE="${SWAP_SIZE:-4G}"
NODE_HEAP_MB="${NODE_HEAP_MB:-4096}"
EXTERNAL_IP="${EXTERNAL_IP:-}"

ask() {
  local var="$1" prompt="$2" def="$3" val
  if [[ "$ASSUME_YES" == "1" ]]; then printf -v "$var" '%s' "${!var:-$def}"; return; fi
  [[ -n "${!var:-}" ]] && return
  read -rp "  $prompt [$def]: " val
  printf -v "$var" '%s' "${val:-$def}"
}
ask_secret() {
  local var="$1" prompt="$2" val val2
  [[ -n "${!var:-}" ]] && return
  if [[ "$ASSUME_YES" == "1" ]]; then
    printf -v "$var" '%s' "$(openssl rand -base64 12)"
    warn "$var not set; generated a random value."; return
  fi
  while :; do
    read -rsp "  $prompt: " val; echo
    read -rsp "  confirm: "     val2; echo
    [[ "$val" == "$val2" && -n "$val" ]] && break
    echo "  -> empty or mismatch, try again."
  done
  printf -v "$var" '%s' "$val"
}

is_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
detect_ip() {
  local ip="" tok
  tok="$(curl -sf --max-time 2 -X PUT 'http://169.254.169.254/latest/api/token' \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  [[ -n "$tok" ]] && ip="$(curl -sf --max-time 2 -H "X-aws-ec2-metadata-token: $tok" \
    'http://169.254.169.254/latest/meta-data/public-ipv4' 2>/dev/null || true)"
  is_ip "$ip" || ip=""
  [[ -z "$ip" ]] && ip="$(curl -sf --max-time 2 -H 'Metadata-Flavor: Google' \
    'http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' 2>/dev/null || true)"
  is_ip "$ip" || ip=""
  [[ -z "$ip" ]] && ip="$(curl -sf --max-time 2 -H 'Metadata: true' \
    'http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text' 2>/dev/null || true)"
  is_ip "$ip" || ip=""
  [[ -z "$ip" ]] && ip="$(curl -sf --max-time 3 'https://checkip.amazonaws.com' 2>/dev/null | tr -d '[:space:]' || true)"
  is_ip "$ip" || ip=""
  printf '%s' "$ip"
}

log "DSpace 10 installer - configuration"
[[ -z "$EXTERNAL_IP" ]] && EXTERNAL_IP="$(detect_ip)"
[[ -z "$EXTERNAL_IP" ]] && warn "Could not auto-detect a public IP."
ask EXTERNAL_IP   "Public address (public IP or DNS) used in URLs" "${EXTERNAL_IP:-localhost}"

ask DSPACE_VERSION  "DSpace version"        "$DSPACE_VERSION"
ask SOLR_VERSION    "Apache Solr version"   "$SOLR_VERSION"
ask TOMCAT_VERSION  "Apache Tomcat version (10.1.x required)" "$TOMCAT_VERSION"
ask MAVEN_VERSION   "Apache Maven version (3.9.x+ required)"  "$MAVEN_VERSION"
ask NODE_VERSION    "Node.js major version (20/22/24)"        "$NODE_VERSION"

ask REST_PORT       "Backend / REST API port (Tomcat)" "$REST_PORT"
ask UI_PORT         "Frontend / UI port (PM2)"         "$UI_PORT"
ask SOLR_PORT       "Solr port (localhost only)"       "$SOLR_PORT"

ask DSPACE_USER     "Service (system) user"            "$DSPACE_USER"
ask DB_NAME         "PostgreSQL database name"         "$DB_NAME"
ask DB_USER         "PostgreSQL database user"         "$DB_USER"
ask_secret DB_PASS  "PostgreSQL password for '$DB_USER'"

ask ADMIN_EMAIL     "DSpace admin e-mail (web login)"  "${ADMIN_EMAIL:-admin@example.com}"
ask ADMIN_FIRST     "DSpace admin first name"          "$ADMIN_FIRST"
ask ADMIN_LAST      "DSpace admin last name"           "$ADMIN_LAST"
ask_secret ADMIN_PASS "DSpace admin password"

SERVER_URL="http://${EXTERNAL_IP}:${REST_PORT}/server"
UI_URL="http://${EXTERNAL_IP}:${UI_PORT}"

cat <<SUMMARY

  ----------------------------------------------------------------
   Review configuration
  ----------------------------------------------------------------
   DSpace ${DSPACE_VERSION}  |  Solr ${SOLR_VERSION}  |  Tomcat ${TOMCAT_VERSION}
   Java 21 (required)  |  Maven ${MAVEN_VERSION}  |  Node ${NODE_VERSION}
   Backend URL : ${SERVER_URL}
   Frontend URL: ${UI_URL}
   Solr        : http://localhost:${SOLR_PORT}/solr   (not exposed externally)
   Service user: ${DSPACE_USER}        Install dir: ${DSPACE_DIR}
   Database    : ${DB_NAME} / ${DB_USER}
   Admin login : ${ADMIN_EMAIL}
   Swap        : ${SWAP_SIZE}     Node build heap: ${NODE_HEAP_MB} MB
  ----------------------------------------------------------------
SUMMARY

if [[ "$ASSUME_YES" != "1" ]]; then
  read -rp "  Proceed with installation? [y/N]: " ok
  [[ "${ok,,}" == "y" ]] || die "Aborted by user."
fi

DSPACE_HOME="$(getent passwd "$DSPACE_USER" | cut -d: -f6 || true)"
DSPACE_HOME="${DSPACE_HOME:-/home/$DSPACE_USER}"
SOLR_DIR="${INSTALL_ROOT}/solr"
TOMCAT_DIR="${INSTALL_ROOT}/tomcat"
MAVEN_DIR="${INSTALL_ROOT}/maven"
SOLR_LIB="${SOLR_DIR}/server/solr/lib"
run_as_dspace() { sudo -u "$DSPACE_USER" bash -lc "$1"; }

if [[ "$SWAP_SIZE" != "0" && ! -f /swapfile ]]; then
  log "Creating ${SWAP_SIZE} swap file"
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

log "Installing system dependencies (Java 21, Ant, PostgreSQL, tools)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y openjdk-21-jdk ant postgresql postgresql-contrib \
  libpostgresql-jdbc-java curl wget git unzip xmlstarlet ufw

JAVA_HOME="/usr/lib/jvm/java-21-openjdk-$(dpkg --print-architecture)"
[[ -d "$JAVA_HOME" ]] || die "JDK 21 not found at ${JAVA_HOME} (DSpace 10 requires Java 21)."
update-alternatives --set java "${JAVA_HOME}/bin/java" >/dev/null 2>&1 || true
update-alternatives --set javac "${JAVA_HOME}/bin/javac" >/dev/null 2>&1 || true

if [[ ! -d "$MAVEN_DIR" ]]; then
  log "Downloading Apache Maven ${MAVEN_VERSION} (DSpace 10 requires 3.9.x+; distro packages are older)"
  wget -q -O /tmp/maven.tgz \
    "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz"
  tar xzf /tmp/maven.tgz -C "$INSTALL_ROOT"
  mv "${INSTALL_ROOT}/apache-maven-${MAVEN_VERSION}" "$MAVEN_DIR"
fi
MVN="${MAVEN_DIR}/bin/mvn"

log "Creating service user '${DSPACE_USER}' and install directories"
id "$DSPACE_USER" &>/dev/null || useradd -m -s /bin/bash "$DSPACE_USER"
mkdir -p "$DSPACE_DIR"
chown "$DSPACE_USER:$DSPACE_USER" "$DSPACE_DIR"

log "Configuring PostgreSQL role '${DB_USER}' and database '${DB_NAME}'"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
  sudo -u postgres createdb --owner="${DB_USER}" --encoding=UNICODE "${DB_NAME}"

PG_VER="$(ls /etc/postgresql/ | sort -V | tail -1)"
HBA="/etc/postgresql/${PG_VER}/main/pg_hba.conf"
if ! grep -qE "^host\s+${DB_NAME}\s+${DB_USER}\s+127\.0\.0\.1" "$HBA"; then
  sed -i "1i host ${DB_NAME} ${DB_USER} 127.0.0.1/32 md5" "$HBA"
fi
systemctl restart postgresql
case "$PG_VER" in
  14|15|16|17) : ;;
  *) warn "PostgreSQL ${PG_VER} is outside DSpace 10's supported range (14-17)." ;;
esac

if [[ ! -d "$SOLR_DIR" ]]; then
  log "Downloading Apache Solr ${SOLR_VERSION}"
  wget -q -O "/tmp/solr-${SOLR_VERSION}.tgz" \
    "https://archive.apache.org/dist/solr/solr/${SOLR_VERSION}/solr-${SOLR_VERSION}.tgz"
  tar xzf "/tmp/solr-${SOLR_VERSION}.tgz" -C "$INSTALL_ROOT"
  mv "${INSTALL_ROOT}/solr-${SOLR_VERSION}" "$SOLR_DIR"
  chown -R "$DSPACE_USER:$DSPACE_USER" "$SOLR_DIR"
fi

if [[ ! -d "$TOMCAT_DIR" ]]; then
  log "Downloading Apache Tomcat ${TOMCAT_VERSION}"
  TC_MAJOR="${TOMCAT_VERSION%%.*}"
  wget -q -O "/tmp/tomcat-${TOMCAT_VERSION}.tar.gz" \
    "https://archive.apache.org/dist/tomcat/tomcat-${TC_MAJOR}/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
  tar xzf "/tmp/tomcat-${TOMCAT_VERSION}.tar.gz" -C "$INSTALL_ROOT"
  mv "${INSTALL_ROOT}/apache-tomcat-${TOMCAT_VERSION}" "$TOMCAT_DIR"
  chown -R "$DSPACE_USER:$DSPACE_USER" "$TOMCAT_DIR"
fi
grep -q 'URIEncoding="UTF-8"' "${TOMCAT_DIR}/conf/server.xml" || \
  sed -i "s|<Connector port=\"8080\"|<Connector port=\"${REST_PORT}\" URIEncoding=\"UTF-8\"|" \
    "${TOMCAT_DIR}/conf/server.xml"

SRC="DSpace-dspace-${DSPACE_VERSION}"
log "Downloading DSpace ${DSPACE_VERSION} source"
run_as_dspace "mkdir -p ~/build && cd ~/build && \
  [ -d '${SRC}' ] || { wget -q -O ds.tgz 'https://github.com/DSpace/DSpace/archive/refs/tags/dspace-${DSPACE_VERSION}.tar.gz' && tar -zxf ds.tgz && rm ds.tgz; }"

CFG="${DSPACE_HOME}/build/${SRC}/dspace/config/local.cfg"
log "Writing local.cfg"
run_as_dspace "cp '${DSPACE_HOME}/build/${SRC}/dspace/config/local.cfg.EXAMPLE' '${CFG}'"
setcfg() {
  local k="$1" v="$2"
  run_as_dspace "sed -i '/^${k//./\\.}[[:space:]]*=.*/d' '${CFG}'; printf '%s = %s\n' '${k}' '${v}' >> '${CFG}'"
}
setcfg "dspace.dir"                "${DSPACE_DIR}"
setcfg "dspace.server.url"         "${SERVER_URL}"
setcfg "dspace.ui.url"             "${UI_URL}"
setcfg "db.url"                    "jdbc:postgresql://localhost:5432/${DB_NAME}"
setcfg "db.username"               "${DB_USER}"
setcfg "db.password"               "${DB_PASS}"
setcfg "solr.server"               "http://localhost:${SOLR_PORT}/solr"
setcfg "rest.cors.allowed-origins" "\${dspace.ui.url}"

log "Building DSpace (mvn package, Java 21) - this takes ~8-10 minutes"
run_as_dspace "export JAVA_HOME='${JAVA_HOME}'; cd ~/build/${SRC} && '${MVN}' -B -q package"
log "Deploying DSpace (ant fresh_install)"
run_as_dspace "export JAVA_HOME='${JAVA_HOME}'; cd ~/build/${SRC}/dspace/target/dspace-installer && ant -q fresh_install"

log "Installing DSpace Solr cores"
mkdir -p "${SOLR_DIR}/server/solr/configsets"
run_as_dspace "cp -R ${DSPACE_DIR}/solr/* ${SOLR_DIR}/server/solr/configsets/"

log "Ensuring Solr ICU analysis jars are present"
mkdir -p "$SOLR_LIB"
if find "${SOLR_DIR}/modules" -name 'lucene-analysis-icu-*.jar' 2>/dev/null | grep -q .; then
  find "${SOLR_DIR}/modules" -name 'lucene-analysis-icu-*.jar' -exec cp {} "$SOLR_LIB/" \;
  find "${SOLR_DIR}/modules" -name 'icu4j-*.jar'              -exec cp {} "$SOLR_LIB/" \;
else
  LUCENE_VER="$(ls "${SOLR_DIR}"/server/solr-webapp/webapp/WEB-INF/lib/lucene-core-*.jar 2>/dev/null | sed -E 's/.*lucene-core-([0-9.]+)\.jar/\1/' | head -1)"
  [[ -z "$LUCENE_VER" ]] && LUCENE_VER="$(find "${SOLR_DIR}" -name 'lucene-core-*.jar' 2>/dev/null | sed -E 's/.*lucene-core-([0-9.]+)\.jar/\1/' | head -1)"
  warn "analysis-extras not bundled; fetching lucene-analysis-icu ${LUCENE_VER} from Maven Central"
  ICU_POM="https://repo1.maven.org/maven2/org/apache/lucene/lucene-analysis-icu/${LUCENE_VER}/lucene-analysis-icu-${LUCENE_VER}.pom"
  ICU4J_VER="$(curl -s "$ICU_POM" | tr -d '\n\r\t ' | grep -oP 'icu4j</artifactId><version>\K[0-9.]+' | head -1)"
  [[ -z "$ICU4J_VER" ]] && { ICU4J_VER="74.2"; warn "Could not parse icu4j version; defaulting to ${ICU4J_VER}"; }
  wget -q -O "${SOLR_LIB}/lucene-analysis-icu-${LUCENE_VER}.jar" \
    "https://repo1.maven.org/maven2/org/apache/lucene/lucene-analysis-icu/${LUCENE_VER}/lucene-analysis-icu-${LUCENE_VER}.jar"
  wget -q -O "${SOLR_LIB}/icu4j-${ICU4J_VER}.jar" \
    "https://repo1.maven.org/maven2/com/ibm/icu/icu4j/${ICU4J_VER}/icu4j-${ICU4J_VER}.jar"
fi
chown -R "$DSPACE_USER:$DSPACE_USER" "$SOLR_LIB"

log "Creating systemd services: solr, tomcat"
cat > /etc/systemd/system/solr.service <<UNIT
[Unit]
Description=Apache Solr (DSpace)
After=network.target
[Service]
Type=forking
User=${DSPACE_USER}
Environment=SOLR_OPTS=-Dsolr.config.lib.enabled=true
ExecStart=${SOLR_DIR}/bin/solr start -p ${SOLR_PORT}
ExecStop=${SOLR_DIR}/bin/solr stop -p ${SOLR_PORT}
Restart=on-failure
TimeoutStartSec=180
[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/tomcat.service <<UNIT
[Unit]
Description=Apache Tomcat (DSpace backend)
After=network.target postgresql.service solr.service
Requires=solr.service
[Service]
Type=forking
User=${DSPACE_USER}
Environment=JAVA_HOME=${JAVA_HOME}
Environment=CATALINA_HOME=${TOMCAT_DIR}
Environment=CATALINA_BASE=${TOMCAT_DIR}
Environment="CATALINA_OPTS=-Xms512m -Xmx1024m -Dfile.encoding=UTF-8"
ExecStart=${TOMCAT_DIR}/bin/startup.sh
ExecStop=${TOMCAT_DIR}/bin/shutdown.sh
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now solr.service

log "Waiting for Solr 'search' core to load"
for i in $(seq 1 40); do
  if curl -s "http://localhost:${SOLR_PORT}/solr/admin/cores?action=STATUS" 2>/dev/null | grep -q '"name":"search"'; then
    log "Solr cores are up"; break
  fi
  sleep 3
  [[ $i -eq 40 ]] && warn "Solr 'search' core not detected after 120s; check 'systemctl status solr'."
done

log "Running database migration"
run_as_dspace "export JAVA_HOME='${JAVA_HOME}'; ${DSPACE_DIR}/bin/dspace database migrate"
log "Creating administrator ${ADMIN_EMAIL}"
run_as_dspace "export JAVA_HOME='${JAVA_HOME}'; ${DSPACE_DIR}/bin/dspace create-administrator \
  -e '${ADMIN_EMAIL}' -f '${ADMIN_FIRST}' -l '${ADMIN_LAST}' -p '${ADMIN_PASS}' -c en" \
  || warn "create-administrator returned non-zero (account may already exist)."

log "Deploying backend webapp and starting Tomcat"
[[ -d "${TOMCAT_DIR}/webapps/server" ]] || run_as_dspace "cp -R ${DSPACE_DIR}/webapps/server ${TOMCAT_DIR}/webapps/server"
systemctl enable --now tomcat.service

log "Installing Node.js ${NODE_VERSION} (nvm) and PM2"
run_as_dspace "[ -d ~/.nvm ] || curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash"
run_as_dspace "export NVM_DIR=~/.nvm; . ~/.nvm/nvm.sh; nvm install ${NODE_VERSION}; npm install -g pm2"

FE="dspace-angular-dspace-${DSPACE_VERSION}"
log "Downloading dspace-angular ${DSPACE_VERSION}"
run_as_dspace "cd ~ && [ -d '${FE}' ] || { wget -q -O fe.tgz 'https://github.com/DSpace/dspace-angular/archive/refs/tags/dspace-${DSPACE_VERSION}.tar.gz' && tar -zxf fe.tgz && rm fe.tgz; }"

log "Writing frontend config.prod.yml"
run_as_dspace "cat > ~/${FE}/config/config.prod.yml <<YML
rest:
  ssl: false
  host: ${EXTERNAL_IP}
  port: ${REST_PORT}
  nameSpace: /server
ui:
  ssl: false
  host: 0.0.0.0
  port: ${UI_PORT}
  nameSpace: /
YML"

log "Installing UI dependencies + building - ~12 min"
run_as_dspace "export NVM_DIR=~/.nvm; . ~/.nvm/nvm.sh; cd ~/${FE}; npm install; \
  export NODE_OPTIONS='--max-old-space-size=${NODE_HEAP_MB}'; npm run build:prod"

log "Configuring PM2"
run_as_dspace "cat > ~/${FE}/dspace-ui.json <<JSON
{
  \"apps\": [{
    \"name\": \"dspace-ui\",
    \"cwd\": \"${DSPACE_HOME}/${FE}\",
    \"script\": \"dist/server/main.js\",
    \"instances\": 1,
    \"exec_mode\": \"cluster\",
    \"env\": { \"NODE_ENV\": \"production\" }
  }]
}
JSON"
run_as_dspace "export NVM_DIR=~/.nvm; . ~/.nvm/nvm.sh; cd ~/${FE}; pm2 start dspace-ui.json; pm2 save"

PM2_BIN="$(run_as_dspace 'export NVM_DIR=~/.nvm; . ~/.nvm/nvm.sh; command -v pm2')"
env PATH="$PATH:$(dirname "$PM2_BIN")" "$PM2_BIN" startup systemd -u "$DSPACE_USER" --hp "$DSPACE_HOME" | \
  grep -E '^sudo env' | bash || warn "PM2 startup hook may need to be run manually."

log "Configuring local UFW firewall"
ufw allow 22/tcp   >/dev/null 2>&1 || true
ufw allow "${REST_PORT}/tcp" >/dev/null 2>&1 || true
ufw allow "${UI_PORT}/tcp"   >/dev/null 2>&1 || true

cat <<DONE

  ================================================================
   DSpace ${DSPACE_VERSION} installation complete
  ================================================================
   Frontend (UI) : ${UI_URL}
   Backend (API) : ${SERVER_URL}
   Admin login   : ${ADMIN_EMAIL}

   Services (systemd): solr, tomcat   |   UI: pm2 (user ${DSPACE_USER})
     systemctl status solr tomcat
     sudo -u ${DSPACE_USER} pm2 status

   IMPORTANT - open TCP ports ${REST_PORT} and ${UI_PORT} in your cloud
   provider's firewall for this VM:
     AWS   : EC2 Security Group inbound rules
     Azure : Network Security Group (az network nsg rule create ...)
     GCP   : VPC firewall rule (gcloud compute firewall-rules create ...)

   IMPORTANT - reserve a STATIC public IP so it survives a stop/start
   (an ephemeral IP changes on restart and breaks the URLs above).

   Quick health check (on the VM):
     curl -s -o /dev/null -w 'API:%{http_code}\\n' http://localhost:${REST_PORT}/server/api
     curl -s -o /dev/null -w 'UI :%{http_code}\\n' http://localhost:${UI_PORT}
     curl -s "http://localhost:${SOLR_PORT}/solr/admin/cores?action=STATUS" | grep -o '"name":"[a-z]*"'
  ================================================================
DONE
