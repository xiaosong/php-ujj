#!/usr/bin/env bash
# 本地构建 + 版本断言 + 冒烟测试
#
#   ./build.sh                      # PHP 8.4 / alpine 3.24 / linux/amd64 / 完整 ICU
#   PHP_MAJOR=83 ./build.sh         # PHP 8.3
#   ICU_DATA=en ./build.sh          # 瘦身：仅 en_US/GB 的 ICU 数据（省约 28.7MiB）
#   APK_MIRROR=https://mirrors.aliyun.com/alpine ./build.sh
#   PLATFORMS=linux/amd64,linux/arm64 PUSH=1 IMAGE=registry.cn-hangzhou.aliyuncs.com/you/lcrp8 ./build.sh
#
# 构建完会断言 PHP 版本 >= MIN_PHP（默认按 PHP_MAJOR 推导出的漏洞修复线），
# 低于修复线直接非 0 退出 —— 防止哪天 alpine 分支回退或装错包。
set -euo pipefail

IMAGE=${IMAGE:-lcrp8}
PHP_MAJOR=${PHP_MAJOR:-84}
ALPINE_VERSION=${ALPINE_VERSION:-3.24}
APK_MIRROR=${APK_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
ICU_DATA=${ICU_DATA:-full}
PLATFORMS=${PLATFORMS:-linux/amd64}
PUSH=${PUSH:-0}
TAG=${TAG:-php${PHP_MAJOR}-$(date +%Y%m%d)}

case "${PHP_MAJOR}" in
  82|83|84|85) ;;
  *) echo "PHP_MAJOR 仅支持 82/83/84/85，收到: ${PHP_MAJOR}" >&2; exit 1 ;;
esac
case "${ICU_DATA}" in
  en|full) ;;
  *) echo "ICU_DATA 仅支持 en/full，收到: ${ICU_DATA}" >&2; exit 1 ;;
esac
case "${PUSH}" in
  0|1) ;;
  *) echo "PUSH 仅支持 0/1，收到: ${PUSH}" >&2; exit 1 ;;
esac
if [[ "${PLATFORMS}" == *,* && "${PUSH}" != "1" ]]; then
  echo "多架构构建必须 PUSH=1（buildx 无法把多架构镜像 --load 进本地 daemon）" >&2
  exit 1
fi

# CVE-2026-109618 / CVE-2026-109619（php2shell）的官方修复线
case "${PHP_MAJOR}" in
  82) DEFAULT_MIN=8.2.35 ;;
  83) DEFAULT_MIN=8.3.36 ;;
  84) DEFAULT_MIN=8.4.27 ;;
  85) DEFAULT_MIN=8.5.12 ;;
  *)  DEFAULT_MIN=0 ;;
esac
MIN_PHP=${MIN_PHP:-$DEFAULT_MIN}

echo "==> ${IMAGE}:${TAG}  (php${PHP_MAJOR} / alpine ${ALPINE_VERSION} / ${PLATFORMS} / ICU ${ICU_DATA})"
echo "==> 版本下限 MIN_PHP=${MIN_PHP:-未设}"

build_args=(
  --build-arg "PHP_MAJOR=${PHP_MAJOR}"
  --build-arg "ALPINE_VERSION=${ALPINE_VERSION}"
  --build-arg "APK_MIRROR=${APK_MIRROR}"
  --build-arg "ICU_DATA=${ICU_DATA}"
)

if [[ "${PUSH}" == "1" ]]; then
  docker buildx build --pull --platform "${PLATFORMS}" "${build_args[@]}" \
    -t "${IMAGE}:${TAG}" -t "${IMAGE}:php${PHP_MAJOR}" --push .
  echo "==> 已推送，跳过本地冒烟（到目标机 docker run 再验）"
  exit 0
fi

docker build --pull --platform "${PLATFORMS}" "${build_args[@]}" \
  -t "${IMAGE}:${TAG}" -t "${IMAGE}:php${PHP_MAJOR}" .

echo "==> 版本断言"
docker run --rm --platform "${PLATFORMS}" -e MIN_PHP="${MIN_PHP}" "${IMAGE}:${TAG}" php -r '
    $min = getenv("MIN_PHP");
    printf("    实际 PHP 版本: %s   下限: %s\n", PHP_VERSION, $min === "" ? "未设" : $min);
    if ($min !== "" && version_compare(PHP_VERSION, $min, "<")) {
        fwrite(STDERR, "    [X] 低于修复线，拒绝交付\n");
        exit(1);
    }
    echo "    [OK] 已越过 CVE-2026-109618 / CVE-2026-109619 修复线\n";
'

echo "==> 安全配置断言"
docker run --rm --platform "${PLATFORMS}" "${IMAGE}:${TAG}" php -r '
    if (ini_get("expose_php")) { fwrite(STDERR, "    [X] expose_php 未关闭\n"); exit(1); }
    if (ini_get("display_errors")) { fwrite(STDERR, "    [X] display_errors 未关闭\n"); exit(1); }
    printf("    expose_php=%s display_errors=%s session.cookie_httponly=%s\n",
        ini_get("expose_php"), ini_get("display_errors"), ini_get("session.cookie_httponly"));
    echo "    [OK] PHP 安全默认值生效\n";
'
docker run --rm --platform "${PLATFORMS}" "${IMAGE}:${TAG}" php-fpm8 -t

echo "==> 冒烟测试"
docker run --rm --platform "${PLATFORMS}" "${IMAGE}:${TAG}" php -m | tr '\n' ' '; echo
docker run --rm --platform "${PLATFORMS}" "${IMAGE}:${TAG}" sh -c 'php-fpm8 -v | head -1; caddy version'

echo "==> done: ${IMAGE}:${TAG}"
