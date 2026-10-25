# lcrp8

Caddy + PHP-FPM + Redis + Supervisor 的单容器运行时。原 `tokumeikoi/lcrp8`（2023-05 停更、PHP 8.0.25 已 EOL）的自维护替代品。

- 基础镜像 `alpine:3.24`，PHP **8.4.27**（含 CVE-2026-109618 / CVE-2026-109619 修复）
- Caddy 固定上游 **2.11.7**（`caddy:2.11.7-alpine`，不再跟随浮动的 `:2-alpine`）
- 目录结构、配置文件、启动命令与原镜像**完全一致**，业务侧无需改动
- 多架构：`linux/amd64`、`linux/arm64`
- 默认 `ICU_DATA=full`，与原镜像一样带完整 locale 数据；可用 `ICU_DATA=en` 构建瘦身版
- `PHP_MAJOR` 支持 `82`（必须配 `ALPINE_VERSION=3.22`）/ `83` / `84` / `85`；3.24 的 php85 尚无 opcache 包，构建会告警并跳过

---

## 漏洞修复状态：已核对确认

`CVE-2026-109618` / `CVE-2026-109619`（php2shell，PHP 核心 RCE，CVSS 4.0 = 9.2）官方修复线：
**8.2.35 / 8.3.36 / 8.4.27 / 8.5.12**，低于这些版本一律中招。

| 分支 | Alpine v3.24 实际包版本 | 修复线 | 结论 |
|---|---|---|---|
| **8.4（默认）** | `php84 8.4.27-r0` | 8.4.27 | ✅ 等于修复版 |
| 8.3 | `php83 8.3.36-r0` | 8.3.36 | ✅ 等于修复版 |
| 8.5（可选） | `php85 8.5.12-r0` | 8.5.12 | ✅ 等于修复版；⚠️ v3.24 未打包 `php85-opcache` |
| 8.2（需 `ALPINE_VERSION=3.22`） | `php82 8.2.35-r0` | 8.2.35 | ✅ 等于修复版；CI 会自动切到 3.22 |

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

构建脚本和 Dockerfile 都内置版本断言，低于修复线直接失败：

```
$ ./build.sh
==> 版本断言
    实际 PHP 版本: 8.4.27   下限: 8.4.27
    [OK] 已越过 CVE-2026-109618 / CVE-2026-109619 修复线
```

> 一个坑：Alpine 的 secdb（`secdb.alpinelinux.org/v3.24/community.json`）目前**还没**把这两个 CVE 标到 php84 条目上（最后记录停在 8.4.9），属数据库同步滞后。v3.22 的 php82 条目已标注 `8.2.35-r0: [CVE-2026-109618, CVE-2026-109619]`，可作旁证。**判断以包版本为准，别以 secdb 为准。**

### Alpine 包扫描（2026-10-25）

按 `secdb.alpinelinux.org/v3.24/{main,community}.json` 对镜像的完整包闭包逐包比对：

- **0 个**「安装版本 < 首个修复版本」的已知漏洞。
- 12 条 secdb 标记为 `0`（无修复/争议）的条目，集中在 `busybox`、`curl`、`git`、`zlib`。其中 zlib 的 CVE-2023-45853 / CVE-2023-6992 属于 minizip（本镜像不提供该可执行文件）；其余条目需按上游公告评估，当前 Alpine 分支没有可用修复包，升级分支或移除对应组件是唯一手段。
- Caddy 二进制不在 Alpine secdb 覆盖范围内，只能跟随上游 release；当前固定 2.11.7（上游 2026-10-03 发布）。

### 本次安全加固

- PHP 默认值：`expose_php=Off`、`display_errors=Off`、`session.cookie_httponly=1`（[`config/php-hardening.ini`](config/php-hardening.ini)）
- Redis 显式 `--bind 127.0.0.1 -::1 --protected-mode yes`，不再可能监听外部地址
- php-fpm unix socket 显式 `listen.mode = 0660`
- compose 示例加 `no-new-privileges:true`
- CI action 全部固定到 commit SHA；手动输入先白名单校验；推送后按 digest 复验；生成 SLSA provenance + SBOM
- Dockerfile 构建期再次断言 PHP 最低版本（绕过 `build.sh` 直接 `docker build` 也拦得住）
- Dependabot 每周跟踪 action / 基础镜像升级

---

## 构建

