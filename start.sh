#!/bin/bash
# ============================================================================
# Metabobank Client - 一键部署 v4.1
# ============================================================================
# 相对 v4.0 的改动
#   1) 下载源修正：官方 https://www.metabobank.cn/docker_download 优先，GitHub 兜底
#   2) 新增 --local 离线模式：同目录三种 tar 包直接部署，全程不联网
#   3) 新增 SHA256SUMS.txt 校验（--skip-checksum 跳过，MB_STRICT_SUMS=1 强制）
#   4) 服务名/端口自动探测，不再写死 metabospark，兼容旧版 compose（web/mongodb）
#   5) 源探测改为 1KB Range 请求，不再白下 131MB
#   6) 覆盖已有 docker-compose.yml 前自动备份
#   7) 下载前检查磁盘余量；docker load 失败不再 gunzip 出 8GB 临时文件
#
# Usage:
#   bash start.sh               在线安装并启动（已装则复用现有容器）
#   bash start.sh --local       离线安装并启动（用同目录的 tar 包，不联网）
#   bash start.sh --force       先 down 再 up（数据目录保留）
#   bash start.sh --only-start  只启动（镜像已 load）
#   bash start.sh stop          停止并删除 3 个容器（数据保留）
#   bash start.sh restart       重启 3 个容器（数据保留）
#   bash start.sh status        查看容器状态
#   bash start.sh logs          跟随 Web 服务日志
#
# 环境变量覆盖：
#   METABOBANK_DATA_DIR  数据目录（默认 ./metabobank_data）
#   METABOBANK_PORT      Web 端口（默认 8090）
#   METABOBANK_MONGO_PORT MongoDB 映射端口（默认 27023）
#   METABOBANK_RSERVE_PORT Rserve 端口（默认 6322，仅容器内暴露）
#   METABOBANK_PROJECT   compose 项目名（默认取目录名）
#   MB_STRICT_SUMS=1     没有 SHA256SUMS.txt 或校验失败时直接中止
#
# 离线包目录长这样即可 bash start.sh --local：
#   metabospark.tar.gz  mongodb5_client.tar.gz  omics.tar.gz
#   docker-compose.yml  SHA256SUMS.txt  start.sh
# ============================================================================
set -eo pipefail

# --- 单实例锁 --------------------------------------------------------------
LOCK_FILE="${TMPDIR:-/tmp}/metabobank_start.lock"
acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            echo "[ERROR] another start.sh instance is running, aborting" >&2
            exit 1
        fi
    else
        echo "[WARN] flock not found, single-instance lock disabled" >&2
    fi
}

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
SUMS_FILE="$APP_DIR/SHA256SUMS.txt"
ENV_FILE="$APP_DIR/.env"

DOWNLOAD_SOURCES=(
    "https://www.metabobank.cn/docker_download"
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
[ -z "$PROJECT_NAME" ] && PROJECT_NAME="metabobank"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- 基础工具 --------------------------------------------------------------
port_busy() {
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$1\$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk 'NR>2{print $4}' | grep -qE "[:.]$1\$"
    else
        return 1
    fi
}

project_containers() {
    docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" \
        --format '{{.Names}}' 2>/dev/null || true
}

compose() {
    # 显式 --env-file，避免 .env 只在"当前工作目录"生效的老问题
    if [ -f "$ENV_FILE" ]; then
        $COMPOSE_CMD --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"
    else
        $COMPOSE_CMD -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"
    fi
}

compose_services() {
    compose config --services 2>/dev/null || true
}

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
    [ -z "$cid" ] && return 1
    out="$(docker port "$cid" 2>/dev/null | head -n1 || true)"
    [ -z "$out" ] && return 1
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

# --- 前置检查 --------------------------------------------------------------
check_prereqs() {
    info "checking environment..."
    command -v docker >/dev/null 2>&1 || error "docker not found, please install Docker 20+"
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
        warn "  METABOBANK_PORT=18090 METABOBANK_MONGO_PORT=37023 bash start.sh $*"
        error "port conflict, aborted"
    fi
}

check_disk() {
    local src="${1:-${DOWNLOAD_SOURCES[0]}}"
    local missing=0 i f len need_kb free
    for i in "${!IMAGE_FILES[@]}"; do
        f="${IMAGE_FILES[$i]}"
        if [ ! -s "$APP_DIR/$f" ]; then
            len="$(head_len "$src/$f")"
            missing=$((missing + len))
        fi
    done
    [ "$missing" -eq 0 ] && { info "all image files present, skip disk check"; return 0; }
    # 下载 + docker load（镜像层落盘）约 2 倍
    need_kb=$(( missing / 512 ))
    free="$(free_kb)"
    [ -z "$free" ] && { warn "cannot read free disk space, skip check"; return 0; }
    if [ "$free" -lt "$need_kb" ]; then
        error "insufficient disk in $APP_DIR: need ~$((need_kb / 1048576))GB, free $((free / 1048576))GB
  建议：腾出空间，或把 tar 包先放到别的盘再用 --local 部署"
    fi
    info "disk ok: need ~$((need_kb / 1048576))GB, free $((free / 1048576))GB"
}

# --- 下载 ------------------------------------------------------------------
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
    warn "existing docker-compose.yml backed up to $(basename "$bak")"
}

