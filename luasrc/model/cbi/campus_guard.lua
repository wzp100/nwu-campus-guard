local m=Map('campus_guard', translate('校园网守护'), translate('从主路由 WAN 检测校园网认证状态，确认掉线后自动重新登录，并按小时统计流量与在线时长。不会注销当前认证，也不会重启路由器。'))
local dashboard=m:section(SimpleSection)
dashboard.template='campus_guard/dashboard'
local s=m:section(NamedSection,'main','main',translate('认证设置'))
s.addremove=false
local enabled=s:option(Flag,'enabled',translate('启用检测')); enabled.default='1'; enabled.rmempty=false
local auto=s:option(Flag,'auto_login',translate('认证失效后自动登录')); auto.default='1'; auto.rmempty=false
local username=s:option(Value,'username',translate('学号')); username.rmempty=false
local password=s:option(Value,'password',translate('校园网密码'),translate('仅保存在路由器 /etc/config/campus_guard（权限 600），状态接口不会返回。')); password.password=true; password.rmempty=false
local suffix=s:option(ListValue,'suffix',translate('登录选项'))
suffix:value('campus',translate('校园用户（纯学号）')); suffix:value('@dx',translate('校园电信')); suffix:value('@lt',translate('校园联通')); suffix.default='campus'; suffix.rmempty=true
function suffix.cfgvalue(self,section)
    local value=Value.cfgvalue(self,section)
    return (value==nil or value=='') and 'campus' or value
end
local data_dir=s:option(Value,'data_dir',translate('统计数据目录'),translate('默认在 /tmp，重启后清空；如需长期保存，请改为硬盘上的目录，例如 /mnt/sda1/campus-guard。'))
data_dir.placeholder='/tmp/campus-guard/data'; data_dir.rmempty=true
function data_dir.validate(self,value)
    if value:match('^/[%w_./%-]+$') and not value:find('..',1,true) then return value end
    return nil, translate('请填写绝对路径，只能包含字母、数字、_ . - /')
end
function m.on_after_commit()
    require('nixio.fs').chmod('/etc/config/campus_guard','600')
    luci.sys.call('/etc/init.d/campus-guard restart >/dev/null 2>&1')
end
return m
