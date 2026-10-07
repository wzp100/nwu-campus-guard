local m=Map('campus_guard', translate('校园网守护'), translate('从主路由 WAN 检测网络；确认出现校园网认证跳转后自动登录。不会注销当前认证，不会重启路由器。学号和密码仅保存在主路由配置中。'))
local stats=m:section(NamedSection,'main','main',translate('用量统计'))
stats.addremove=false
local charts=stats:option(DummyValue,'_statistics','')
charts.template='campus_guard/statistics'
local s=m:section(NamedSection,'main','main',translate('检测与认证'))
s.addremove=false
local status=s:option(DummyValue,'_status',translate('当前状态'))
status.template='campus_guard/status'
local enabled=s:option(Flag,'enabled',translate('启用检测')); enabled.default='1'; enabled.rmempty=false
local auto=s:option(Flag,'auto_login',translate('认证失效后自动登录')); auto.default='1'; auto.rmempty=false
local username=s:option(Value,'username',translate('学号')); username.rmempty=false
local password=s:option(Value,'password',translate('校园网密码')); password.password=true; password.rmempty=false
local suffix=s:option(ListValue,'suffix',translate('登录选项'))
suffix:value('campus',translate('校园用户（纯学号）')); suffix:value('@dx',translate('校园电信')); suffix:value('@lt',translate('校园联通')); suffix.default='campus'; suffix.rmempty=true
function suffix.cfgvalue(self,section)
    local value=Value.cfgvalue(self,section)
    return (value==nil or value=='') and 'campus' or value
end
local check=s:option(Button,'_check',translate('立即检测')); check.inputtitle=translate('检测网络'); check.inputstyle='apply'
function check.write()
    luci.sys.call('/usr/bin/lua /usr/share/campus-guard/campus-guard.lua >/dev/null 2>&1 &')
end
function m.on_after_commit()
    require('nixio.fs').chmod('/etc/config/campus_guard','600')
    luci.sys.call('/etc/init.d/campus-guard restart >/dev/null 2>&1')
end
return m
