#!/usr/bin/env bash
# 作息打卡（DailyRoutineTracker）—— Linux 服务器一键安装
#
# 用法（在服务器上以 root 运行）：
#   curl -fsSL --retry 5 --retry-all-errors -o install.sh https://raw.githubusercontent.com/Friday770/daily-routine-tracker/main/install.sh
#   sudo bash install.sh            # 换端口：sudo PORT=9090 bash install.sh
#
# 服务器连不上 GitHub 时（国内服务器常见）：把项目包上传到服务器，解压后在项目目录里运行
#   sudo bash install.sh
#
# 服务器上已有 MySQL / MariaDB（包括宝塔面板装的）时，直接使用，不会再下载安装（需要输入它的 root 密码）。
#
# 可用环境变量修改默认值，例如：
#   curl -fsSL .../install.sh | sudo PORT=9000 APP_TIMEZONE=Asia/Shanghai bash
#
#   APP_DIR       安装目录            默认 /opt/daily-routine-tracker
#   APP_USER      运行服务的系统用户  默认 routine
#   PORT          网页端口            默认 8000
#   APP_TIMEZONE  统一时区            默认 Asia/Shanghai
#   REPO / BRANCH GitHub 仓库和分支
#
# 支持 Ubuntu / Debian（apt）和 Rocky / AlmaLinux / CentOS Stream / Fedora（dnf）。
# 重复运行是安全的：已有的数据库和 .env 会保留，只补齐缺少的部分。
set -euo pipefail

