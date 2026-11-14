#!/usr/bin/env bash
# 作息打卡 —— 第一次安装：建 Python 虚拟环境、安装依赖、生成 .env
set -euo pipefail
cd "$(dirname "$0")"

PY="${PYTHON:-python3}"
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "找不到 python3。Ubuntu/Debian：sudo apt install python3 python3-venv；CentOS/Rocky：sudo dnf install python3" >&2
  exit 1
fi

# 从别的电脑拷来的 .venv 不能用，重新建
if [ ! -x .venv/bin/python ] || ! .venv/bin/python -c "import sys" >/dev/null 2>&1; then
  rm -rf .venv
  echo "创建 Python 虚拟环境..."
  "$PY" -m venv .venv || { echo "创建失败。Ubuntu/Debian 请先：sudo apt install python3-venv" >&2; exit 1; }
fi

echo "安装依赖..."
.venv/bin/python -m pip install --upgrade pip >/dev/null
.venv/bin/python -m pip install -r requirements.txt

if [ ! -f .env ]; then
  cp .env.example .env
  chmod 600 .env
  echo
  echo "已生成 .env，请编辑它，填写 DB_USER / DB_PASSWORD：  nano .env"
fi
echo
echo "安装完成。下一步：./init_db.sh 导入数据库（第一次部署时），然后 ./start.sh 启动。"