```bash
./build.sh                                              # php8.4 / alpine 3.24 / amd64 / ICU full
ICU_DATA=en ./build.sh                                  # 瘦身：仅 en_US/GB ICU 数据
PHP_MAJOR=83 ./build.sh                                 # 换 PHP 版本
PHP_MAJOR=82 ALPINE_VERSION=3.22 ./build.sh             # 8.2 只在 3.22 仓库里
APK_CACHE_BUST=$(date +%s) ./build.sh                   # 强制刷新 apk 包，不吃层缓存
APK_MIRROR=https://mirrors.aliyun.com/alpine ./build.sh # 国内构建
PLATFORMS=linux/amd64,linux/arm64 PUSH=1 IMAGE=your.registry/lcrp8 ./build.sh
```

或者直接：

```bash
docker build -t lcrp8:php84 .
docker build -t lcrp8:php83 --build-arg PHP_MAJOR=83 .
docker build -t lcrp8:php84-slim --build-arg ICU_DATA=en .
```

构建参数：

| ARG | 默认 | 说明 |
|---|---|---|
| `PHP_MAJOR` | `84` | `84` / `83` / `82` / `85`；`82` 必须配 `ALPINE_VERSION=3.22` |
| `ALPINE_VERSION` | `3.24` | 换分支时注意该分支的 php 版本是否已修复漏洞；CI 对 82 自动用 3.22 |
| `APK_MIRROR` | `https://dl-cdn.alpinelinux.org/alpine` | 国内可换阿里云 / 中科大 |
| `ICU_DATA` | `full` | `full`：完整 ICU 数据（31.6 MiB，含 zh 等）；`en`：仅 en_US/GB（2.9 MiB） |
| `APK_CACHE_BUST` | `0` | 任意变化值都会让 apk 层缓存失效；CI 每次传 `run_id`，本地刷新传时间戳 |

> `ICU_DATA` 不是可有可无的优化项：原 Alpine 3.15 的 `icu-libs` 自带完整数据，3.16 起拆成 `icu-data-en` / `icu-data-full`。选 `en` 时 `IntlDateFormatter('zh_CN')`、`Collator('zh')` 等会退化到根 locale，**默认 full 是为了保持与原镜像一致的行为**。

---

## 架构

当前镜像刻意保持原镜像的“单容器多进程”形态：`supervisord` 作为 PID 1，拉起 `php-fpm`、`caddy`、`redis`、`crond` 四个进程。这样 `Caddyfile`、`/run/supervisor/*.conf`、`/www`、`/wwwlogs`、`/tmp/php-cgi.sock` 和启动命令都与原镜像一致，换镜像只改 tag。

合理的地方：迁移成本为零，不需要拆 compose，老机器/老运维习惯不变。

不合理的地方（新部署需要知道）：

- 四个进程共享同一内存、网络和生命周期；Redis 重启会连带 Web 一起重启，无法独立扩缩容。
- 进程全部是 root；一个 PHP 应用 RCE 就是容器 root（见「已知风险」）。
- 多副本部署时 cron 会重复执行，Redis 也各自独立。
- `supervisord` 本身不是 init，孤儿子进程可能变僵尸；示例 compose 已加 `init: true`，不用 compose 时请加 `--init`。
- supervisor + Python 运行时约 28.3 MiB，是单容器方案的主要“管理税”。

结论：**如果目标是替换原镜像，这个架构是合理的，不建议为省体积拆掉 supervisor**。新项目建议拆成 caddy / php-fpm / redis / cron 四个服务，Redis 独立持久化并加 ACL，cron 单独跑一个副本；那时镜像可以去掉 supervisor、redis、crond 以及整条 Python 依赖。

## 体积

按 Alpine v3.24 APKINDEX 的 installed-size 实测（2026-10-25）：

- 含 base 在内共 **109 个包、151.5 MiB**（其中落在闭包里的 base 包 7.5 MiB）；扣掉后新增包在 APKINDEX 中合计 **144.0 MiB**（full，含 `icu-data-en` 2.88 MiB 与 `icu-data-full` 31.57 MiB 的重叠）；en 分支为 **112.4 MiB**。
- Alpine base 总计约 7.9 MiB；Caddy 2.11.7 二进制 49.5 MiB（官方 release，已 strip、静态链接）。

| 组成 | full | en |
|---|---:|---:|
| apk 新增包（不含 base，已扣 ICU 重叠） | ≈ 141.1 MiB | ≈ 112.4 MiB |
| Alpine base | ≈ 7.9 MiB | ≈ 7.9 MiB |
| Caddy 2.11.7 二进制 | 49.5 MiB | 49.5 MiB |
| **合计（未压缩）** | **≈ 198.5 MiB** | **≈ 169.8 MiB** |

