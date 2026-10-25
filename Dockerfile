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
#   docker build -t lcrp8:8.4 --build-arg ICU_DATA=en .        # 瘦身版，仅 en_US/GB 数据
#
# 目录布局与原始镜像保持一致：/www（代码）、/wwwlogs（日志）、/run/caddy/Caddyfile（外挂）、
# /run/supervisor/supervisord.conf（外挂附加配置）、php-fpm 监听 /tmp/php-cgi.sock

ARG ALPINE_VERSION=3.24
ARG PHP_MAJOR=84

# ---------------------------------------------------------------------------
# stage 1：取 Caddy 二进制（官方镜像多架构，跟随 caddy 安全更新）
# 固定到具体次版本，避免 :2-alpine 漂移；升级请改这一行（Dependabot 也会提 PR）。
# ---------------------------------------------------------------------------
FROM caddy:2.11.7-alpine AS caddy

# ---------------------------------------------------------------------------
# stage 2：运行时
# ---------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION}

ARG ALPINE_VERSION
ARG PHP_MAJOR
# 国内构建可换成 https://mirrors.aliyun.com/alpine 或 https://mirrors.ustc.edu.cn/alpine
ARG APK_MIRROR=https://dl-cdn.alpinelinux.org/alpine
# full：与原镜像一致的完整 ICU 数据（含 zh 等 locale，约 31.6MiB）
# en  ：仅 en_US/GB，省约 28.7MiB，但非英语 locale 的 intl 排序/格式会退化
ARG ICU_DATA=full
# CI 每次传入新的 run_id，强制 apk 层重建，避免 buildx cache 跳过安全更新；
# 本地默认 0 保留缓存，需要刷新时传 APK_CACHE_BUST=$(date +%s)
ARG APK_CACHE_BUST=0

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
# 4) 构建期拒绝未知 PHP 主版本 / ICU 选项；82 只能配 Alpine 3.22，85 在 3.24 无 opcache
# 5) ICU full 必须在最后装：php8x-intl 会先按 provider_priority 拉入 en 数据，
#    再装 full 才能让完整的 icudt*.dat 覆盖掉 en 的小文件（Alpine 官方推荐做法）
RUN set -eux; \
    case "${PHP_MAJOR}" in \
        82|83|84|85) ;; \
        *) echo "PHP_MAJOR must be one of 82/83/84/85" >&2; exit 1 ;; \
    esac; \
    if [ "${PHP_MAJOR}" = "82" ]; then \
        case "${ALPINE_VERSION#v}" in \
            3.22*) ;; \
            *) echo "PHP 8.2 is only packaged in Alpine 3.22; set ALPINE_VERSION=3.22" >&2; exit 1 ;; \
        esac; \
    fi; \
    echo "apk cache bust: ${APK_CACHE_BUST}"; \
    case "${ICU_DATA}" in \
        en|full) ;; \
        *) echo "ICU_DATA must be en or full" >&2; exit 1 ;; \
    esac; \
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
        php${PHP_MAJOR}-zip; \
    case "${PHP_MAJOR}" in \
        85) echo "WARNING: php85-opcache is not packaged in Alpine ${ALPINE_VERSION}; building without OPcache" >&2 ;; \
        *)  apk add --no-cache "php${PHP_MAJOR}-opcache" ;; \
    esac; \
    case "${ICU_DATA}" in \
        full) apk add --no-cache icu-data-full ;; \
        en)   apk add --no-cache icu-data-en ;; \
    esac; \
    rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

# 目录（与原镜像完全一致）
RUN mkdir -p /www /wwwlogs /run/php /run/caddy /run/supervisor

# 配置文件：FPM / Supervisor 与原镜像保持一致；外加 PHP 安全默认值
COPY config/php-fpm.conf /etc/php${PHP_MAJOR}/php-fpm.d/www.conf
COPY config/php-hardening.ini /etc/php${PHP_MAJOR}/conf.d/99-hardening.ini
COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# 兼容层：让老配置/老脚本继续按 php8 的路径工作
#   /etc/php8 -> /etc/php84   （挂 php.ini 请改挂 /etc/php84/php.ini）
#   php8 / php-fpm8 / php     （supervisord.conf 里的 `php-fpm8 -RF` 不用改）
# 构建期再断言一次 PHP 版本：绕过 build.sh 直接 docker build 也不会发出带已知漏洞的镜像
RUN set -eux; \
    ln -sfn "/etc/php${PHP_MAJOR}" /etc/php8; \
    ln -sf "/usr/bin/php${PHP_MAJOR}" /usr/local/bin/php8; \
    ln -sf "/usr/sbin/php-fpm${PHP_MAJOR}" /usr/local/bin/php-fpm8; \
    ln -sf "/usr/bin/php${PHP_MAJOR}" /usr/local/bin/php; \
    case "${PHP_MAJOR}" in \
        82) min=8.2.35 ;; \
        83) min=8.3.36 ;; \
        84) min=8.4.27 ;; \
        85) min=8.5.12 ;; \
        *)  min=0 ;; \
    esac; \
    MIN_PHP="${min}" php -r ' \
        if (version_compare(PHP_VERSION, getenv("MIN_PHP"), "<")) { \
            fwrite(STDERR, "PHP " . PHP_VERSION . " < " . getenv("MIN_PHP") . ", refusing to build\n"); \
            exit(1); \
        } \
        echo "PHP " . PHP_VERSION . " >= " . getenv("MIN_PHP") . "\n"; \
    '; \
    php -v

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy

WORKDIR /www
EXPOSE 80 443
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
