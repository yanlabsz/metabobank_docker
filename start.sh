#!/bin/bash
# ============================================================================
#  Metabobank - one-click installer and controller
# ============================================================================
#  WHAT THIS SCRIPT DOES
#    Downloads (or reuses) three Docker images, loads them, creates the data
#    directory and starts the three services Metabobank needs:
#      - metabospark      the web application you open in a browser
#      - mongodb5_client  the database that ships with preloaded MS data
#      - rserve           the R analysis backend used by the web app
#
#  QUICK START
#    bash start.sh                install and start (local files are used when present)
#    bash start.sh --local        force "no network at all" (usually not needed)
#
#  COMMON COMMANDS
#    bash start.sh status         what is running right now
#    bash start.sh logs           follow the web application log
#    bash start.sh stop           stop everything (your data is kept)
#    bash start.sh restart        stop, then start again
#    bash start.sh recreate <svc> recreate one service (others keep running)
#    bash start.sh --force        rebuild containers from scratch
#    bash start.sh --only-start   just start (images are already loaded)
#    bash start.sh --help         show this text
#
#  OPTIONS
#    --local            force offline: refuse to use the network at all (optional,
#                       because files already in this folder are always used first)
#    --force            remove containers first, then start them again
#    --only-start       skip the download/load phase entirely
#    --skip-checksum    do not verify SHA256SUMS.txt (not recommended)
#    --status / status  print the current state
#    --stop / stop      shut the services down
#    --restart          restart the services
#    --logs / logs      follow the log of the web application
#    --recreate <svc>   recreate the named service(s) with --no-deps --force-recreate
#    --with-deps        with --recreate: also recreate the dependencies
#
#  CUSTOM PORTS AND PATHS
#    METABOBANK_PORT=18090 bash start.sh          web on port 18090
#    METABOBANK_DATA_DIR=/data/metabobank bash start.sh
#  The database port is not published to the host (only the web container
#  reaches it), so a busy 27023 on the host does not affect this install.
#
#  IF SOMETHING GOES WRONG
#    1. run: bash start.sh status      (which service is not running?)
#    2. run: bash start.sh logs        (what does the web app say?)
#    3. if the port is taken: METABOBANK_PORT=18090 bash start.sh
#    4. with an incomplete offline bundle: check the four files listed below
#
#  ONLY THIS ONE FILE IS NEEDED ONLINE
#    start.sh downloads docker-compose.yml, the three images and the checksum
#    file from the download site by itself. Nothing else has to be fetched by hand.
#
#  AN OFFLINE BUNDLE IS AT LEAST THESE FOUR FILES IN ONE FOLDER
#    start.sh
#    metabospark.tar.gz  mongodb5_client.tar.gz  omics.tar.gz
#    optional: docker-compose.yml (a standard one is written when missing)
#              SHA256SUMS.txt     (without it the files are not verified)
# ============================================================================
set -eo pipefail

# --- one instance at a time -------------------------------------------------
LOCK_FILE="${TMPDIR:-/tmp}/metabobank_start.lock"
acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            echo "" >&2
            echo "[STOP] Another copy of start.sh is already running." >&2
            echo "       Wait for it to finish, or check: bash start.sh status" >&2
            echo "" >&2
            exit 1
        fi
    fi
}

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
SUMS_FILE="$APP_DIR/SHA256SUMS.txt"
ENV_FILE="$APP_DIR/.env"

DOWNLOAD_SOURCES=(
    "https://www.metabobank.cn/download"
    "https://raw.githubusercontent.com/yanlabsz/metabobank_docker/main"
)
IMAGE_FILES=("metabospark.tar.gz" "mongodb5_client.tar.gz" "omics.tar.gz")
IMAGE_REFS=("metabank/metabospark:v3.0" "metabank/mongodb5_client:v3.0" "metabank/metabospark-omics:v3.0")

DATA_DIR="${METABOBANK_DATA_DIR:-$APP_DIR/metabobank_data}"
DATA_SUBDIRS=(csv_upload spectrum_upload sample_upload single_upload tools_upload download compound_catche dbs)
META_PORT="${METABOBANK_PORT:-8090}"
MONGO_PORT="${METABOBANK_MONGO_PORT:-27023}"
RSERVE_PORT="${METABOBANK_RSERVE_PORT:-6322}"
PROJECT_NAME="${METABOBANK_PROJECT:-$(basename "$APP_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')}"
if [ -z "$PROJECT_NAME" ]; then PROJECT_NAME="metabobank"; fi

BOLD='\033[1m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'
info()   { echo -e "${GREEN}[OK]${NC}   $*"; }
note()   { echo -e "       $*"; }
warn()   { echo -e "${YELLOW}[NOTE]${NC} $*"; }
error()  { echo ""; echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
phase()  {
    echo ""
    echo -e "${BOLD}------------------------------------------------------------------${NC}"
    echo -e "${BOLD}>> $*${NC}"
    echo -e "${BOLD}------------------------------------------------------------------${NC}"
}
STEP=0
phase_step() { STEP=$((STEP + 1)); phase "Step $STEP: $*"; }
do_this() { echo -e "       ${BOLD}What to do:${NC} $*"; }

banner() {
    echo ""
    echo -e "${BOLD}==================================================================${NC}"
    echo -e "${BOLD}  Metabobank installer${NC}"
    echo -e "  This sets up three services: web application, database, R backend."
    echo -e "  Nothing is deleted: your data stays in ${DIM}${DATA_DIR}${NC}"
    echo -e "${BOLD}==================================================================${NC}"
}

# --- helpers ---------------------------------------------------------------
# Which kind of host are we on? Linux servers are the normal case; Git Bash /
# MSYS on Windows also works with Docker Desktop, but a few commands differ.
HOST_KIND="linux"
case "$(uname -s 2>/dev/null || echo Linux)" in
    MINGW*|MSYS*|CYGWIN*) HOST_KIND="windows" ;;
esac

DOCKER_VER=""
DOCKER_MAJOR=0

