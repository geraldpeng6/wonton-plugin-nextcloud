#!/bin/sh
# 真正可用：status.php 由完整 Web 栈答出来且装完（"installed":true），数据库也真连得上。
# status.php 不查库——库挂了它照样 200，所以要补一条直连 MySQL 的检查。
# 应用听 8080（见 apache/ports.conf）。核心网页端口也是 8080 时，转发也要绑 127.0.0.1:8080：
# apache 可能起不来（连不上），或者答话的是转发到核心的那一头（内容对不上 status.php），两种都如实失败。
# 再检查一次身份提供方：登录要靠 127.0.0.1:<核心端口> 上的转发（只有签发方是 *.localhost 才起转发），
# 转发没了或应用被换进了新沙箱时这条从应用这一侧就能看见，网页登录才不会悄悄坏掉。
set -eu
# 记下本容器的 netns 号（在数据卷里），relay 拿它和自己比：对不上就是应用重启换过沙箱、转发已经失效。
readlink /proc/self/ns/net >/var/www/html/.wonton-netns
curl -fsS http://127.0.0.1:8080/status.php | grep -q '"installed":true'
php -r "try { new PDO('mysql:host=' . getenv('MYSQL_HOST') . ';dbname=' . getenv('MYSQL_DATABASE'), getenv('MYSQL_USER'), getenv('MYSQL_PASSWORD')); } catch (Throwable \$e) { exit(1); }"
if [ -n "${WONTON_OIDC_ISSUER:-}" ]; then
	auth="${WONTON_OIDC_ISSUER#*://}"
	auth="${auth%%/*}"
	host="${auth%%:*}"
	port=80
	case "$WONTON_OIDC_ISSUER" in https:*) port=443 ;; esac
	case "$auth" in
		*:*) port="${auth##*:}" ;;
	esac
	case "$host" in
		*.localhost)
			# 端口上的可能是 http 也可能是 https（TLS 在网关终结，转到 127.0.0.1 时证书名对不上，用 -k）。
			code=000
			for proto in http https; do
				code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 --noproxy '*' "$proto://127.0.0.1:$port/" || true)"
				[ "$code" = 000 ] || break
			done
			[ "$code" != 000 ] || { echo "经 127.0.0.1:$port 到不了身份提供方" >&2; exit 1; } ;;
	esac
fi
