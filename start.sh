#!/bin/bash
# ============================================================================
# Metabobank Client - one-click deployment (v4.0)
# ============================================================================
# Usage:
#   bash start.sh                install & start (reuse if already installed)
#   bash start.sh --force        recreate containers (down then up)
#   bash start.sh --only-start   start only (images already loaded)
#   bash start.sh --stop         stop and remove this project's containers
#   bash start.sh --restart      restart this project
#
# Images:
#   metabospark.tar.gz        - Web 主程序
#   mongodb5_client.tar.gz    - MongoDB 5.0 一体化镜像（含二进制+配置+预置质谱数据）
#   omics.tar.gz              - 组学分析 Rserve
#
# Data persistence:
#   用户数据存在 ${METABOBANK_DATA:-./metabobank_data}/dbs
#   - 首次启动：dbs 为空时，容器 entrypoint 自动从镜像内置快照复制初始数据
#   - 后续启动：dbs 非空则直接使用用户数据，绝不覆盖
#   - 删镜像 / 删容器 / 升级版本：都不影响 dbs 目录里的数据
#   - 只有手动删除 dbs 目录才会清空数据库
#
# Safety:
#   * flock single-instance lock (no concurrent / duplicated execution)
#   * compose project name derived from directory (or METABOBANK_PROJECT)
#   * no container_name in docker-compose.yml => never collides with an
#     existing Metabobank installation on the same host
#   * port conflict check with clear hint to override via env vars
# ============================================================================
set -e

LOCK_FILE="/tmp/metabobank_start.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[ERROR] another start.sh instance is running, aborting"
    exit 1
fi

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

DOWNLOAD_SOURCES=(
    "https://raw.githubusercontent.com/yanlabsz/metabobank_docker/main"
    "https://www.metabobank.cn/docker_download"
)
IMAGE_FILES=("metabospark.tar.gz" "mongodb5_client.tar.gz" "omics.tar.gz")
COMPOSE_REMOTE="docker-compose.yml"

DATA_DIR="${METABOBANK_DATA_DIR:-$APP_DIR/metabobank_data}"
META_PORT="${METABOBANK_PORT:-8090}"
MONGO_PORT="${METABOBANK_MONGO_PORT:-27023}"
RSERVE_PORT="${METABOBANK_RSERVE_PORT:-6322}"
PROJECT_NAME="${METABOBANK_PROJECT:-$(basename "$APP_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- helpers ---------------------------------------------------------------
port_busy() {
    ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$1$"
}

project_containers() {
    docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" \
        --format '{{.Names}}' 2>/dev/null || true
}

# --- preflight -------------------------------------------------------------
check_prereqs() {
    info "checking environment..."
    command -v docker >/dev/null 2>&1 || error "docker not found, please install Docker 20+"
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || error "curl or wget required"

    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        error "docker compose (v2) or docker-compose not found"
    fi
    info "OK: $COMPOSE_CMD"
}

check_ports() {
    local p busy=0
    for p in "$META_PORT" "$MONGO_PORT"; do
        if port_busy "$p"; then
            warn "port $p is already in use"
            busy=1
        fi
    done
    if [ "$busy" -eq 1 ]; then
        warn "another service (maybe an existing Metabobank) is using these ports."
        warn "choose different ports, for example:"
        warn "  METABOBANK_PORT=18090 METABOBANK_MONGO_PORT=37023 bash start.sh"
        error "port conflict, aborted"
    fi
}

# --- download --------------------------------------------------------------
fetch() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -C - -o "$out" "$url" 2>/dev/null
    else
        wget -q -c -O "$out" "$url" 2>/dev/null
    fi
}

probe_source() {
    local src
    for src in "${DOWNLOAD_SOURCES[@]}"; do
        if fetch "$src/${IMAGE_FILES[0]}" "$APP_DIR/.probe_tmp" 2>/dev/null; then
            rm -f "$APP_DIR/.probe_tmp"
            echo "$src"
            return 0
        fi
    done
    return 1
}

