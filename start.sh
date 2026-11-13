#!/bin/bash
# Metabobank Client 启动脚本
# 同一份文件支持两种运行方式：
#   1) 容器内（Dockerfile_metabobank 的 CMD）：前台运行 pserve，日志进 docker logs
#   2) 服务器直装（无容器）：沿用 conda 环境 + nohup 后台运行

set -e

APP_DIR="${APP_DIR:-/opt/Metabobank_client}"
CONF="${PSERVE_CONF:-deployment.ini}"

if [ -d "$APP_DIR/Metabobank_dev" ]; then
    # ---------- 容器模式 ----------
    cd "$APP_DIR"
    if [ -f .env ]; then
        set -a
        . ./.env
        set +a
    fi
    echo "[start] container mode: app=$APP_DIR conf=$CONF port=8090"
    exec pserve "$CONF"
fi

# ---------- 服务器直装模式 ----------
cd /var/www/html/Metabobank_client || exit 1
# shellcheck disable=SC1091
source /data1/software/miniconda3/bin/activate metabobank

if [ -f .env ]; then
    set -a
    . ./.env
    set +a
fi

if [ -f pserve.pid ]; then
    old_pid=$(cat pserve.pid)
    if kill -0 "$old_pid" 2>/dev/null; then
        kill "$old_pid"
        sleep 2
    fi
fi

echo "[start] server mode: $(pwd) conf=$CONF"
nohup pserve "$CONF" > pserve.log 2>&1 &
echo $! > pserve.pid
sleep 3
tail -20 pserve.log
