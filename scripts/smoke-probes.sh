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
nc_core() { # 核心容器：Mailpit 的别名和 API 密码都在它的网络上/数据目录里
	docker ps --format '{{.Names}}' | grep -xE "wonton-${SMOKE_INSTANCE:-}--core" | head -1
}

nc_mailpit() { # <path>：调 Mailpit API（basic core:<密码>）。主路照核心自己的冒烟：在核心网络里
	# 打 mailpit.wonton.internal:8025；兜底用应用容器的 wget（它的网络里也有这个别名）。
	local core pw dd out webc
	core="$(nc_core)" || return 1
	if declare -F read_env >/dev/null; then dd="$(read_env WONTON_DATA_DIR)"; else dd="$(probes_setting WONTON_DATA_DIR)"; fi
	pw="$(docker exec "$core" cat "$dd/core/mailpit/api-password" 2>/dev/null)"
	[[ -n "${pw:-}" ]] || { echo "读不到 Mailpit API 密码（核心数据目录 core/mailpit/api-password）"; return 1; }
	out="$(docker run --rm --network "container:$core" curlimages/curl:8.23.0 \
		-s -u "core:$pw" "http://mailpit.wonton.internal:8025$1" 2>&1)"
	if jq -e '.messages' <<<"$out" >/dev/null 2>&1 || [[ "$out" == "{"* ]]; then
		printf '%s' "$out"; return 0
	fi
	webc="$(docker ps --format '{{.Names}}' | grep "$SMOKE_INSTANCE" | grep 'nextcloud' | head -1)"
	[[ -n "$webc" ]] || { echo "Mailpit 主路没拿到 JSON：$(head -c 200 <<<"$out")"; return 1; }
	docker exec "$webc" wget -qO- --header "Authorization: Basic $(printf 'core:%s' "$pw" | base64 | tr -d '\n')" \
		"http://smtp.wonton.internal:8025$1" 2>&1
}

nc_mailpit_wait() { # <from> <to> [次数=20]：等一封 From/To 对上的信进 Mailpit
	local from="$1" to="$2" n="${3:-20}" i out
	for ((i = 0; i < n; i++)); do
		out="$(nc_mailpit "/api/v1/messages?limit=100")" || { sleep 3; continue; }
		jq -e --arg f "$from" --arg t "$to" \
			'.messages | any(.From.Address == $f and any(.To[]; .Address == $t))' <<<"$out" >/dev/null 2>&1 && return 0
		sleep 3
	done
	return 1
}

nc_mailpit_wait_gone() { # <to> [次数=20]：等收件人的信从 Mailpit 里消失（核心投进私聊后会把信删掉）
	local to="$1" n="${2:-20}" i out
	for ((i = 0; i < n; i++)); do
		out="$(nc_mailpit "/api/v1/messages?limit=100")" || { sleep 3; continue; }
		jq -e --arg t "$to" '(.messages | map(select(.To[].Address == $t)) | length) == 0' <<<"$out" >/dev/null 2>&1 && return 0
		sleep 3
	done
	return 1
}

extra_check() { # 发信端到端：真实分享邮件进 Mailpit（From=内部发件地址、To=主人内部邮箱），被核心投进私聊后取走删除
	local marker origin token file resp to
	origin="$(origin_of "$SMOKE_WEB_URL")"
	to="${SMOKE_OWNER:-owner}@wonton.internal"
	oidc_login "$SMOKE_JAR" || { echo "登录链没建立应用会话"; return 1; }
	token="$(requesttoken "$SMOKE_JAR")" || { echo "取不到 CSRF 令牌"; return 1; }
	# 上传一个小文件，用「通过邮件分享」发给主人的内部邮箱：应用的真实发信路径。
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
	grep -q '<code>200</code>\|"code":200' <<<"$resp" ||
		{ echo "邮件分享没成功：$(head -c 200 <<<"$resp")"; return 1; }
	# 信进内部邮箱：From 是 WONTON_MAIL_FROM（com.nextcloud.nextcloud@plugins.wonton.internal）。
	nc_mailpit_wait "com.nextcloud.nextcloud@plugins.wonton.internal" "$to" 20 ||
		{ echo "分享邮件 60 秒没进 Mailpit：$(nc_mailpit '/api/v1/messages?limit=5' | head -c 300)"; return 1; }
	echo "分享邮件已进内部邮箱（To=$to）"
	# 核心投进收件人私聊后把信从 Mailpit 删掉：信箱里没有这封信 = 已投递。
	nc_mailpit_wait_gone "$to" 20 ||
		{ echo "分享邮件一直留在 Mailpit：核心没把它投进主人私聊（投完才会删）"; return 1; }
	echo "核心已把信投进主人的 Wonton 私聊（Mailpit 里已删除）"
}
