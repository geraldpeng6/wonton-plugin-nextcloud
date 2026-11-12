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
# 应用会话用 dweb --sso 建：从清单 webui.path 的入口（/apps/user_oidc/login/1）出发，提交核心登录页的
# 自动表单并跟完 user_oidc 的回调重定向，落下来的 jar 已带 Nextcloud 会话；每次重建，不依赖旧状态。

nc_session() { # 重建应用会话（jar 可能过期；重装后核心也换过）
	dweb --sso / >/dev/null || { echo "应用的 SSO 登录链走不通" >&2; return 1; }
}

web_assert() { # 未登录 Nextcloud 时根路径 302 到登录页：登录页就是应用的真实页面
	grep -qi 'nextcloud'
}

identity_check() { # Nextcloud 的“当前用户”接口（OCS XML）：断言认出的就是主人本人，且在 admin 组（管理员）
	local me
	nc_session || return 1
	me="$(curl -sS --noproxy '*' --max-time 60 --fail-with-body -b "$SMOKE_JAR" -H 'OCS-APIRequest: true' \
		"$SMOKE_WEB_ORIGIN/ocs/v1.php/cloud/user")" || { echo "当前用户接口失败：$me"; return 1; }
	grep -q "<id>$SMOKE_OWNER</id>" <<<"$me" || { echo "当前用户不是 $SMOKE_OWNER：$(head -c 300 <<<"$me")"; return 1; }
	grep -q '<element>admin</element>' <<<"$me" || { echo "$SMOKE_OWNER 不在 admin 组：$(head -c 300 <<<"$me")"; return 1; }
}

requesttoken() { # <jar>：DAV 的写操作靠会话 cookie 认证时要带 CSRF 令牌，否则回 401/412
	curl -sS --noproxy '*' --max-time 30 --fail-with-body -b "$1" "$SMOKE_WEB_ORIGIN/csrftoken" | jq -er '.token'
}

data_write() { # 建一个带随机标记的文件夹、传一个内容也是标记的文件，标记存进 $SMOKE_STATE
	local marker token
	marker="$(head -c 12 /dev/urandom | base64 | tr -d '=+/' | head -c 16)"
	printf '%s' "$marker" >"$SMOKE_STATE"
	nc_session || return 1
	token="$(requesttoken "$SMOKE_JAR")" || { echo "取不到 CSRF 令牌"; return 1; }
	curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		--fail-with-body -X MKCOL "$SMOKE_WEB_ORIGIN/remote.php/dav/files/$SMOKE_OWNER/wonton-smoke-$marker" >/dev/null ||
		{ echo "建目录失败"; return 1; }
	curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		--fail-with-body -T "$SMOKE_STATE" \
		"$SMOKE_WEB_ORIGIN/remote.php/dav/files/$SMOKE_OWNER/wonton-smoke-$marker/marker.txt" >/dev/null ||
		{ echo "传文件失败"; return 1; }
}

data_check() { # 读回标记：文件内容一致，目录也在
	local marker dir body listing token
	marker="$(cat "$SMOKE_STATE")"
	dir="wonton-smoke-$marker"
	nc_session || return 1
	token="$(requesttoken "$SMOKE_JAR")" || { echo "取不到 CSRF 令牌"; return 1; }
	body="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		--fail-with-body "$SMOKE_WEB_ORIGIN/remote.php/dav/files/$SMOKE_OWNER/$dir/marker.txt")" ||
		{ echo "读不回 marker.txt（目录 $dir 不在或内容丢了）"; return 1; }
	[[ "$body" == "$marker" ]] || { echo "marker.txt 内容对不上：写了 $marker，读到 ${body:0:64}"; return 1; }
	listing="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		--fail-with-body -X PROPFIND -H 'Depth: 1' \
		"$SMOKE_WEB_ORIGIN/remote.php/dav/files/$SMOKE_OWNER/")" ||
		{ echo "列根目录失败"; return 1; }
	grep -q "$dir" <<<"$listing" || { echo "根目录里找不到 $dir"; return 1; }
}

# ---------- 发信（notify，规范 0.11）----------
extra_check() { # 发信端到端：用应用的「通过邮件分享」真发一封给主人内部邮箱（应用自己的发信路径），
	# 然后等核心把它投进主人的「Wonton」私聊（读通知房的消息，投递的最终证据）。
	local marker token file resp to sid wp mailf
	to="$SMOKE_OWNER@wonton.internal"
	nc_session || { echo "登录链没建立应用会话"; return 1; }
	token="$(requesttoken "$SMOKE_JAR")" || { echo "取不到 CSRF 令牌"; return 1; }
	# 上传一个小文件，用「通过邮件分享」发给主人的内部邮箱；创建后调 send-email 触发发信
	# （Nextcloud 35 建 share 不会自动发信，网页和这里都要单独调一次）。
	marker="$(head -c 12 /dev/urandom | base64 | tr -d '=+/' | head -c 16)"
	file="wonton-mail-$marker.txt"
	mailf="$(mktemp)"
	printf 'wonton mail probe %s' "$marker" >"$mailf"
	curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		--fail-with-body -T "$mailf" "$SMOKE_WEB_ORIGIN/remote.php/dav/files/$SMOKE_OWNER/$file" >/dev/null ||
		{ rm -f "$mailf"; echo "传分享文件失败"; return 1; }
	rm -f "$mailf"
	resp="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		--fail-with-body --data-urlencode "path=/$file" --data-urlencode "shareType=4" \
		--data-urlencode "shareWith=$to" \
		"$SMOKE_WEB_ORIGIN/ocs/v2.php/apps/files_sharing/api/v1/shares")" ||
		{ echo "邮件分享请求失败：$(head -c 200 <<<"$resp")"; return 1; }
	grep -q '<statuscode>200</statuscode>\|"statuscode":200' <<<"$resp" ||
		{ echo "邮件分享没成功：$(head -c 200 <<<"$resp")"; return 1; }
	sid="$(grep -oE '<id>[0-9]+</id>' <<<"$resp" | head -1 | tr -dc 0-9)"
	[[ -n "$sid" ]] || { echo "分享响应里没有 id：$(head -c 200 <<<"$resp")"; return 1; }
	# 等待先挂后台再触发（套件的用法）：信进私聊是秒级投递，先等后发才等得到。
	probes_owner_room_wait 120 "$marker" & wp=$!
	resp="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "requesttoken: $token" -H 'OCS-APIRequest: true' \
		-X POST "$SMOKE_WEB_ORIGIN/ocs/v2.php/apps/files_sharing/api/v1/shares/$sid/send-email")" ||
		{ kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; echo "触发发信失败：$(head -c 200 <<<"$resp")"; return 1; }
	# 核心把信投进主人的「Wonton」私聊：房里出现这一封（标记在文件名/正文里）。
	wait "$wp" ||
		{ echo "分享邮件 120 秒没出现在主人的 Wonton 私聊（房里没这封信）"; return 1; }
	echo "分享邮件已进主人的 Wonton 私聊（Nextcloud：owner shared $file with you）"
}
