#!/bin/sh
# oidc-relay 是否真的可用：经回环上的转发取一次核心的答案（TLS 端口上答 400 Bad Request 也算答上——
# 关键是有东西从转发另一头回来）。不转发时（没有目标文件）直接成功。
# 只连监听不算数：netns 换掉以后旧监听还连着也不通，DNS 也是坏的，照样要判失败。
set -u
p="$(cat /tmp/oidc-relay.port 2>/dev/null)" || exit 0
h="$(cat /tmp/oidc-relay.host 2>/dev/null)" || exit 1
printf 'GET / HTTP/1.0\r\nHost: %s\r\n\r\n' "$h" |
	socat -T 4 - "TCP:127.0.0.1:$p,connect-timeout=2" | grep -q 'HTTP/'
