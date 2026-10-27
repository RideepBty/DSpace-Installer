#!/usr/bin/env bash
# record-run.sh - run a DSpace installer on a fresh Ubuntu VM and record the run.
#
#   sudo bash record-run.sh --label local-u2404-d10-r1 --ref v1.2.1 --script install-dspace10.sh
#   sudo bash record-run.sh --label local-u2404-d10-p3 --ref main --cache    (practice run, download cache on)
#   sudo bash record-run.sh --label rebuild-t07 --file install.sh
#   sudo bash record-run.sh --label local-u2404-d10-int12 --ref v1.2.1 --interrupt-after 12
#   sudo bash record-run.sh --label local-u2404-d10-reboot --check
#
# Each run gets a folder ~/dspace-runs/<label>/ and one row in ~/dspace-runs/results.csv.
# Test passwords are generated once per VM, kept in /root/dspace-test-secrets.env
# (root only) and masked in the saved logs.
# --cache gives the installer DOWNLOAD_CACHE=/var/cache/dspace-installer and records cache=yes;
# it is refused for labels of reported runs, which must download everything.
# On a cloud VM the cloud is found from its metadata service (AWS, Google Cloud, Azure, Oracle, Akamai,
# and IBM Cloud when the VM was created with metadata on); --provider names it when that fails.

set -uo pipefail

REPO="${REPO:-RideepBty/DSpace-Installer}"
REST_PORT="${REST_PORT:-8080}"
UI_PORT="${UI_PORT:-4000}"
SOLR_PORT="${SOLR_PORT:-8983}"
DSPACE_DIR="${DSPACE_DIR:-/dspace}"
TOMCAT_DIR="${TOMCAT_DIR:-/opt/tomcat}"
DSPACE_USER="${DSPACE_USER:-dspace}"
STAGE_MARK="${STAGE_MARK:-==>}"
SECRETS="/root/dspace-test-secrets.env"
WRAPPER_VERSION="1.3"
CACHE_DIR="${DOWNLOAD_CACHE:-/var/cache/dspace-installer}"

LABEL="" REF="main" SCRIPT="install-dspace10.sh" FILE="" INTERRUPT="" CHECK_ONLY=0 NOTE="" PROVIDER_ARG="" CACHE=0

usage() {
  cat <<'USAGE'
Usage:
  sudo bash record-run.sh --label NAME [--provider CLOUD] [--ref TAG] [--script FILE.sh] [--note TEXT]
  sudo bash record-run.sh --label NAME --cache                    (practice runs: use the download cache)
  sudo bash record-run.sh --label NAME --file ./install.sh        (test a local script)
  sudo bash record-run.sh --label NAME --interrupt-after MINUTES  (stop the installer on purpose)
  sudo bash record-run.sh --label NAME --check                    (checks only, e.g. after a reboot)
Labels: letters, digits, dot, dash, underscore - e.g. local-u2404-d10-r1
--cache: the installer keeps and reuses downloads in /var/cache/dspace-installer; not for reported runs.
--provider: the cloud's short name (oracle, ibm, akamai, aws, azure, gcp), or local.
USAGE
  exit 2
}
die() { printf 'record-run: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)           LABEL="${2:-}"; shift 2 ;;
    --ref)             REF="${2:-}"; shift 2 ;;
    --script)          SCRIPT="${2:-}"; shift 2 ;;
    --file)            FILE="${2:-}"; shift 2 ;;
    --interrupt-after) INTERRUPT="${2:-}"; shift 2 ;;
    --check)           CHECK_ONLY=1; shift ;;
    --note)            NOTE="${2:-}"; shift 2 ;;
    --provider)        PROVIDER_ARG="${2:-}"; shift 2 ;;
    --cache)           CACHE=1; shift ;;
    -h|--help)         usage ;;
    *)                 printf 'Unknown option: %s\n' "$1" >&2; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run with sudo: sudo bash record-run.sh ..."
