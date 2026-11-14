# DailyRoutineTracker（作息打卡）v1.2

[English](README.md) | 中文

自己部署的作息打卡网页：显示现在该做什么、还剩多少时间；学习时间用一个大按钮打“开始学习”和“结束学习”两次卡，自动记录实际学习时长；休息、用餐等非学习时间不需要打卡。错过的可以在完整作息表里补打卡。每日 / 每周统计用柱状图 + 折线图展示。手机和电脑同时打开时，任何一端打卡，另一端约 1 秒内自动更新。

技术栈：Python（FastAPI、Uvicorn、PyMySQL）· MySQL 8 · 原生 HTML/CSS/JavaScript（无需构建）

```
daily-routine-tracker/
├── app.py                       后端（FastAPI），同时提供网页
├── static/                      网页和主屏幕图标
├── daily_routine.sql            干净的数据库：表、统计视图、初始作息，没有打卡记录
├── migrations/                  以后的数据库变更（启动时自动执行）
├── requirements.txt             Python 依赖
├── .env.example                 配置模板
├── Dockerfile / docker-compose.yml   Docker 部署
├── docker-install.sh            Docker 一键部署
├── install.sh                   不用 Docker 时的一键安装
├── update.sh                    检查并安装新版本
├── setup.sh / init_db.sh / start.sh   手动安装用
└── deploy/                      systemd 服务、nginx 配置示例
```

## 用 Docker 部署（推荐）

服务器上需要已安装 Docker（宝塔面板可在“Docker”里一键安装）。运行：

```bash
curl -fsSL --retry 5 --retry-all-errors -o docker-install.sh https://raw.githubusercontent.com/Friday770/daily-routine-tracker/main/docker-install.sh
sudo bash docker-install.sh
```

默认端口 9090，换端口：`sudo HOST_PORT=8080 bash docker-install.sh`。

脚本会把项目下载到 `/opt/daily-routine-tracker`，生成 `.env`（数据库密码随机生成），然后启动两个容器：
- `app`：网页和后端；
- `db`：独立的 MySQL 8.4，数据保存在 Docker 数据卷里，不会碰服务器上已有的 MySQL（包括宝塔的）。

容器设置了自动重启，服务器重启后也会自动运行。打开 `http://服务器IP:9090`；云服务器要在安全组里放行这个端口。绑定域名时，宝塔反向代理的目标填 `http://127.0.0.1:9090`。

常用命令（在 `/opt/daily-routine-tracker` 下）：

```bash
docker compose ps              # 状态
docker compose logs -f app     # 日志
docker compose restart app     # 重启
```

**更新**：网页上出现“发现新版本”时点“立即更新”即可，容器会自动拉取新代码、执行数据库变更并重启。也可以在服务器上运行 `sudo ./update.sh`。

## 不用 Docker：一键安装（Linux 服务器）

支持 Ubuntu / Debian 和 Rocky / AlmaLinux / CentOS Stream / Fedora。在服务器上运行：

```bash
curl -fsSL --retry 5 --retry-all-errors -o install.sh https://raw.githubusercontent.com/Friday770/daily-routine-tracker/main/install.sh
sudo bash install.sh
```

脚本会：安装 git、Python、MySQL → 下载项目到 `/opt/daily-routine-tracker` → 导入干净的数据库，并新建数据库账号（随机密码）→ 生成 `.env` → 安装依赖 → 注册系统服务 `daily-routine`（开机自启、崩溃自动重启）→ 放行防火墙端口。安装完成后打开 `http://服务器IP:8000`。云服务器还需要在控制台的安全组里放行 8000 端口。

可以用环境变量修改默认值，例如换端口（先用上面的 curl 下载好 install.sh）：

```bash
sudo PORT=9000 bash install.sh
```

| 变量 | 默认值 | 说明 |
|---|---|---|
| `APP_DIR` | `/opt/daily-routine-tracker` | 安装目录 |
| `PORT` | `8000` | 网页端口 |
| `APP_TIMEZONE` | `Asia/Shanghai` | 统一时区 |
| `APP_USER` | `routine` | 运行服务的系统用户 |

重复运行安装脚本是安全的：已有的数据库和配置会保留。

