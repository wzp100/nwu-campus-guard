"""打包 OpenWrt / iStoreOS 可直接安装的 ipk（纯脚本，架构 all）。

用法：python scripts/build-ipk.py 1.0.0
输出：dist/luci-app-campus-guard_<版本>-r1_all.ipk
"""
from pathlib import Path
import io
import re
import sys
import tarfile
import time

PACKAGE = 'luci-app-campus-guard'
DEPENDS = 'libc, lua, curl, luci-compat, luci-lib-jsonc, luci-lib-nixio'
CONFFILE = '/etc/config/campus_guard'

POSTINST = """#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
chmod 600 /etc/config/campus_guard
# 旧版手动安装留下的两个独立视图已合并进 dashboard.htm
rm -f /usr/lib/lua/luci/view/campus_guard/status.htm /usr/lib/lua/luci/view/campus_guard/statistics.htm
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/campus-guard enable
/etc/init.d/campus-guard restart
exit 0
"""

PRERM = """#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/campus-guard stop 2>/dev/null
/etc/init.d/campus-guard disable 2>/dev/null
exit 0
"""

repo = Path(__file__).resolve().parent.parent
version = sys.argv[1].lstrip('v') if len(sys.argv) > 1 else '0.0.0'
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    sys.exit('版本号格式应为 1.2.3')
full_version = version + '-r1'
mtime = int(time.time())


def files():
    for path in sorted((repo / 'root').rglob('*')):
        if path.is_file():
            yield path, '/' + path.relative_to(repo / 'root').as_posix()
    for path in sorted((repo / 'luasrc').rglob('*')):
        if path.is_file():
            yield path, '/usr/lib/lua/luci/' + path.relative_to(repo / 'luasrc').as_posix()


def mode_of(target):
    if target == CONFFILE:
        return 0o600
    if target.startswith('/etc/init.d/') or target.endswith('.sh'):
        return 0o755
    return 0o644


def add(tf, name, data=None, mode=0o644):
    info = tarfile.TarInfo(name)
    info.mtime = mtime
    info.uid = info.gid = 0
    info.uname = info.gname = 'root'
    if data is None:
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        tf.addfile(info)
    else:
        info.size = len(data)
        info.mode = mode
        tf.addfile(info, io.BytesIO(data))


def targz(build):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz', format=tarfile.GNU_FORMAT) as tf:
        build(tf)
    return buf.getvalue()


entries = [(target, src.read_bytes().replace(b'\r\n', b'\n')) for src, target in files()]
installed_size = sum(len(data) for _, data in entries)


def build_data(tf):
    dirs = set()
    for target, _ in entries:
        parts = target.strip('/').split('/')[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add('/'.join(parts[:i]))
    for d in sorted(dirs):
        add(tf, './' + d + '/')
    for target, data in entries:
        add(tf, '.' + target, data, mode_of(target))


control = f"""Package: {PACKAGE}
Version: {full_version}
Depends: {DEPENDS}
Source: https://github.com/wzp100/nwu-campus-guard
SourceName: {PACKAGE}
License: MIT
Section: luci
URL: https://github.com/wzp100/nwu-campus-guard
Maintainer: wzp100
Architecture: all
Installed-Size: {installed_size}
Description: NWU 校园网守护：检测西北大学校园网认证状态，掉线后自动重登，并统计流量与在线时长。
"""


def build_control(tf):
    add(tf, './')
    add(tf, './control', control.encode())
    add(tf, './conffiles', (CONFFILE + '\n').encode())
    add(tf, './postinst', POSTINST.encode(), 0o755)
    add(tf, './prerm', PRERM.encode(), 0o755)


def build_ipk(tf):
    add(tf, './debian-binary', b'2.0\n')
    add(tf, './data.tar.gz', targz(build_data))
    add(tf, './control.tar.gz', targz(build_control))


out = repo / 'dist' / f'{PACKAGE}_{full_version}_all.ipk'
out.parent.mkdir(exist_ok=True)
out.write_bytes(targz(build_ipk))
print(out)