record_docker_version() {
    DOCKER_VER="$(docker --version 2>/dev/null | sed -n 's/.*version[ =]*\([0-9][0-9.]*\).*/\1/p')"
    DOCKER_MAJOR="${DOCKER_VER%%.*}"
    case "$DOCKER_MAJOR" in
        ''|*[!0-9]*) DOCKER_MAJOR=0 ;;
    esac
}

# Find a usable Compose, in three ways. The third one matters on old hosts:
# with Docker 1.13 the CLI cannot load plugins at all, so docker-compose-plugin
# installs fine but "docker compose" never appears. The binary itself still
# works when called directly.
detect_compose() {
    COMPOSE_CMD=""
    local p

    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
        note "Docker Compose ... $(docker compose version 2>/dev/null | awk '{print $NF}') (plugin)"
        return 0
    fi

    if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
        note "Docker Compose ... $(docker-compose version 2>/dev/null | head -n1)"
        return 0
    fi

    for p in /usr/libexec/docker/cli-plugins/docker-compose \
             /usr/local/lib/docker/cli-plugins/docker-compose \
             /usr/lib/docker/cli-plugins/docker-compose \
             "$HOME/.docker/cli-plugins/docker-compose"; do
        if [ -x "$p" ] && "$p" version >/dev/null 2>&1; then
            COMPOSE_CMD="$p"
            note "Docker Compose ... $("$p" version 2>/dev/null | head -n1)"
            note "  called directly from $p"
            warn "Your docker CLI ($DOCKER_VER) cannot load plugins, so the compose binary is used directly."
            if [ "$DOCKER_MAJOR" -lt 19 ] 2>/dev/null; then
                warn "Compose v2 against a Docker engine this old may fail; upgrading the engine is safer."
            fi
            return 0
        fi
    done

    return 1
}

port_busy() {
    local out=""
    if [ "$HOST_KIND" = "windows" ]; then
        # Windows netstat: "TCP  0.0.0.0:8090  0.0.0.0:0  LISTENING  1234"
        out="$(netstat -ano 2>/dev/null | awk '$1=="TCP"{print $2}' || true)"
    elif command -v ss >/dev/null 2>&1; then
        out="$(ss -lnt 2>/dev/null | awk 'NR>1{print $4}' || true)"
    elif command -v netstat >/dev/null 2>&1; then
        out="$(netstat -lnt 2>/dev/null | awk 'NR>2{print $4}' || true)"
    else
        return 1
    fi
    if echo "$out" | grep -qE "[:.]$1\$"; then
        return 0
    fi
    return 1
}

project_containers() {
    docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" \
        --format '{{.Names}}' 2>/dev/null || true
}

compose() {
    # --env-file is passed explicitly: a .env file is otherwise only read from
    # the current working directory, which breaks when the script is called
    # from somewhere else.
    if [ -f "$ENV_FILE" ]; then
        $COMPOSE_CMD --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"
    else
        $COMPOSE_CMD -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"
    fi
}

compose_services() { compose config --services 2>/dev/null || true; }

detect_web_service() {
    if [ -f "$COMPOSE_FILE" ]; then
        local svcs s
        svcs="$(compose_services)"
        for s in $svcs; do
            case "$s" in
                *spark*|*metabobank*|*web*) echo "$s"; return 0 ;;
            esac
        done
        echo "$svcs" | head -n1
        return 0
    fi
    echo "metabospark"
}

detect_host_port() {
    local cid out
    cid="$(compose ps -q "$WEB_SVC" 2>/dev/null | head -n1 || true)"
    if [ -z "$cid" ]; then return 1; fi
    out="$(docker port "$cid" 2>/dev/null | head -n1 || true)"
    if [ -z "$out" ]; then return 1; fi
    echo "${out##*:}"
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

head_len() {
    local len
    len="$(curl -fsIL --max-time 20 "$1" 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^content-length:/{v=$2} END{print v}' || true)"
    case "$len" in ''|*[!0-9]*) echo 0 ;; *) echo "$len" ;; esac
}

free_kb() { df -Pk "$APP_DIR" 2>/dev/null | awk 'NR==2{print $4}'; }

human_size() { awk -v b="$1" 'BEGIN{ if (b >= 1073741824) printf "%.1f GB", b/1073741824; else if (b >= 1048576) printf "%.0f MB", b/1048576; else printf "%.0f KB", b/1024 }'; }

