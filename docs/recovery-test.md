# 校园网断网恢复测试

2026-10-07 实测通过。主路由 192.168.1.1 成功退出校园网认证后，校园网守护自动重登，约 25 秒恢复；独立备用恢复进程无需介入。最终复查主路由认证、外网及电脑 HTTP 探针均正常。

## 实测记录

- 22:54:17：按校园认证页面实际流程，调用本机 MAC 解绑及退出接口，返回成功。
- 22:54:18：观察到认证已退出。
- 22:54:22：外网探针失败，出现校园认证重定向。
- 22:54:40：校园网守护自动登录。
- 22:54:42：认证在线，域名与 IP 两个外网探针均通过。
- 备用恢复进程延迟 180 秒检查，发现网络已恢复，未提交登录。
- 23:00:29：电脑 HTTP 探针、路由认证及外网复查通过。

恢复时间以发送有效退出请求到两项外网探针及认证状态恢复为准，包含轮询间隔。普通注销接口在这次环境中返回超时，不能证明退出成功；脚本已按校园网页的 `mac/unbind` 流程处理，仅针对主路由当前在线账号及本机连接。

## 路由器上再次运行

两个脚本已经部署：

```text
/usr/share/campus-guard/test-recovery.lua
/usr/share/campus-guard/test-recovery.sh
```

仅预检查，不退出认证：

```sh
lua /usr/share/campus-guard/test-recovery.lua --dry-run
```

实际测试应后台启动，保证 SSH 或电脑断网后仍独立执行：

```sh
umask 077
setsid /bin/sh /usr/share/campus-guard/test-recovery.sh > /mnt/nvme0n1-4/Configs/campus-guard/tests/test-run.log 2>&1 < /dev/null &
```

脚本先检查当前认证、外网、已保存账号、守护进程和自动登录开关，再预置独立备用恢复进程，最后执行退出。正常守护最多观察 120 秒，超时则尝试备用认证；独立备用进程从启动后 180 秒开始检查。脚本使用路由器上已保存的账号密码，无需把密码写进测试文件，也不会把密码输出到报告。不会关闭 WAN 或重启路由器。

记录位置：

```text
/mnt/nvme0n1-4/Configs/campus-guard/tests/test-run.log
/mnt/nvme0n1-4/Configs/campus-guard/tests/latest.json
/mnt/nvme0n1-4/Configs/campus-guard/tests/latest-rescue.json
/mnt/nvme0n1-4/Configs/campus-guard/tests/test-日期时间-进程号.json
```

结果 `guard_recovery_pass` 才表示观察到退出且正常守护自动恢复。`guard_failed_rescue_succeeded` 表示备用恢复成功、正常守护未通过；`logout_not_observed` 表示没有观察到退出，不能当作成功。

同目录的 `test-campus-recovery-result.json` 是本次实测记录与最后复查结果。分发的 Lua 和 shell 文件分别对应路由器上的 `test-recovery.lua` 和 `test-recovery.sh`。
