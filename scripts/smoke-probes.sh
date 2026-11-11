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

oidc_login() { # <jar 文件>：走完 OIDC 链把 Nextcloud 会话写进会话 jar。
	# user_oidc 的回调 /apps/user_oidc/code 自己也是 302（换完会话跳回首页），不能一把 -L 跟到底——
	# code/state 只出现在到达回调前的那个跳转地址上，所以逐跳跟；会话已有效时链里没有回调，
	# user_oidc 把登录入口直接跳回首页，落到 Nextcloud 页面即视为已登录，幂等返回 0。
	local jar="$1" origin url next code state resp
	# 同一台机器可能同时跑两个 nextcloud 冒烟，响应体不能落在固定的 /tmp 名字上
	resp="$(mktemp)"
	origin="$(origin_of "$SMOKE_WEB_URL")"
	# e2e 在身份项之前就会跑数据钩子，那时核心会话还没建立、jar 是空的（第一步就 401）。有令牌就照
	# web_login 的做法自己登：先拿令牌换核心会话，再打开插件根让网关把会话换成应用的，之后照常走登录链。
	# 都带 -b 才不会把 jar 覆盖没了；已登录时幂等；没有令牌（dev.sh probes）就跳过。
	if [[ -n ${SMOKE_TOKEN:-} ]]; then
		core="${SMOKE_BASE:-$(sed -E 's#^(https?://)[^./]+\.#\1#' <<<"$origin")}"
		curl -sS --noproxy '*' --max-time 30 -o /dev/null -b "$jar" -c "$jar" \
			--data-urlencode "token=$SMOKE_TOKEN" "$core/_wonton/login" ||
			{ echo "核心登录失败"; rm -f "$resp"; return 1; }
		curl -sS --noproxy '*' --max-time 60 -o /dev/null -L -b "$jar" -c "$jar" -H 'Accept: text/html' "$origin/" ||
			{ echo "打开插件根失败"; rm -f "$resp"; return 1; }
	fi
	url="$origin/apps/user_oidc/login/1"
	for _ in 1 2 3 4 5 6 7 8; do
		[[ "$url" == *"/apps/user_oidc/code?"* ]] && break
		next="$(curl -sS --noproxy '*' -o "$resp" -b "$jar" -c "$jar" -w '%{redirect_url}' "$url")" ||
			{ echo "请求失败：$url"; rm -f "$resp"; return 1; }
		[[ -n "$next" ]] && url="$next"
	done
	if [[ "$url" == *"/apps/user_oidc/code?"* ]]; then
		code="$(qparam "$url" code)"
		state="$(qparam "$url" state)"
		[[ -n "$code" && -n "$state" ]] || { echo "回调里没有 code/state：$url"; rm -f "$resp"; return 1; }
		curl -sS --noproxy '*' -o /dev/null -b "$jar" -c "$jar" --fail-with-body \
			--get --data-urlencode "code=$code" --data-urlencode "state=$state" \
			"$origin/apps/user_oidc/code" || { echo "code 换会话失败"; rm -f "$resp"; return 1; }
	else
		grep -qi 'nextcloud' "$resp" ||
			{ echo "登录链没有产生回跳，也没落到 Nextcloud 页面：$(head -c 200 "$resp" | tr '\n' ' ')"; rm -f "$resp"; return 1; }
	fi
	rm -f "$resp"
}

web_assert() { # 未登录 Nextcloud 时根路径 302 到登录页：登录页就是应用的真实页面
	grep -qi 'nextcloud'
}

identity_check() { # Nextcloud 的“当前用户”接口（OCS XML）：断言认出的就是主人本人，且在 admin 组（管理员）
	local me
	oidc_login "$SMOKE_JAR" || return 1
	# 不用 web_get：SMOKE_WEB_URL 可能带 webui.path 入口路径，拼子路径会错，这里一律用源点。
	me="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'OCS-APIRequest: true' \
		"$(origin_of "$SMOKE_WEB_URL")/ocs/v1.php/cloud/user")" || { echo "当前用户接口失败：$me"; return 1; }
	grep -q "<id>$SMOKE_OWNER</id>" <<<"$me" || { echo "当前用户不是 $SMOKE_OWNER：$(head -c 300 <<<"$me")"; return 1; }
	grep -q '<element>admin</element>' <<<"$me" || { echo "$SMOKE_OWNER 不在 admin 组：$(head -c 300 <<<"$me")"; return 1; }
}

requesttoken() { # <jar>：DAV 的写操作靠会话 cookie 认证时要带 CSRF 令牌，否则回 401/412
	curl -sS --noproxy '*' --fail-with-body -b "$1" "$(origin_of "$SMOKE_WEB_URL")/csrftoken" | jq -er '.token'
}

data_write() { # 建一个带随机标记的文件夹、传一个内容也是标记的文件，标记存进状态目录
	local marker origin token
	marker="$(head -c 12 /dev/urandom | base64 | tr -d '=+/' | head -c 16)"
	printf '%s' "$marker" >"$(marker_file)"
	origin="$(origin_of "$SMOKE_WEB_URL")"
	oidc_login "$SMOKE_JAR" || return 1
	token="$(requesttoken "$SMOKE_JAR")" || { echo "取不到 CSRF 令牌"; return 1; }
	curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		--fail-with-body -X MKCOL "$origin/remote.php/dav/files/$SMOKE_OWNER/wonton-smoke-$marker" >/dev/null ||
		{ echo "建目录失败"; return 1; }
	curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		--fail-with-body -T "$(marker_file)" \
		"$origin/remote.php/dav/files/$SMOKE_OWNER/wonton-smoke-$marker/marker.txt" >/dev/null ||
		{ echo "传文件失败"; return 1; }
}

