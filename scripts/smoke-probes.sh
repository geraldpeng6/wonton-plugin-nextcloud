# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 用应用自己的“当前用户”接口断言认出的是用户管理员。没有用户体系时写 IDENTITY_NA=1，
#       并在 SMOKE_NOTE 里写原因。dweb / web_get 是带用户会话的请求助手，可继续走应用自己的登录链。
# 工具：MCP_TOOL 写一个只读工具名（可带插件前缀），MCP_ARGS 是 JSON 参数；mcp_assert 从标准输入读调用结果。
#       要断言多个工具时改成写 mcp_check；调用前要备数据时写 before_mcp。
# 数据：合并前要验证“升级/重装不丢用户数据”时写 data_write 和 data_check（两个都写才跑）：data_write 用随机标记写
#       一条数据并把标记原样存进 $SMOKE_STATE，data_check 读回标记去应用里找，对不上就打印看到了什么并返回非 0。
#       应用不存用户数据时写 DATA_NA=1（两项记 N/A）。
# 装之前要准备（如先配出口代理）：写 before_install。

# 插件清单没有 mcp，工具一项由套件按“清单没有 mcp”记 N/A。

origin_of() { # WEB_URL 可能带入口路径（新核心），一律只取源点
	printf '%s' "$1" | sed -E 's#^(https?://[^/]+).*#\1#'
}

marker_file() { # SMOKE_STATE 在 dev.sh probes 里是目录、在 e2e 里是文件，标记放旁边
	if [[ -d "$SMOKE_STATE" ]]; then
		printf '%s' "$SMOKE_STATE/nextcloud-marker"
	else
		printf '%s' "${SMOKE_STATE}.marker"
	fi
}

oidc_login() { # <jar 文件>：走完 OIDC 链把 Nextcloud 会话写进会话 jar。user_oidc 的 code 换会话在服务端做，
	# 整条链（登录入口 → 身份提供方 → 回调）都是 302，curl 跟得完；会话已有效时 user_oidc 直接跳回首页，幂等。
	local jar="$1" origin start code state body
	origin="$(origin_of "$SMOKE_WEB_URL")"
	start="$(curl -sS --noproxy '*' -o /tmp/nc-login-resp -b "$jar" -c "$jar" \
		-w '%{redirect_url}' "$origin/apps/user_oidc/login/1")" || { echo "进不了 user_oidc 登录入口"; return 1; }
	[[ -n "$start" ]] || {
		echo "登录入口没有 302（响应开头：$(head -c 200 /tmp/nc-login-resp | tr '\n' ' ')）"
		return 1
	}
	final="$(curl -sS --noproxy '*' -o /dev/null -L -b "$jar" -c "$jar" -H 'Accept: text/html' \
		-w '%{url_effective}' "$start")" || { echo "authorize 链失败：$start"; return 1; }
	code="$(qparam "$final" code)"
	state="$(qparam "$final" state)"
	[[ -n "$code" && -n "$state" ]] || { echo "回调里没有 code/state：$final"; return 1; }
	curl -sS --noproxy '*' -o /dev/null -b "$jar" -c "$jar" --fail-with-body \
		--get --data-urlencode "code=$code" --data-urlencode "state=$state" \
		"$origin/apps/user_oidc/code" || { echo "code 换会话失败"; return 1; }
}

web_assert() { # 未登录 Nextcloud 时根路径 302 到登录页：登录页就是应用的真实页面
	grep -qi 'nextcloud'
}

identity_check() { # Nextcloud 的“当前用户”接口（OCS XML）：断言认出的就是主人本人，且在 admin 组（管理员）
	local me
	oidc_login "$SMOKE_JAR" || return 1
	me="$(web_get '/ocs/v1.php/cloud/user' -H 'OCS-APIRequest: true')" || { echo "当前用户接口失败：$me"; return 1; }
	grep -q "<id>$SMOKE_OWNER</id>" <<<"$me" || { echo "当前用户不是 $SMOKE_OWNER：$(head -c 300 <<<"$me")"; return 1; }
	grep -q '<element>admin</element>' <<<"$me" || { echo "$SMOKE_OWNER 不在 admin 组：$(head -c 300 <<<"$me")"; return 1; }
}

data_write() { # 建一个带随机标记的文件夹、传一个内容也是标记的文件，标记存进状态目录
	local marker origin
	marker="$(head -c 12 /dev/urandom | base64 | tr -d '=+/' | head -c 16)"
	printf '%s' "$marker" >"$(marker_file)"
	origin="$(origin_of "$SMOKE_WEB_URL")"
	oidc_login "$SMOKE_JAR" || return 1
	curl -sS --noproxy '*' -b "$SMOKE_JAR" --fail-with-body -X MKCOL \
		"$origin/remote.php/dav/files/$SMOKE_OWNER/wonton-smoke-$marker" >/dev/null ||
		{ echo "建目录失败"; return 1; }
	curl -sS --noproxy '*' -b "$SMOKE_JAR" --fail-with-body -T "$(marker_file)" \
		"$origin/remote.php/dav/files/$SMOKE_OWNER/wonton-smoke-$marker/marker.txt" >/dev/null ||
		{ echo "传文件失败"; return 1; }
}

data_check() { # 读回标记：文件内容一致，目录也在
	local marker dir origin body listing
	marker="$(cat "$(marker_file)")"
	dir="wonton-smoke-$marker"
	origin="$(origin_of "$SMOKE_WEB_URL")"
	oidc_login "$SMOKE_JAR" || return 1
	body="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" --fail-with-body \
		"$origin/remote.php/dav/files/$SMOKE_OWNER/$dir/marker.txt")" ||
		{ echo "读不回 marker.txt（目录 $dir 不在或内容丢了）"; return 1; }
	[[ "$body" == "$marker" ]] || { echo "marker.txt 内容对不上：写了 $marker，读到 ${body:0:64}"; return 1; }
	listing="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" --fail-with-body -X PROPFIND -H 'Depth: 1' \
		"$origin/remote.php/dav/files/$SMOKE_OWNER/")" ||
		{ echo "列根目录失败"; return 1; }
	grep -q "$dir" <<<"$listing" || { echo "根目录里找不到 $dir"; return 1; }
}

qparam() { # <url> <名字>：取查询参数
	python3 -c 'import sys,urllib.parse;print((urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query).get(sys.argv[2]) or [""])[0])' "$1" "$2"
}
