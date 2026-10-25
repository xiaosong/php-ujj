# lcrp8

Caddy + PHP-FPM + Redis + Supervisor 的单容器运行时。原 `tokumeikoi/lcrp8`（2023-05 停更、PHP 8.0.25 已 EOL）的自维护替代品。

- 基础镜像 `alpine:3.24`，PHP **8.4.27**（含 CVE-2026-109618 / CVE-2026-109619 修复）
- 目录结构、配置文件、启动命令与原镜像**完全一致**，业务侧无需改动
- 多架构：`linux/amd64`、`linux/arm64`

---

## 漏洞修复状态：已核对确认

`CVE-2026-109618` / `CVE-2026-109619`（php2shell，PHP 核心 RCE，CVSS 4.0 = 9.2）官方修复线：
**8.2.35 / 8.3.36 / 8.4.27 / 8.5.12**，低于这些版本一律中招。

| 分支 | Alpine v3.24 实际包版本 | 修复线 | 结论 |
|---|---|---|---|
| **8.4（默认）** | `php84 8.4.27-r0` | 8.4.27 | ✅ 等于修复版 |
| 8.3 | `php83 8.3.36-r0` | 8.3.36 | ✅ 等于修复版 |
| 8.5（可选） | `php85 8.5.12-r0` | 8.5.12 | ✅ 等于修复版 |
| 8.2（需 `ALPINE_VERSION=3.22`） | `php82 8.2.35-r0` | 8.2.35 | ✅ 等于修复版 |

四路互证（2026-10-25 核对）：

1. **php.net 官方公告**：8.4.27 于 2026-10-21 发布，正文写明 "security release fixing two critical vulnerabilities (CVE-2026-109618, CVE-2026-109619)… updating is the only safe choice"。
2. **Alpine aports 源码**（`3.24-stable/community/php84/APKBUILD`）：`pkgver=8.4.27`、`pkgrel=0`、源码直取 `php-8.4.27.tar.xz`——即直接用上游修复版，没有额外本地补丁。
3. **打包时间**：pkgs.alpinelinux.org 显示 v3.24 的 php84 构建于 **2026-10-21 16:38**，与上游发版同日。
4. **仓库实时索引**：v3.24 community 的 php84 主包 + 63 个扩展包全部为 `8.4.27-r0`（另有一个 pecl 包走自己的版本号）。

自己复核一条命令：

```bash
curl -s https://dl-cdn.alpinelinux.org/alpine/v3.24/community/x86_64/APKINDEX.tar.gz \
  | tar -xzO APKINDEX | grep -A2 '^P:php84$'
```

构建脚本已内置版本断言，低于修复线直接失败：

```
$ ./build.sh
==> 版本断言
    实际 PHP 版本: 8.4.27   下限: 8.4.27
    [OK] 已越过 CVE-2026-109618 / CVE-2026-109619 修复线
```

> 一个坑：Alpine 的 secdb（`secdb.alpinelinux.org/v3.24/community.json`）目前**还没**把这两个 CVE 标到 php84 条目上（最后记录停在 8.4.9），属数据库同步滞后。v3.22 的 php82 条目已标注 `8.2.35-r0: [CVE-2026-109618, CVE-2026-109619]`，可作旁证。**判断以包版本为准，别以 secdb 为准。**

---

## 构建

```bash
./build.sh                                              # php8.4 / alpine 3.24 / amd64
PHP_MAJOR=83 ./build.sh                                 # 换 PHP 版本
APK_MIRROR=https://mirrors.aliyun.com/alpine ./build.sh # 国内构建
PLATFORMS=linux/amd64,linux/arm64 PUSH=1 IMAGE=your.registry/lcrp8 ./build.sh
```

或者直接：

```bash
docker build -t lcrp8:php84 .
docker build -t lcrp8:php83 --build-arg PHP_MAJOR=83 .
```

构建参数：

| ARG | 默认 | 说明 |
|---|---|---|
| `PHP_MAJOR` | `84` | `84` / `83` / `82` |
| `ALPINE_VERSION` | `3.24` | 换分支时注意该分支的 php 版本是否已修复漏洞 |
| `APK_MIRROR` | `https://dl-cdn.alpinelinux.org/alpine` | 国内可换阿里云 / 中科大 |

---

## 运行

```bash
cp docker-compose.example.yml docker-compose.yml
docker compose up -d
```

镜像内的约定（**与原镜像一致，别改**）：