# --- 1. environment --------------------------------------------------------
check_prereqs() {
    phase_step "checking Docker on this machine"

    if ! command -v docker >/dev/null 2>&1; then
        echo ""
        echo -e "${RED}Docker is not installed.${NC}"
        echo "  Metabobank runs in Docker, so Docker has to be installed first."
        echo ""
        echo "  CentOS / RHEL:"
        echo "    sudo yum install -y yum-utils"
        echo "    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
        echo "    sudo yum install -y docker-ce docker-compose-plugin"
        echo "    sudo systemctl start docker && sudo systemctl enable docker"
        echo ""
        echo "  Ubuntu / Debian:"
        echo "    sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2"
        echo "    sudo systemctl start docker"
        echo ""
        echo "  Then run this script again."
        exit 1
    fi
    note "Docker ... $(docker --version 2>/dev/null | sed 's/Docker version //; s/, build.*//')"
    record_docker_version

    if ! docker info >/dev/null 2>&1; then
        echo ""
        echo -e "${RED}Docker is installed but not running.${NC}"
        do_this "start it with:  sudo systemctl start docker"
        do_this "if you are not root, add yourself to the docker group:  sudo usermod -aG docker \$USER  (then log out and back in)"
        exit 1
    fi
    note "Docker daemon ... running"

    if ! detect_compose; then
        echo ""
        echo -e "${RED}Docker Compose cannot be used on this machine.${NC}"
        local doc_ver major
        doc_ver="$(docker --version 2>/dev/null | sed -n 's/.*version[ =]*\([0-9][0-9.]*\).*/\1/p')"
        major="${doc_ver%%.*}"
        if [ -n "$major" ] && [ "$major" -lt 19 ] 2>/dev/null; then
            echo "  Docker itself is too old ($doc_ver). The compose plugin needs Docker 19.03 or"
            echo "  newer, so 'docker-compose-plugin' installs correctly but can never be used."
            echo ""
            do_this "upgrade the engine and CLI (CentOS 7):"
            echo "           sudo yum remove -y docker docker-common docker-client || true"
            echo "           sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"
            echo "           sudo systemctl enable --now docker"
            echo ""
            do_this "or, if the engine must stay on 1.13, install the legacy Compose v1:"
            echo "           sudo yum install -y epel-release && sudo yum install -y docker-compose"
            echo "           (or: sudo pip install docker-compose==1.29.2)"
            echo ""
            echo "  After upgrading, verify with:  docker compose version"
        else
            echo "  The docker CLI works, but no compose binary was found."
            echo ""
            do_this "CentOS:  sudo yum install -y docker-compose-plugin"
            do_this "Ubuntu:  sudo apt-get install -y docker-compose-v2"
            do_this "legacy:  sudo pip install docker-compose==1.29.2"
        fi
        exit 1
    fi

    if [ "$DOCKER_MAJOR" -lt 20 ] 2>/dev/null; then
        warn "Docker $DOCKER_VER is quite old. Images saved by a newer Docker may fail to load"
        warn "with 'docker load'. If that happens, upgrade the engine: yum install -y docker-ce docker-ce-cli containerd.io"
    fi

    if [ "$(free_kb)" = "" ]; then
        warn "Cannot read free disk space; the installer will continue anyway."
    fi

    if [ "$HOST_KIND" = "windows" ]; then
        echo ""
        note "Windows detected (Git Bash). Docker Desktop must be running."
        note "  - The images are Linux images, so Docker Desktop must use the WSL 2 backend."
        note "  - Keep the data on a Windows path, for example: METABOBANK_DATA_DIR=C:/metabobank_data"
        note "  - If bash fails on odd lines, the file has CRLF endings: run"
        note "    sed -i 's/\\r\$//' start.sh    and try again."
        note "  - Windows works for testing; a Linux server or WSL 2 is recommended for real use."
        if grep -q $'\r' "$0" 2>/dev/null; then
            warn "start.sh currently has Windows (CRLF) line endings."
        fi
    fi
    info "Docker is ready."
}

# --- 2. ports --------------------------------------------------------------
check_ports() {
    phase_step "checking the ports Metabobank needs"
    local p busy=0 ports_to_check="$META_PORT"
    if mongo_port_published; then ports_to_check="$META_PORT $MONGO_PORT"; fi
    for p in $ports_to_check; do
        if port_busy "$p"; then
            warn "Port $p is already used by another program."
            busy=1
        else
            note "Port $p ... free"
        fi
    done
    if [ "$busy" -eq 1 ]; then
        echo ""
        echo -e "${RED}Cannot start: the port(s) above are taken.${NC}"
        echo "  This is often an older Metabobank installation still running."
        echo ""
        do_this "use another web port, for example:"
        echo "           METABOBANK_PORT=18090 bash start.sh $*"
        do_this "or stop the old installation first:  bash start.sh stop   (in its own folder)"
        exit 1
    fi
    info "The ports it needs are available."
}

check_disk() {
    phase_step "checking free disk space"
    local src="${1:-${DOWNLOAD_SOURCES[0]}}"
    local missing=0 i f len need_kb free
    for i in "${!IMAGE_FILES[@]}"; do
        f="${IMAGE_FILES[$i]}"
        if [ ! -s "$APP_DIR/$f" ]; then
            len="$(head_len "$src/$f")"
            missing=$((missing + len))
        fi
    done
    if [ "$missing" -eq 0 ]; then
        note "The image files are already here, nothing to download."
        info "Disk check skipped."
        return 0
    fi
    # the download plus the images written to disk need roughly twice the size
    need_kb=$(( missing / 512 ))
    free="$(free_kb)"
    if [ -z "$free" ]; then
        warn "Cannot read free space; continuing, but watch the next step."
        return 0
    fi
    note "Download size ... about $(human_size "$missing")"
    note "Free space ... about $((free / 1048576)) GB"
    if [ "$free" -lt "$need_kb" ]; then
        echo ""
        echo -e "${RED}Not enough free disk space in $APP_DIR.${NC}"
        echo "  The download plus the loaded images need about $(human_size "$missing") twice."
        echo ""
        do_this "free up space (check with: df -h \"$APP_DIR\")"
        do_this "or move the .tar.gz files to a bigger disk and run:  bash start.sh --local"
        exit 1
    fi
    info "Enough disk space."
}

# --- 4. download -----------------------------------------------------------
fetch_file() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar --connect-timeout 20 --retry 3 --retry-delay 5 \
             -C - -o "$out" "$url"
    else
        wget -q --show-progress -c -O "$out" "$url"
    fi
}

probe_source() {
    local src
    for src in "${DOWNLOAD_SOURCES[@]}"; do
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL -r 0-1023 -o /dev/null --max-time 20 "$src/${IMAGE_FILES[0]}" 2>/dev/null; then
                echo "$src"; return 0
            fi
        else
            if wget -q --spider --timeout=20 "$src/${IMAGE_FILES[0]}" 2>/dev/null; then
                echo "$src"; return 0
            fi
        fi
    done
    return 1
}

backup_compose() {
    local bak
    bak="$COMPOSE_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$COMPOSE_FILE" "$bak"
    warn "A docker-compose.yml was already here; it was backed up as $(basename "$bak")"
}

download_compose() {
    local src="$1" tmp="$APP_DIR/.docker-compose.yml.new"
    fetch_file "$src/docker-compose.yml" "$tmp" || error "Could not download docker-compose.yml from $src
       Check your network, or use an offline bundle: bash start.sh --local"
    if [ -f "$COMPOSE_FILE" ]; then
        if cmp -s "$COMPOSE_FILE" "$tmp"; then
            rm -f "$tmp"
            note "docker-compose.yml ... already up to date"
        else
            backup_compose
            mv "$tmp" "$COMPOSE_FILE"
            note "docker-compose.yml ... updated"
        fi
    else
        mv "$tmp" "$COMPOSE_FILE"
        note "docker-compose.yml ... downloaded"
    fi
}

