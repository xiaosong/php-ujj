#!/usr/bin/env bash
# 本地构建 + 版本断言 + 冒烟测试
#
#   ./build.sh                      # PHP 8.4 / alpine 3.24 / linux/amd64 / 完整 ICU
#   PHP_MAJOR=83 ./build.sh         # PHP 8.3
#   PHP_MAJOR=82 ALPINE_VERSION=3.22 ./build.sh   # PHP 8.2 只在 3.22 仓库里
#   ICU_DATA=en ./build.sh          # 瘦身：仅 en_US/GB 的 ICU 数据（省约 28.7MiB）
#   APK_CACHE_BUST=$(date +%s) ./build.sh         # 强制 apk 层重建，拉最新安全更新
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
APK_CACHE_BUST=${APK_CACHE_BUST:-0}
PLATFORMS=${PLATFORMS:-linux/amd64}
PUSH=${PUSH:-0}

case "${PHP_MAJOR}" in
  82|83|84|85) ;;
  *) echo "PHP_MAJOR 仅支持 82/83/84/85，收到: ${PHP_MAJOR}" >&2; exit 1 ;;
esac
if [[ "${PHP_MAJOR}" == "82" && "${ALPINE_VERSION#v}" != 3.22* ]]; then
  echo "PHP_MAJOR=82 只能配 ALPINE_VERSION=3.22（3.24 仓库里没有 php82）" >&2
  exit 1
fi
case "${ICU_DATA}" in
  full) variant="php${PHP_MAJOR}" ;;
  en) variant="php${PHP_MAJOR}-en" ;;
  *) echo "ICU_DATA 仅支持 en/full，收到: ${ICU_DATA}" >&2; exit 1 ;;
esac
case "${PUSH}" in
  0|1) ;;
  *) echo "PUSH 仅支持 0/1，收到: ${PUSH}" >&2; exit 1 ;;
esac
if [[ "${PLATFORMS}" == *,* && "${PUSH}" != "1" ]]; then
  echo "多架构构建必须 PUSH=1" >&2
  exit 1
fi
IFS=',' read -r -a platforms <<< "${PLATFORMS}"
for platform in "${platforms[@]}"; do
  case "${platform}" in
    linux/amd64|linux/arm64) ;;
    *) echo "PLATFORMS 仅支持 linux/amd64、linux/arm64" >&2; exit 1 ;;
  esac
done
if [[ "${PLATFORMS}" == *, ]]; then
  echo "PLATFORMS 不能以逗号结尾" >&2
  exit 1
fi
TAG=${TAG:-${variant}-$(date +%Y%m%d)}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

echo "==> ${IMAGE}:${TAG}  (php${PHP_MAJOR} / alpine ${ALPINE_VERSION} / ${PLATFORMS} / ICU ${ICU_DATA} / cache-bust ${APK_CACHE_BUST})"

build_args=(
  --build-arg "PHP_MAJOR=${PHP_MAJOR}"
  --build-arg "ALPINE_VERSION=${ALPINE_VERSION}"
  --build-arg "APK_MIRROR=${APK_MIRROR}"
  --build-arg "ICU_DATA=${ICU_DATA}"
  --build-arg "APK_CACHE_BUST=${APK_CACHE_BUST}"
)

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${PUSH}" == "1" ]]; then
  candidate="${IMAGE}:candidate-${variant}-$(date +%s)-$$-${RANDOM}"
  docker buildx build --pull --platform "${PLATFORMS}" "${build_args[@]}" \
    --provenance=true --sbom=true -t "${candidate}" --push "${script_dir}"
  digest=$(docker buildx imagetools inspect "${candidate}" --format '{{.Manifest.Digest}}')
  if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "无法读取候选镜像 digest" >&2
    exit 1
  fi
  built_image="${IMAGE}@${digest}"
else
  docker build --pull --platform "${PLATFORMS}" "${build_args[@]}" \
    --iidfile "${workdir}/image-id" "${script_dir}"
  built_image=$(<"${workdir}/image-id")
fi

for platform in "${platforms[@]}"; do
  PHP_MAJOR="${PHP_MAJOR}" ICU_DATA="${ICU_DATA}" \
    bash "${script_dir}/smoke-test.sh" "${built_image}" "${platform}"
done

if [[ "${PUSH}" == "1" ]]; then
  docker buildx imagetools create -t "${IMAGE}:${TAG}" -t "${IMAGE}:${variant}" "${built_image}"
  echo "==> 已验证并发布: ${built_image}"
else
  docker tag "${built_image}" "${IMAGE}:${TAG}"
  docker tag "${built_image}" "${IMAGE}:${variant}"
fi
echo "==> done: ${IMAGE}:${TAG} / ${IMAGE}:${variant}"
