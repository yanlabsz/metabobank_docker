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
#    bash start.sh                normal install (needs internet)
#    bash start.sh --local        offline: use the .tar.gz files in this folder
#
#  COMMON COMMANDS
#    bash start.sh status         what is running right now
#    bash start.sh logs           follow the web application log
#    bash start.sh stop           stop everything (your data is kept)
#    bash start.sh restart        stop, then start again
#    bash start.sh --force        rebuild containers from scratch
#    bash start.sh --only-start   just start (images are already loaded)
#    bash start.sh --help         show this text
#
#  OPTIONS
#    --local            never touch the network; deploy from local .tar.gz files
#    --force            remove containers first, then start them again
#    --only-start       skip the download/load phase entirely
#    --skip-checksum    do not verify SHA256SUMS.txt (not recommended)
#    --status / status  print the current state
#    --stop / stop      shut the services down
#    --restart          restart the services
#    --logs / logs      follow the log of the web application
#
#  CUSTOM PORTS AND PATHS
#    METABOBANK_PORT=18090 bash start.sh          web on port 18090
#    METABOBANK_MONGO_PORT=37023 bash start.sh    database on port 37023
#    METABOBANK_DATA_DIR=/data/metabobank bash start.sh
#
#  IF SOMETHING GOES WRONG
#    1. run: bash start.sh status      (which service is not running?)
#    2. run: bash start.sh logs        (what does the web app say?)
#    3. if the port is taken: METABOBANK_PORT=18090 bash start.sh
#    4. with an incomplete offline bundle: check the four files listed below
#
#  AN OFFLINE BUNDLE IS THIS FOLDER CONTAINING
#    metabospark.tar.gz  mongodb5_client.tar.gz  omics.tar.gz
#    docker-compose.yml  SHA256SUMS.txt          start.sh
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

    if ! docker info >/dev/null 2>&1; then
        echo ""
        echo -e "${RED}Docker is installed but not running.${NC}"
        do_this "start it with:  sudo systemctl start docker"
        do_this "if you are not root, add yourself to the docker group:  sudo usermod -aG docker \$USER  (then log out and back in)"
        exit 1
    fi
    note "Docker daemon ... running"

    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
        note "Docker Compose ... $(docker compose version 2>/dev/null | awk '{print $NF}')"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
        note "Docker Compose ... legacy docker-compose found"
    else
        echo ""
        echo -e "${RED}Docker Compose is missing.${NC}"
        do_this "CentOS:  sudo yum install -y docker-compose-plugin"
        do_this "Ubuntu:  sudo apt-get install -y docker-compose-v2"
        exit 1
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
    local p busy=0
    for p in "$META_PORT" "$MONGO_PORT"; do
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
        do_this "use different ports, for example:"
        echo "           METABOBANK_PORT=18090 METABOBANK_MONGO_PORT=37023 bash start.sh $*"
        do_this "or stop the old installation first:  bash start.sh stop   (in its own folder)"
        exit 1
    fi
    info "Both ports are available."
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

prepare_data_dir() {
    echo ""
    echo -e "${BOLD}>> Preparing the data directory${NC}"
    note "${DATA_DIR}"
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
    cat > "$ENV_FILE" <<ENVEOF
METABOBANK_DATA=$data_for_compose
METABOBANK_PORT=$META_PORT
METABOBANK_DB_PORT=$MONGO_PORT
METABOBANK_RSERVE_PORT=$RSERVE_PORT
ENVEOF
    note "Settings written to .env"
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
      METABOBANK_DB_HOST: mongodb5_client
      METABOBANK_DB_PORT: "27023"
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
    ports:
      - "${METABOBANK_DB_PORT:-27023}:27023"
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
    echo -e "  Database port:          $MONGO_PORT (only needed for external tools)"
    echo ""
    echo -e "  Everyday commands:"
    echo -e "    bash start.sh status     see what is running"
    echo -e "    bash start.sh logs       watch the web application log"
    echo -e "    bash start.sh stop       stop it (your data stays)"
    echo -e "    bash start.sh restart    stop and start again"
    echo -e "    bash start.sh --local    start again without internet"
    echo -e "${GREEN}${BOLD}==================================================================${NC}"
    echo ""
}

do_start() {
    WEB_SVC="$(detect_web_service)"
    echo ""
    echo -e "${BOLD}>> Starting the services${NC}"
    note "web application: $WEB_SVC, database, R backend"
    compose up -d
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
        info "All three services are stopped and removed."
        note "Your data was not touched and is still in $DATA_DIR"
        note "Start again with: bash start.sh --only-start"
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

    if images_all_present && [ -f "$COMPOSE_FILE" ]; then
        phase "Everything needed is already on this machine"
        note "Skipping the download and load steps."
        verify_sums || true
        prepare_data_dir
        do_start
        return 0
    fi

    check_ports ""
    src="$(probe_source)" || error "Cannot reach the download site.
       Tried:  ${DOWNLOAD_SOURCES[0]}
              ${DOWNLOAD_SOURCES[1]}
       What to do:
         - check this machine can open https://www.metabobank.cn/ in a browser
         - if the machine has no internet, use an offline bundle:
             copy the three .tar.gz files into $APP_DIR, then run: bash start.sh --local"

    check_disk "$src"
    download_all "$src"
    verify_sums
    load_images
    prepare_data_dir
    do_start
}

# --- main ------------------------------------------------------------------
main() {
    local mode="install"
    FORCE="no"; SKIP_SUMS="no"
    STRICT_SUMS="${MB_STRICT_SUMS:-no}"

    for arg in "$@"; do
        case "$arg" in
            --local)            mode="local" ;;
            --force)            FORCE="yes" ;;
            --skip-checksum)    SKIP_SUMS="yes" ;;
            --only-start|start) mode="start" ;;
            --stop|stop)        mode="stop" ;;
            --restart|restart)  mode="restart" ;;
            --status|status)    mode="status" ;;
            --logs|logs)        mode="logs" ;;
            -h|--help)          sed -n '3,/^set -eo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,2\}//'; exit 0 ;;
            *) echo ""
               echo "Unknown option: $arg"
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
