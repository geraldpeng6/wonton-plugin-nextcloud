#!/usr/bin/env bash
# 每次创建容器（安装、升级、重建）都会重跑，必须幂等：所有 occ 都直接写最终值，不判断存在。
# user_oidc 应用装在 /var/www/html/custom_apps（数据卷里），升级镜像和重建容器都不丢。
set -euo pipefail

occ() { # 以 www-data 执行 occ（root 跑 occ 会被拒绝）；参数逐个单引号转义，值进不了 shell
	local cmd="php /var/www/html/occ" a
	for a in "$@"; do cmd+=" '${a//\'/\'\\\'\'}'"; done
	su -p www-data -s /bin/sh -c "$cmd"
}

# 反代设置：网关保留 Host，带 X-Forwarded-For/Proto。overwriteprotocol 跟着插件网页地址的协议走
# （生产 https、开发 http），不猜环境；trusted_proxies 填核心容器在本插件网络的地址，客户端 IP
# 和限流才看到真实来源。身份提供方别名只在该插件网络里存在，解析不到说明核心没就位，装不下。
url="$WONTON_APP_URL"
proto="${url%%://*}"
hostport="$(printf '%s' "${url#*://}" | cut -d/ -f1)"
occ config:system:set overwrite.cli.url --value="$url"
occ config:system:set overwriteprotocol --value="$proto"
occ config:system:set trusted_domains 1 --value="$hostport"

auth_host="$(printf '%s' "$WONTON_OIDC_ISSUER" | cut -d/ -f3)"
auth_host="${auth_host%%:*}" # 开发环境的 issuer 带端口，解析主机名要去掉
proxy_ip=""
for _ in 1 2 3 4 5; do
	proxy_ip="$(getent ahostsv4 "$auth_host" | awk '{print $1; exit}')"
	[ -n "$proxy_ip" ] && break
	sleep 5
done
[ -n "$proxy_ip" ] || { echo "解析不了 $auth_host（核心身份提供方别名），拿不到 trusted_proxies" >&2; exit 1; }
occ config:system:set trusted_proxies 0 --value="$proxy_ip"
# 签发方是插件网络里的内网名字，不是回环：Nextcloud 的 HTTP 客户端默认拒绝本地地址，放行（否则登录页报
# "Could not reach the OpenID Connect provider."）。--type boolean 要给，只给 --value 1 会存成字符串判断不过。
occ config:system:set allow_local_remote_servers --value true --type boolean

# 容器只经核心网关访问，TLS 在网关上终结；放开 user_oidc 的 https 限制，开发环境（http）也能走 OIDC。
occ config:app:set user_oidc allow_insecure_http --value 1

# 密钥经环境变量传给 occ（--clientsecret-env），不进命令行参数。
if [ ! -d /var/www/html/custom_apps/user_oidc ]; then
	occ app:install user_oidc
fi
occ app:enable user_oidc

occ user_oidc:provider wonton \
	--clientid "$WONTON_OIDC_CLIENT_ID" \
	--clientsecret-env WONTON_OIDC_CLIENT_SECRET \
	--discoveryuri "$WONTON_OIDC_ISSUER/.well-known/openid-configuration" \
	--scope "openid profile email" \
	--unique-uid 0 \
	--send-id-token-hint 1

# webui.path 指向 /apps/user_oidc/login/1，要求提供方 ID 恰好是 1（新库的第一个 provider）。
provider_id="$(occ user_oidc:provider wonton --output json | php -r 'echo json_decode(stream_get_contents(STDIN), true)["id"] ?? "";')"
[ "$provider_id" = "1" ] || {
	echo "user_oidc 提供方 ID 是 $provider_id，不是 1；清单 webui.path 指向的 /apps/user_oidc/login/1 会 404" >&2
	exit 1
}
# 登录时 user_oidc 会取发现文档；这里先自检一次，取不到就装不上并写明原因（失败即停，别等用户登录才失败）。
# 请求是发往 *.localhost 的：容器里 curl 会把它当 127.0.0.1，由同 netns 的 oidc-relay 转给核心。
curl -fsS --noproxy '*' "$WONTON_OIDC_ISSUER/.well-known/openid-configuration" >/dev/null || {
	echo "取不到身份提供方发现文档：$WONTON_OIDC_ISSUER/.well-known/openid-configuration（容器内解析或访问失败）" >&2
	exit 1
}
