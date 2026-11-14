#!/usr/bin/env bash
# 作息打卡 —— 把 daily_routine.sql 导入 MySQL（新建数据库 daily_routine）
# 注意：如果库里已有同名表，会先删除再重建，已有的打卡记录会丢失。
set -euo pipefail
cd "$(dirname "$0")"

command -v mysql >/dev/null 2>&1 || { echo "找不到 mysql 命令。Ubuntu/Debian：sudo apt install mysql-client（或 mysql-server）" >&2; exit 1; }

echo "将创建数据库 daily_routine，并删除其中已有的表和打卡记录。"
read -r -p "确认继续请输入 YES：" ans
[ "$ans" = "YES" ] || { echo "已取消。"; exit 1; }

read -r -p "MySQL 管理员用户名 [root]：" user
user="${user:-root}"
echo "请输入 $user 的 MySQL 密码（Ubuntu 上 root 若用系统登录，可直接按 Ctrl+C，改用：sudo mysql < daily_routine.sql）"
mysql -u "$user" -p --default-character-set=utf8mb4 < daily_routine.sql
echo "导入完成。"
