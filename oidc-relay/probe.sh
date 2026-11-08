#!/bin/sh
# oidc-relay 是否真的可用：经回环上的转发取一次核心的答案（TLS 端口上答 400 Bad Request 也算答上——
# 关键是有东西从转发另一头回来）。不转发时（没有目标文件）直接成功。
# 只连监听不算数：netns 换掉以后旧监听还连着也不通，DNS 也是坏的，照样要判失败。
set -u
p="$(cat /tmp/oidc-relay.port 2>/dev/null)" || exit 0
h="$(cat /tmp/oidc-relay.host 2>/dev/null)" || exit 1
# 写入端要按住一会儿：socat 在 stdin 一 EOF 就把连接也关掉，核心回包稍慢就没赶上（实测裸 printf 拿不到，
# 按住之后再慢的服务也能收到）。有回包后由服务端的 close 结束，不会等满。
{ printf 'GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$h"; sleep 2; } |
	socat -T 5 - "TCP:127.0.0.1:$p,connect-timeout=2" | grep -q 'HTTP/'