download_sums() {
    local src="$1" tmp="$APP_DIR/.SHA256SUMS.new"
    if fetch_file "$src/SHA256SUMS.txt" "$tmp" 2>/dev/null; then
        mv "$tmp" "$SUMS_FILE"
        note "SHA256SUMS.txt ... downloaded"
    else
        rm -f "$tmp"
        warn "No SHA256SUMS.txt at $src, so the files cannot be verified."
    fi
}

download_all() {
    local src="$1" i f sz len
    phase_step "downloading files"
    note "Source: $src"
    note "This can take a while: the database image alone is about 7.6 GB."
    echo ""

    download_compose "$src"

    for i in "${!IMAGE_FILES[@]}"; do
        f="${IMAGE_FILES[$i]}"
        if [ -s "$APP_DIR/$f" ]; then
            sz="$(du -h "$APP_DIR/$f" 2>/dev/null | awk '{print $1}')"
            note "$f ... already here (${sz:-?}), skipping"
            continue
        fi
        len="$(head_len "$src/$f")"
        if [ "$len" -gt 0 ]; then
            note "$f ... downloading ($(human_size "$len"))"
        else
            note "$f ... downloading"
        fi
        fetch_file "$src/$f" "$APP_DIR/$f" \
            || error "Download failed: $f
       Check your network and run the script again; the download resumes where it stopped.
       Or copy $f manually into $APP_DIR and run: bash start.sh --local"
    done
    download_sums "$src"
    info "All files are in place."
}

# --- 5. verify -------------------------------------------------------------
verify_sums() {
    phase_step "verifying the files"
    local i f exp act h
    if [ "$SKIP_SUMS" = "yes" ]; then
        warn "Verification skipped on request (--skip-checksum)."
        return 0
    fi
    if [ ! -s "$SUMS_FILE" ]; then
        if [ "$STRICT_SUMS" = "yes" ]; then
            error "SHA256SUMS.txt is missing, and MB_STRICT_SUMS=1 requires it.
       Download the file again, or drop MB_STRICT_SUMS to continue unverified."
        fi
        warn "No SHA256SUMS.txt here, so the files cannot be verified. Continuing."
        return 0
    fi
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        warn "This system has no sha256sum/shasum tool; verification skipped."
        return 0
    fi
    for i in "${!IMAGE_FILES[@]}"; do
        f="${IMAGE_FILES[$i]}"
        [ -s "$APP_DIR/$f" ] || continue
        exp="$(awk -v n="$f" '{g=$2; sub(/^\.\//,"",g); sub(/^\*/,"",g); if (g==n) {print $1; exit}}' "$SUMS_FILE")"
        if [ -z "$exp" ] && [ -s "$APP_DIR/$f.sha256" ]; then
            exp="$(awk '{print $1; exit}' "$APP_DIR/$f.sha256")"
            h="  (from $f.sha256)"
        else
            h=""
        fi
        if [ -z "$exp" ]; then
            warn "No checksum listed for $f, skipping it."
            if [ "$STRICT_SUMS" = "yes" ]; then
                error "No checksum listed for $f, and strict verification is on."
            fi
            continue
        fi
        act="$(sha256_file "$APP_DIR/$f")" || warn "Could not read $f to compute its checksum."
        if [ "$act" != "$exp" ]; then
            echo ""
            echo -e "${RED}The file $f is damaged or incomplete.${NC}"
            echo "  Expected: $exp"
            echo "  Actual:   $act"
            echo ""
            do_this "delete it and let the script download it again:"
            echo "           rm -f \"$APP_DIR/$f\" && bash start.sh"
            do_this "if you copied the file from somewhere by hand, check the source"
            exit 1
        fi
        note "$f ... verified$h"
    done
    info "Every file matches its checksum."
}

# --- 6. images and data ----------------------------------------------------
load_images() {
    phase_step "loading images into Docker"
    note "Loading the 7.6 GB database image takes a few minutes. Please wait."
    echo ""
    local i f ref
    for i in "${!IMAGE_FILES[@]}"; do
        f="${IMAGE_FILES[$i]}"
        ref="${IMAGE_REFS[$i]}"
        if docker image inspect "$ref" >/dev/null 2>&1; then
            note "$ref ... already loaded, skipping"
            continue
        fi
        [ -s "$APP_DIR/$f" ] || { warn "$f is not here, skipping $ref"; continue; }
        note "$f ... loading"
        docker load -i "$APP_DIR/$f" || error "Docker could not load $f.
       This is usually a disk space problem. Check with:  df -h \"$APP_DIR\"
       Do not unpack the .tar.gz by hand; just free some space and run the script again."
        if ! docker image inspect "$ref" >/dev/null 2>&1; then
            warn "$f loaded, but the image $ref was not found inside it."
        fi
    done
    info "Images are loaded."
}

env_existing() {
    local k="$1"
    if [ ! -f "$ENV_FILE" ]; then return 1; fi
    awk -F= -v key="$k" '$1==key {sub(/^[^=]*=/,""); print; exit}' "$ENV_FILE" | grep . || return 1
}