download_compose() {
    local src="$1" tmp="$APP_DIR/.docker-compose.yml.new"
    fetch_file "$src/docker-compose.yml" "$tmp" || error "failed to download docker-compose.yml"
    if [ -f "$COMPOSE_FILE" ]; then
        if cmp -s "$COMPOSE_FILE" "$tmp"; then
            rm -f "$tmp"
            info "docker-compose.yml unchanged"
        else
            backup_compose
            mv "$tmp" "$COMPOSE_FILE"
            info "docker-compose.yml updated"
        fi
    else
        mv "$tmp" "$COMPOSE_FILE"
        info "docker-compose.yml downloaded"
    fi
}

download_sums() {
    local src="$1" tmp="$APP_DIR/.SHA256SUMS.new"
    if fetch_file "$src/SHA256SUMS.txt" "$tmp" 2>/dev/null; then
        mv "$tmp" "$SUMS_FILE"
        info "SHA256SUMS.txt downloaded"
    else
        rm -f "$tmp"
        warn "SHA256SUMS.txt not available on $src"
    fi
}

download_all() {
    local src="$1" i f sz
    info "download source: $src"
    download_compose "$src"
    for i in "${!IMAGE_FILES[@]}"; do
        f="${IMAGE_FILES[$i]}"
        if [ -s "$APP_DIR/$f" ]; then
            sz="$(du -h "$APP_DIR/$f" 2>/dev/null | awk '{print $1}')"
            info "$f already exists (${sz:-?}), skip (delete it to force re-download)"
            continue
        fi
        info "downloading $f (large file, please wait)..."
        fetch_file "$src/$f" "$APP_DIR/$f" || error "failed to download $f"
    done
    download_sums "$src"
}

# --- 校验 ------------------------------------------------------------------
verify_sums() {
    local i f exp act h
    if [ "$SKIP_SUMS" = "yes" ]; then
        warn "checksum verification skipped by --skip-checksum"
        return 0
    fi
    if [ ! -s "$SUMS_FILE" ]; then
        if [ "$STRICT_SUMS" = "yes" ]; then
            error "SHA256SUMS.txt missing, but MB_STRICT_SUMS=1"
        fi
        warn "SHA256SUMS.txt not found, skip checksum verification"
        return 0
    fi
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        warn "sha256sum/shasum not found, skip checksum verification"
        return 0
    fi
    for i in "${!IMAGE_FILES[@]}"; do
        f="${IMAGE_FILES[$i]}"
        [ -s "$APP_DIR/$f" ] || continue
        exp="$(awk -v n="$f" '{g=$2; sub(/^\.\//,"",g); sub(/^\*/,"",g); if (g==n) {print $1; exit}}' "$SUMS_FILE")"
        if [ -z "$exp" ] && [ -s "$APP_DIR/$f.sha256" ]; then
            exp="$(awk '{print $1; exit}' "$APP_DIR/$f.sha256")"
            h="  (source: $f.sha256)"
        else
            h=""
        fi
        if [ -z "$exp" ]; then
            warn "no checksum entry for $f"
            [ "$STRICT_SUMS" = "yes" ] && error "no checksum entry for $f (strict mode)"
            continue
        fi
        info "verifying $f ..."
        act="$(sha256_file "$APP_DIR/$f")" || warn "cannot compute sha256 for $f"
        if [ "$act" != "$exp" ]; then
            error "checksum mismatch for $f
  expected: $exp
  actual:   $act
  处理：删掉该文件重新下载（rm -f \"$APP_DIR/$f\"），或确认来源可信后再用 --skip-checksum"
        fi
        info "  OK $f$h"
    done
}