data_check() { # 读回标记：文件内容一致，目录也在
	local marker dir origin body listing token
	marker="$(cat "$(marker_file)")"
	dir="wonton-smoke-$marker"
	origin="$(origin_of "$SMOKE_WEB_URL")"
	oidc_login "$SMOKE_JAR" || return 1
	token="$(requesttoken "$SMOKE_JAR")" || { echo "取不到 CSRF 令牌"; return 1; }
	body="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		--fail-with-body "$origin/remote.php/dav/files/$SMOKE_OWNER/$dir/marker.txt")" ||
		{ echo "读不回 marker.txt（目录 $dir 不在或内容丢了）"; return 1; }
	[[ "$body" == "$marker" ]] || { echo "marker.txt 内容对不上：写了 $marker，读到 ${body:0:64}"; return 1; }
	listing="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		--fail-with-body -X PROPFIND -H 'Depth: 1' \
		"$origin/remote.php/dav/files/$SMOKE_OWNER/")" ||
		{ echo "列根目录失败"; return 1; }
	grep -q "$dir" <<<"$listing" || { echo "根目录里找不到 $dir"; return 1; }
}

qparam() { # <url> <名字>：取查询参数
	python3 -c 'import sys,urllib.parse;print((urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query).get(sys.argv[2]) or [""])[0])' "$1" "$2"
}

# ---------- 发信（notify，规范 0.11）----------
nc_core() { # 核心容器：Mailpit 的别名、API 密码和 Matrix 记录都在它的网络上/数据目录里
	docker ps --format '{{.Names}}' | grep -xE "wonton-${SMOKE_INSTANCE:-}--core" | head -1
}

nc_dd() { # 核心数据目录（e2e 冒烟有 read_env；dev.sh probes 用 probes_setting）
	if declare -F read_env >/dev/null; then read_env WONTON_DATA_DIR; else probes_setting WONTON_DATA_DIR; fi
}

nc_room_wait() { # <超时秒> <要找的文字>：等主人的「Wonton」私聊出现这段文字。用套件 probes.sh 的
	# probes_owner_room_wait（随 main 的 kit 同步修），在独立进程里跑，套件的 pass/fail 不盖进冒烟自己的 shell。
	# 文字里带每次随机的标记，旧信不会误配；等待开始即计时，信到多快都等得到（无轮询竞态）。
	local core dd pdir
	core="$(nc_core)" || return 1
	dd="$(nc_dd)"
	pdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck disable=SC2016 # 单引号里是子进程 bash 的变量，$1/$2/$3 是 bash -c 的位置参数
	env SMOKE_CORE="$core" SMOKE_DATA_DIR="$dd" SMOKE_OWNER="${SMOKE_OWNER:-owner}" \
		bash -c 'source "$1/lib.sh" && source "$1/probes.sh" && probes_owner_room_wait "$2" "$3"' \
		_ "$pdir" "$1" "$2"
}

extra_check() { # 发信端到端：用应用的「通过邮件分享」真发一封给主人内部邮箱（应用自己的发信路径），
	# 然后等核心把它投进主人的「Wonton」私聊（读通知房的消息，投递的最终证据）。
	local marker origin token file resp to sid wp
	origin="$(origin_of "$SMOKE_WEB_URL")"
	to="${SMOKE_OWNER:-owner}@wonton.internal"
	oidc_login "$SMOKE_JAR" || { echo "登录链没建立应用会话"; return 1; }
	token="$(requesttoken "$SMOKE_JAR")" || { echo "取不到 CSRF 令牌"; return 1; }
	# 上传一个小文件，用「通过邮件分享」发给主人的内部邮箱；创建后调 send-email 触发发信
	# （Nextcloud 35 建 share 不会自动发信，网页和这里都要单独调一次）。
	marker="$(head -c 12 /dev/urandom | base64 | tr -d '=+/' | head -c 16)"
	file="wonton-mail-$marker.txt"
	printf 'wonton e2e mail probe %s' "$marker" >"$(marker_file).mail"
	curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		--fail-with-body -T "$(marker_file).mail" "$origin/remote.php/dav/files/${SMOKE_OWNER:-owner}/$file" >/dev/null ||
		{ echo "传分享文件失败"; return 1; }
	resp="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		--fail-with-body --data-urlencode "path=/$file" --data-urlencode "shareType=4" \
		--data-urlencode "shareWith=$to" \
		"$origin/ocs/v2.php/apps/files_sharing/api/v1/shares")" ||
		{ echo "邮件分享请求失败：$(head -c 200 <<<"$resp")"; return 1; }
	grep -q '<statuscode>200</statuscode>\|"statuscode":200' <<<"$resp" ||
		{ echo "邮件分享没成功：$(head -c 200 <<<"$resp")"; return 1; }
	sid="$(grep -oE '<id>[0-9]+</id>' <<<"$resp" | head -1 | tr -dc 0-9)"
	[[ -n "$sid" ]] || { echo "分享响应里没有 id：$(head -c 200 <<<"$resp")"; return 1; }
	# 等待先挂后台再触发（模板的用法）：信进私聊是秒级投递，先等后发才等得到。
	nc_room_wait 120 "$marker" & wp=$!
	resp="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		-X POST "$origin/ocs/v2.php/apps/files_sharing/api/v1/shares/$sid/send-email")" ||
		{ kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; echo "触发发信失败：$(head -c 200 <<<"$resp")"; return 1; }
	# 核心把信投进主人的「Wonton」私聊：房里出现这一封（标记在文件名/正文里）。
	wait "$wp" ||
		{ echo "分享邮件 120 秒没出现在主人的 Wonton 私聊（房里没这封信）"; return 1; }
	echo "分享邮件已进主人的 Wonton 私聊（Nextcloud：owner shared $file with you）"
}