REPO="${REPO:-https://github.com/Friday770/daily-routine-tracker.git}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/daily-routine-tracker}"
APP_USER="${APP_USER:-routine}"
PORT="${PORT:-8000}"
APP_TIMEZONE="${APP_TIMEZONE:-Asia/Shanghai}"
SERVICE="daily-routine"
DB_NAME="daily_routine"
DB_USER="routine"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m注意：%s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m错误：%s\033[0m\n' "$*" >&2; exit 1; }
ask()  { # ask "提示" 默认值 —— 通过 curl | bash 运行时从终端读取
  local ans=""
  if [ -r /dev/tty ]; then read -r -p "$1" ans < /dev/tty || true; fi
  echo "${ans:-$2}"
}
askpw() { # 输入时不显示
  local ans=""
  if [ -r /dev/tty ]; then read -r -s -p "$1" ans < /dev/tty || true; echo >&2; fi
  echo "$ans"
}

[ "$(id -u)" -eq 0 ] || die "请用 root 运行：curl -fsSL <地址> | sudo bash"

# ------------------------------------------------------------ 1. 安装软件
# 先检测服务器上是否已经有 MySQL / MariaDB。只要已经有，就直接使用，绝不再下载安装第二个
#（两个数据库会抢 3306 端口，后装的那个启动失败）。
#   MYSQL_STATE: bt 宝塔面板装的 / running 正在运行 / installed 已安装但没运行 / none 没有
MYSQL_STATE="none"; MYSQL_DESC=""; MYSQL_BIN=""
pkg_ok() { # 软件包已完整安装
  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
  elif command -v rpm >/dev/null 2>&1; then
    rpm -q "$1" >/dev/null 2>&1
  else
    return 1
  fi
}
detect_mysql() {
  if [ -x /www/server/mysql/bin/mysqld ] || [ -x /www/server/mysql/bin/mysql ]; then
    MYSQL_STATE="bt"; MYSQL_DESC="宝塔面板的 MySQL"; MYSQL_BIN="/www/server/mysql/bin/mysql"
  elif pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd >/dev/null 2>&1; then
    MYSQL_STATE="running"; MYSQL_DESC="正在运行的 MySQL / MariaDB"
  elif (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -qE '[:.]3306[[:space:]]'; then
    MYSQL_STATE="running"; MYSQL_DESC="3306 端口上正在运行的数据库"
  elif [ -x /usr/local/mysql/bin/mysqld ]; then
    MYSQL_STATE="installed"; MYSQL_DESC="/usr/local/mysql 下的 MySQL"; MYSQL_BIN="/usr/local/mysql/bin/mysql"
  elif pkg_ok mysql-server || pkg_ok mysql-server-8.0 || pkg_ok mysql-community-server \
       || pkg_ok mariadb-server || pkg_ok default-mysql-server; then
    MYSQL_STATE="installed"; MYSQL_DESC="已安装的 MySQL / MariaDB"
  fi
}
find_mysql_client() {
  local c
  for c in "$MYSQL_BIN" /www/server/mysql/bin/mysql /usr/local/mysql/bin/mysql "$(command -v mysql 2>/dev/null)" "$(command -v mariadb 2>/dev/null)"; do
    if [ -n "$c" ] && [ -x "$c" ]; then MYSQL_BIN="$c"; return 0; fi
  done
  return 1
}

detect_mysql
if [ "$MYSQL_STATE" = "none" ]; then
  echo "没有检测到 MySQL，将安装 MySQL"
else
  echo "检测到${MYSQL_DESC}，直接使用，不再下载安装 MySQL"
fi

if [ "$MYSQL_STATE" = "none" ]; then say "安装系统软件（git、Python、MySQL）"; else say "安装系统软件（git、Python）"; fi
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  # 之前和已有 MySQL 冲突、装了一半的系统 MySQL 会让 apt 一直报错，先卸掉（不影响已有的数据库）
  if [ "$MYSQL_STATE" != "none" ] && dpkg -l mysql-server-8.0 2>/dev/null | grep -qE '^(iU|iF|iH|rF|rU|pF)'; then
    warn "清理之前装了一半的系统 MySQL（mysql-server-8.0），不影响${MYSQL_DESC}"
    apt-get remove -y mysql-server mysql-server-8.0 || dpkg --remove --force-depends mysql-server mysql-server-8.0 || true
  fi
  if [ "$MYSQL_STATE" = "none" ] && dpkg -l mysql-server-8.0 2>/dev/null | grep -qE '^(iU|iF|iH)'; then
    warn "系统 MySQL 上次没装完，尝试继续配置"
    dpkg --configure -a || die "MySQL 配置失败。请运行下面的命令，把输出发给开发者：
  journalctl -u mysql -n 50 --no-pager; tail -n 50 /var/log/mysql/error.log"
    detect_mysql
  fi
  apt-get update -y
  apt-get install -y git curl python3 python3-venv python3-pip
  if [ "$MYSQL_STATE" = "none" ]; then
    if apt-cache show mysql-server >/dev/null 2>&1; then
      apt-get install -y mysql-server
    else
      warn "软件源里没有 MySQL，改装 MariaDB"
      apt-get install -y mariadb-server
    fi
  elif ! find_mysql_client; then
    echo "已有数据库但没有 mysql 命令行客户端，只安装客户端"
    apt-get install -y mysql-client || apt-get install -y default-mysql-client || apt-get install -y mariadb-client
  fi
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y git curl python3 python3-pip
  if [ "$MYSQL_STATE" = "none" ]; then
    dnf install -y mysql-server || dnf install -y mariadb-server
  elif ! find_mysql_client; then
    echo "已有数据库但没有 mysql 命令行客户端，只安装客户端"
    dnf install -y mysql || dnf install -y mariadb
  fi
else
  die "只支持 apt（Ubuntu/Debian）或 dnf（Rocky/Alma/CentOS/Fedora）的系统"
fi
find_mysql_client || die "找不到 mysql 命令行客户端"
echo "使用数据库客户端：$MYSQL_BIN"

# 选一个 3.9 及以上的 Python
PY=""
for c in python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
    PY="$(command -v "$c")"; break
  fi
done
[ -n "$PY" ] || die "需要 Python 3.9 及以上。dnf 系统可以：dnf install -y python3.11"
echo "使用 $("$PY" --version)"

if [ "$MYSQL_STATE" = "none" ] || [ "$MYSQL_STATE" = "installed" ]; then
  say "启动数据库服务"
  for s in mysql mysqld mariadb; do
    if systemctl list-unit-files "$s.service" 2>/dev/null | grep -q "$s.service"; then
      systemctl enable --now "$s" && break
    fi
  done
  for _ in $(seq 1 30); do mysqladmin ping >/dev/null 2>&1 && break; sleep 1; done
fi

# 连不上 PyPI 官方源时，改用阿里云镜像安装 Python 依赖
if [ -z "${PIP_INDEX_URL:-}" ] && ! curl -s -m 8 -o /dev/null https://pypi.org/simple/pip/; then
  export PIP_INDEX_URL="https://mirrors.aliyun.com/pypi/simple/"
  echo "PyPI 访问较慢，改用镜像 $PIP_INDEX_URL"
fi

# ------------------------------------------------------------ 2. 下载项目
say "准备项目文件 $APP_DIR"
id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || pwd)"
if [ -f "$APP_DIR/app.py" ]; then
  echo "项目文件已在 ${APP_DIR}，保留现有代码（更新请运行 $APP_DIR/update.sh）"
elif [ -f "$SRC_DIR/app.py" ] && [ "$SRC_DIR" != "$APP_DIR" ]; then
  echo "使用上传的项目文件：$SRC_DIR"
  mkdir -p "$APP_DIR"
  cp -a "$SRC_DIR/." "$APP_DIR/"
  rm -rf "$APP_DIR/.venv"
else
  [ -e "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ] && die "$APP_DIR 已存在且不是空目录"
  ok=0
  for i in 1 2 3 4 5; do
    if git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 clone --branch "$BRANCH" "$REPO" "$APP_DIR"; then
      ok=1; break
    fi
    rm -rf "$APP_DIR"
    echo "从 GitHub 下载失败，${i} 秒后重试（第 ${i}/5 次）..."
    sleep "$i"
  done
  [ "$ok" -eq 1 ] || die "从 GitHub 下载失败（国内服务器常见），可以稍后重新运行本脚本；
  或者把项目包上传到服务器，解压后进入项目目录运行：sudo bash install.sh"
fi
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
run_as() { runuser -u "$APP_USER" -- "$@"; }

# ------------------------------------------------------------ 3. 数据库
say "准备数据库"
MYSQL=("$MYSQL_BIN" --default-character-set=utf8mb4)
if ! "${MYSQL[@]}" -uroot -e "SELECT 1" >/dev/null 2>&1; then
  echo "需要 MySQL 的 root 密码。宝塔面板：左侧“数据库” → 右上角“root 密码”里可以查看或修改。"
  for _ in 1 2 3; do
    ROOTPW="$(askpw "请输入 MySQL root 密码：")"
    MYSQL=("$MYSQL_BIN" --default-character-set=utf8mb4 -uroot "-p$ROOTPW")
    "${MYSQL[@]}" -e "SELECT 1" >/dev/null 2>&1 && break
    echo "密码不对，请重试。"
  done
  "${MYSQL[@]}" -e "SELECT 1" >/dev/null 2>&1 || die "MySQL root 登录失败"
else
  MYSQL=("$MYSQL_BIN" --default-character-set=utf8mb4 -uroot)
fi
echo "MySQL 版本：$("${MYSQL[@]}" -N -e "SELECT VERSION()")"

if "${MYSQL[@]}" -N -e "SELECT 1 FROM information_schema.tables WHERE table_schema='$DB_NAME' AND table_name='schedule'" | grep -q 1; then
  echo "数据库 $DB_NAME 已存在，保留现有数据"
else
  "${MYSQL[@]}" < "$APP_DIR/daily_routine.sql"
  echo "已导入 daily_routine.sql（干净的数据库：作息安排，没有打卡记录）"
fi

ENV="$APP_DIR/.env"
if [ -f "$ENV" ]; then
  DB_PASS="$(grep -E '^DB_PASSWORD=' "$ENV" | cut -d= -f2- || true)"
fi
if [ -z "${DB_PASS:-}" ] || printf '%s' "$DB_PASS" | grep -q '填写'; then
  DB_PASS="$("$PY" -c 'import secrets; print(secrets.token_urlsafe(18))')"
fi
for h in localhost 127.0.0.1; do
  "${MYSQL[@]}" -e "CREATE USER IF NOT EXISTS '$DB_USER'@'$h' IDENTIFIED BY '$DB_PASS';
                    ALTER USER '$DB_USER'@'$h' IDENTIFIED BY '$DB_PASS';
                    GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'$h';"
done
"${MYSQL[@]}" -e "FLUSH PRIVILEGES;"
echo "数据库账号 $DB_USER 已就绪（密码随机生成，保存在 .env）"

# ------------------------------------------------------------ 4. 配置 .env
say "生成配置 $ENV"
cat > "$ENV" <<EOF
# 由 install.sh 生成。修改后运行：sudo systemctl restart $SERVICE
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASS
DB_NAME=$DB_NAME

HOST=0.0.0.0
PORT=$PORT
APP_TIMEZONE=$APP_TIMEZONE
EOF
chown "$APP_USER:$APP_USER" "$ENV"
chmod 600 "$ENV"

# ------------------------------------------------------------ 5. Python 依赖
say "安装 Python 依赖"
[ -x "$APP_DIR/.venv/bin/python" ] || run_as "$PY" -m venv "$APP_DIR/.venv"
run_as "$APP_DIR/.venv/bin/python" -m pip install --quiet --upgrade pip
run_as "$APP_DIR/.venv/bin/python" -m pip install --quiet -r "$APP_DIR/requirements.txt"
chmod +x "$APP_DIR"/*.sh

# ------------------------------------------------------------ 6. 系统服务
say "注册系统服务 ${SERVICE}（开机自启、崩溃自动重启）"
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=DailyRoutineTracker (作息打卡)
After=network-online.target mysql.service mysqld.service mariadb.service
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/.venv/bin/python app.py
Restart=always
RestartSec=2
Environment=HOME=$APP_DIR

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null
systemctl restart "$SERVICE"

# 防火墙放行端口
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "$PORT/tcp" >/dev/null && echo "ufw 已放行 $PORT 端口"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null && firewall-cmd --reload >/dev/null && echo "firewalld 已放行 $PORT 端口"
fi

# ------------------------------------------------------------ 7. 检查
say "检查服务"
ok=0
for _ in $(seq 1 20); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/apple-touch-icon.png" || true)"
  [ "$code" = "200" ] && { ok=1; break; }
  sleep 1
done
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [ "$ok" -eq 1 ]; then
  say "安装完成"
  echo "  打开：http://${IP:-服务器IP}:$PORT"
  echo "  云服务器还需要在控制台的安全组里放行 $PORT 端口"
  echo
  echo "  常用命令："
  echo "    查看状态  systemctl status $SERVICE"
  echo "    查看日志  journalctl -u $SERVICE -f"
  echo "    重启      systemctl restart $SERVICE"
  echo "    更新      sudo $APP_DIR/update.sh   （网页上也会提示新版本）"
else
  die "服务没有正常启动，请查看：journalctl -u $SERVICE -n 50"
fi
