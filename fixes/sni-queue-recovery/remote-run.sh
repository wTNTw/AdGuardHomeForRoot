#!/bin/bash
# remote-run.sh -- 本机调试辅助：把本地脚本 scp 到路由器再执行
#
#   AGH_HOST=root@192.168.31.2 AGH_PASS='…' ./remote-run.sh ./some-script.sh
#
# 凭据只从环境变量读，不写死在文件里（避免误提交到仓库）。
# 只用于排查，不是部署的一部分。
set -eu

: "${AGH_HOST:?需要 AGH_HOST，例如 root@192.168.31.2}"
: "${AGH_PASS:?需要 AGH_PASS}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

sshpass -p "$AGH_PASS" scp -O "${SSH_OPTS[@]}" "$1" "$AGH_HOST:/tmp/remote-run.sh"
sshpass -p "$AGH_PASS" ssh "${SSH_OPTS[@]}" -T "$AGH_HOST" "sh /tmp/remote-run.sh"