原镜像（PHP 8.0 / alpine 3.15 / Caddy 约 38MB）包闭包约 155 MiB，合计约 201 MiB。**默认 full 与原镜像基本持平（约 −2 MiB：Caddy 大了约 11.5 MiB，其余包小了约 14 MiB）；en 约小 31 MiB。**

主要可移除项的边际体积（移除该项及其独占依赖能省多少，各项不可相加）：

| 组件 | 边际体积 | 说明 |
|---|---:|---|
| `icu-data-full` | 31.6 MiB | 完整 locale；换 en 后实际省约 29 MiB |
| supervisor + Python | 28.3 MiB | supervisor 1.5 + python3 22.5 + setuptools/parsing/packaging 4.0 |
| php84-gd + 图像库 | 18.2 MiB | 其中 AVIF 链（aom/libyuv/dav1d/libavif）约 12，XPM/X11 链约 4.5 |
| php84-fileinfo | 8.2 MiB | `.so` 内嵌 libmagic 数据库，Composer/文件检测要用 |
| git | 6.7 MiB | 只有 composer 拉 VCS 源时需要 |
| redis | 4.2 MiB | Redis server + cli + benchmark |
| bash / opcache / curl | 1.3 / 1.2 / 0.3 MiB | 兼容脚本、性能、命令行调试 |

> **没有发现“装了但没用到”的包**。显式列表里的 `php84`、`php84-dom`、`php84-session`、`php84-sockets`、`php84-openssl`、`php84-pdo` 是传递依赖，删掉列表项 apk 仍会装，体积 **0 变化**；保留它们是为了让扩展契约显式。`icu-data-en` 同理由 `icu-libs` 自动拉入。

> Alpine 的 `icu-libs` 依赖虚拟包 `icu-data`，默认 provider 是 `icu-data-en`；`icu-data-full` 与 en 安装同一个 `icudt*.dat`，所以 Dockerfile 在 PHP 包之后**最后**装 full，让完整数据覆盖 en 的小文件。两份包记录会同时存在，这是 Alpine 的预期行为；容器内不要 `apk fix` 或重装 `icu-data-en`，否则可能把数据覆盖回 en，升级请重建镜像。

继续压缩只能动有功能代价的组件，均未默认实施：

| 方案 | 省（安装后） | 代价 |
|---|---|---|
| `ICU_DATA=en` | ≈ 29 MiB | 非英语 locale 数据缺失 |
| 去掉 supervisor（换 s6/tini） | ≈ 28.3 MiB | 丢 `/run/supervisor/*.conf` 外挂、自动重启/重试语义；需要改启动方式 |
| 去掉 git | ≈ 6.7 MiB | 容器内 composer 拉 git 源会失败 |
| 自编译 gd 关闭 AVIF | ≈ 12 MiB | `imageavif()` 失效，需自维护扩展构建 |
| 自编译 gd 关闭 XPM/X11 | ≈ 4.5 MiB | XPM 图像失效，同样要自维护 |
| 自编译 Caddy 精简模块 | 约 10–20 MiB（未实测） | Caddyfile 兼容性无法保证 |
| 删 Python `ensurepip`/测试/`pydoc_data`/`config-*` | ≈ 3.3 MiB | 只影响容器内 Python 工具，不影响 supervisor；但文件不在 apk 清单里，`apk verify` 会报缺失 |
| 删 `py3-setuptools` | ≈ 4.0 MiB | supervisor 4.3 在 Python 3.14 已改用 importlib，但 apk 声明了依赖，删除会造成包依赖不一致 |
| UPX 压 Caddy | 压缩层显著变小 | 运行时解压内存、杀软误报、审计困难，不建议 |

