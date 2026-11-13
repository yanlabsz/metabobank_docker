#!/bin/bash
# ============================================================================
# Metabobank Client - 一键部署脚本 (v3.2)
# ============================================================================
# 用法：
#   bash start.sh                  # 安装并启动（已有容器则复用，不重建）
#   bash start.sh --with-data      # 安装并下载预置 MongoDB 数据快照（约 7.4GB）
#   bash start.sh --force          # 强制重建（先 down 再 up，容器会被替换）
#   bash start.sh --only-start     # 只启动（镜像已 docker load 过）
#   bash start.sh --stop           # 停止并移除本项目的容器
#   bash start.sh --restart        # 重启本项目服务
#
# 安全机制：
#   1. flock 单实例锁，防止脚本并发/重复执行
#   2. 容器归属检测：发现同名容器属于其他 compose 项目时拒绝操作，避免误删
#   3. 已有容器复用：配置不变时 compose up -d 幂等，不会重复创建容器
# ============================================================================
set -e

# --- 单实例锁 ---------------------------------------------------------------
LOCK_FILE="/tmp/metabobank_start.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[ERROR] 另一个 start.sh 实例正在运行，本次退出"
    exit 1
fi

# --- 基本配置 ---------------------------------------------------------------
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

DOWNLOAD_SOURCES=(
    "https://raw.githubusercontent.com/yanlabsz/metabobank_docker/main"
    "https://www.metabobank.cn/docker_download"
)
IMAGE_FILES=(
    "metabospark.tar.gz"
    "mongodb5.tar.gz"
    "omics.tar.gz"
)
DATA_FILE="mongodb5_data.tar.gz"
COMPOSE_REMOTE="docker-compose.yml"

DATA_DIR="${METABOBANK_DATA_DIR:-$APP_DIR/metabobank_data}"
META_PORT="${METABOBANK_PORT:-8090}"
MONGO_PORT="${METABOBANK_MONGO_PORT:-27023}"
RSERVE_PORT="${METABOBANK_RSERVE_PORT:-6322}"

CONTAINERS=("metabospark" "mongodb5_client" "metabospark_rserve")

# --- 颜色输出 ---------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- 工具函数 ---------------------------------------------------------------
container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

# 容器属于哪个 compose 项目（无标签返回空）
container_project() {
    docker inspect "$1" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true
}

# 当前目录对应的默认 compose 项目名（compose 规则：目录名小写、去非法字符）
current_project() {
    basename "$APP_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g'
}

# --- 前置检查 ---------------------------------------------------------------
check_prereqs() {
    info "检查运行环境..."
    command -v docker >/dev/null 2>&1 || error "未检测到 docker，请先安装 Docker 20+"
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || error "未检测到 curl 或 wget"

    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        error "未检测到 docker compose v2 或 docker-compose"
    fi
    info "OK: $COMPOSE_CMD"
}

# --- 容器归属检测（核心保护）------------------------------------------------
# 返回：
#   0 = 干净，可以全新安装（没有任何目标容器）
#   2 = 目标容器已存在且属于本项目 → 复用
#   1 = 发现属于其他项目的同名容器 → 拒绝（除非 --force）
check_existing() {
    local cur_proj foreign="" mine=0 total=0
    cur_proj=$(current_project)

    for c in "${CONTAINERS[@]}"; do
        if container_exists "$c"; then
            total=$((total+1))
            local proj
            proj=$(container_project "$c")
            if [ -n "$proj" ] && [ "$proj" != "$cur_proj" ]; then
                foreign="$foreign $c($proj)"
            else
                mine=$((mine+1))
            fi
        fi
    done

    if [ -n "$foreign" ]; then
        warn "检测到以下同名容器属于其他 compose 项目："
        for f in $foreign; do warn "  - $f"; done
        warn "当前目录项目名为: $cur_proj"
        warn "继续操作会删除并重建这些容器，可能导致其数据目录被替换！"
        return 1
    fi

    if [ "$total" -gt 0 ]; then
        info "检测到 $total 个已存在的本项目容器，将复用（不重新下载镜像）"
        return 2
    fi
    return 0
}

# --- 下载工具 ---------------------------------------------------------------
fetch() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -C - -o "$out" "$url" 2>/dev/null
    else
        wget -q -c -O "$out" "$url" 2>/dev/null
    fi
}

probe_source() {
    local src test_url
    for src in "${DOWNLOAD_SOURCES[@]}"; do
        test_url="$src/${IMAGE_FILES[0]}"
        if fetch "$test_url" "$APP_DIR/.probe_tmp" 2>/dev/null; then
            rm -f "$APP_DIR/.probe_tmp"
            echo "$src"
            return 0
        fi
    done
    return 1
}