# --- 镜像 ------------------------------------------------------------------
load_images() {
    local i f ref
    for i in "${!IMAGE_FILES[@]}"; do
        f="${IMAGE_FILES[$i]}"
        ref="${IMAGE_REFS[$i]}"
        if docker image inspect "$ref" >/dev/null 2>&1; then
            info "$ref already loaded, skip"
            continue
        fi
        [ -s "$APP_DIR/$f" ] || { warn "$f not found, skip loading $ref"; continue; }
        info "loading image: $f"
        docker load -i "$APP_DIR/$f" \
            || error "docker load failed for $f（先检查磁盘余量：df -h \"$APP_DIR\"；不要解压后重试）"
        if ! docker image inspect "$ref" >/dev/null 2>&1; then
            warn "$f loaded, but image $ref not found; 包内 tag 可能与客户端预期不一致"
        fi
    done
    info "images ready:"
    docker images --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E 'metabank/' || true
}

# --- 数据目录 --------------------------------------------------------------
prepare_data_dir() {
    info "preparing data directory: $DATA_DIR"
    local d
    for d in "${DATA_SUBDIRS[@]}"; do
        mkdir -p "$DATA_DIR/$d"
    done
    cat > "$APP_DIR/.env" <<ENVEOF
METABOBANK_DATA=$DATA_DIR
METABOBANK_PORT=$META_PORT
METABOBANK_DB_PORT=$MONGO_PORT
METABOBANK_RSERVE_PORT=$RSERVE_PORT
ENVEOF
    info "dbs dir: $DATA_DIR/dbs (entrypoint auto-init if empty)"
    info ".env written"
}

write_default_compose() {
    warn "docker-compose.yml not found, writing built-in default (v3.0 layout)"
    cat > "$COMPOSE_FILE" <<'COMPOSEEOF'
# Metabobank Client - 内置默认部署文件（start.sh --local 生成）
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
    info "built-in docker-compose.yml written"
}

# --- 启动 / 停止 -----------------------------------------------------------
wait_healthy() {
    local i cid state hp
    for i in $(seq 1 18); do
        cid="$(compose ps -q "$WEB_SVC" 2>/dev/null | head -n1 || true)"
        if [ -n "$cid" ]; then
            state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)"
            case "$state" in
                healthy)
                    info "$WEB_SVC is healthy"
                    return 0 ;;
                none)
                    hp="$(detect_host_port || true)"
                    if [ -n "$hp" ] && curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$hp/login" 2>/dev/null; then
                        info "$WEB_SVC responding on :$hp (no healthcheck in image)"
                        return 0
                    fi ;;
                unhealthy)
                    warn "$WEB_SVC reported unhealthy, keep waiting..." ;;
            esac
        fi
        sleep 5
    done
    warn "$WEB_SVC not healthy within 90s; run 'bash start.sh logs' to inspect"
    return 1
}

do_start() {
    WEB_SVC="$(detect_web_service)"
    info "web service: $WEB_SVC"
    info "starting services (project: $PROJECT_NAME)..."
    compose up -d
    echo ""
    info "waiting for services to become healthy (up to 90s)..."
    wait_healthy || true
    compose ps
    echo ""
    local ip hp
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [ -z "$ip" ] && ip="127.0.0.1"
    hp="$(detect_host_port || true)"
    [ -z "$hp" ] && hp="$META_PORT"
    info "=============================================="
    info "  URL:        http://$ip:$hp"
    info "  data dir:   $DATA_DIR"
    info "  MongoDB:    $ip:$MONGO_PORT"
    info "  project:    $PROJECT_NAME"
    info "=============================================="
}

do_status() {
    WEB_SVC="$(detect_web_service)"
    info "container status (project: $PROJECT_NAME):"
    compose ps
}

