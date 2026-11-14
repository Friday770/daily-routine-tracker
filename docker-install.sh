#!/usr/bin/env bash
# DailyRoutineTracker（作息打卡）—— 用 Docker 一键部署
#
# 用法（服务器上需已安装 Docker 和 docker compose 插件）：
#   curl -fsSL --retry 5 --retry-all-errors -o docker-install.sh https://raw.githubusercontent.com/Friday770/daily-routine-tracker/main/docker-install.sh
#   sudo bash docker-install.sh                 # 默认端口 9090
#   sudo HOST_PORT=8080 bash docker-install.sh  # 换端口
#
# 会启动两个容器：app（网页和后端）和 db（独立的 MySQL 8.4，数据保存在 Docker 数据卷里，
# 不会碰服务器上已有的 MySQL）。重复运行是安全的：已有的 .env 和数据会保留。
#
#   APP_DIR       安装目录      默认 /opt/daily-routine-tracker
#   HOST_PORT     网页端口      默认 9090
#   APP_TIMEZONE  统一时区      默认 Asia/Shanghai
#   PIP_INDEX_URL Python 依赖镜像源（国内服务器连不上 PyPI 时会自动用阿里云镜像）
set -euo pipefail

REPO="${REPO:-https://github.com/Friday770/daily-routine-tracker.git}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/daily-routine-tracker}"
HOST_PORT="${HOST_PORT:-9090}"
APP_TIMEZONE="${APP_TIMEZONE:-Asia/Shanghai}"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m注意：%s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m错误：%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo bash docker-install.sh"
command -v docker >/dev/null 2>&1 || die "没有安装 Docker。宝塔面板可在“Docker”里一键安装，或参考 https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || die "没有 docker compose 插件（需要 Docker Compose v2）"
docker info >/dev/null 2>&1 || die "Docker 没有运行，请先启动：systemctl start docker"
command -v git >/dev/null 2>&1 || {
  if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y git
  elif command -v dnf >/dev/null 2>&1; then dnf install -y git
  else die "请先安装 git"; fi
}

# ------------------------------------------------------------ 1. 项目文件
say "准备项目文件 ${APP_DIR}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || pwd)"
if [ -f "$APP_DIR/docker-compose.yml" ]; then
  echo "项目文件已在 ${APP_DIR}，保留现有代码（更新请在网页上点“立即更新”，或运行 ${APP_DIR}/update.sh）"
elif [ -f "$SRC_DIR/docker-compose.yml" ] && [ "$SRC_DIR" != "$APP_DIR" ]; then
  echo "使用上传的项目文件：${SRC_DIR}"
  mkdir -p "$APP_DIR" && cp -a "$SRC_DIR/." "$APP_DIR/" && rm -rf "$APP_DIR/.venv"
else
  [ -e "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ] && die "${APP_DIR} 已存在且不是空目录"
  ok=0
  for i in 1 2 3 4 5; do
    if git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 clone --branch "$BRANCH" "$REPO" "$APP_DIR"; then ok=1; break; fi
    rm -rf "$APP_DIR"; echo "从 GitHub 下载失败，${i} 秒后重试（第 ${i}/5 次）..."; sleep "$i"
  done
  [ "$ok" -eq 1 ] || die "从 GitHub 下载失败。可以稍后重试，或把项目包上传到服务器解压后，在项目目录里运行：sudo bash docker-install.sh"
fi
cd "$APP_DIR"
chmod +x ./*.sh

# ------------------------------------------------------------ 2. 配置 .env
if [ -f .env ] && grep -q '^MYSQL_ROOT_PASSWORD=' .env; then
  echo "保留已有配置 .env"
else
  say "生成配置 .env（数据库密码随机生成）"
  rand() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-24; }
  PIP_LINE=""
  if [ -z "${PIP_INDEX_URL:-}" ] && ! curl -s -m 8 -o /dev/null https://pypi.org/simple/pip/; then
    PIP_INDEX_URL="https://mirrors.aliyun.com/pypi/simple/"
    echo "PyPI 访问较慢，构建时使用镜像 ${PIP_INDEX_URL}"
  fi
  [ -n "${PIP_INDEX_URL:-}" ] && PIP_LINE="PIP_INDEX_URL=${PIP_INDEX_URL}"
  cat > .env <<EOF
# 由 docker-install.sh 生成。修改后运行：cd ${APP_DIR} && docker compose up -d
# 网页端口（服务器上对外的端口）
HOST_PORT=${HOST_PORT}
# 统一时区（页面、打卡判断、数据库统计都按它）
APP_TIMEZONE=${APP_TIMEZONE}

# 数据库（Docker 里独立的 MySQL，第一次启动时用这些密码初始化，之后不要再改）
DB_NAME=daily_routine
DB_USER=routine
DB_PASSWORD=$(rand)
MYSQL_ROOT_PASSWORD=$(rand)
${PIP_LINE}
EOF
  chmod 600 .env
fi

# ------------------------------------------------------------ 3. 启动
say "构建并启动容器（第一次需要几分钟）"
docker compose up -d --build

say "等待服务就绪"
PORT_NOW="$(grep -E '^HOST_PORT=' .env | cut -d= -f2)"; PORT_NOW="${PORT_NOW:-9090}"
ok=0
for _ in $(seq 1 90); do
  if curl -fs "http://127.0.0.1:${PORT_NOW}/api/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [ "$ok" -ne 1 ]; then
  docker compose ps
  die "服务没有正常启动，请查看日志：cd ${APP_DIR} && docker compose logs --tail 80"
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
say "部署完成"
echo "  打开：http://${IP:-服务器IP}:${PORT_NOW}"
echo "  云服务器还需要在安全组里放行 ${PORT_NOW} 端口；绑定域名时反向代理到 http://127.0.0.1:${PORT_NOW}"
echo
echo "  常用命令（在 ${APP_DIR} 目录下）："
echo "    查看状态  docker compose ps"
echo "    查看日志  docker compose logs -f app"
echo "    重启      docker compose restart app"
echo "    更新      网页上点“立即更新”，或运行 ./update.sh"
