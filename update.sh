#!/usr/bin/env bash
# 作息打卡 —— 检查 GitHub 上的新版本并更新
#
#   ./update.sh          检查更新，有新版本时询问是否更新
#   ./update.sh --yes    有新版本直接更新，不询问
#
# 网页上点“立即更新”时，后端也会调用本脚本（--yes --from-app --pid 后端进程号）。
# 更新内容：拉取最新代码 → 安装依赖 → 重启后端（重启时自动执行数据库变更）。
# 打卡数据保存在 MySQL 里，更新不会影响。
set -euo pipefail
cd "$(dirname "$0")"

BRANCH="${UPDATE_BRANCH:-main}"
SERVICE="${SERVICE_NAME:-daily-routine}"
YES=0; FROM_APP=0; APP_PID=""
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) YES=1 ;;
    --from-app) FROM_APP=1 ;;
    --pid) APP_PID="${2:-}"; shift ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "错误：$*"; exit 1; }

[ -d .git ] || die "当前目录不是 git 仓库，请用 install.sh 安装后再在线更新"

# 用 root 运行时，以项目目录的所有者身份执行 git / pip，避免改乱文件权限
OWNER="$(stat -c %U . 2>/dev/null || stat -f %Su .)"
as_owner() {
  if [ "$(id -u)" -eq 0 ] && [ "$OWNER" != "root" ]; then
    runuser -u "$OWNER" -- "$@"
  else
    "$@"
  fi
}

log "检查更新（分支 ${BRANCH}）..."
as_owner git fetch --quiet origin "$BRANCH" || die "连不上 GitHub"
BEHIND="$(as_owner git rev-list --count "HEAD..origin/$BRANCH")"
CUR="$(as_owner git rev-parse --short HEAD)"
NEW="$(as_owner git rev-parse --short "origin/$BRANCH")"
if [ "$BEHIND" -eq 0 ]; then
  log "已经是最新版本（${CUR}）。"
  exit 0
fi

echo "发现 $BEHIND 个更新：$CUR → $NEW"
as_owner git log --format='  - %s' "HEAD..origin/$BRANCH" | head -20

if [ "$YES" -ne 1 ]; then
  if [ -r /dev/tty ]; then
    read -r -p "是否更新？[y/N] " ans < /dev/tty
  else
    ans="n"
  fi
  case "$ans" in y|Y|yes|YES) ;; *) echo "已取消。"; exit 0 ;; esac
fi

log "下载新版本..."
as_owner git merge --ff-only "origin/$BRANCH" \
  || die "服务器上的代码被手动改过，无法自动合并。请先处理（git status 查看），或运行：git reset --hard origin/$BRANCH"

if [ -x .venv/bin/python ]; then
  log "安装依赖..."
  as_owner .venv/bin/python -m pip install --quiet --disable-pip-version-check -r requirements.txt \
    || die "依赖安装失败"
fi

log "重启后端..."
if [ "$FROM_APP" -eq 1 ] && [ -n "$APP_PID" ]; then
  if [ -n "${INVOCATION_ID:-}" ]; then
    # 由 systemd 管理：结束旧进程后 systemd 会自动用新代码重启（Restart=always）
    kill "$APP_PID" 2>/dev/null || true
  else
    # 手动用 start.sh 运行的：结束旧进程，再在后台启动新进程
    kill "$APP_PID" 2>/dev/null || true
    for _ in $(seq 1 40); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
    mkdir -p logs
    nohup .venv/bin/python app.py >> logs/app.log 2>&1 < /dev/null &
    log "已在后台启动新版本（日志：logs/app.log）"
  fi
elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
  if [ "$(id -u)" -eq 0 ]; then systemctl restart "$SERVICE"; else sudo systemctl restart "$SERVICE"; fi
else
  log "请手动重启后端（例如重新运行 ./start.sh）。"
fi
log "更新完成：$CUR → $NEW"
