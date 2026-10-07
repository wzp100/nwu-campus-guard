"""通过 SSH 把校园网守护安装到 OpenWrt / iStoreOS 路由器。

用法：python scripts/deploy.py [root@192.168.1.1]

已有的 /etc/config/campus_guard（含学号密码）不会被覆盖。
"""
from pathlib import Path
import io
import subprocess
import sys
import tarfile
import time

sys.stdout.reconfigure(encoding='utf-8')
repo = Path(__file__).resolve().parent.parent
host = sys.argv[1] if len(sys.argv) > 1 else 'root@192.168.1.1'
ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host]

files = {}
for path in (repo / 'root').rglob('*'):
    if path.is_file():
        files[path] = '/' + path.relative_to(repo / 'root').as_posix()
for path in (repo / 'luasrc').rglob('*'):
    if path.is_file():
        files[path] = '/usr/lib/lua/luci/' + path.relative_to(repo / 'luasrc').as_posix()
config = files.pop(repo / 'root/etc/config/campus_guard')

archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode='w') as tf:
    for source, target in sorted(files.items(), key=lambda item: item[1]):
        data = source.read_bytes().replace(b'\r\n', b'\n')
        info = tarfile.TarInfo(target.lstrip('/'))
        info.size = len(data)
        info.mtime = int(time.time())
        info.mode = 0o755 if target.startswith('/etc/init.d/') or target.endswith('.sh') else 0o644
        tf.addfile(info, io.BytesIO(data))

subprocess.run(ssh + ['tar -x -f - -C /'], input=archive.getvalue(), check=True)
# 首次安装才写入默认配置；旧版本的两个独立视图已合并进 dashboard.htm。
subprocess.run(ssh + ['umask 077; [ -f /etc/config/campus_guard ] || cat > /etc/config/campus_guard'],
               input=config.read_bytes().replace(b'\r\n', b'\n'), check=True)
subprocess.run(ssh + [
    'set -e; chmod 600 /etc/config/campus_guard;'
    ' rm -f /usr/lib/lua/luci/view/campus_guard/status.htm /usr/lib/lua/luci/view/campus_guard/statistics.htm;'
    ' for f in /usr/share/campus-guard/*.lua /usr/lib/lua/luci/controller/campus_guard.lua /usr/lib/lua/luci/model/cbi/campus_guard.lua;'
    ' do lua -e "assert(loadfile(\'$f\'))"; done;'
    ' sh -n /usr/share/campus-guard/loop.sh; sh -n /etc/init.d/campus-guard;'
    ' rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true;'
    ' /etc/init.d/campus-guard enable; /etc/init.d/campus-guard restart;'
    ' echo "已安装到 $(uname -n)，在 LuCI → 服务 → 校园网守护 中填写学号密码"'
], check=True)