[[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || die "give a --label made of letters, digits, '.', '-' or '_'"
[[ -z "$INTERRUPT" || "$INTERRUPT" =~ ^[0-9]+$ ]] || die "--interrupt-after takes whole minutes"
[[ -z "$FILE" || -f "$FILE" ]] || die "file not found: $FILE"
[[ -z "$PROVIDER_ARG" || "$PROVIDER_ARG" =~ ^[a-z0-9-]+$ ]] || die "--provider takes a short lowercase name, e.g. oracle"
if [[ $CACHE -eq 1 ]]; then
  [[ -z "$FILE" && $CHECK_ONLY -eq 0 ]] || die "--cache works only when installing the repository's installers (not with --file or --check)"
  if [[ "$LABEL" =~ -(r[0-9]+|rerun|reboot|int[0-9]*|resume)(-[0-9]+)?$ ]]; then
    die "--cache is for practice runs; '$LABEL' is a reported-run label, and reported runs must download everything. Use a label ending in -p1, -p2 ..."
  fi
fi
for c in curl python3 script timeout sha256sum; do
  command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
done

OWNER="${SUDO_USER:-root}"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
OWNER_HOME="${OWNER_HOME:-/root}"
RUNS="${RUNS_DIR:-$OWNER_HOME/dspace-runs}"
mkdir -p "$RUNS"
DIR="$RUNS/$LABEL"
n=2
while [[ -e "$DIR" ]]; do DIR="$RUNS/$LABEL-$n"; n=$((n + 1)); done
RUN_ID="$(basename "$DIR")"
mkdir -p "$DIR"

# ---------------------------------------------------------------- secrets
# Re-runs and checks on the same VM must reuse the same passwords.
if [[ -f "$SECRETS" ]]; then
  # shellcheck disable=SC1090
  . "$SECRETS"
fi
DB_PASS="${DB_PASS:-${T_DB_PASS:-$(openssl rand -hex 12)}}"
ADMIN_PASS="${ADMIN_PASS:-${T_ADMIN_PASS:-$(openssl rand -hex 12)}}"
ADMIN_EMAIL="${ADMIN_EMAIL:-${T_ADMIN_EMAIL:-admin@example.com}}"
( umask 077
  printf 'T_DB_PASS=%q\nT_ADMIN_PASS=%q\nT_ADMIN_EMAIL=%q\n' \
    "$DB_PASS" "$ADMIN_PASS" "$ADMIN_EMAIL" > "$SECRETS" )

# ------------------------------------------------------------ environment
MD="${MD_BASE:-http://169.254.169.254}"
md() { curl -sf --max-time 2 "$@" 2>/dev/null; }
is_ipv4() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
is_private() {  # RFC 1918, carrier-grade NAT, link-local and loopback addresses
  [[ "$1" =~ ^(10|127)\. || "$1" =~ ^192\.168\. || "$1" =~ ^169\.254\. || "$1" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ||
     "$1" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}
json_get() {  # json_get key.subkey < JSON  -> the value, or nothing
  python3 -c 'import json, sys
try:
    v = json.load(sys.stdin)
    for k in sys.argv[1].split("."):
        v = v[k]
    print(v)
except Exception:
    pass' "$1"
}
PROVIDER="local" ITYPE="" REGION="" PUB_IP=""
AZ='api-version=2021-02-01&format=text'
OCI='Authorization: Bearer Oracle'
tok="$(md -X PUT "$MD/latest/api/token" -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
if [[ -n "$tok" ]]; then
  PROVIDER="aws"
  ITYPE="$(md -H "X-aws-ec2-metadata-token: $tok" "$MD/latest/meta-data/instance-type" || true)"
  REGION="$(md -H "X-aws-ec2-metadata-token: $tok" "$MD/latest/meta-data/placement/region" || true)"
  PUB_IP="$(md -H "X-aws-ec2-metadata-token: $tok" "$MD/latest/meta-data/public-ipv4" || true)"
elif mt="$(md -H 'Metadata-Flavor: Google' "$MD/computeMetadata/v1/instance/machine-type")"; then
  PROVIDER="gcp"
  ITYPE="${mt##*/}"
  zone="$(md -H 'Metadata-Flavor: Google' "$MD/computeMetadata/v1/instance/zone" || true)"
  REGION="${zone##*/}"
  PUB_IP="$(md -H 'Metadata-Flavor: Google' \
    "$MD/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" || true)"
elif sz="$(md -H 'Metadata: true' "$MD/metadata/instance/compute/vmSize?$AZ")"; then
  PROVIDER="azure"
  ITYPE="$sz"
  REGION="$(md -H 'Metadata: true' "$MD/metadata/instance/compute/location?$AZ" || true)"
  PUB_IP="$(md -H 'Metadata: true' \
    "$MD/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?$AZ" || true)"
elif shape="$(md -H "$OCI" "$MD/opc/v2/instance/shape")" && [[ -n "$shape" ]]; then
  PROVIDER="oracle"
  sc="$(md -H "$OCI" "$MD/opc/v2/instance/shapeConfig" || true)"
  ocpus="$(printf '%s' "$sc" | json_get ocpus)"
  mem="$(printf '%s' "$sc" | json_get memoryInGBs)"
  ITYPE="$shape${ocpus:+ (${ocpus%.0} OCPU, ${mem%.0} GB)}"
  REGION="$(md -H "$OCI" "$MD/opc/v2/instance/canonicalRegionName" || true)"
elif atok="$(md -X PUT -H 'Metadata-Token-Expiry-Seconds: 300' "$MD/v1/token")" && [[ -n "$atok" ]]; then
  PROVIDER="akamai"
  info="$(md -H "Metadata-Token: $atok" "$MD/v1/instance" || true)"
  ITYPE="$(printf '%s\n' "$info" | sed -n 's/^type: *//p' | head -1)"
  REGION="$(printf '%s\n' "$info" | sed -n 's/^region: *//p' | head -1)"
elif itok="$(md -X PUT "$MD/identity/v1/token?version=2025-08-26" -H 'Metadata-Flavor: ibm' \
        -H 'Content-Type: application/json' -d '{"expires_in": 300}' | json_get access_token)" && [[ -n "$itok" ]]; then
  PROVIDER="ibm"
  info="$(md -H "Authorization: Bearer $itok" "$MD/metadata/v1/instance?version=2025-04-22" || true)"
  ITYPE="$(printf '%s' "$info" | json_get profile.name)"
  REGION="$(printf '%s' "$info" | json_get zone.name)"
fi
DETECTED="$PROVIDER"
[[ -n "$PROVIDER_ARG" ]] && PROVIDER="$PROVIDER_ARG"
if [[ "$PROVIDER" == "local" ]]; then
  # Local VM: prefer an address the host can reach. VirtualBox's NAT address (10.0.2.x) is not
  # reachable from the host, so a host-only or bridged address wins when there is one.
  PUB_IP=""
  for ip in $(hostname -I 2>/dev/null); do
    is_ipv4 "$ip" || continue
    [[ -z "$PUB_IP" ]] && PUB_IP="$ip"
    if [[ "$ip" != 10.0.2.* ]]; then PUB_IP="$ip"; break; fi
  done
elif [[ -z "$PUB_IP" ]]; then
  # Clouds whose metadata gives no public IP: Akamai puts it on the VM itself; Oracle and IBM Cloud
  # keep it on a NAT gateway, so an outside echo service is asked (not the one the installer uses).
  for ip in $(hostname -I 2>/dev/null); do
    if is_ipv4 "$ip" && ! is_private "$ip"; then PUB_IP="$ip"; break; fi
  done
  [[ -z "$PUB_IP" ]] && PUB_IP="$(curl -s --max-time 5 "${IP_ECHO:-https://api.ipify.org}" 2>/dev/null | tr -d '[:space:]')"
fi
is_ipv4 "$PUB_IP" || PUB_IP=""

# The original installer finds its public address itself on a cloud VM; that is part of the test.
# A local VM has no cloud metadata, and a script under test (--file) is given the address.
IP_MODE="auto"
if [[ -n "${EXTERNAL_IP:-}" ]]; then
  IP_MODE="given"
  PUB_IP="$EXTERNAL_IP"
elif [[ "$PROVIDER" == "local" || -n "$FILE" ]]; then
  EXTERNAL_IP="$PUB_IP"
  IP_MODE="set-by-recorder"
fi
[[ $CHECK_ONLY -eq 1 ]] && REF=""

# shellcheck disable=SC1091
. /etc/os-release
OS_NAME="${PRETTY_NAME:-unknown}"
VCPUS="$(nproc)"
RAM_GB="$(awk '/MemTotal/ {printf "%.1f", $2/1048576}' /proc/meminfo)"
DISK_GB="$(df -BG --output=size / | tail -1 | tr -dc '0-9')"
CLOUD_INIT="$(cloud-init status 2>/dev/null | awk '/status:/ {print $2}')"
CLOUD_INIT="${CLOUD_INIT:-n/a}"
if pgrep -f 'unattended-upgrade|apt.systemd.daily|apt-get|dpkg ' >/dev/null 2>&1; then
  APT_BUSY="yes"
else
  APT_BUSY="no"
fi
# The installer's download cache: used only with --cache; its size is recorded either way.
cache_mb() { if [[ -d "$CACHE_DIR" ]]; then du -sm "$CACHE_DIR" 2>/dev/null | cut -f1; else echo 0; fi; }
CACHE_MB_START="$(cache_mb)"
if [[ $CACHE -eq 1 ]]; then
  CACHE_USED="yes" CACHE_TEXT="used: $CACHE_DIR, $CACHE_MB_START MB at start"
elif [[ -d "$CACHE_DIR" ]]; then
  CACHE_USED="no" CACHE_TEXT="not used ($CACHE_DIR exists, $CACHE_MB_START MB)"
else
  CACHE_USED="no" CACHE_TEXT="not used ($CACHE_DIR absent)"
fi

# --------------------------------------------------------------- installer
SOURCE="" SHA="" COMMIT="" LINE_ENDINGS="unchanged"
if [[ $CHECK_ONLY -eq 0 ]]; then
  if [[ -n "$FILE" ]]; then
    cp "$FILE" "$DIR/installer.sh"
    # A script saved on Windows has CRLF line endings, which bash cannot run.
    if grep -q $'\r' "$DIR/installer.sh"; then sed -i 's/\r$//' "$DIR/installer.sh"; LINE_ENDINGS="CRLF converted to LF"; fi
    SOURCE="file:$(basename "$FILE")"
    REF=""
  else
    SOURCE="https://raw.githubusercontent.com/$REPO/$REF/$SCRIPT"
    curl -fsSL --retry 3 -o "$DIR/installer.sh" "$SOURCE" || die "download failed: $SOURCE"
    COMMIT="$(curl -fsSL --max-time 10 "https://api.github.com/repos/$REPO/commits/$REF" 2>/dev/null |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])' 2>/dev/null || true)"
  fi
  SHA="$(sha256sum "$DIR/installer.sh" | cut -d' ' -f1)"
fi

{
  echo "run_id:          $RUN_ID"
  echo "wrapper_version: $WRAPPER_VERSION"
  echo "date_utc:        $(date -u +%FT%TZ)"
  echo "os:              $OS_NAME"
  echo "kernel:          $(uname -r)"
  echo "vcpus:           $VCPUS"
  echo "ram_gb:          $RAM_GB"
  echo "disk_gb:         $DISK_GB"
  echo "provider:        $PROVIDER${PROVIDER_ARG:+ (given with --provider; metadata found: $DETECTED)}"
  echo "instance_type:   $ITYPE"
  echo "region:          $REGION"
  echo "cloud_init:      $CLOUD_INIT"
  echo "apt_busy:        $APT_BUSY"
  echo "public_ip:       ${PUB_IP:-unknown}"
  echo "external_ip:     ${EXTERNAL_IP:-(installer detects)} [$IP_MODE]"
  echo "installer:       ${SOURCE:-none (checks only)}"
  echo "ref:             $REF"
  echo "commit:          $COMMIT"
  echo "sha256:          $SHA"
  echo "line_endings:    $LINE_ENDINGS"
  echo "download_cache:  $CACHE_TEXT"
  echo "admin_email:     $ADMIN_EMAIL"
} > "$DIR/env.txt"

# --------------------------------------------------------------------- run
KIND="install"
[[ -n "$INTERRUPT" ]] && KIND="interrupted"
[[ $CHECK_ONLY -eq 1 ]] && KIND="check"
EXIT="" START="$(date -u +%s)"
if [[ $CHECK_ONLY -eq 0 ]]; then
  export ASSUME_YES=1 DB_PASS ADMIN_PASS ADMIN_EMAIL
  [[ -n "${EXTERNAL_IP:-}" ]] && export EXTERNAL_IP
  # Only --cache turns the download cache on; a DOWNLOAD_CACHE left in the environment must not leak in.
  if [[ $CACHE -eq 1 ]]; then
    export DOWNLOAD_CACHE="$CACHE_DIR"
  else
    unset DOWNLOAD_CACHE
    [[ -d "$CACHE_DIR" ]] && printf '[record-run] note: %s exists (%s MB) but is not used without --cache.\n' "$CACHE_DIR" "$CACHE_MB_START"
  fi
  cmd="bash '$DIR/installer.sh'"
  [[ -n "$INTERRUPT" ]] && cmd="timeout -s INT -k 60 ${INTERRUPT}m $cmd"
  printf '\n[record-run] %s: starting %s at %s UTC\n\n' "$RUN_ID" "${SOURCE}" "$(date -u +%T)"
  cd "$OWNER_HOME" || cd /
  script -q -f -e -T "$DIR/timing.log" -c "$cmd" "$DIR/terminal.log"
  EXIT=$?
fi
END="$(date -u +%s)"
CACHE_MB_END="$(cache_mb)"

# ------------------------------------------------------------------ checks
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null; }
wait_code() {  # url, seconds -> prints final HTTP code
  local url="$1" secs="$2" c t=0
  c="$(code "$url")"
  while [[ "$c" != "200" && $t -lt $secs ]]; do sleep 10; t=$((t + 10)); c="$(code "$url")"; done
  printf '%s' "${c:-000}"
}
CFG=""
for f in "$DSPACE_DIR/config/local.cfg" /dspace/config/local.cfg /opt/dspace/config/local.cfg /srv/dspace/config/local.cfg; do
  [[ -f "$f" ]] && { CFG="$f"; break; }
done
cfg_get() { [[ -n "$CFG" ]] && sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CFG" | tail -1 | tr -d '[:space:]'; }

WAIT=600
[[ "$KIND" == "interrupted" || ( -n "$EXIT" && "$EXIT" != "0" ) ]] && WAIT=0
API_LOCAL="$(wait_code "http://localhost:$REST_PORT/server/api" "$WAIT")"
UI_LOCAL="$(wait_code "http://localhost:$UI_PORT/" "$(( WAIT / 2 ))")"
# The public check uses the URLs DSpace is configured with (what browsers will be sent to);
# if no local.cfg is found, it uses this VM's public address.
SERVER_URL="$(cfg_get 'dspace\.server\.url' || true)" URL_SOURCE="local.cfg"
UI_URL="$(cfg_get 'dspace\.ui\.url' || true)"
if [[ -z "$SERVER_URL" ]]; then
  URL_SOURCE="public address"
  [[ -n "$PUB_IP" ]] && SERVER_URL="http://$PUB_IP:$REST_PORT/server"
fi
[[ -z "$UI_URL" && -n "$PUB_IP" ]] && UI_URL="http://$PUB_IP:$UI_PORT"
REST_HOST="$(printf '%s' "$SERVER_URL" | sed -E 's#^[A-Za-z]+://([^/:]+).*#\1#')"
LOCALHOST_URL="no"
[[ -z "$REST_HOST" || "$REST_HOST" == "localhost" || "$REST_HOST" =~ ^127\. || "$REST_HOST" == "0.0.0.0" ]] && LOCALHOST_URL="yes"
API_PUBLIC="" UI_PUBLIC=""
[[ -n "$SERVER_URL" ]] && API_PUBLIC="$(code "$SERVER_URL/api")"
[[ -n "$UI_URL" ]] && UI_PUBLIC="$(code "$UI_URL/")"
# The UI's own idea of its public address: robots.txt lists the sitemap there. DSpace 10 takes it from the UI's
# baseUrl setting (http://localhost:4000 when unset), which it also uses for redirects and Google Scholar tags.
SITEMAP_URL="" UI_BASE_OK=""
if [[ -n "$UI_URL" ]]; then
  SITEMAP_URL="$(curl -s --max-time 20 "$UI_URL/robots.txt" 2>/dev/null | tr -d '\r' |
    sed -n 's/^[Ss]itemap:[[:space:]]*//p' | head -1)"
  if [[ -z "$SITEMAP_URL" ]]; then
    UI_BASE_OK="unknown"
  elif [[ "$SITEMAP_URL" == "${UI_URL%/}/"* ]]; then
    UI_BASE_OK="yes"
  else
    UI_BASE_OK="no"
  fi
fi

LOGIN="000"
if [[ "$API_LOCAL" == "200" ]]; then
  jar="$(mktemp)" hdr="$(mktemp)" pw="$(mktemp)"
  printf '%s' "$ADMIN_PASS" > "$pw"
  api="http://localhost:$REST_PORT/server/api"
  curl -s -c "$jar" -b "$jar" -D "$hdr" -o /dev/null --max-time 20 "$api/security/csrf"
  xsrf="$(awk 'tolower($1) == "dspace-xsrf-token:" {print $2}' "$hdr" | tr -d '\r' | tail -1)"
  LOGIN="$(curl -s -c "$jar" -b "$jar" -o /dev/null -w '%{http_code}' --max-time 30 \
    -X POST "$api/authn/login" -H "X-XSRF-TOKEN: $xsrf" \
    --data-urlencode "user=$ADMIN_EMAIL" --data-urlencode "password@$pw")"
  rm -f "$jar" "$hdr" "$pw"
fi

SOLR_JSON="$(curl -s --max-time 20 "http://localhost:$SOLR_PORT/solr/admin/cores?action=STATUS&wt=json" 2>/dev/null)"
read -r SOLR_CORES SOLR_SEARCH < <(printf '%s' "$SOLR_JSON" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)["status"]
    print(len(s), "yes" if "search" in s else "no")
except Exception:
    print(0, "no")')

svc() {  # unit -> "active/enabled"
  command -v systemctl >/dev/null 2>&1 || { printf 'n/a'; return; }
  printf '%s/%s' "$(systemctl is-active "$1" 2>/dev/null | head -1)" "$(systemctl is-enabled "$1" 2>/dev/null | head -1)"
}
SVC_PG="$(svc postgresql)" SVC_SOLR="$(svc solr)" SVC_TOMCAT="$(svc tomcat)" SVC_PM2="$(svc "pm2-$DSPACE_USER")"

URIENC="" NESTED=""
if [[ -f "$TOMCAT_DIR/conf/server.xml" ]]; then
  URIENC="$(grep -o 'URIEncoding="UTF-8"' "$TOMCAT_DIR/conf/server.xml" | wc -l)"
  NESTED="no"; [[ -d "$TOMCAT_DIR/webapps/server/server" ]] && NESTED="yes"
fi
OOM="$(journalctl -k --no-pager --since "@$START" 2>/dev/null | grep -ci 'out of memory' || true)"
[[ "$KIND" == "check" ]] && OOM="$(journalctl -k -b --no-pager 2>/dev/null | grep -ci 'out of memory' || true)"
DISK_USED="$(df -BG --output=used / | tail -1 | tr -dc '0-9')"
JAVA_V=""
command -v java >/dev/null 2>&1 && JAVA_V="$(java -version 2>&1 | grep -m1 ' version ' | tr -d '"')"
NODE_V="$(sudo -u "$DSPACE_USER" bash -c 'export NVM_DIR=~/.nvm; . ~/.nvm/nvm.sh >/dev/null 2>&1 && node -v' 2>/dev/null || true)"
DSPACE_V=""
if [[ -x "$DSPACE_DIR/bin/dspace" ]]; then
  DSPACE_V="$(cd /tmp && timeout 180 sudo -u "$DSPACE_USER" "$DSPACE_DIR/bin/dspace" version 2>/dev/null |
    sed -n 's/^ *DSpace version: *//p' | head -1 || true)"
fi

PASS="no"
if [[ "$KIND" != "interrupted" && ( "$KIND" == "check" || "$EXIT" == "0" ) && "$API_LOCAL" == "200" &&
      "$API_PUBLIC" == "200" && "$LOCALHOST_URL" == "no" && "$UI_LOCAL" == "200" && "$LOGIN" == "200" &&
      "$SOLR_SEARCH" == "yes" && "$UI_BASE_OK" == "yes" ]]; then
  PASS="yes"
fi

{
  echo "api_local:   $API_LOCAL   (http://localhost:$REST_PORT/server/api)"
  echo "api_public:  ${API_PUBLIC:-n/a}   (${SERVER_URL:-no URL}/api, from $URL_SOURCE; localhost URL: $LOCALHOST_URL)"
  echo "ui_local:    $UI_LOCAL   (http://localhost:$UI_PORT/)"
  echo "ui_public:   ${UI_PUBLIC:-n/a}   (${UI_URL:-no URL}/)"
  echo "ui_address:  ${UI_BASE_OK:-n/a}   (robots.txt sitemap: ${SITEMAP_URL:-none}; expected under ${UI_URL:-?}/)"
  echo "login:       $LOGIN   (POST /server/api/authn/login as $ADMIN_EMAIL)"
  echo "solr_cores:  $SOLR_CORES (search core: $SOLR_SEARCH)"
  echo "services:    postgresql=$SVC_PG solr=$SVC_SOLR tomcat=$SVC_TOMCAT pm2-$DSPACE_USER=$SVC_PM2"
  echo "server.xml:  URIEncoding count=${URIENC:-n/a}; nested webapps/server/server=${NESTED:-n/a}"
  echo "oom_kills:   $OOM"
  echo "disk_used:   ${DISK_USED} GB"
  echo "java:        $JAVA_V"
  echo "node:        $NODE_V"
  echo "dspace:      $DSPACE_V"
  echo "pass:        $PASS"
} > "$DIR/health.txt"

# --------------------------------------------- mask secrets, stages, CSV row
export RR_DIR="$DIR" RR_MASK1="$DB_PASS" RR_MASK2="$ADMIN_PASS" RR_MARK="$STAGE_MARK" RR_TOTAL="$((END - START))"
export RR_ROW
RR_ROW="$(python3 -c 'import json,sys; print(json.dumps(dict(zip(sys.argv[1::2], sys.argv[2::2]))))' \
  run_id "$RUN_ID" label "$LABEL" kind "$KIND" date_utc "$(date -u -d "@$START" +%F)" \
  start_utc "$(date -u -d "@$START" +%T)" end_utc "$(date -u -d "@$END" +%T)" \
  minutes "$(awk -v s="$START" -v e="$END" -v k="$KIND" 'BEGIN { if (k != "check") printf "%.1f", (e - s) / 60 }')" \
  exit_code "$EXIT" interrupt_after_min "$INTERRUPT" provider "$PROVIDER" instance_type "$ITYPE" region "$REGION" \
  os "$OS_NAME" vcpus "$VCPUS" ram_gb "$RAM_GB" disk_gb "$DISK_GB" cloud_init "$CLOUD_INIT" apt_busy "$APT_BUSY" \
  ip_mode "$IP_MODE" installer "$SOURCE" ref "$REF" commit "$COMMIT" sha256 "$SHA" \
  api_local "$API_LOCAL" api_public "$API_PUBLIC" public_ip "$PUB_IP" rest_url "$SERVER_URL" \
  url_source "$URL_SOURCE" rest_url_localhost "$LOCALHOST_URL" ui_local "$UI_LOCAL" ui_public "$UI_PUBLIC" login "$LOGIN" \
  solr_cores "$SOLR_CORES" solr_search "$SOLR_SEARCH" svc_postgresql "$SVC_PG" svc_solr "$SVC_SOLR" \
  svc_tomcat "$SVC_TOMCAT" svc_pm2 "$SVC_PM2" uriencoding_count "$URIENC" nested_webapp "$NESTED" \
  oom_kills "$OOM" disk_used_gb "$DISK_USED" java "$JAVA_V" node "$NODE_V" dspace "$DSPACE_V" \
  pass "$PASS" note "$NOTE" wrapper_version "$WRAPPER_VERSION" \
  cache "$CACHE_USED" cache_mb_at_start "$CACHE_MB_START" cache_mb_at_end "$CACHE_MB_END" \
  ui_sitemap_url "$SITEMAP_URL" ui_base_ok "$UI_BASE_OK")"

python3 - <<'PY'
import bisect, csv, json, os, re

d = os.environ["RR_DIR"]
row = json.loads(os.environ["RR_ROW"])
ts_path, tm_path = os.path.join(d, "terminal.log"), os.path.join(d, "timing.log")
stages = []

if os.path.exists(ts_path):
    raw = open(ts_path, "rb").read()
    for key in ("RR_MASK1", "RR_MASK2"):          # same-length masks keep the replay timing valid
        s = os.environ.get(key, "").encode()
        if len(s) >= 6:
            raw = raw.replace(s, b"*" * len(s))
    open(ts_path, "wb").write(raw)

    ansi = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][A-Za-z0-9]")
    lines = []
    for line in ansi.sub(b"", raw).decode("utf-8", "replace").split("\n"):
        line = line.rstrip("\r")
        lines.append(line.split("\r")[-1])
    open(os.path.join(d, "terminal.txt"), "w").write("\n".join(lines))

    # Byte offset of each output chunk -> seconds since the start (script --log-timing).
    body = raw.find(b"\n") + 1 if raw.startswith(b"Script started") else 0
    chunks, t, off = [], 0.0, body
    if os.path.exists(tm_path):
        for tl in open(tm_path):
            p = tl.split()
            if len(p) == 2:
                delay, nbytes = p
            elif len(p) == 3 and p[0] == "O":
                _, delay, nbytes = p
            else:
                continue
            t += float(delay)
            chunks.append((off, t))
            off += int(nbytes)
    starts = [c[0] for c in chunks]
    mark = os.environ.get("RR_MARK", "==>").encode()
    for m in re.finditer(re.escape(mark), raw):
        i = bisect.bisect_right(starts, m.start()) - 1
        when = chunks[i][1] if i >= 0 else 0.0
        end = raw.find(b"\n", m.end())
        text = ansi.sub(b"", raw[m.end(): end if end > 0 else len(raw)]).decode("utf-8", "replace")
        stages.append([text.strip().rstrip("\r"), when])
    total = max(t, float(os.environ.get("RR_TOTAL", "0") or 0))
    with open(os.path.join(d, "stages.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["stage_no", "stage", "start_min", "minutes"])
        for i, (name, sec) in enumerate(stages):
            nxt = stages[i + 1][1] if i + 1 < len(stages) else total
            w.writerow([i + 1, name, f"{sec / 60:.2f}", f"{(nxt - sec) / 60:.2f}"])

row["stages_seen"] = str(len(stages))
row["last_stage"] = stages[-1][0] if stages else ""
cols = ["run_id", "label", "kind", "pass", "date_utc", "start_utc", "end_utc", "minutes", "exit_code",
        "interrupt_after_min", "last_stage", "stages_seen", "provider", "instance_type", "region", "os",
        "vcpus", "ram_gb", "disk_gb", "cloud_init", "apt_busy", "ip_mode", "installer", "ref", "commit",
        "sha256", "api_local", "api_public", "public_ip", "rest_url", "url_source", "rest_url_localhost",
        "ui_local", "ui_public", "login", "solr_cores", "solr_search",
        "svc_postgresql", "svc_solr", "svc_tomcat", "svc_pm2", "uriencoding_count", "nested_webapp",
        "oom_kills", "disk_used_gb", "java", "node", "dspace", "note", "wrapper_version",
        "cache", "cache_mb_at_start", "cache_mb_at_end", "ui_sitemap_url", "ui_base_ok"]
json.dump(row, open(os.path.join(d, "result.json"), "w"), indent=2)
results = os.path.join(os.path.dirname(d), "results.csv")
new = not os.path.exists(results)
if not new:
    # A results.csv started by an older wrapper gets the current columns, so no value lands in the wrong one.
    with open(results, newline="") as f:
        reader = csv.DictReader(f)
        old_cols, old_rows = reader.fieldnames or [], list(reader)
    if old_cols != cols:
        with open(results, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
            w.writeheader()
            w.writerows(old_rows)
with open(results, "a", newline="") as f:
    w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
    if new:
        w.writeheader()
    w.writerow(row)
PY

chown -R "$OWNER": "$RUNS" 2>/dev/null || true

cat <<EOF

[record-run] ${RUN_ID}: kind=${KIND} exit=${EXIT:-n/a} pass=${PASS} cache=${CACHE_USED}
             API ${API_LOCAL} (public ${API_PUBLIC:-n/a})  UI ${UI_LOCAL} (address ${UI_BASE_OK:-n/a})  login ${LOGIN}  Solr cores ${SOLR_CORES}
             saved in ${DIR}
EOF
[[ -f "$DIR/terminal.txt" ]] && echo "             last lines of the output:  tail -n 60 $DIR/terminal.txt"
exit 0
