# DailyRoutineTracker 后端镜像
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    RUNNING_IN_DOCKER=1

# git：网页上的“检查更新 / 立即更新”需要它
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/* \
 && git config --system --add safe.directory '*'

WORKDIR /app
# 国内服务器构建时可传入镜像源：docker compose build --build-arg PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
ARG PIP_INDEX_URL=""
COPY requirements.txt .
RUN pip install --no-cache-dir ${PIP_INDEX_URL:+-i $PIP_INDEX_URL} -r requirements.txt

# 代码在 docker-compose.yml 里以目录挂载的方式提供（/app），这样在线更新后重启容器即可生效
COPY . .

EXPOSE 8000
CMD ["python", "app.py"]