# Write .env: only the keys this script manages are rewritten. Everything else
# in an existing .env is preserved, so hand-filled database credentials survive.
write_env_file() {
    local data_for_compose="$1"
    local bu bp ba su sp extra bak
    bu="$(env_existing METABOBANK_DB_USER || true)"
    [ -z "$bu" ] && bu="${METABOBANK_DB_USER:-docker_user}"
    bp="$(env_existing METABOBANK_DB_PASS || true)"
    [ -z "$bp" ] && bp="${METABOBANK_DB_PASS:-docker@2026}"
    ba="$(env_existing METABOBANK_DB_AUTH || true)"
    [ -z "$ba" ] && ba="${METABOBANK_DB_AUTH:-admin}"
    su="$(env_existing METABOBANK_SYNC_USER || true)"
    [ -z "$su" ] && su="${METABOBANK_SYNC_USER:-webuser}"
    sp="$(env_existing METABOBANK_SYNC_PASS || true)"
    [ -z "$sp" ] && sp="${METABOBANK_SYNC_PASS:-passw0rd}"
    extra=""
    if [ -f "$ENV_FILE" ]; then
        bak="$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S)"
        cp "$ENV_FILE" "$bak"
        extra="$(grep -vE '^(METABOBANK_DATA|METABOBANK_PORT|METABOBANK_DB_PORT|METABOBANK_RSERVE_PORT|METABOBANK_DB_HOST|METABOBANK_DB_USER|METABOBANK_DB_PASS|METABOBANK_DB_AUTH|METABOBANK_SYNC_USER|METABOBANK_SYNC_PASS)=' "$ENV_FILE" || true)"
    fi
    {
        echo "METABOBANK_DATA=$data_for_compose"
        echo "METABOBANK_PORT=$META_PORT"
        echo "METABOBANK_DB_PORT=$MONGO_PORT"
        echo "METABOBANK_RSERVE_PORT=$RSERVE_PORT"
        echo "METABOBANK_DB_HOST=${METABOBANK_DB_HOST:-mongodb5_client}"
        echo "METABOBANK_DB_USER=$bu"
        echo "METABOBANK_DB_PASS=$bp"
        echo "METABOBANK_DB_AUTH=$ba"
        echo "METABOBANK_SYNC_USER=$su"
        echo "METABOBANK_SYNC_PASS=$sp"
    } > "$ENV_FILE"
    if [ -n "$extra" ]; then printf '%s\n' "$extra" >> "$ENV_FILE"; fi
    if [ -n "$bak" ]; then note "The previous .env was backed up as $(basename "$bak")"; fi
}

prepare_data_dir() {
    echo ""
    echo -e "${BOLD}>> Preparing the data directory${NC}"
    note "${DATA_DIR}"
    case "$DATA_DIR" in
        */metabobank_data/metabobank_data*)
            warn "The package was unpacked inside a metabobank_data folder, so the data is nested:"
            warn "  ${DATA_DIR}"
            warn "If you meant to reuse an existing data folder, point the installer at it:"
            warn "  METABOBANK_DATA_DIR=${DATA_DIR%/metabobank_data} bash start.sh"
            ;;
    esac
    local d data_for_compose
    for d in "${DATA_SUBDIRS[@]}"; do
        mkdir -p "$DATA_DIR/$d"
    done
    # Git Bash reports /c/Users/... which Docker Desktop cannot mount; the same
    # folder has to be written as C:/Users/... inside .env
    data_for_compose="$DATA_DIR"
    if [ "$HOST_KIND" = "windows" ]; then
        data_for_compose="$(printf '%s' "$DATA_DIR" | sed -E 's#^/([a-zA-Z])/#\U\1:/#')"
    fi
    write_env_file "$data_for_compose"
    note "Settings written to .env"
    note "Database credentials live in .env: METABOBANK_DB_USER / METABOBANK_DB_PASS / METABOBANK_DB_AUTH"
    note "The database starts empty on first run and fills itself from the image."
    info "Data directory is ready. Uploaded files and results will live here."
}

write_default_compose() {
    warn "No docker-compose.yml in this folder; writing the standard one."
    cat > "$COMPOSE_FILE" <<'COMPOSEEOF'
# Metabobank Client - built-in default deployment file (generated by start.sh --local)
services:
  metabospark:
    image: metabank/metabospark:v3.0
    restart: unless-stopped
    ports:
      - "${METABOBANK_PORT:-8090}:8090"
    environment:
      TZ: Asia/Shanghai
      METABOBANK_DB_HOST: "${METABOBANK_DB_HOST:-mongodb5_client}"
      METABOBANK_DB_PORT: "27023"
      METABOBANK_DB_USER: "${METABOBANK_DB_USER:-docker_user}"
      METABOBANK_DB_PASS: "${METABOBANK_DB_PASS:-docker@2026}"
      METABOBANK_DB_AUTH: "${METABOBANK_DB_AUTH:-admin}"
      METABOBANK_SYNC_USER: "${METABOBANK_SYNC_USER:-webuser}"
      METABOBANK_SYNC_PASS: "${METABOBANK_SYNC_PASS:-passw0rd}"
      MB_RSERVE_HOST: rserve
      MB_RSERVE_PORT: "6322"
      MB_RSERVE_CONNECT_TIMEOUT: "10"
      MB_RSERVE_EVAL_TIMEOUT: "1800"
    volumes:
      - "${METABOBANK_DATA:-./metabobank_data}:/metabobank_data"
    depends_on:
      - mongodb5_client
      - rserve
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8090/login || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 40s
    networks:
      - metabobank
  mongodb5_client:
    image: metabank/mongodb5_client:v3.0
    restart: unless-stopped
    user: "0:0"
    # database port not published to the host; only the web container reaches it
    # ports:
    #   - "127.0.0.1:${METABOBANK_DB_PORT:-27023}:27023"
    volumes:
      - "${METABOBANK_DATA:-./metabobank_data}/dbs:/opt/mongodb5_client/dbs"
    healthcheck:
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/127.0.0.1/27023 && echo ok || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s
    networks:
      - metabobank
  rserve:
    image: metabank/metabospark-omics:v3.0
    restart: unless-stopped
    expose:
      - "6322"
      - "6311"
    volumes:
      - "${METABOBANK_DATA:-./metabobank_data}:/metabobank_data"
    networks:
      - metabobank
networks:
  metabobank:
    driver: bridge
COMPOSEEOF
    note "docker-compose.yml written."
}

# --- start / stop ----------------------------------------------------------
wait_healthy() {
    echo ""
    note "Waiting for the web application to finish starting (usually 30-60 seconds) ..."
    local i cid state hp dots
    for i in $(seq 1 18); do
        cid="$(compose ps -q "$WEB_SVC" 2>/dev/null | head -n1 || true)"
        if [ -n "$cid" ]; then
            state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)"
            case "$state" in
                healthy)
                    info "The web application reports itself healthy."
                    return 0 ;;
                none)
                    hp="$(detect_host_port || true)"
                    if [ -n "$hp" ] && curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$hp/login" 2>/dev/null; then
                        info "The web application answers on port $hp."
                        return 0
                    fi ;;
                unhealthy)
                    warn "It reported unhealthy once; still waiting ..." ;;
            esac
        fi
        printf '.'
        sleep 5
    done
    echo ""
    echo ""
    echo -e "${YELLOW}The web application did not come up within 90 seconds.${NC}"
    echo "  This is often a slow first start while the database imports its data."
    echo ""
    do_this "check the state:      bash start.sh status"
    do_this "read the log:         bash start.sh logs"
    do_this "wait two minutes, then open the URL below anyway; it may still start"
    return 1
}

