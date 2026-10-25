#!/usr/bin/env bash

set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "ERROR: run with sudo: sudo bash $0" >&2; exit 1; }

# Keep a copy of everything the installer prints, so a failed install can be diagnosed later.
INSTALL_LOG="${INSTALL_LOG:-/var/log/dspace-installer.log}"
touch "$INSTALL_LOG" && chmod 600 "$INSTALL_LOG"
printf '\n===== %s: %s started\n' "$(date -u +%FT%TZ)" "$(basename "$0")" >> "$INSTALL_LOG"
exec > >(tee -a "$INSTALL_LOG") 2>&1
on_exit() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    printf '\n[error] The installer stopped (exit code %s). Its full output is in %s\n' "$rc" "$INSTALL_LOG"
  fi
}
trap on_exit EXIT

log()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# Optional download cache: with DOWNLOAD_CACHE set (e.g. /var/cache/dspace-installer), everything this
# installer downloads is also saved there, and later runs take it from there instead of the internet.
cache_put() {  # cache_put <file> <path in the cache>: copy, then rename, so a stopped run never leaves half a file
  mkdir -p "$(dirname "$2")" || return 1
  if cp "$1" "$2.part" && mv -f "$2.part" "$2"; then return 0; fi
  rm -f "$2.part"
  return 1
}
file_ok() {  # a .tar.gz or .tgz file must pass gzip's test; any other file must not be empty
  case "$1" in
    *.tar.gz|*.tgz) gzip -t "$1" 2>/dev/null ;;
    *) [[ -s "$1" ]] ;;
  esac
}

# Download an Apache release file (Apache's CDN first, then its archive) and check its SHA-512.
# With the download cache on, a cached copy is used when it matches the checksum.
apache_get() {  # apache_get <path under dist/> <output file>
  local path="$1" out="$2" want="" base got cached=""
  [[ -n "${DOWNLOAD_CACHE:-}" ]] && cached="${DOWNLOAD_CACHE}/apache/${path}"
  if [[ -n "$cached" && -f "${cached}.sha512" ]]; then
    want="$(tr -d '[:space:]' < "${cached}.sha512" | grep -oiE '[0-9a-f]{128}' | head -1 || true)"
  fi
  if [[ -z "$want" ]]; then
    for base in https://downloads.apache.org https://archive.apache.org/dist; do
      want="$(curl -fsSL --max-time 60 "${base}/${path}.sha512" 2>/dev/null | tr -d '[:space:]' | grep -oiE '[0-9a-f]{128}' | head -1 || true)"
      [[ -n "$want" ]] && break
    done
  fi
  [[ -n "$want" ]] || die "No SHA-512 checksum found for ${path}"
  want="${want,,}"
  if [[ -n "$cached" && -f "$cached" && "$(sha512sum "$cached" | awk '{print $1}')" == "$want" ]]; then
    echo "  Taking ${path##*/} from the download cache (SHA-512 checked)"
    cp "$cached" "$out" || die "Could not copy ${cached} to ${out}"
    return 0
  fi
  for base in https://dlcdn.apache.org https://archive.apache.org/dist; do
    if wget -q --show-progress --progress=dot:giga --timeout=60 --tries=3 -O "$out" "${base}/${path}"; then
      got="$(sha512sum "$out" | awk '{print $1}')"
      if [[ "$want" == "$got" ]]; then
        if [[ -n "$cached" ]]; then
          if cache_put "$out" "$cached" && printf '%s\n' "$want" > "${cached}.sha512"; then
            echo "  Saved a copy in the download cache"
          else
            warn "Could not save ${path##*/} in the download cache."
          fi
        fi
        return 0
      fi
      warn "Checksum mismatch for ${path} from ${base}; trying the next source."
    else
      warn "Download from ${base} failed; trying the next source."
    fi
    rm -f "$out"
  done
  die "Could not download a verified copy of ${path}"
}

