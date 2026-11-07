#!/usr/bin/env bash
set -euo pipefail

image=${1:?Usage: bash smoke-test.sh IMAGE PLATFORM}
platform=${2:?Usage: bash smoke-test.sh IMAGE PLATFORM}
PHP_MAJOR=${PHP_MAJOR:-84}
ICU_DATA=${ICU_DATA:-full}
case "${PHP_MAJOR}" in
  82) default_min=8.2.35 ;;
  83) default_min=8.3.36 ;;
  84) default_min=8.4.27 ;;
  85) default_min=8.5.12 ;;
  *) echo "Unsupported PHP_MAJOR: ${PHP_MAJOR}" >&2; exit 1 ;;
esac
case "${ICU_DATA}" in
  full|en) ;;
  *) echo "Unsupported ICU_DATA: ${ICU_DATA}" >&2; exit 1 ;;
esac
MIN_PHP=${MIN_PHP:-${default_min}}

echo "==> 验证 ${image} (${platform}, PHP ${PHP_MAJOR}, ICU ${ICU_DATA})"
docker run --rm --platform "${platform}" \
  -e MIN_PHP="${MIN_PHP}" -e PHP_MAJOR="${PHP_MAJOR}" -e ICU_DATA="${ICU_DATA}" \
  "${image}" php -r '
    if (PHP_MAJOR_VERSION . PHP_MINOR_VERSION !== getenv("PHP_MAJOR") ||
        version_compare(PHP_VERSION, getenv("MIN_PHP"), "<")) {
        fwrite(STDERR, "Unexpected PHP version: " . PHP_VERSION . "\n"); exit(1);
    }
    $required = ["bcmath", "ctype", "curl", "dom", "fileinfo", "gd", "gettext",
        "gmp", "iconv", "intl", "mbstring", "mysqli", "openssl", "pcntl", "PDO",
        "pdo_mysql", "pdo_sqlite", "Phar", "posix", "redis", "session", "SimpleXML",
        "sockets", "sodium", "sqlite3", "sysvsem", "tokenizer", "xml", "xmlreader",
        "xmlwriter", "zip", "json", "zlib", "Zend OPcache"];
    foreach ($required as $extension) {
        if (!extension_loaded($extension)) {
            fwrite(STDERR, "Missing extension: $extension\n"); exit(1);
        }
    }
    if (ini_get("expose_php") || ini_get("display_errors") ||
        !ini_get("session.cookie_httponly") || !ini_get("opcache.enable")) {
        fwrite(STDERR, "Unexpected PHP configuration\n"); exit(1);
    }
    $hasChinese = in_array("zh", ResourceBundle::getLocales(""), true);
    if ($hasChinese !== (getenv("ICU_DATA") === "full")) {
        fwrite(STDERR, "ICU locale data does not match the requested variant\n"); exit(1);
    }
    printf("PHP %s: extensions, OPcache, hardening and ICU OK\n", PHP_VERSION);
  '
docker run --rm --platform "${platform}" "${image}" php-fpm8 -t
docker run --rm --platform "${platform}" "${image}" caddy version

workdir=$(mktemp -d)
container=
cleanup() {
  status=$?
  if [[ -n "${container}" ]]; then
    if [[ "${status}" != "0" ]]; then
      docker logs "${container}" >&2 || true
    fi
    docker rm -f "${container}" >/dev/null || true
  fi
  rm -rf "${workdir}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "${workdir}/public"
cat > "${workdir}/Caddyfile" <<'CADDY'
:80 {
    root * /www/public
    php_fastcgi unix//tmp/php-cgi.sock
    file_server
}
CADDY
cat > "${workdir}/public/index.php" <<'PHP'
<?php
if (!extension_loaded('Zend OPcache') || !ini_get('opcache.enable') ||
    ini_get('expose_php') || ini_get('display_errors') || !ini_get('session.cookie_httponly')) {
    http_response_code(503);
    exit('invalid FPM configuration');
}
echo 'fpm-ok';
PHP
printf 'static-ok' > "${workdir}/public/static.txt"
cat > "${workdir}/worker.php" <<'PHP'
<?php
file_put_contents('/tmp/smoke-worker.pid', (string) getmypid());
echo "worker ready\n";
while (true) {
    sleep(60);
}
PHP
cat > "${workdir}/supervisord.conf" <<'SUPERVISOR'
[program:smoke-worker]
command=php8 /www/worker.php
autostart=true
autorestart=true
startretries=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
SUPERVISOR

container=$(docker create --platform "${platform}" --init "${image}")
docker cp "${workdir}/Caddyfile" "${container}:/run/caddy/Caddyfile"
docker cp "${workdir}/public" "${container}:/www/public"
docker cp "${workdir}/worker.php" "${container}:/www/worker.php"
docker cp "${workdir}/supervisord.conf" "${container}:/run/supervisor/supervisord.conf"
docker start "${container}" >/dev/null

response=$(docker exec "${container}" curl --fail --silent --show-error \
  --retry 30 --retry-all-errors --retry-delay 1 --retry-max-time 60 --max-time 2 \
  http://127.0.0.1/index.php)
if [[ "${response}" != "fpm-ok" ]]; then
  echo "PHP HTTP response did not match: ${response}" >&2
  exit 1
fi
response=$(docker exec "${container}" curl --fail --silent --show-error --max-time 5 \
  http://127.0.0.1/static.txt)
if [[ "${response}" != "static-ok" ]]; then
  echo "Static HTTP response did not match: ${response}" >&2
  exit 1
fi
docker exec "${container}" sh -ec '
  for attempt in $(seq 1 30); do
    if test -S /tmp/php-cgi.sock && pidof crond >/dev/null &&
       test -s /tmp/smoke-worker.pid && kill -0 "$(cat /tmp/smoke-worker.pid)" &&
       test "$(redis-cli ping)" = PONG; then
      exit 0
    fi
    sleep 1
  done
  echo "Redis, cron or the custom worker did not become ready" >&2
  exit 1
'
docker stop --timeout 20 "${container}" >/dev/null
exit_code=$(docker inspect --format '{{.State.ExitCode}}' "${container}")
if [[ "${exit_code}" != "0" ]]; then
  echo "Container did not stop cleanly: ${exit_code}" >&2
  exit 1
fi
echo "==> ${platform}: HTTP / FPM / Redis / cron / 外挂任务 / 停止测试通过"
