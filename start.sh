#!/usr/bin/env bash
# 作息打卡 —— 在前台启动后端（调试用；长期运行请用 deploy/daily-routine.service）
set -euo pipefail
cd "$(dirname "$0")"
[ -x .venv/bin/python ] || { echo "请先运行 ./setup.sh" >&2; exit 1; }
[ -f .env ] || { echo "缺少 .env，请先运行 ./setup.sh 并编辑 .env" >&2; exit 1; }
exec .venv/bin/python app.py
