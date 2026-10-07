#!/bin/sh
# 在主路由上独立执行断网恢复测试；不会关闭 WAN 或重启路由器。
set -eu
umask 077
trap '' HUP
APP=/usr/share/campus-guard/test-recovery.lua
DATA="$(uci -q get campus_guard.main.data_dir || echo /tmp/campus-guard/data)/tests"
LOCK=/tmp/campus-guard/recovery-test-lock
mkdir "$LOCK" || { echo '另一个恢复测试正在执行'; exit 1; }
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
/usr/bin/lua "$APP" --dry-run
mkdir -p "$DATA"
# 恢复进程与测试进程分开，SSH 或测试进程退出仍会继续检查。
rm -f "$DATA/watchdog.pid"
/usr/bin/setsid /bin/sh -c 'trap "" HUP; echo $$ > "$1/watchdog.pid"; sleep 180; exec /usr/bin/lua /usr/share/campus-guard/test-recovery.lua --rescue' campus-rescue "$DATA" >"$DATA/rescue.log" 2>&1 </dev/null &
for attempt in 1 2 3 4 5; do
    [ -s "$DATA/watchdog.pid" ] && break
    sleep 1
done
[ -s "$DATA/watchdog.pid" ] || { echo '备用恢复进程未启动，取消测试'; exit 1; }
WATCHDOG_PID=$(cat "$DATA/watchdog.pid")
kill -0 "$WATCHDOG_PID" || { echo '备用恢复进程未运行，取消测试'; exit 1; }
echo "已预置独立恢复进程 PID=$WATCHDOG_PID（180 秒后检查）"
/usr/bin/lua "$APP" --run
