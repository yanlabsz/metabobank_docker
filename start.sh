#!/bin/bash
# ============================================================================
# Metabobank Client - 一键部署脚本 (v3.1)
# ============================================================================
# 使用：
#   bash start.sh                    # 一键下载所有镜像 + compose 并启动
#   bash start.sh --with-data        # 同时下载预置 MongoDB 数据快照（~2GB）
#   bash start.sh --only-start       # 只启动（镜像和数据已提前准备好）
#   bash start.sh --stop             # 停止服务
#   bash start.sh --restart          # 重启服务
#
# 需要：Docker 20+ 和 Docker Compose v2
# ============================================================================
set -e

# --- 基本配置 ---------------------------------------------------------------
APP_NAME="metabobank"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

# 两个下载源：GitHub 和 官网；按顺序尝试，谁先通用谁
DOWNLOAD_SOURCES=(
    "https://raw.githubusercontent.com/yanlabsz/metabobank_docker/main"
    "https://www.metabobank.cn/docker_download"
)

# 必须下载的镜像 tar（用户端只需 load）
IMAGE_FILES=(
    "metabospark.tar.gz"      # Web 主程序
    "mongodb5.tar.gz"         # MongoDB 5.0 官方镜像（实际从 hub 拉即可，这里留作离线备用）
    "omics.tar.gz"            # 组学分析 Rserve
)

# 可选下载：预置 MongoDB 数据快照（首次部署强烈建议下，否则是空库没有数据）
# 结构：mongodb5_data.tar.gz 解压后顶层 dbs/ conf/ logs/
DATA_FILE="mongodb5_data.tar.gz"

COMPOSE_REMOTE="docker-compose.yml"

# 数据目录：默认放在脚本同级目录的 metabobank_data
DATA_DIR="${METABOBANK_DATA_DIR:-$APP_DIR/metabobank_data}"
META_PORT="${METABOBANK_PORT:-8090}"
MONGO_PORT="${METABOBANK_MONGO_PORT:-27023}"
RSERVE_PORT="${METABOBANK_RSERVE_PORT:-6322}"

# --- 颜色输出 ---------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- 前置检查 ---------------------------------------------------------------
check_prereqs() {
    info "检查运行环境..."
    command -v docker   >/dev/null 2>&1 || error "未检测到 docker，请先安装 Docker 20+"
    command -v curl     >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || error "未检测到 curl 或 wget"

    local docker_ver
    docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1)
    if [ "$docker_ver" -lt 20 ] 2>/dev/null; then
        warn "Docker 版本较低（$(docker version --format '{{.Server.Version}}' 2>/dev/null)），建议升级到 20+"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        if command -v docker-compose >/dev/null 2>&1; then
            COMPOSE_CMD="docker-compose"
        else
            error "未检测到 docker compose v2 或 docker-compose"
        fi
    else
        COMPOSE_CMD="docker compose"
    fi
    info "OK: docker compose 命令 = $COMPOSE_CMD"
}

# --- 下载工具 ---------------------------------------------------------------
fetch() {
    # fetch <url> <outfile>  支持断点续传，优先 curl，fallback wget
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -C - -o "$out" "$url" 2>/dev/null
    else
        wget -q -c -O "$out" "$url" 2>/dev/null
    fi
}

# --- 探测可用下载源 ---------------------------------------------------------
probe_source() {
    local src file test_url
    file="${IMAGE_FILES[0]}"
    for src in "${DOWNLOAD_SOURCES[@]}"; do
        test_url="$src/$file"
        if fetch "$test_url" "$APP_DIR/.probe_tmp" 2>/dev/null; then
            rm -f "$APP_DIR/.probe_tmp"
            echo "$src"
            return 0
        fi
    done
    return 1
}

# --- 下载所有文件 -----------------------------------------------------------
download_all() {
    local src="$1" with_data="${2:-no}"
    info "使用下载源: $src"

    info "下载 $COMPOSE_REMOTE ..."
    fetch "$src/$COMPOSE_REMOTE" "$COMPOSE_FILE" || error "下载 $COMPOSE_REMOTE 失败"

    local f
    for f in "${IMAGE_FILES[@]}"; do
        if [ -s "$APP_DIR/$f" ]; then
            info "已存在 $f，跳过"
            continue
        fi
        info "下载 $f （较大，请耐心等待）..."
        fetch "$src/$f" "$APP_DIR/$f" || error "下载 $f 失败"
    done

    # 可选数据快照
    if [ "$with_data" = "yes" ]; then
        if [ -s "$APP_DIR/$DATA_FILE" ]; then
            info "已存在 $DATA_FILE，跳过"
        else
            info "下载预置 MongoDB 数据快照 $DATA_FILE ..."
            fetch "$src/$DATA_FILE" "$APP_DIR/$DATA_FILE" || {
                warn "下载 $DATA_FILE 失败，将使用空库（无数据）"
                rm -f "$APP_DIR/$DATA_FILE"
            }
        fi
    fi
    info "文件下载完成"
}

