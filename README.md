# 云吞插件：Nextcloud

自托管网盘，文件、相册、日历、办公一站都有。插件用 Nextcloud 官方镜像（apache 变体）装上游
Nextcloud 33，MariaDB 存元数据，Valkey 做缓存、文件锁和 PHP 会话，另有一个后台任务 sidecar。

登录经云吞的身份提供方（Ory Hydra）：首次启动从应用商店装官方 [user_oidc](https://apps.nextcloud.com/apps/user_oidc)
应用并登记身份源，打开插件就是自己的管理员账号，不用再登录一次。

开发流程见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)，清单和规则见
[插件规范](https://github.com/geraldpeng6/wonton-docs/blob/main/plugin-spec.md)。

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件清单和四个服务（nextcloud、db、valkey、cron）加一次性 setup |
| `setup/nextcloud-setup.sh` | 一次性收尾：反代设置、装 user_oidc、登记身份提供方（幂等） |
| `healthcheck/nextcloud-health.sh` | Nextcloud 的健康检查：status.php 装完且数据库连得上 |
| `icon.svg` | 插件图标 |
| `screenshots/` | 商店截图 |

## 登录怎么接的

- Nextcloud 的管理员账号就是云吞用户：官方镜像的安装流程用 `NEXTCLOUD_ADMIN_USER=<云吞用户名>` 建号，
  user_oidc 首次登录按 OIDC 的 `sub`（= 云吞用户名）绑到这个账号，云吞用户即为管理员，没有第二个账号。
- `webui.path` 指向 `/apps/user_oidc/login/1`，打开就进云吞登录，不落在 Nextcloud 自己的登录表单；
  user_oidc 按自增 ID 路由，setup 里断言提供方 ID 是 1。
- 插件申请了出网（首次启动装 user_oidc 用），内部服务按规范用核心生成的密钥加了密码。

## 图标

`icon.svg` 用 Nextcloud 官方标志（白色原样，放在官方品牌蓝底上），来源和商标说明见 [NOTICE](NOTICE)。