images_all_present() {
    local i
    for i in "${!IMAGE_REFS[@]}"; do
        docker image inspect "${IMAGE_REFS[$i]}" >/dev/null 2>&1 || return 1
    done
    return 0
}

local_tarballs_present() {
    local i f
    for i in "${!IMAGE_FILES[@]}"; do
        f="${IMAGE_FILES[$i]}"
        if [ ! -s "$APP_DIR/$f" ]; then return 1; fi
    done
    return 0
}

# Is the database port published on the host? If you comment out the ports
# entry of mongodb5_client, the host's 27023 is irrelevant to this install.
mongo_port_published() {
    local f="$COMPOSE_FILE"
    [ -f "$f" ] || return 0
    sed 's/#.*//' "$f" | grep -qE ':27023"' && return 0
    sed 's/#.*//' "$f" | grep -qE ':27023$|- "27023:27023"' && return 0
    return 1
}

print_summary() {
    local ip hp
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [ -z "$ip" ]; then ip="127.0.0.1"; fi
    hp="$(detect_host_port || true)"
    if [ -z "$hp" ]; then hp="$META_PORT"; fi
    if [ "$HOST_KIND" = "windows" ]; then ip="localhost"; fi
    echo ""
    echo -e "${GREEN}${BOLD}==================================================================${NC}"
    echo -e "${GREEN}${BOLD}  Metabobank is running${NC}"
    echo -e "${GREEN}${BOLD}==================================================================${NC}"
    echo -e "  Open it in a browser:   ${BOLD}http://$ip:$hp${NC}"
    if [ "$HOST_KIND" = "windows" ]; then
        echo -e "  (in Windows, localhost is what Docker Desktop publishes the port on)"
    else
        echo -e "  On this machine:        http://127.0.0.1:$hp"
    fi
    echo -e "  Data is stored in:      $DATA_DIR"
    if mongo_port_published; then
        echo -e "  Database port:          $MONGO_PORT (only needed for external tools)"
    else
        echo -e "  Database port:          internal 27023 only, not published to the host"
    fi
    echo ""
    echo -e "  Everyday commands:"
    echo -e "    bash start.sh status     see what is running"
    echo -e "    bash start.sh logs       watch the web application log"
    echo -e "    bash start.sh stop       stop it (your data stays)"
    echo -e "    bash start.sh restart    stop and start again"
    echo -e "    bash start.sh recreate <svc>   replace one service, others keep running"
    echo -e "${GREEN}${BOLD}==================================================================${NC}"
    echo ""
}

running_container_on_port() {
    local n
    for n in $(docker ps --format '{{.Names}}' 2>/dev/null); do
        if docker port "$n" 2>/dev/null | grep -qE "[:.]$1\$"; then
            echo "$n"
            return 0
        fi
    done
    return 1
}

container_project() {
    docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$1" 2>/dev/null || true
}

container_image() {
    docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null || true
}

# Containers made from Metabobank images that belong to some OTHER folder's
# installation. Typical case: an older v3 deployment with fixed container names
# (metabospark, mongodb5_client, metabospark_rserve) still running and holding
# the ports. "compose down" here never touches them, so they have to be named.
foreign_metabobank_containers() {
    local n img proj
    for n in $(docker ps --format '{{.Names}}' 2>/dev/null); do
        img="$(container_image "$n")"
        case "$img" in
            *metabank/metabospark*|*metabank/mongodb5_client*|*metabank/metabospark-omics*|*metabobank*) ;;
            *) continue ;;
        esac
        proj="$(container_project "$n")"
        if [ "$proj" != "$PROJECT_NAME" ]; then
            echo "$n"
        fi
    done
}

report_foreign_metabobank() {
    local list c
    list="$(foreign_metabobank_containers || true)"
    if [ -z "$list" ]; then return 0; fi
    echo ""
    warn "These Metabobank containers are still running, and they were NOT started by this folder:"
    for c in $list; do
        note "  $c   image: $(container_image "$c")   ports: $(docker port "$c" 2>/dev/null | tr '\n' ' ')"
    done
    note "They are probably an older installation deployed from another folder."
    do_this "stop them (their data is not touched):  docker stop $(echo "$list" | tr '\n' ' ')"
    do_this "or start this installation on other ports instead"
}