**已有 MySQL 时不会重复安装**：服务器上已经有 MySQL / MariaDB（包括宝塔面板装的、正在运行的、已安装但没启动的）时，脚本会直接使用它，只在缺少 `mysql` 命令行工具时补装客户端；运行时输入它的 root 密码即可。

常用命令：

```bash
systemctl status daily-routine        # 查看状态
journalctl -u daily-routine -f        # 查看日志
sudo systemctl restart daily-routine  # 重启（改了 .env 之后）
```

### 国内服务器 / 宝塔面板

- **连不上 GitHub**（`curl: (35) Connection reset by peer` 等）：在自己电脑上下载项目包（GitHub 页面 Code → Download ZIP，或开发者提供的 `daily-routine-tracker.tar.gz`），用宝塔“文件”或 scp 上传到服务器并解压，然后在项目目录里运行：

  ```bash
  sudo PORT=9090 bash install.sh
  ```

- **已经装了宝塔的 MySQL**：安装脚本会自动使用它，不再另装一个；运行时输入它的 root 密码（宝塔“数据库”页面右上角“root 密码”）。之前装失败、留下一半的系统 MySQL 也会被自动清理。
- **Python 依赖下载慢**：脚本会自动改用阿里云的 PyPI 镜像。
- **在线更新**需要服务器能访问 GitHub；连不上时，网页上不会出现更新提示，可以照上面的方法上传新版本的项目包，解压覆盖后运行 `sudo systemctl restart daily-routine`。

## 更新

GitHub 上有新版本时：

- **网页上**：页面顶部会出现“发现新版本”的提示，列出更新内容。点 **立即更新**，后端会自动下载新代码、安装依赖、执行数据库变更并重启，大约半分钟后页面自动刷新。点“稍后”则这个版本不再提示。
- **服务器上**：运行 `sudo /opt/daily-routine-tracker/update.sh`，有新版本时会询问是否更新；加 `--yes` 则直接更新。

服务器每 30 分钟检查一次更新。打卡数据保存在数据库里，更新不会影响。

## 手动安装

不想用一键脚本时，按下面的步骤操作（以 Ubuntu 为例）。

#### 1. 安装软件

```bash
sudo apt update
sudo apt install -y python3 python3-venv mysql-server
```

需要 Python 3.10 及以上、MySQL 8。

#### 2. 下载项目

```bash
sudo git clone https://github.com/Friday770/daily-routine-tracker.git /opt/daily-routine-tracker
```

#### 3. 建数据库和账号

导入建库脚本（Ubuntu 上 root 默认用系统登录，所以用 `sudo mysql`）：

```bash
cd /opt/daily-routine-tracker
sudo mysql --default-character-set=utf8mb4 < daily_routine.sql
```

给网页建一个专用账号（把密码换成你自己的）：

```bash
sudo mysql -e "CREATE USER 'routine'@'localhost' IDENTIFIED BY '换成你的密码'; GRANT ALL PRIVILEGES ON daily_routine.* TO 'routine'@'localhost';"
```

也可以用 `./init_db.sh` 交互式导入（适合 root 用密码登录的 MySQL）。

#### 4. 安装依赖、填写配置

```bash
./setup.sh
nano .env
```

在 `.env` 里填 `DB_PASSWORD`（上一步设的密码）。

#### 5. 先试运行

```bash
./start.sh
```

看到 `Uvicorn running on http://0.0.0.0:8000` 后，浏览器打开 `http://服务器IP:8000`。没问题就按 `Ctrl + C` 停止。

如果打不开，检查防火墙和云服务器的安全组是否放行 8000 端口：

```bash
sudo ufw allow 8000/tcp
```

#### 6. 设为系统服务（长期运行）

按需修改 `deploy/daily-routine.service` 里的 `User` 和目录，然后：

```bash
sudo useradd --system --home-dir /opt/daily-routine-tracker --shell /usr/sbin/nologin routine
sudo chown -R routine:routine /opt/daily-routine-tracker
sudo cp deploy/daily-routine.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now daily-routine
systemctl status daily-routine
```

之后服务器重启也会自动运行。改了 `.env` 或代码后：`sudo systemctl restart daily-routine`；看日志：`journalctl -u daily-routine -f`。

