# 云吞插件：Nextcloud

自托管网盘，文件、相册、共享和 WebDAV 都在（日历、办公这些应用在应用商店里另装）。插件用 Nextcloud
官方镜像（apache 变体）装上游 Nextcloud 35，MariaDB 存元数据，Valkey 做缓存、文件锁和 PHP 会话，
另有一个后台任务 sidecar。

登录经云吞的身份提供方（Ory Hydra）：首次启动从应用商店装官方 [user_oidc](https://apps.nextcloud.com/apps/user_oidc)
应用并登记身份源，打开插件就是自己的管理员账号，不用再登录一次。

开发流程见[插件开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)，清单和规则见
[插件规范](https://github.com/wontonapp/wonton-docs/blob/main/plugin-spec.md)。

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件清单和五个服务（nextcloud、db、valkey、cron、oidc-relay）加一次性 setup |
| `setup/nextcloud-setup.sh` | 一次性收尾：反代设置、装 user_oidc、登记身份提供方、配发信（幂等） |
| `healthcheck/nextcloud-health.sh` | Nextcloud 的健康检查：status.php 装完且数据库连得上 |
| `apache/ports.conf` | 镜像同名文件的副本，只把应用端口改成 8080 |
| `oidc-relay/probe.sh` | 转发的健康检查和自愈探针：经转发取一次核心的答复 |
| `icon.svg` | 插件图标 |
| `screenshots/` | 商店截图 |

## 登录怎么接的

- Nextcloud 的管理员账号就是云吞用户：官方镜像的安装流程用 `NEXTCLOUD_ADMIN_USER=<云吞用户名>` 建号，
  user_oidc 首次登录按 OIDC 的 `sub`（= 云吞用户名）绑到这个账号，云吞用户即为管理员，没有第二个账号。
- `webui.path` 指向 `/apps/user_oidc/login/1`，打开就进云吞登录，不落在 Nextcloud 自己的登录表单；
  user_oidc 按自增 ID 路由，setup 里断言提供方 ID 是 1。

核心升级时容器会按新的签发方自动重建，不用重装；账号按已有的身份记录认回原账号，数据不动。
- 容器里的 curl 和 PHP 把 `*.localhost` 直接当 127.0.0.1，不走 Docker DNS，所以 `oidc-relay` 和 Nextcloud
  共 netns，在 `127.0.0.1:<核心端口>` 上把请求转给核心；基础域名换成别的域名时容器里走 Docker DNS，
  转发不启动。应用因此听 8080 而不是 80，核心网页端口也用 8080 时 setup 会报出来，转发绑不上时也会报。
  共用 netns 的代价：Nextcloud 单独重启（崩溃被 restart 拉起、`docker restart`）会换掉沙箱，转发留在旧的
  那个里——看着还通、应用却连不上。探针比较自己的地址和 DNS 里 `nextcloud` 的地址，加上经转发取一次答复，
  判坏就退出、由 restart 重建回新沙箱；应用的健康检查也从应用这一侧探一次转发，坏了状态就不绿。
- 插件申请了出网（首次启动装 user_oidc 用），内部服务按规范用核心生成的密钥加了密码。
- 开了 `allow_local_remote_servers`：签发方解析成回环（`*.localhost` 由转发接住）或插件网络里的内网地址，
  Nextcloud 默认不让 HTTP 客户端请求本地地址，不开登录会报“无法连接身份提供方”。

## 发信

- 应用发的信（找回密码、分享邀请、活动通知）交给核心的内部邮箱 SMTP（`notify` 权限注入的 `WONTON_SMTP_*`），
  不认证、不加密，所以没配 SMTP 用户名密码；核心把信转进收件人的“Wonton”私聊。
- 发件地址用 `WONTON_MAIL_FROM`。Nextcloud 把发件人拆成 mail_from_address（本地部分）加 mail_domain（域名）
  两段存，compose 拆不了 `@`，由 setup 用 occ 写进 config.php——因此不走官方镜像的
  `SMTP_*`/`MAIL_FROM_*` 环境变量（那套要求三个变量一起给，域名拆不出来）。
- 分享给外部邮箱（“通过邮件分享”）发不到外面，Nextcloud 会报发送失败。

## 图标

`icon.svg` 用 Nextcloud 官方标志（白色原样，放在官方品牌蓝底上），来源和商标说明见 [NOTICE](NOTICE)。
