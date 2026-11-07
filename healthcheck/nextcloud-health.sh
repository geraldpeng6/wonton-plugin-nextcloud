#!/bin/sh
# 真正可用：status.php 由完整 Web 栈答出来且装完（"installed":true），数据库也真连得上。
# status.php 不查库——库挂了它照样 200，所以要补一条直连 MySQL 的检查。
set -eu
curl -fsS http://127.0.0.1/status.php | grep -q '"installed":true'
php -r "try { new PDO('mysql:host=' . getenv('MYSQL_HOST') . ';dbname=' . getenv('MYSQL_DATABASE'), getenv('MYSQL_USER'), getenv('MYSQL_PASSWORD')); } catch (Throwable \$e) { exit(1); }"