注意：只能运行 1 个后端进程，实时同步依赖它。

#### 7. 域名和 HTTPS（可选）

用 nginx 反向代理：把 `.env` 里的 `HOST` 改成 `127.0.0.1`，修改 `deploy/nginx.conf` 里的域名，然后：

```bash
sudo apt install -y nginx
sudo cp deploy/nginx.conf /etc/nginx/conf.d/daily-routine.conf
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d 你的域名      # 申请免费 HTTPS 证书（需先 apt install certbot python3-certbot-nginx）
```

`nginx.conf` 里已经为实时同步（`/api/events`）关闭了缓冲，不要删掉那一段，否则手机和电脑之间不会立即同步。


## 时区

`.env` 里的 `APP_TIMEZONE` 决定统一使用的时区（默认 `Asia/Shanghai` 北京时间）。电脑和手机上的页面、后端判断能否打卡、数据库统计的“今天”，都按这个时区，和设备自己的系统时区无关。留空则用服务器的系统时区。修改后需要重启：`sudo systemctl restart daily-routine`。

## 打卡规则

**只有学习时间需要打卡**（科研学习、复盘、规划）。休息、用餐、洗漱、娱乐、睡觉等非学习时间不需要打卡。

每个学习项打**两次卡**，都用主页面中间的蓝色大圆按钮：

| 打卡 | 什么时候可以点 | 说明 |
|---|---|---|
| 开始学习 | 开始前 1 分钟起，到这一项结束前 1 分钟 | 迟到也可以开始；更早的时候按钮是灰色的，点了只提示时间 |
| 结束学习 | 结束前 1 分钟起，到结束后 5 分钟 | 实际学习时长 = 结束 − 开始；达到计划的 90% 算完成，否则算部分完成。没打开始卡也能结束，按计划时长记 |

- 没到时间一律不能打卡。
- 打卡时间内不打算做的项，可以在完整作息表里点它选“跳过”。
- 过了结束打卡时间还没结束的（包括只打了开始卡的），算未打卡，显示红色；可以在完整作息表里补打卡（完成 / 部分完成 / 跳过），记为“补”，不记备注。只能补最近 7 天。
- 点错了可以在完整作息表里点这一项“撤销打卡”。

## 统计指标（只算学习时间）

| 指标 | 算法 |
|---|---|
| 学习打卡率 | （完成项 + 部分完成项 × 0.5）÷ 应打卡的学习项 |
| 学习完成率 | 学习项实际分钟 ÷ 学习项计划分钟 |
| 未打卡 | 时间已过且没有打卡的学习项 |
| 各学习事项 | 本周每个学习事项（深度科研、浅度科研……）的实际 / 计划时长和打卡次数 |

当天还没到的学习项暂时算作“未打卡”，一天结束后才是最终结果。哪些事项需要打卡由 `schedule` 表的 `count_in_rate` 决定（1 需要，0 不需要），默认类别为 `study`、`plan` 的事项是 1。

## 调整作息

不要直接改 `schedule` 表的旧行，否则历史完成率会跟着变。做法是给旧作息填上结束日期，再插入新作息：

```sql
-- 旧的工作日作息到 12 月 11 日为止
UPDATE schedule SET valid_to = '2026-12-11' WHERE day_type = 'week' AND valid_to IS NULL;
-- 再按建库脚本里的格式插入新的作息行，valid_from = '2026-12-12'
```

## 可调参数（app.py 顶部）

| 参数 | 默认 | 含义 |
|---|---|---|
| `START_BEFORE_MIN` | 1 | 开始前多少分钟可以开始学习 |
| `END_BEFORE_MIN` | 1 | 结束前多少分钟可以结束学习 |
| `END_AFTER_MIN` | 5 | 结束后多少分钟内还能结束学习 |
| `MAKEUP_MAX_DAYS` | 7 | 最多能补几天前的卡 |
| `DONE_RATIO` | 0.9 | 计时打卡达到计划时长的多少算完成 |

网页里的 `START_BEFORE`、`END_BEFORE`、`END_AFTER`、`MAX_BACK` 与上面保持一致。