# Download a file that has no published checksum (GitHub source archives, Maven Central jars),
# or take the copy an earlier run saved in the download cache.
cached_get() {  # cached_get <url> <output file>
  local url="$1" out="$2" cached=""
  if [[ -n "${DOWNLOAD_CACHE:-}" ]]; then
    cached="${DOWNLOAD_CACHE}/files/${url#*://}"
    if [[ -s "$cached" ]] && file_ok "$cached"; then
      echo "  Taking ${url##*/} ($(cut -d/ -f1-3 <<< "${url#*://}")) from the download cache"
      cp "$cached" "$out" || return 1
      return 0
    fi
  fi
  if ! { wget -q -O "$out" "$url" && file_ok "$out"; }; then
    rm -f "$out"
    return 1
  fi
  if [[ -n "$cached" ]]; then
    if cache_put "$out" "$cached"; then
      echo "  Saved a copy in the download cache"
    else
      warn "Could not save ${url##*/} in the download cache."
    fi
  fi
  return 0
}

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
CREDENTIALS_FILE="${CREDENTIALS_FILE:-/root/dspace-credentials.txt}"
DOWNLOAD_CACHE="${DOWNLOAD_CACHE:-}"

ask() {
  local var="$1" prompt="$2" def="$3" val
  if [[ "$ASSUME_YES" == "1" ]]; then printf -v "$var" '%s' "${!var:-$def}"; return; fi
  [[ -n "${!var:-}" ]] && return
  read -rp "  $prompt [$def]: " val
  printf -v "$var" '%s' "${val:-$def}"
}
ask_secret() {
  local var="$1" prompt="$2" val="" val2
  [[ -n "${!var:-}" ]] && return
  if [[ "$ASSUME_YES" == "1" ]]; then
    # A re-run reuses the value an earlier run generated, so it still matches the database and the admin account.
    [[ -r "$CREDENTIALS_FILE" ]] && val="$(sed -n "s/^${var}=//p" "$CREDENTIALS_FILE" | tail -n 1)"
    if [[ -n "$val" ]]; then
      printf -v "$var" '%s' "$val"
      warn "$var not set; reusing the value saved in ${CREDENTIALS_FILE}."
    else
      printf -v "$var" '%s' "$(openssl rand -base64 12)"
      GENERATED_SECRETS=1
      warn "$var not set; generated a random value."
    fi
    SAVED_SECRETS=1
    return
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

# The download cache also keeps the apt packages: apt-get is pointed at a folder inside it.
APT_CACHE=()
if [[ -n "$DOWNLOAD_CACHE" ]]; then
  [[ "$DOWNLOAD_CACHE" =~ ^/[A-Za-z0-9._/-]+$ ]] || \
    die "DOWNLOAD_CACHE must be a full path made of letters, digits and . _ - / (for example /var/cache/dspace-installer)."
  mkdir -p "${DOWNLOAD_CACHE}/apt/partial"
  chown _apt:root "${DOWNLOAD_CACHE}/apt/partial" 2>/dev/null && chmod 700 "${DOWNLOAD_CACHE}/apt/partial" || true
  APT_CACHE=(-o "Dir::Cache::Archives=${DOWNLOAD_CACHE}/apt/")
fi

# Minimal Ubuntu images leave out curl, which the address detection below needs.
if ! command -v curl >/dev/null 2>&1; then
  log "Installing curl (needed to find the public address)"
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get "${APT_CACHE[@]}" install -y curl >/dev/null
fi

log "DSpace 10 installer - configuration"
if [[ -z "$EXTERNAL_IP" ]]; then
  DETECTED_IP="$(detect_ip)"
  [[ -z "$DETECTED_IP" ]] && warn "Could not auto-detect a public IP."
  if [[ "$ASSUME_YES" == "1" ]]; then
    EXTERNAL_IP="${DETECTED_IP:-localhost}"
  else
    # Ask even when detection worked: on a local VM or behind NAT the detected address can be the wrong one.
    [[ -n "$DETECTED_IP" ]] && echo "  Detected public address: ${DETECTED_IP}. Press Enter to use it, or type the right one."
    while :; do
      read -rp "  Public address (public IP or DNS) used in URLs [${DETECTED_IP:-localhost}]: " EXTERNAL_IP
      EXTERNAL_IP="${EXTERNAL_IP:-${DETECTED_IP:-localhost}}"
      [[ "$EXTERNAL_IP" =~ ^[A-Za-z0-9.-]+$ ]] && break
      echo "  -> type only the address, e.g. 203.0.113.10 or repo.example.org (no http://, port or spaces)."
    done
  fi
fi

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
cache_size() { du -sh "$DOWNLOAD_CACHE" 2>/dev/null | cut -f1 || true; }
CACHE_LINE=""
[[ -n "$DOWNLOAD_CACHE" ]] && CACHE_LINE=$'\n'"   Download cache: ${DOWNLOAD_CACHE} ($(cache_size) saved so far)"

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
   Swap        : ${SWAP_SIZE}     Node build heap: ${NODE_HEAP_MB} MB${CACHE_LINE}
  ----------------------------------------------------------------
SUMMARY

if [[ "$ASSUME_YES" != "1" ]]; then
  read -rp "  Proceed with installation? [y/N]: " ok
  [[ "${ok,,}" == "y" ]] || die "Aborted by user."
fi

# Save generated passwords before anything is installed, so they survive a failed run.
if [[ "${GENERATED_SECRETS:-0}" == "1" ]]; then
  ( umask 077
    printf '# DSpace installer: passwords for this server. A re-run reads this file; keep it.\nADMIN_EMAIL=%s\nADMIN_PASS=%s\nDB_PASS=%s\n' \
      "$ADMIN_EMAIL" "$ADMIN_PASS" "$DB_PASS" > "$CREDENTIALS_FILE" )
  chmod 600 "$CREDENTIALS_FILE"
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
if command -v netfilter-persistent >/dev/null 2>&1; then FW_PKG=""; else FW_PKG="ufw"; fi
apt-get update -y
apt-get "${APT_CACHE[@]}" install -y openjdk-21-jdk ant postgresql postgresql-contrib \
  libpostgresql-jdbc-java curl wget git unzip ${FW_PKG:+"$FW_PKG"}

JAVA_HOME="/usr/lib/jvm/java-21-openjdk-$(dpkg --print-architecture)"
[[ -d "$JAVA_HOME" ]] || die "JDK 21 not found at ${JAVA_HOME} (DSpace 10 requires Java 21)."
update-alternatives --set java "${JAVA_HOME}/bin/java" >/dev/null 2>&1 || true
update-alternatives --set javac "${JAVA_HOME}/bin/javac" >/dev/null 2>&1 || true

if [[ ! -d "$MAVEN_DIR" ]]; then
  log "Downloading Apache Maven ${MAVEN_VERSION} (DSpace 10 requires 3.9.x+; distro packages are older)"
  apache_get "maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" /tmp/maven.tgz
  tar xzf /tmp/maven.tgz -C "$INSTALL_ROOT"
  mv "${INSTALL_ROOT}/apache-maven-${MAVEN_VERSION}" "$MAVEN_DIR"
fi
MVN="${MAVEN_DIR}/bin/mvn"

log "Creating service user '${DSPACE_USER}' and install directories"
id "$DSPACE_USER" &>/dev/null || useradd -m -s /bin/bash "$DSPACE_USER"
mkdir -p "$DSPACE_DIR"
chown "$DSPACE_USER:$DSPACE_USER" "$DSPACE_DIR"

# Maven, npm and nvm run as the service user, so their parts of the download cache belong to it.
MVN_CACHE="" NPM_CACHE=""
if [[ -n "$DOWNLOAD_CACHE" ]]; then
  for d in maven npm nvm; do
    mkdir -p "${DOWNLOAD_CACHE}/${d}"
    chown -R "$DSPACE_USER:$DSPACE_USER" "${DOWNLOAD_CACHE}/${d}" || warn "Could not hand ${DOWNLOAD_CACHE}/${d} to ${DSPACE_USER}."
    sudo -u "$DSPACE_USER" test -w "${DOWNLOAD_CACHE}/${d}" || \
      die "The '${DSPACE_USER}' user cannot write to ${DOWNLOAD_CACHE}/${d}; use a folder it can reach, such as /var/cache/dspace-installer."
  done
  MVN_CACHE=" -Dmaven.repo.local='${DOWNLOAD_CACHE}/maven'"
  NPM_CACHE="export npm_config_cache='${DOWNLOAD_CACHE}/npm' npm_config_prefer_offline=true; "
fi

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
  apache_get "solr/solr/${SOLR_VERSION}/solr-${SOLR_VERSION}.tgz" "/tmp/solr-${SOLR_VERSION}.tgz"
  tar xzf "/tmp/solr-${SOLR_VERSION}.tgz" -C "$INSTALL_ROOT"
  mv "${INSTALL_ROOT}/solr-${SOLR_VERSION}" "$SOLR_DIR"
  chown -R "$DSPACE_USER:$DSPACE_USER" "$SOLR_DIR"
fi

if [[ ! -d "$TOMCAT_DIR" ]]; then
  log "Downloading Apache Tomcat ${TOMCAT_VERSION}"
  TC_MAJOR="${TOMCAT_VERSION%%.*}"
  apache_get "tomcat/tomcat-${TC_MAJOR}/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" "/tmp/tomcat-${TOMCAT_VERSION}.tar.gz"
  tar xzf "/tmp/tomcat-${TOMCAT_VERSION}.tar.gz" -C "$INSTALL_ROOT"
  mv "${INSTALL_ROOT}/apache-tomcat-${TOMCAT_VERSION}" "$TOMCAT_DIR"
  chown -R "$DSPACE_USER:$DSPACE_USER" "$TOMCAT_DIR"
fi
grep -q 'URIEncoding="UTF-8"' "${TOMCAT_DIR}/conf/server.xml" || \
  sed -i "s|<Connector port=\"8080\"|<Connector port=\"${REST_PORT}\" URIEncoding=\"UTF-8\"|" \
    "${TOMCAT_DIR}/conf/server.xml"

SRC="DSpace-dspace-${DSPACE_VERSION}"
log "Downloading DSpace ${DSPACE_VERSION} source"
if [[ ! -d "${DSPACE_HOME}/build/${SRC}" ]]; then
  cached_get "https://github.com/DSpace/DSpace/archive/refs/tags/dspace-${DSPACE_VERSION}.tar.gz" /tmp/dspace-src.tgz || \
    die "Could not download the DSpace ${DSPACE_VERSION} source from GitHub."
  chmod 644 /tmp/dspace-src.tgz
  run_as_dspace "mkdir -p ~/build && cd ~/build && tar -zxf /tmp/dspace-src.tgz"
  rm -f /tmp/dspace-src.tgz
fi

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
run_as_dspace "export JAVA_HOME='${JAVA_HOME}'; cd ~/build/${SRC} && '${MVN}' -B -ntp${MVN_CACHE} package"
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
  cached_get "https://repo1.maven.org/maven2/org/apache/lucene/lucene-analysis-icu/${LUCENE_VER}/lucene-analysis-icu-${LUCENE_VER}.jar" \
    "${SOLR_LIB}/lucene-analysis-icu-${LUCENE_VER}.jar"
  cached_get "https://repo1.maven.org/maven2/com/ibm/icu/icu4j/${ICU4J_VER}/icu4j-${ICU4J_VER}.jar" \
    "${SOLR_LIB}/icu4j-${ICU4J_VER}.jar"
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
if [[ -n "$DOWNLOAD_CACHE" ]]; then
  # nvm keeps the Node.js archives it downloads in ~/.nvm/.cache and reuses them when their checksum matches.
  run_as_dspace "[ -e ~/.nvm/.cache ] || { rm -f ~/.nvm/.cache; ln -s '${DOWNLOAD_CACHE}/nvm' ~/.nvm/.cache; }" || \
    warn "Could not point nvm's cache at ${DOWNLOAD_CACHE}/nvm."
elif [[ -L "${DSPACE_HOME}/.nvm/.cache" && ! -e "${DSPACE_HOME}/.nvm/.cache" ]]; then
  rm -f "${DSPACE_HOME}/.nvm/.cache"   # left by an earlier run whose download cache has since been deleted
fi
run_as_dspace "export NVM_DIR=~/.nvm; . ~/.nvm/nvm.sh; ${NPM_CACHE}nvm install ${NODE_VERSION}; npm install -g pm2"

FE="dspace-angular-dspace-${DSPACE_VERSION}"
log "Downloading dspace-angular ${DSPACE_VERSION}"
if [[ ! -d "${DSPACE_HOME}/${FE}" ]]; then
  cached_get "https://github.com/DSpace/dspace-angular/archive/refs/tags/dspace-${DSPACE_VERSION}.tar.gz" /tmp/dspace-angular-src.tgz || \
    die "Could not download the dspace-angular ${DSPACE_VERSION} source from GitHub."
  chmod 644 /tmp/dspace-angular-src.tgz
  run_as_dspace "cd ~ && tar -zxf /tmp/dspace-angular-src.tgz"
  rm -f /tmp/dspace-angular-src.tgz
fi

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
# dspace-angular's dev dependencies include the Cypress test runner, which a production server never uses,
# so npm install skips its download.
run_as_dspace "export NVM_DIR=~/.nvm; . ~/.nvm/nvm.sh; ${NPM_CACHE}cd ~/${FE}; CYPRESS_INSTALL_BINARY=0 npm install; \
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
UFW_STATE="$(ufw status 2>/dev/null || true)"
INPUT_RULES="$(iptables -S INPUT 2>/dev/null || true)"
if [[ "$UFW_STATE" != *"Status: active"* && "$INPUT_RULES" == *"-j REJECT"* ]]; then
  echo "  iptables rejects incoming connections on this VM: opening ports ${REST_PORT} and ${UI_PORT}"
  for p in "$REST_PORT" "$UI_PORT"; do
    iptables -C INPUT -p tcp -m state --state NEW --dport "$p" -j ACCEPT 2>/dev/null ||
      iptables -I INPUT 1 -p tcp -m state --state NEW --dport "$p" -j ACCEPT ||
      warn "Could not open port $p in iptables."
  done
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || warn "Could not save the iptables rules; ports may close after a reboot."
  else
    warn "netfilter-persistent not found; ports ${REST_PORT} and ${UI_PORT} may close after a reboot."
  fi
fi

if [[ "${SAVED_SECRETS:-0}" == "1" ]]; then
  warn "The generated passwords are in ${CREDENTIALS_FILE} (readable by root only). Show them with: sudo cat ${CREDENTIALS_FILE}"
fi
CACHE_DONE=""
[[ -n "$DOWNLOAD_CACHE" ]] && CACHE_DONE=$'\n'"   Download cache: ${DOWNLOAD_CACHE} ($(cache_size); copy the folder to reuse it)"

cat <<DONE

  ================================================================
   DSpace ${DSPACE_VERSION} installation complete
  ================================================================
   Frontend (UI) : ${UI_URL}
   Backend (API) : ${SERVER_URL}
   Admin login   : ${ADMIN_EMAIL}
   Install log   : ${INSTALL_LOG}${CACHE_DONE}

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
