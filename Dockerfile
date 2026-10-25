# syntax=docker/dockerfile:1
#
# LCRP8 —— 由 tokumeikoi/lcrp8 逆向还原后重建的「自维护版」
#
#   原始镜像 : tokumeikoi/lcrp8:latest  (2023-05-20 构建, PHP 8.0.25, alpine 3.15)
#   原始仓库 : https://github.com/tokumeikoi/lcrp  @ 63adc81f  (仓库已删除/404)
#   还原方式 : OCI provenance attestation + 镜像层解包
#
# 与原始镜像的差别只有三处：
#   1. 基础镜像 alpine 3.15 → 3.24（3.15 已 EOL），PHP 8.0 → 8.4（8.0 已 EOL 且无补丁）
#   2. Caddy 从官方镜像取二进制，不再把 38MB 的 2023 年版二进制塞进仓库
#   3. 加了 /etc/php8、php8、php-fpm8 兼容软链 —— 原有 Caddyfile / supervisord.conf /
#      crontab / 启动脚本里的路径不用改
#
# 构建：
#   docker build -t lcrp8:8.4 .
#   docker build -t lcrp8:8.3 --build-arg PHP_MAJOR=83 .
#   docker build -t lcrp8:8.4 --build-arg APK_MIRROR=https://mirrors.aliyun.com/alpine .
#
# 目录布局与原始镜像保持一致：/www（代码）、/wwwlogs（日志）、/run/caddy/Caddyfile（外挂）、
# /run/supervisor/supervisord.conf（外挂附加配置）、php-fpm 监听 /tmp/php-cgi.sock

ARG ALPINE_VERSION=3.24
ARG PHP_MAJOR=84

# ---------------------------------------------------------------------------
# stage 1：取 Caddy 二进制（官方镜像多架构，跟随 caddy 安全更新）
# ---------------------------------------------------------------------------
FROM caddy:2-alpine AS caddy

# ---------------------------------------------------------------------------
# stage 2：运行时
# ---------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION}

ARG ALPINE_VERSION
ARG PHP_MAJOR
# 国内构建可换成 https://mirrors.aliyun.com/alpine 或 https://mirrors.ustc.edu.cn/alpine
ARG APK_MIRROR=https://dl-cdn.alpinelinux.org/alpine

LABEL org.opencontainers.image.title="lcrp8" \
      org.opencontainers.image.description="Caddy + PHP-FPM + Redis + Supervisor (LCRP stack), rebuilt from tokumeikoi/lcrp8" \
      org.opencontainers.image.source="https://github.com/tokumeikoi/lcrp" \
      org.opencontainers.image.licenses="MIT"

# 1) 显式写死仓库地址（community 里才有 php8x 包），顺带支持国内镜像源
# 2) apk upgrade：把基础系统补到最新安全版本
# 3) 装包：与原始镜像的 apk add 列表逐项对齐，仅两处差异：
#      - php8-zlib  → 新版 Alpine 已把 zlib 编进 php 主程序，无此独立包
#      - php8-json  → PHP 8 起 json 恒定内置，无此独立包
#      - php8-redis → 改名为 php8x-pecl-redis
RUN set -eux; \
    printf '%s\n%s\n' \
        "${APK_MIRROR}/v${ALPINE_VERSION#v}/main" \
        "${APK_MIRROR}/v${ALPINE_VERSION#v}/community" > /etc/apk/repositories; \
    apk upgrade --no-cache; \
    apk add --no-cache \
        bash curl git supervisor redis \
        php${PHP_MAJOR} \
        php${PHP_MAJOR}-fpm \
        php${PHP_MAJOR}-pecl-redis \
        php${PHP_MAJOR}-bcmath \
        php${PHP_MAJOR}-ctype \
        php${PHP_MAJOR}-curl \
        php${PHP_MAJOR}-dom \
        php${PHP_MAJOR}-fileinfo \
        php${PHP_MAJOR}-gd \
        php${PHP_MAJOR}-gettext \
        php${PHP_MAJOR}-gmp \
        php${PHP_MAJOR}-iconv \
        php${PHP_MAJOR}-intl \
        php${PHP_MAJOR}-mbstring \
        php${PHP_MAJOR}-mysqli \
        php${PHP_MAJOR}-opcache \
        php${PHP_MAJOR}-openssl \
        php${PHP_MAJOR}-pcntl \
        php${PHP_MAJOR}-pdo \
        php${PHP_MAJOR}-pdo_mysql \
        php${PHP_MAJOR}-pdo_sqlite \
        php${PHP_MAJOR}-phar \
        php${PHP_MAJOR}-posix \
        php${PHP_MAJOR}-session \
        php${PHP_MAJOR}-simplexml \
        php${PHP_MAJOR}-sockets \
        php${PHP_MAJOR}-sodium \
        php${PHP_MAJOR}-sqlite3 \
        php${PHP_MAJOR}-sysvsem \
        php${PHP_MAJOR}-tokenizer \
        php${PHP_MAJOR}-xml \
        php${PHP_MAJOR}-xmlreader \
        php${PHP_MAJOR}-xmlwriter \
        php${PHP_MAJOR}-zip

# 目录（与原镜像完全一致）
RUN mkdir -p /www /wwwlogs /run/php /run/caddy /run/supervisor

# 配置文件：与原镜像 byte-identical，路径改成新版 php 的 /etc/php8x
COPY config/php-fpm.conf /tmp/php-fpm.conf
COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
# 兼容层：让老配置/老脚本继续按 php8 的路径工作
#   /etc/php8 -> /etc/php84   （挂 php.ini 请改挂 /etc/php84/php.ini）
#   php8 / php-fpm8 / php     （supervisord.conf 里的 `php-fpm8 -RF` 不用改）
RUN set -eux; \
    mv /tmp/php-fpm.conf "/etc/php${PHP_MAJOR}/php-fpm.d/www.conf"; \
    ln -sfn "/etc/php${PHP_MAJOR}" /etc/php8; \
    ln -sf "/usr/bin/php${PHP_MAJOR}" /usr/local/bin/php8; \
    ln -sf "/usr/sbin/php-fpm${PHP_MAJOR}" /usr/local/bin/php-fpm8; \
    ln -sf "/usr/bin/php${PHP_MAJOR}" /usr/local/bin/php; \
    php -v

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy

WORKDIR /www
EXPOSE 443 80
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