# --- 加载镜像 ---------------------------------------------------------------
load_images() {
    local f
    for f in "${IMAGE_FILES[@]}"; do
        [ ! -s "$APP_DIR/$f" ] && continue
        info "加载镜像: $f"
        if ! docker load -i "$APP_DIR/$f" 2>/dev/null; then
            # 有些 tar.gz 被 docker load 当作旧格式，先 gunzip 再 load
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
    mkdir -p "$DATA_DIR"
    # 必须的子目录（CSV 上传、组学分析等）
    mkdir -p "$DATA_DIR/csv_upload" "$DATA_DIR/spectrum_upload" \
             "$DATA_DIR/sample_upload" "$DATA_DIR/single_upload" \
             "$DATA_DIR/tools_upload" "$DATA_DIR/download" \
             "$DATA_DIR/compound_catche"

    # 如果有预置数据快照，解压 dbs 到 DATA_DIR 下
    if [ -s "$APP_DIR/$DATA_FILE" ]; then
        info "发现预置数据快照 $DATA_FILE，解压到 $DATA_DIR ..."
        # 先检查 dbs/ 是否已有数据
        if [ -d "$DATA_DIR/dbs" ] && [ "$(ls -A "$DATA_DIR/dbs" 2>/dev/null)" ]; then
            warn "检测到 $DATA_DIR/dbs 已有数据，跳过解压（如需全新安装请手动清空）"
        else
            # 解压后顶层就是 dbs/ conf/ logs/，直接落到 DATA_DIR
            tar xzf "$APP_DIR/$DATA_FILE" -C "$DATA_DIR" 2>/dev/null || {
                warn "直接解压失败，可能包结构不同，尝试修复..."
                # 兼容：有些包顶层多一层 mongodb/
                local tmpdir
                tmpdir=$(mktemp -d)
                tar xzf "$APP_DIR/$DATA_FILE" -C "$tmpdir"
                # 找到 dbs/ 挪到 DATA_DIR
                if [ -d "$tmpdir/mongodb/dbs" ]; then
                    mv "$tmpdir/mongodb/dbs" "$DATA_DIR/dbs"
                elif [ -d "$tmpdir/dbs" ]; then
                    mv "$tmpdir/dbs" "$DATA_DIR/dbs"
                fi
                rm -rf "$tmpdir"
            }
            info "数据解压完成"
        fi
    else
        # 没有数据快照 → 确保 dbs/ 存在（空目录，mongo 会自动初始化）
        mkdir -p "$DATA_DIR/dbs"
        warn "未检测到预置数据快照，将以空库启动（可访问下载 $DATA_FILE 后重启）"
    fi

    # 把 DATA_DIR 写入 .env 供 compose 使用
    cat > "$APP_DIR/.env" <<ENVEOF
METABOBANK_DATA=$DATA_DIR
METABOBANK_DB_PORT=$MONGO_PORT
METABOBANK_PORT=$META_PORT
METABOBANK_RSERVE_PORT=$RSERVE_PORT
ENVEOF
    info ".env 已生成"
}

# --- 启动/停止/重启 ---------------------------------------------------------
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
    info "停止 Metabobank 服务..."
    if [ -f "$COMPOSE_FILE" ]; then
        $COMPOSE_CMD -f "$COMPOSE_FILE" down
    else
        error "未找到 $COMPOSE_FILE，无法停止"
    fi
    info "已停止"
}

# --- 主流程 -----------------------------------------------------------------
main() {
    local mode="install" with_data="no"

    for arg in "$@"; do
        case "$arg" in
            --only-start|--stop|--restart|install) mode="$arg" ;;
            --with-data) with_data="yes" ;;
        esac
    done

    case "$mode" in
        --only-start)
            [ -f "$COMPOSE_FILE" ] || error "--only-start 需要先有 docker-compose.yml"
            prepare_data_dir
            do_start
            ;;
        --stop)
            check_prereqs
            do_stop
            ;;
        --restart)
            check_prereqs
            do_stop
            prepare_data_dir
            do_start
            ;;
        install|"")
            check_prereqs
            local src
            src=$(probe_source) || error "无法连通 GitHub 和官网下载源，请检查网络"
            download_all "$src" "$with_data"
            load_images
            prepare_data_dir
            do_start
            ;;
        *)
            echo "用法: bash start.sh [install|--with-data|--only-start|--stop|--restart]"
            exit 1
            ;;
    esac
}

main "$@"