download_all() {
    local src="$1" with_data="${2:-no}"
    info "使用下载源: $src"

    info "下载 $COMPOSE_REMOTE ..."
    fetch "$src/$COMPOSE_REMOTE" "$COMPOSE_FILE" || error "下载 $COMPOSE_REMOTE 失败"

    local f
    for f in "${IMAGE_FILES[@]}"; do
        if [ -s "$APP_DIR/$f" ]; then
            info "已存在 $f，跳过下载"
            continue
        fi
        info "下载 $f （较大，请耐心等待）..."
        fetch "$src/$f" "$APP_DIR/$f" || error "下载 $f 失败"
    done

    if [ "$with_data" = "yes" ]; then
        if [ -s "$APP_DIR/$DATA_FILE" ]; then
            info "已存在 $DATA_FILE，跳过下载"
        else
            info "下载预置数据快照 $DATA_FILE（约 7.4GB）..."
            fetch "$src/$DATA_FILE" "$APP_DIR/$DATA_FILE" || {
                warn "数据快照下载失败，将使用空库启动"
                rm -f "$APP_DIR/$DATA_FILE"
            }
        fi
    fi
    info "文件下载完成"
}

load_images() {
    local f
    for f in "${IMAGE_FILES[@]}"; do
        [ ! -s "$APP_DIR/$f" ] && continue
        info "加载镜像: $f"
        if ! docker load -i "$APP_DIR/$f" 2>/dev/null; then
            local tmp="${f%.gz}"
            gunzip -c "$APP_DIR/$f" > "$APP_DIR/$tmp"
            docker load -i "$APP_DIR/$tmp"
            rm -f "$APP_DIR/$tmp"
        fi
    done
    info "镜像加载完成"
    docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E 'metabank|^mongo:5' || true
}

# --- 准备数据目录 -----------------------------------------------------------
prepare_data_dir() {
    info "准备数据目录: $DATA_DIR"
    mkdir -p "$DATA_DIR/csv_upload" "$DATA_DIR/spectrum_upload" \
             "$DATA_DIR/sample_upload" "$DATA_DIR/single_upload" \
             "$DATA_DIR/tools_upload" "$DATA_DIR/download" \
             "$DATA_DIR/compound_catche"

    if [ -s "$APP_DIR/$DATA_FILE" ]; then
        if [ -d "$DATA_DIR/dbs" ] && [ "$(ls -A "$DATA_DIR/dbs" 2>/dev/null)" ]; then
            warn "$DATA_DIR/dbs 已有数据，跳过解压"
        else
            info "解压数据快照到 $DATA_DIR ..."
            tar xzf "$APP_DIR/$DATA_FILE" -C "$DATA_DIR"
            info "数据解压完成"
        fi
    else
        mkdir -p "$DATA_DIR/dbs"
        warn "无数据快照，以空库启动（可用 --with-data 重新安装获取数据）"
    fi

    cat > "$APP_DIR/.env" <<ENVEOF
METABOBANK_DATA=$DATA_DIR
METABOBANK_DB_PORT=$MONGO_PORT
METABOBANK_PORT=$META_PORT
METABOBANK_RSERVE_PORT=$RSERVE_PORT
ENVEOF
    info ".env 已生成"
}

# --- 启动/停止 --------------------------------------------------------------
do_start() {
    info "启动 Metabobank 服务..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" up -d
    echo ""
    info "等待服务就绪（约 15 秒）..."
    sleep 15
    $COMPOSE_CMD -f "$COMPOSE_FILE" ps
    echo ""
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="127.0.0.1"
    info "=============================================="
    info "  访问地址: http://$ip:$META_PORT"
    info "  数据目录: $DATA_DIR"
    info "  MongoDB:  $ip:$MONGO_PORT"
    info "=============================================="
}

do_stop() {
    info "停止本项目 Metabobank 服务..."
    [ -f "$COMPOSE_FILE" ] || error "未找到 $COMPOSE_FILE"
    $COMPOSE_CMD -f "$COMPOSE_FILE" down
    info "已停止"
}

# --- 主流程 -----------------------------------------------------------------
main() {
    local mode="install" with_data="no" force="no"
    for arg in "$@"; do
        case "$arg" in
            --with-data) with_data="yes" ;;
            --force)     force="yes" ;;
            --only-start|--stop|--restart) mode="$arg" ;;
            install)     mode="install" ;;
            *) echo "用法: bash start.sh [--with-data] [--force] [--only-start|--stop|--restart]"; exit 1 ;;
        esac
    done

    check_prereqs

    # 容器归属检测：任何模式下都先做保护
    local exist_rc=0
    check_existing || exist_rc=$?

    if [ "$exist_rc" -eq 1 ]; then
        if [ "$force" != "yes" ]; then
            error "因存在其他项目的同名容器，已中止。确认要替换请加 --force，或先手动 docker rm 这些容器"
        fi
        warn "--force 已指定，将强制重建这些容器"
    fi

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
            [ -f "$COMPOSE_FILE" ] || error "--only-start 需要先有 docker-compose.yml"
            prepare_data_dir
            do_start
            ;;
        install)
            if [ "$force" = "yes" ] && [ -f "$COMPOSE_FILE" ]; then
                do_stop
            fi
            if [ "$exist_rc" -eq 2 ]; then
                # 复用：跳过下载和 load
                info "复用已存在容器，直接启动"
                prepare_data_dir
                do_start
            else
                local src
                src=$(probe_source) || error "无法连通 GitHub 和官网下载源，请检查网络"
                download_all "$src" "$with_data"
                load_images
                prepare_data_dir
                do_start
            fi
            ;;
    esac
}

main "$@"
