#!/bin/sh
# 真正可用：status.php 由完整 Web 栈答出来且装完（"installed":true），数据库也真连得上。
# status.php 不查库——库挂了它照样 200，所以要补一条直连 MySQL 的检查。
# 应用听 8080（见 apache/ports.conf）。核心网页端口也是 8080 时，转发也要绑 127.0.0.1:8080：
# apache 可能起不来（连不上），或者答话的是转发到核心的那一头（内容对不上 status.php），两种都如实失败。
set -eu
curl -fsS http://127.0.0.1:8080/status.php | grep -q '"installed":true'
php -r "try { new PDO('mysql:host=' . getenv('MYSQL_HOST') . ';dbname=' . getenv('MYSQL_DATABASE'), getenv('MYSQL_USER'), getenv('MYSQL_PASSWORD')); } catch (Throwable \$e) { exit(1); }"