download_all() {
    local src="$1"
    info "download source: $src"

    info "downloading $COMPOSE_REMOTE ..."
    fetch "$src/$COMPOSE_REMOTE" "$COMPOSE_FILE" || error "failed to download $COMPOSE_REMOTE"

    local f
    for f in "${IMAGE_FILES[@]}"; do
        if [ -s "$APP_DIR/$f" ]; then
            info "$f already exists, skip"
            continue
        fi
        info "downloading $f (large file, please wait)..."
        fetch "$src/$f" "$APP_DIR/$f" || error "failed to download $f"
    done
    info "download finished"
}

load_images() {
    local f tmp
    for f in "${IMAGE_FILES[@]}"; do
        [ ! -s "$APP_DIR/$f" ] && continue
        info "loading image: $f"
        if ! docker load -i "$APP_DIR/$f" 2>/dev/null; then
            tmp="${f%.gz}"
            gunzip -c "$APP_DIR/$f" > "$APP_DIR/$tmp"
            docker load -i "$APP_DIR/$tmp"
            rm -f "$APP_DIR/$tmp"
        fi
    done
    info "images loaded"
    docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E 'metabank' || true
}

# --- data dir --------------------------------------------------------------
prepare_data_dir() {
    info "preparing data directory: $DATA_DIR"
    mkdir -p "$DATA_DIR/csv_upload" "$DATA_DIR/spectrum_upload" \
             "$DATA_DIR/sample_upload" "$DATA_DIR/single_upload" \
             "$DATA_DIR/tools_upload" "$DATA_DIR/download" \
             "$DATA_DIR/compound_catche" "$DATA_DIR/dbs"
    # dbs 目录的数据由 mongodb5_client 容器 entrypoint 管理：
    # 空目录自动从镜像内置快照初始化，非空则保留用户数据
    info "dbs dir: $DATA_DIR/dbs (entrypoint auto-init if empty)"

    cat > "$APP_DIR/.env" <<ENVEOF
METABOBANK_DATA=$DATA_DIR
METABOBANK_DB_PORT=$MONGO_PORT
METABOBANK_PORT=$META_PORT
METABOBANK_RSERVE_PORT=$RSERVE_PORT
ENVEOF
    info ".env written"
}

# --- start / stop ----------------------------------------------------------
compose() { $COMPOSE_CMD -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"; }

do_start() {
    info "starting services (project: $PROJECT_NAME)..."
    compose up -d
    echo ""
    info "waiting for services to become ready (~15s)..."
    sleep 15
    compose ps
    echo ""
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="127.0.0.1"
    info "=============================================="
    info "  URL:        http://$ip:$META_PORT"
    info "  data dir:   $DATA_DIR"
    info "  MongoDB:    $ip:$MONGO_PORT"
    info "  project:    $PROJECT_NAME"
    info "=============================================="
}

do_stop() {
    info "stopping services (project: $PROJECT_NAME)..."
    [ -f "$COMPOSE_FILE" ] || error "$COMPOSE_FILE not found"
    compose down
    info "stopped"
}

# --- main ------------------------------------------------------------------
main() {
    local mode="install" force="no"
    for arg in "$@"; do
        case "$arg" in
            --force)     force="yes" ;;
            --only-start|--stop|--restart) mode="$arg" ;;
            *) echo "usage: bash start.sh [--force] [--only-start|--stop|--restart]"; exit 1 ;;
        esac
    done

    check_prereqs

    local mine
    mine=$(project_containers)
    local has_mine=0
    [ -n "$mine" ] && has_mine=1

    case "$mode" in
        --stop)
            do_stop
            ;;
        --restart)
            do_stop
            prepare_data_dir
            do_start
            ;;
        --only-start)
            [ -f "$COMPOSE_FILE" ] || error "--only-start needs docker-compose.yml"
            prepare_data_dir
            do_start
            ;;
        install)
            if [ "$has_mine" -eq 1 ]; then
                info "found existing containers of project '$PROJECT_NAME':"
                echo "$mine" | while read -r c; do [ -n "$c" ] && info "  - $c"; done
                info "reusing them (no download, no image load)"
                prepare_data_dir
                do_start
            else
                check_ports
                if [ "$force" = "yes" ] && [ -f "$COMPOSE_FILE" ]; then
                    do_stop
                fi
                local src
                src=$(probe_source) || error "cannot reach GitHub or the official download site"
                download_all "$src"
                load_images
                prepare_data_dir
                do_start
            fi
            ;;
    esac
}

main "$@"
