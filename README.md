# DailyRoutineTracker v1.2

English | [中文](README.zh-CN.md)

DailyRoutineTracker is a small self-hosted web app for sticking to a fixed daily schedule. It shows what you should be doing right now and how much time is left, and lets you check in with one big button: tap **Start** when a study block begins and **End** when it finishes, and the app records how long you actually studied. Rest, meals and other non-study blocks need no check-in. Missed blocks can be made up later from the full schedule view. Daily and weekly stats are shown as combined bar and line charts. Open it on your phone and your computer at the same time and every check-in syncs to the other device within a second.

The UI text is in Chinese.

## Features

- "Now" view with the current block, remaining time and a one-tap check-in button
- Two check-ins per study block: Start (from 1 min before it begins) and End (1 min before to 5 min after it ends)
- Make-up check-ins, skip and undo for the last 7 days
- Full schedule view with color-coded status (done, partial, missed, upcoming)
- Daily and weekly stats: check-in rate, study completion rate, hours per task, bar + line charts
- Real-time sync between devices (Server-Sent Events)
- One-command server install, and in-app update notices with one-click update
- Docker deployment (app + MySQL containers)
- Configurable time zone
- Mobile friendly; works well on iPhone and can be added to the home screen

**Tech stack:** Python (FastAPI, Uvicorn, PyMySQL) · MySQL 8 · plain HTML/CSS/JavaScript, no build step

```
daily-routine-tracker/
├── app.py                 backend (FastAPI), also serves the page
├── static/                web page and home-screen icon
├── daily_routine.sql      clean database: tables, stats views, initial schedule, no check-ins
├── migrations/            future schema changes, applied automatically on start
├── requirements.txt
├── .env.example           configuration template
├── Dockerfile, docker-compose.yml   Docker deployment
├── docker-install.sh      one-command Docker deployment
├── install.sh             one-command install without Docker
├── update.sh              check for and install new versions
├── setup.sh / init_db.sh / start.sh   for manual installs
└── deploy/                systemd unit and nginx example
```

## Deploy with Docker (recommended)

Requires Docker with the compose plugin on the server. Run:

```bash
curl -fsSL --retry 5 --retry-all-errors -o docker-install.sh https://raw.githubusercontent.com/Friday770/daily-routine-tracker/main/docker-install.sh
sudo bash docker-install.sh
```

The default port is 9090; change it with `sudo HOST_PORT=8080 bash docker-install.sh`. The script clones the project to `/opt/daily-routine-tracker`, writes `.env` with random database passwords and starts two containers: `app` (web + backend) and `db` (a separate MySQL 8.4 with its data in a Docker volume; an existing MySQL on the host is not touched). Both restart automatically.

```bash
docker compose ps              # status   (run in /opt/daily-routine-tracker)
docker compose logs -f app     # logs
docker compose restart app     # restart
```

**Updating:** click "立即更新" when the page shows a new version; the container pulls the code, applies migrations and restarts itself. Or run `sudo ./update.sh` on the server.

## Install without Docker

Supports Ubuntu / Debian and Rocky / AlmaLinux / CentOS Stream / Fedora. On the server:

```bash
curl -fsSL --retry 5 --retry-all-errors -o install.sh https://raw.githubusercontent.com/Friday770/daily-routine-tracker/main/install.sh
sudo bash install.sh
```

The script installs git, Python and MySQL, clones the project to `/opt/daily-routine-tracker`, imports the clean database and creates a database user with a random password, writes `.env`, installs the Python packages, registers the `daily-routine` systemd service (starts on boot, restarts on crash) and opens the firewall port.

Then open `http://SERVER_IP:8000`. On a cloud server, also allow port 8000 in the provider's security group.

Defaults can be changed with environment variables (after downloading install.sh as above):

```bash
sudo PORT=9000 bash install.sh
```

| Variable | Default | Meaning |
|---|---|---|
| `APP_DIR` | `/opt/daily-routine-tracker` | install directory |
| `PORT` | `8000` | web port |
| `APP_TIMEZONE` | `Asia/Shanghai` | time zone used everywhere |
| `APP_USER` | `routine` | system user that runs the service |

Running the installer again is safe: an existing database and `.env` are kept.

**An existing MySQL is never reinstalled**: if MySQL or MariaDB is already present (BaoTa, running, or installed but stopped), the installer uses it and only adds the `mysql` client if missing; it asks for that server's root password.

```bash
systemctl status daily-routine          # status
journalctl -u daily-routine -f          # logs
sudo systemctl restart daily-routine    # restart after editing .env
```

### Servers in mainland China / BaoTa panel

- **GitHub unreachable** (e.g. `curl: (35) Connection reset by peer`): download the project (Code → Download ZIP, or a provided `daily-routine-tracker.tar.gz`), upload and extract it on the server, then run inside the project folder: `sudo PORT=9090 bash install.sh`
- **MySQL already installed by BaoTa**: the installer uses it instead of installing a second MySQL, and asks for its root password. A half-installed system MySQL from an earlier failed run is removed automatically.
- **Slow PyPI**: the installer switches to the Aliyun PyPI mirror automatically.
- **Online updates** need access to GitHub. Without it, upload a newer package, extract it over the install directory and run `sudo systemctl restart daily-routine`.

## Updating

When a new version is pushed to GitHub:

- **In the web page:** a "发现新版本" (new version) notice appears at the top with the list of changes. Click **立即更新** (update now): the server pulls the new code, installs dependencies, applies database migrations and restarts; the page reloads by itself after about half a minute.
- **On the server:** run `sudo /opt/daily-routine-tracker/update.sh`. It shows the changes and asks before updating; add `--yes` to skip the question.

The server checks for updates every 30 minutes. Check-in data lives in MySQL and is not affected by updates.

## Configuration

`.env` (created by the installer; see `.env.example`):

| Key | Meaning |
|---|---|
| `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` | MySQL connection |
| `HOST`, `PORT` | listen address and port (`127.0.0.1` when behind nginx) |
| `APP_TIMEZONE` | time zone for the page, check-in rules and stats, e.g. `Asia/Shanghai` |

For a domain name and HTTPS, see `deploy/nginx.conf`. Keep its `/api/events` block: it disables buffering, which real-time sync needs. Run only one backend process.

## Check-in rules

Only study blocks need check-ins (categories `study` and `plan`, i.e. study, review and planning).

| Check-in | When | Notes |
|---|---|---|
| Start | from 1 min before the block until 1 min before it ends | starting late is allowed |
| End | from 1 min before the block ends until 5 min after | duration = end − start; ≥ 90% of plan counts as done, otherwise partial |

After the end window a block counts as missed and can be made up from the full schedule (marked as make-up). Nothing can be checked in early.

## Changing the schedule

Edit the `schedule` table. Do not change old rows, or past statistics change too: set `valid_to` on the old rows and insert new rows with a new `valid_from`. See the Chinese README for an example.

## Developing

```bash
./setup.sh          # create .venv, install packages, create .env
./init_db.sh        # import daily_routine.sql into a local MySQL
./start.sh          # run on http://localhost:8000
```

Schema changes go into `migrations/` as numbered `.sql` files; see `migrations/README.md`.