# Before "compose up": a port held by another Docker container gives
# "Bind for 0.0.0.0:27023 failed: port is already allocated" from the daemon,
# which says nothing about who owns it. This names the owner first.
prestart_port_check() {
    local p owner proj ports_to_check="$META_PORT"
    if mongo_port_published; then ports_to_check="$META_PORT $MONGO_PORT"; fi
    for p in $ports_to_check; do
        if ! port_busy "$p"; then continue; fi
        owner="$(running_container_on_port "$p" || true)"
        if [ -n "$owner" ]; then
            proj="$(container_project "$owner")"
            if [ "$proj" = "$PROJECT_NAME" ]; then
                note "Port $p is already published by $owner, which belongs to this installation - fine."
                continue
            fi
            echo ""
            echo -e "${RED}Cannot start: port $p is taken by the Docker container \"$owner\".${NC}"
            if [ -n "$proj" ]; then
                echo "  That container belongs to another Docker Compose project: $proj"
            else
                echo "  That container was not started by Docker Compose (it has a fixed name)."
            fi
            case "$(container_image "$owner")" in
                *metabank/*) echo "  Its image is $(container_image "$owner"), so this is another Metabobank instance." ;;
            esac
            echo ""
            echo "  See it with:   docker ps --format '{{.Names}}\t{{.Ports}}' | grep :$p"
            echo ""
            do_this "stop the other container:  docker stop $owner"
            do_this "or run this installation on another web port:"
            echo "           METABOBANK_PORT=18090 bash start.sh"
            exit 1
        fi
        echo ""
        echo -e "${RED}Cannot start: port $p is used by a program on this machine.${NC}"
        echo "  No Docker container publishes it, so it is an ordinary process."
        echo ""
        echo "  See it with:   ss -lntp | grep :$p"
        echo ""
        do_this "stop that program, or run this installation on another web port:"
        echo "           METABOBANK_PORT=18090 bash start.sh"
        exit 1
    done
}

do_start() {
    WEB_SVC="$(detect_web_service)"
    echo ""
    echo -e "${BOLD}>> Starting the services${NC}"
    note "web application: $WEB_SVC, database, R backend"
    prestart_port_check
    if ! compose up -d; then
        echo ""
        echo -e "${RED}Docker refused to start one of the containers.${NC}"
        echo "  If the message above mentions \"port is already allocated\", the port is held"
        echo "  by another container or program. Find it with:"
        echo "    ss -lntp | grep -E ':($META_PORT)'"
        echo "    docker ps --format '{{.Names}}\t{{.Ports}}'"
        echo ""
        do_this "stop the other container, or use another web port:"
        echo "           METABOBANK_PORT=18090 bash start.sh"
        echo ""
        echo "  Left-over containers from this attempt can be removed with: bash start.sh stop"
        exit 1
    fi
    wait_healthy || true
    echo ""
    echo -e "${BOLD}>> Current state${NC}"
    compose ps
    print_summary
}

do_status() {
    WEB_SVC="$(detect_web_service)"
    echo ""
    echo -e "${BOLD}>> What is running now${NC}"
    compose ps
    echo ""
    local hp
    hp="$(detect_host_port || true)"
    if [ -n "$hp" ]; then
        note "The web application is published on port $hp."
    else
        note "The web application is not publishing a port right now."
    fi
    note "If a service shows Exited or Restarting, read the log: bash start.sh logs"
}

do_logs() {
    WEB_SVC="$(detect_web_service)"
    echo ""
    echo -e "${BOLD}>> Web application log (press Ctrl+C to stop watching)${NC}"
    compose logs -f --tail 100 "$WEB_SVC"
}

do_stop() {
    echo ""
    echo -e "${BOLD}>> Stopping Metabobank${NC}"
    [ -f "$COMPOSE_FILE" ] || error "Nothing to stop: docker-compose.yml is not in this folder.
       Run 'bash start.sh' once, or run this from the folder where Metabobank was installed."
    local remaining
    compose down
    remaining="$(compose ps -q 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    if [ "${remaining:-0}" -eq 0 ]; then
        info "All three services of this folder are stopped and removed."
        note "Your data was not touched and is still in $DATA_DIR"
        note "Start again with: bash start.sh --only-start"
        report_foreign_metabobank
    else
        warn "$remaining container(s) are still there. Check with: bash start.sh status"
    fi
}

# --- modes -----------------------------------------------------------------
do_local() {
    local i have=0 f
    phase "Offline mode: installing from the files in this folder"
    note "Folder: $APP_DIR"
    check_ports "--local"

    for i in "${!IMAGE_REFS[@]}"; do
        if docker image inspect "${IMAGE_REFS[$i]}" >/dev/null 2>&1; then have=1; fi
    done

    if [ "$have" -eq 1 ]; then
        echo ""
        echo -e "${BOLD}>> The images are already in Docker${NC}"
        note "Skipping the load step."
        verify_sums || true
    else
        echo ""
        echo -e "${BOLD}>> Looking for the three image files${NC}"
        local missing=0
        for i in "${!IMAGE_FILES[@]}"; do
            f="${IMAGE_FILES[$i]}"
            if [ -s "$APP_DIR/$f" ]; then
                note "$f ... found ($(du -h "$APP_DIR/$f" | awk '{print $1}'))"
            elif docker image inspect "${IMAGE_REFS[$i]}" >/dev/null 2>&1; then
                note "$f ... not needed, image already loaded"
            else
                note "$f ... MISSING"
                missing=1
            fi
        done
        if [ "$missing" -eq 1 ]; then
            echo ""
            echo -e "${RED}The offline bundle is incomplete.${NC}"
            echo "  Offline installation needs these three files in $APP_DIR:"
            echo "    metabospark.tar.gz   mongodb5_client.tar.gz   omics.tar.gz"
            echo ""
            do_this "copy the missing files here and run: bash start.sh --local"
            do_this "or install online instead:  bash start.sh"
            exit 1
        fi
        if [ ! -f "$COMPOSE_FILE" ]; then write_default_compose; fi
        verify_sums
        load_images
    fi
    prepare_data_dir
    do_start
}

do_install() {
    local mine has_mine=0 src
    mine="$(project_containers)"
    if [ -n "$mine" ]; then has_mine=1; fi
    if [ "$has_mine" -eq 1 ]; then
        phase "An installation already exists, starting it again"
        note "Nothing will be downloaded and no image will be loaded."
        note "Running containers are reused as they are, so changed ports or settings are NOT applied here."
        note "To apply them: bash start.sh stop  then  bash start.sh"
        echo "$mine" | while read -r c; do
            if [ -n "$c" ]; then note "container: $c"; fi
        done
        prepare_data_dir
        do_start
        return 0
    fi

    if [ "$FORCE" = "yes" ] && [ -f "$COMPOSE_FILE" ]; then
        do_stop
    fi

    if images_all_present; then
        phase "Everything needed is already on this machine"
        note "Skipping the download and load steps."
        if [ ! -f "$COMPOSE_FILE" ]; then write_default_compose; fi
        verify_sums || true
        prepare_data_dir
        do_start
        return 0
    fi

    # The three tarballs are here but the images are not loaded yet: load them
    # from disk and never touch the network. This is why --local is optional.
    if local_tarballs_present; then
        phase "All three image files are already in this folder"
        note "Nothing will be downloaded; the images are loaded from disk."
        if [ ! -f "$COMPOSE_FILE" ]; then write_default_compose; fi
        verify_sums || true
        load_images
        prepare_data_dir
        do_start
        return 0
    fi

    check_ports ""
    src="$(probe_source)" || error "Cannot reach the download site.
       Tried:  ${DOWNLOAD_SOURCES[0]}
              ${DOWNLOAD_SOURCES[1]}
       What to do:
         - if the three .tar.gz files are already in this folder, nothing else is needed:
             bash start.sh
         - if some files are still missing and this machine has no internet, copy the
           missing .tar.gz files here and run: bash start.sh --local
         - otherwise check that the machine can open https://www.metabobank.cn/ in a browser"

    check_disk "$src"
    download_all "$src"
    verify_sums
    load_images
    prepare_data_dir
    do_start
}

# --- recreate one service -------------------------------------------------
# Why these flags:
#   --force-recreate  without it Compose decides "nothing changed" and does
#                     nothing, even when you edited .env or the compose file
#   --no-deps         without it Compose also recreates the services this one
#                     depends on, so "recreate metabospark" would restart the
#                     database and the R backend too - needless downtime
#   (no --build)      the images are prebuilt tarballs; there is no Dockerfile
#   (no --pull)       the images are local; pulling would only add a failure
do_recreate() {
    [ -f "$COMPOSE_FILE" ] || error "Metabobank is not installed in this folder yet.
       Run 'bash start.sh' first."
    local svcs names s flags
    svcs="$(compose_services)"
    WEB_SVC="$(detect_web_service)"
    if [ -z "$svcs" ]; then
        error "Cannot read the service list from docker-compose.yml.
       Check the file with: docker compose -f $COMPOSE_FILE config --services"
    fi

    if [ -z "$REBUILD_SVCS" ]; then
        echo ""
        echo "Which service should be recreated? Add one of these names:"
        for s in $svcs; do
            case "$s" in
                *spark*) if [ "$s" = "$(detect_web_service)" ]; then echo "    $s        (the web application)"; else echo "    $s"; fi ;;
                *mongo*) echo "    $s      (the database)" ;;
                rserve*|*omics*) echo "    $s              (the R backend)" ;;
                *) echo "    $s" ;;
            esac
        done
        echo ""
        echo "  bash start.sh recreate metabospark        recreate the web application"
        echo "  bash start.sh recreate rserve             recreate the R backend"
        echo "  bash start.sh recreate metabospark rserve recreate several at once"
        echo "  add --with-deps to also recreate its dependencies"
        echo ""
        echo "To replace all three, run:  bash start.sh stop  then  bash start.sh"
        echo ""
        exit 1
    fi

    names="$(echo $REBUILD_SVCS)"

    for s in $names; do
        if ! echo "$svcs" | grep -qx "$s"; then
            echo ""
            echo -e "${RED}No service named \"$s\" in docker-compose.yml.${NC}"
            echo "  Available services:"
            for n in $svcs; do echo "    $n"; done
            echo ""
            exit 1
        fi
    done

    flags="--force-recreate"
    if [ "$WITH_DEPS" != "yes" ]; then
        flags="$flags --no-deps"
    fi

    echo ""
    echo -e "${BOLD}>> Recreating: $names${NC}"
    if [ "$WITH_DEPS" = "yes" ]; then
        note "dependencies are recreated as well"
    else
        note "dependencies (database, R backend) are left running"
    fi
    if ! compose up -d $flags $names; then
        echo ""
        echo -e "${RED}Recreating $names failed.${NC}"
        echo "  Read the log of the affected service:  bash start.sh logs"
        echo "  Full state:                            bash start.sh status"
        exit 1
    fi

    case " $names " in
        *" $WEB_SVC "*)
            wait_healthy || true ;;
    esac
    echo ""
    echo -e "${BOLD}>> Current state${NC}"
    compose ps
}

# --- main ------------------------------------------------------------------
main() {
    local mode="install"
    FORCE="no"; SKIP_SUMS="no"
    STRICT_SUMS="${MB_STRICT_SUMS:-no}"
    REBUILD_SVCS=""; WITH_DEPS="no"

    while [ $# -gt 0 ]; do
        case "$1" in
            --local)            mode="local"; shift ;;
            --force)            FORCE="yes"; shift ;;
            --skip-checksum)    SKIP_SUMS="yes"; shift ;;
            --only-start|start) mode="start"; shift ;;
            --stop|stop)        mode="stop"; shift ;;
            --restart|restart)  mode="restart"; shift ;;
            --status|status)    mode="status"; shift ;;
            --logs|logs)        mode="logs"; shift ;;
            --recreate|recreate)
                                mode="recreate"; shift
                                while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do
                                    REBUILD_SVCS="$REBUILD_SVCS $1"; shift
                                done ;;
            --all)              echo ""
                                echo "--all is not a command here. To replace all three services:"
                                echo "  bash start.sh stop"
                                echo "  bash start.sh"
                                echo "To replace one service without stopping the others:"
                                echo "  bash start.sh recreate <service>"
                                echo ""
                                exit 1 ;;
            --with-deps)        WITH_DEPS="yes"; shift ;;
            -h|--help)          sed -n '3,/^set -eo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,2\}//'; exit 0 ;;
            *) echo ""
               echo "Unknown option: $1"
               echo "Run: bash start.sh --help   to see the available commands."
               echo ""
               exit 1 ;;
        esac
    done

    if [ "$mode" = "install" ] || [ "$mode" = "local" ] || [ "$mode" = "restart" ]; then
        banner
    fi

    check_prereqs
    acquire_lock
    case "$mode" in
        local)   do_local ;;
        stop)    do_stop ;;
        restart) do_stop; prepare_data_dir; do_start ;;
        recreate) do_recreate ;;
        start)
            [ -f "$COMPOSE_FILE" ] || error "There is no docker-compose.yml in this folder yet.
       Run 'bash start.sh' once (online) or 'bash start.sh --local' (offline)."
            prepare_data_dir; do_start ;;
        status)
            [ -f "$COMPOSE_FILE" ] || error "Metabobank is not installed in this folder yet.
       Run 'bash start.sh' first."
            do_status ;;
        logs)
            [ -f "$COMPOSE_FILE" ] || error "Metabobank is not installed in this folder yet.
       Run 'bash start.sh' first."
            do_logs ;;
        install) do_install ;;
    esac
}

main "$@"
