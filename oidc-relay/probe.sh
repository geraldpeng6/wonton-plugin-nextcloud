#!/bin/sh
# oidc-relay 是否真的可用。两条都要成立：
#  1) 本容器还在应用当前的沙箱里。应用容器一重启（崩溃被 restart 拉起、docker restart）netns 就换成新的，
#     relay 留在旧沙箱：转发看着还能用（核心从旧沙箱照样够得着），只有应用自己连不上 127.0.0.1。
#     所以比对 netns：应用的健康检查把自己当前的 netns 号写进数据卷的 .wonton-netns，这里和本进程的比，
#     对不上就是换过沙箱了。文件还没有（应用还没跑过一次检查）时先放行，转发那一步照旧。
#  2) 经回环上的转发真能取到核心的答复（TLS 端口上答 400 Bad Request 也算答上），只连监听不算数。
# 不转发时（没有目标文件，签发方不是 *.localhost）只做 1)。
set -u
[ -f /tmp/oidc-relay.host ] || exit 0
app="$(cat /wonton/app/.wonton-netns 2>/dev/null)"
own="$(readlink /proc/self/ns/net 2>/dev/null)"
[ -n "$own" ] && [ -n "$app" ] && [ "$own" != "$app" ] && exit 1
p="$(cat /tmp/oidc-relay.port 2>/dev/null)" || exit 1
h="$(cat /tmp/oidc-relay.host 2>/dev/null)" || exit 1
# 写入端要按住一会儿：socat 在 stdin 一 EOF 就把连接也关掉，核心回包稍慢就没赶上（实测裸 printf 拿不到，
# 按住之后再慢的服务也能收到）。有回包后由服务端的 close 结束，不会等满。
{ printf 'GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$h"; sleep 2; } |
	socat -T 5 - "TCP:127.0.0.1:$p,connect-timeout=2" | grep -q 'HTTP/'