```
/www                          代码目录（WORKDIR，外挂）
/wwwlogs                      php-fpm.log / php-slow.log（外挂）
/run/caddy/Caddyfile          Caddy 配置（外挂）
/run/supervisor/*.conf        supervisord 附加程序（外挂）
/etc/php84/php-fpm.d/www.conf FPM 配置（镜像内）
/tmp/php-cgi.sock             FPM socket，Caddy 反代目标
```

进程树：`supervisord → php-fpm8 -RF / caddy run --config /run/caddy/Caddyfile / redis-server / crond -f`

端口：`80`、`443`。

### 兼容层

为了不动老配置，镜像里做了几个软链：

| 路径 | 指向 |
|---|---|
| `/etc/php8` | `/etc/php84` |
| `php8` | `/usr/bin/php84` |
| `php-fpm8` | `/usr/sbin/php-fpm84` |
| `php` | `/usr/bin/php84` |

所以老 `supervisord.conf` 里的 `php-fpm8 -RF`、crontab 里的 `php8 artisan`、运维脚本里的 `/etc/php8/...` 都照旧能用。

> 唯一要注意：**挂 `php.ini` 请挂到 `/etc/php84/php.ini`**，挂 `/etc/php8/php.ini` 会被软链绕过去。

---

## 升级 PHP 的兼容性

PHP 8.0 → 8.2+ 的已知破坏点，上线前在预发跑一遍：

- 动态属性（`$obj->undefinedProp = 1`）→ 8.2 起 deprecated，老框架会刷日志
- `${var}` 字符串插值 → 8.2 deprecated
- `utf8_encode` / `utf8_decode` → 8.2 deprecated
- 内部函数参数类型更严格，`null` 传给非 nullable 参数会报 deprecated

按框架选 `PHP_MAJOR`：

| 项目 | 建议 |
|---|---|
| Laravel 11 / 12 | `84`（默认），8.4 安全支持到 2028-12 |
| Laravel 10 | `83`，8.3 安全支持到 2027-12 |
| Laravel 9 及更早 | `82`（需把 `ALPINE_VERSION` 设成 `3.22`，那里 php82 = 8.2.35 已修复）——**8.2 于 2026-12-31 EOL**，只剩两个月，尽快排期升框架 |
| 其他 PHP 应用 | 取「框架支持上限」与「已修复版本」的交集 |

已修复版本线：8.2.35 / 8.3.36 / 8.4.27 / 8.5.12，低于这些的都会中招。

---

## 维护

`.github/workflows/build.yml` 已配好：**每周一自动重建并推送 GHCR**（多架构），alpine 的安全更新会自动进来；也支持手动触发并指定 PHP 主版本。

出新 CVE 时的处理顺序：

1. 查官方修复版本 → 确认 Alpine 对应分支的包是否已跟进（`https://pkgs.alpinelinux.org/packages?name=php84`）
2. 改 `ALPINE_VERSION` 或 `PHP_MAJOR`，跑 `./build.sh`
3. 冒烟测试会打印 `php -v` 和 `php -m`，确认版本越过修复线
4. 保留旧 tag，回滚只需改 image tag

---

## 已知风险

1. **php-fpm 以 root 运行**（`config/php-fpm.conf` 里 `user = root`）——一旦 RCE 即容器 root。建议改 `user = www-data` 并 `chown -R www-data /www`，需确认业务文件权限。
2. **`pm.max_children = 300`**——小机器上被打满就是 OOM。按 `可用内存 / 单进程常驻` 重算。
3. **无 HEALTHCHECK**——Caddy 可能只监听 443 且用内部证书，硬加会误报。需要时自行加 `curl -fsS http://127.0.0.1/`。
4. **容器以 root 启动**——为与原镜像行为一致而保留。要加固需同时处理 80/443 绑定（`CAP_NET_BIND_SERVICE` 或改高位端口）。
5. **Caddy 大版本跨度**——若 Caddyfile 里有已废弃指令，新版会启动失败。上线前先验：
   ```bash
   docker run --rm -v $PWD/Caddyfile:/run/caddy/Caddyfile:ro lcrp8:php84 \
     caddy validate --config /run/caddy/Caddyfile
   ```

---

## 目录

```
.
├── Dockerfile
├── config/
│   ├── php-fpm.conf
│   └── supervisord.conf
├── build.sh
├── docker-compose.example.yml
├── .dockerignore
└── .github/workflows/build.yml
```