do_logs() {
    WEB_SVC="$(detect_web_service)"
    compose logs -f --tail 100 "$WEB_SVC"
}

do_stop() {
    info "stopping all containers (project: $PROJECT_NAME) ..."
    [ -f "$COMPOSE_FILE" ] || error "$COMPOSE_FILE not found, run 'bash start.sh' first"
    local remaining
    compose down
    remaining="$(compose ps -q 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    if [ "${remaining:-0}" -eq 0 ]; then
        info "all containers stopped and removed (data dir untouched)"
    else
        warn "$remaining container(s) still present, check 'bash start.sh status'"
    fi
}

# --- 模式 ------------------------------------------------------------------
do_local() {
    local i have=0 f
    info "local (offline) mode: using files in $APP_DIR"
    [ -f "$COMPOSE_FILE" ] || write_default_compose
    check_ports "--local"

    for i in "${!IMAGE_REFS[@]}"; do
        if docker image inspect "${IMAGE_REFS[$i]}" >/dev/null 2>&1; then have=1; fi
    done

    if [ "$have" -eq 1 ]; then
        info "images already loaded, skip docker load"
        verify_sums || true
    else
        local missing=0
        for i in "${!IMAGE_FILES[@]}"; do
            f="${IMAGE_FILES[$i]}"
            if [ ! -s "$APP_DIR/$f" ] && ! docker image inspect "${IMAGE_REFS[$i]}" >/dev/null 2>&1; then
                warn "missing: $f"
                missing=1
            fi
        done
        [ "$missing" -eq 1 ] && error "离线包不完整：需要 metabospark.tar.gz / mongodb5_client.tar.gz / omics.tar.gz
  或先在本机 docker load 好 metabank/*:v3.0 镜像再运行"
        verify_sums
        load_images
    fi
    prepare_data_dir
    do_start
}

images_all_present() {
    local i
    for i in "${!IMAGE_REFS[@]}"; do
        docker image inspect "${IMAGE_REFS[$i]}" >/dev/null 2>&1 || return 1
    done
    return 0
}

do_install() {
    local mine has_mine=0 src
    mine="$(project_containers)"
    [ -n "$mine" ] && has_mine=1
    if [ "$has_mine" -eq 1 ]; then
        info "found existing containers of project '$PROJECT_NAME':"
        echo "$mine" | while read -r c; do [ -n "$c" ] && info "  - $c"; done
        info "reusing them (no download, no image load)"
        prepare_data_dir
        do_start
        return 0
    fi

    check_ports ""
    if [ "$FORCE" = "yes" ] && [ -f "$COMPOSE_FILE" ]; then
        do_stop
    fi
    if images_all_present && [ -f "$COMPOSE_FILE" ]; then
        info "all images already loaded and compose present, skip download"
        verify_sums || true
        prepare_data_dir
        do_start
        return 0
    fi
    src="$(probe_source)" || error "cannot reach https://www.metabobank.cn/docker_download nor GitHub"
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
            --local)         mode="local" ;;
            --force)         FORCE="yes" ;;
            --skip-checksum) SKIP_SUMS="yes" ;;
            --only-start|start) mode="start" ;;
            --stop|stop)     mode="stop" ;;
            --restart|restart) mode="restart" ;;
            --status|status) mode="status" ;;
            --logs|logs)     mode="logs" ;;
            -h|--help)       sed -n '3,/^set -eo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) echo "usage: bash start.sh [--local] [--force] [--skip-checksum] [start|stop|restart|status|logs]"; exit 1 ;;
        esac
    done

    check_prereqs
    acquire_lock
    case "$mode" in
        local)   do_local ;;
        stop)    do_stop ;;
        restart) do_stop; prepare_data_dir; do_start ;;
        start)
            [ -f "$COMPOSE_FILE" ] || error "start needs docker-compose.yml; run 'bash start.sh' first"
            prepare_data_dir; do_start ;;
        status)
            [ -f "$COMPOSE_FILE" ] || error "status needs docker-compose.yml; run 'bash start.sh' first"
            do_status ;;
        logs)
            [ -f "$COMPOSE_FILE" ] || error "logs needs docker-compose.yml; run 'bash start.sh' first"
            do_logs ;;
        install) do_install ;;
    esac
}

main "$@"