当前已做的无损裁剪：合并配置层、去掉 `/tmp` 中间文件、同层清理 apk 缓存、Caddy 只取 `/usr/bin/caddy`；Alpine 的文档包本就没有安装，PHP/Redis/Git/Caddy 二进制均已 strip。**剩下的“无损大头”已经没有了**，再往下都是上面这些功能或架构取舍。

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
/run/supervisor/*.conf        supervisord 附加程序（外挂，建议只读挂载）
/etc/php84/php-fpm.d/www.conf FPM 配置（镜像内）
/tmp/php-cgi.sock             FPM socket，Caddy 反代目标
```

进程树：`supervisord → php-fpm8 -RF / caddy run --config /run/caddy/Caddyfile / redis-server（仅 127.0.0.1） / crond -f`

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

`.github/workflows/build.yml` 已配好：**每周一自动重建并推送 GHCR**（多架构），alpine 的安全更新会自动进来；也支持手动触发并指定 PHP 主版本 / ICU 数据。

- Caddy 固定次版本；`.github/dependabot.yml` 每周提 PR 跟踪 Caddy 升级。Alpine 版本走 `ALPINE_VERSION` 构建参数，Dependabot 解析不到，需手动改。
- CI action 固定到 commit SHA，由 Dependabot 更新；不要直接改回浮动 tag。
- CI 每次把 `github.run_id` 传给 `APK_CACHE_BUST`，强制 apk 层重建；否则 buildx 缓存会让 `apk upgrade` 直接复用旧层，周构建拿不到新包。本地用 `APK_CACHE_BUST=$(date +%s) ./build.sh` 达到同样效果。
- 手动选择 `php_major=82` 时 CI 自动切到 `ALPINE_VERSION=3.22`；`php85` 在 3.24 没有 `php85-opcache`，构建会告警并在无 OPcache 的情况下继续（83/84 会被 CI 断言必须带 OPcache）。
- 推送后 CI 会按刚生成的 digest 拉取并断言 PHP 版本、`expose_php`、FPM 配置、扩展列表。

出新 CVE 时的处理顺序：

1. 查官方修复版本 → 确认 Alpine 对应分支的包是否已跟进（`https://pkgs.alpinelinux.org/packages?name=php84`）
2. 改 `ALPINE_VERSION` 或 `PHP_MAJOR`，跑 `./build.sh`
3. 冒烟测试会打印 `php -v`、`php -m`、FPM 配置测试和安全默认值，确认版本越过修复线
4. 保留旧 tag，回滚只需改 image tag

---

## 已知风险

1. **php-fpm 以 root 运行**（`config/php-fpm.conf` 里 `user = root`）——一旦 RCE 即容器 root。改成 `www-data` 需同时处理 `/www`、`/wwwlogs` 的挂载权限，属于行为变更，未默认做。
2. **容器以 root 启动**——为与原镜像行为一致而保留；80/443 绑定也需要。`no-new-privileges` 只能阻止再提权，不能把 root 变成非 root。
3. **`pm.max_children = 300`**——小机器上被打满就是 OOM。按 `可用内存 / 单进程常驻` 重算。
4. **Caddy admin API 默认监听 `127.0.0.1:2019` 且无认证**——应用侧 RCE 后可改 Caddy 配置、读证书。Caddyfile 由外挂提供，镜像内无法统一关闭；不需要动态配置时在 Caddyfile 顶部加 `{ admin off }`。
5. **`pm.status_path = /phpfpm_status`**——默认 Caddy 不会把它转给 FPM（`php_fastcgi` 只匹配 `*.php`），但如果 Caddyfile 显式路由了它，会泄露进程/请求信息。对外暴露前加认证或删除该路由。
6. **`/run/supervisor/supervisord.conf` 可追加 root 程序**——示例 compose 中该挂载默认注释；启用时请加 `:ro`。
7. **无 HEALTHCHECK**——Caddy 可能只监听 443 且用内部证书，硬加会误报。需要时自行加 `curl -fsS http://127.0.0.1/`。
8. **Caddy 大版本跨度**——若 Caddyfile 里有已废弃指令，2.11 会启动失败。上线前先验：
   ```bash
   docker run --rm -v $PWD/Caddyfile:/run/caddy/Caddyfile:ro lcrp8:php84 \
     caddy validate --config /run/caddy/Caddyfile
   ```
9. **`session.cookie_httponly=1`**——这是安全默认值；如果老应用依赖 JS 读取 PHPSESSID，需要在应用层覆盖。
10. **Redis 只绑回环**——其他容器/宿主不能再直连 6379；如原有跨容器依赖，需显式改回并自行加 ACL/密码，不建议。
11. **`ICU_DATA=en` 的行为差异**——见上文；需要 zh 等 locale 时用默认 full。
12. **`supervisord` 不是 init**——它只回收自己的子进程，应用产生的孤儿进程可能变僵尸。示例 compose 已加 `init: true`；直接 `docker run` 时请加 `--init`。
13. **PHP 8.5 无 OPcache**——Alpine v3.24 尚未打包 `php85-opcache`，只有显式选 `PHP_MAJOR=85` 才会遇到；默认 84 与 83 均带 OPcache。

---

## 目录

```
.
├── Dockerfile
├── config/
│   ├── php-fpm.conf
│   ├── php-hardening.ini
│   └── supervisord.conf
├── build.sh
├── docker-compose.example.yml
├── .dockerignore
├── .gitignore
└── .github/
    ├── dependabot.yml
    └── workflows/build.yml
```
