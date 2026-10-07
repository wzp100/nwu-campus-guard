#!/usr/bin/lua
-- 在主路由本机运行；断网后仍能检测、恢复和记录结果。
-- 用法：lua /usr/share/campus-guard/test-recovery.lua --dry-run | --run | --rescue
local json=require 'luci.jsonc'
local fs=require 'nixio.fs'
local nixio=require 'nixio'
local uci=require 'luci.model.uci'.cursor()
local mode=arg[1]
assert(mode=='--dry-run' or mode=='--run' or mode=='--rescue','请指定 --dry-run、--run 或 --rescue')
local data_dir=uci:get('campus_guard','main','data_dir') or '/tmp/campus-guard/data'
assert(data_dir:match('^/[%w_./%-]+$') and not data_dir:find('..',1,true),'统计目录配置无效')
local root=data_dir..'/tests'
fs.mkdir(data_dir,'700')
fs.mkdir(root,'700'); fs.chmod(root,'700')
local pid=tostring(nixio.getpid())
local report={started_at=os.date('%Y-%m-%d %H:%M:%S'),epoch=os.time(),mode=mode,events={}}
local reportpath=root..'/test-'..os.date('%Y%m%d-%H%M%S')..'-'..pid..'.json'
local latestpath=root..(mode=='--rescue' and '/latest-rescue.json' or '/latest.json')
local function save(path,data)
  assert(fs.writefile(path..'.new',data));fs.chmod(path..'.new','600');assert(fs.rename(path..'.new',path))
end
local function event(name,fields)
  local e={time=os.date('%Y-%m-%d %H:%M:%S'),epoch=os.time(),event=name}
  for k,v in pairs(fields or {}) do e[k]=v end
  report.events[#report.events+1]=e;save(reportpath,json.stringify(report));save(latestpath,json.stringify(report))
  print(json.stringify(e));io.stdout:flush()
end
local function quote(s)return "'"..tostring(s):gsub("'","'\\''").."'" end
local function run(cmd)local p=assert(io.popen(cmd));local s=p:read('*a') or '';p:close();return s end
local function enc(s)return tostring(s or ''):gsub('([^%w%-_%.~])',function(c)return string.format('%%%02X',string.byte(c))end)end
local function query(t)local r={};for k,v in pairs(t)do r[#r+1]=enc(k)..'='..enc(v)end;table.sort(r);return table.concat(r,'&')end
local function parse(raw)local body=raw:match('\r?\n\r?\n(.*)') or raw;local object=body:match('(%b{})');return object and json.parse(object) or nil end
local function cfg(k,d)return uci:get('campus_guard','main',k) or d end
local wan=json.parse(run('ubus call network.interface.wan status')) or {}
local device=wan.l3_device or '';assert(device:match('^[%w_.%-]+$'),'WAN 设备不可用')
local ip=wan['ipv4-address'] and wan['ipv4-address'][1] and wan['ipv4-address'][1].address
assert(wan.up and ip,'WAN 未连接，取消退出测试')
local portal=cfg('portal_ip','172.30.9.18');assert(portal:match('^%d+%.%d+%.%d+%.%d+$'))
local host='calogin.nwu.edu.cn'
local function fetch(url)
  local path='/tmp/campus-guard/recovery-request-'..pid..'.cfg'
  save(path,'url = "'..url:gsub('\\','\\\\'):gsub('"','\\"'):gsub('[\r\n]','')..'"\n')
  local raw=run('curl --noproxy '..quote('*')..' --interface '..quote(device)..' --connect-timeout 4 --max-time 10 --max-filesize 262144 --silent --include --config '..quote(path)..' --resolve '..quote(host..':443:'..portal)..' --resolve '..quote(host..':802:'..portal)..' 2>/dev/null')
  fs.unlink(path);return raw
end
local function auth()return parse(fetch('https://'..host..'/drcom/chkstatus?callback=recovery&jsVersion=4.X&v='..os.time()))end
local function probes()
  local a=fetch('http://www.msftconnecttest.com/connecttest.txt')
  local b=fetch('http://1.1.1.1/')
  local dns_ok=a:match('HTTP/%S+%s+200') and a:match('\r?\n\r?\nMicrosoft Connect Test%s*$')~=nil
  local ip_ok=b:match('HTTP/%S+%s+301') and b:match('[Ll]ocation:%s*https://1%.1%.1%.1/')~=nil
  local location=a:match('[Ll]ocation:%s*([^\r\n]+)') or b:match('[Ll]ocation:%s*([^\r\n]+)') or ''
  return dns_ok or ip_ok or false,location,dns_ok or false,ip_ok or false
end
local function pageconfig(nas)
  return parse(fetch('https://'..host..':802/eportal/portal/page/loadConfig?'..query({callback='recovery',program_index='',page_index='',wlan_user_ip=nixio.bin.b64encode(ip),wlan_user_ipv6='',wlan_vlan_id=0,wlan_user_ssid='',wlan_user_areaid='',wlan_ac_ip=nixio.bin.b64encode(nas or ''),wlan_ap_mac='000000000000',gw_id='000000000000',jsVersion='4.X',lang='zh',v=os.time()})))
end
local function rescue_login(preconfig)
  local online,location=probes();if online then return true end
  local nas=location:match('[?&]nasip=([%d%.]+)') or ''
  local mac=(location:match('[?&]usermac=([%x%-:]+)') or fs.readfile('/sys/class/net/'..device..'/address') or ''):gsub('[^%x]','')
  local config=pageconfig(nas);local d=config and config.data or preconfig
  assert(d,'恢复时无法读取认证配置')
  assert(tonumber(d.account_prefix or 0)==0 and tonumber(d.en_md5 or 0)==0,'认证参数变化，停止自动提交')
  local suffix=cfg('suffix','campus');if suffix=='campus'then suffix=''end
  local username=cfg('username','')..suffix;local password=cfg('password','')
  assert(username~='' and password~='','恢复凭据未配置')
  local p={callback='recovery',program_index=d.program_index or '',page_index=d.page_index or '',jsVersion='4.X',lang='zh',terminal_type=1,v=os.time()}
  local method=tonumber(d.login_method)
  if method==1 then
    p.login_method=1;p.user_account=username;p.user_password=password;p.wlan_user_ip=ip;p.wlan_user_ipv6='';p.wlan_user_mac=mac;p.wlan_ac_ip=nas;p.wlan_ac_name=''
  elseif method==0 then
    p.DDDDD=username;p.upass=password;p['0MKKey']='123456';p.R1='';p.R2='';p.R3='';p.R6=0;p.para='';p.v6ip=''
  else error('不支持当前认证协议')end
  local result=parse(fetch('https://'..host..(method==1 and ':802/eportal/portal/login?' or '/drcom/login?')..query(p))) or {}
  event('rescue_login',{result=tonumber(result.result),ret_code=tonumber(result.ret_code)})
  nixio.nanosleep(3)
  local restored=probes()
  if restored then return true end
  -- 有线网络还保留 Dr.COM 本地认证通道，作为独立恢复的第二种方式。
  if method==1 then
    local local_args={callback='recovery',DDDDD=username,upass=password,['0MKKey']='123456',R1='',R2='',R3='',R6=0,para='',v6ip='',terminal_type=1,jsVersion='4.X',lang='zh',v=os.time()}
    local result=parse(fetch('https://'..host..'/drcom/login?'..query(local_args))) or {}
    event('rescue_local_login',{result=tonumber(result.result),ret_code=tonumber(result.ret_code)})
    nixio.nanosleep(3)
    return probes()
  end
  return false
end
local function execute()
  if mode=='--rescue' then
    for attempt=1,10 do
      if probes() then report.result='rescue_not_needed';event('network_online');return end
      local ok,restored=pcall(rescue_login)
      if ok and restored then report.result='rescued';event('network_restored',{attempt=attempt});return end
      event('rescue_retry',{attempt=attempt});nixio.nanosleep(30)
    end
    report.result='rescue_failed';event('needs_manual_login');return
  end
  assert(cfg('enabled','0')=='1' and cfg('auto_login','0')=='1','守护程序或自动认证没有启用')
  assert(cfg('username','')~='' and cfg('password','')~='','学号密码未配置')
  local service=json.parse(run('ubus call service list '..quote('{"name":"campus-guard"}'))) or {}
  local instances=service['campus-guard'] and service['campus-guard'].instances or {}
  local running=false;for _,s in pairs(instances)do if s.running then running=true end end
  assert(running,'守护进程没有运行，取消测试')
  local before=auth();local initial_online=probes()
  assert(before and tonumber(before.result)==1 and (before.v46ip or before.v4ip or before.ss5)==ip and initial_online,'当前网络或认证不正常，取消退出测试')
  local account=before.uid or before.AC
  assert(account==cfg('username',''),'当前在线账号与保存学号不同，取消退出测试')
  local config=pageconfig('');local d=config and config.data
  assert(d and tonumber(d.login_method)==1 and tonumber(d.account_prefix or 0)==0 and tonumber(d.en_md5 or 0)==0,'认证规则变化，取消测试')
  local old=json.parse(fs.readfile('/tmp/campus-guard/status.json') or '') or {}
  report.wan_ip=ip;report.guard_login_before=old.last_login_at;event('preflight_ok',{wan_ip=ip,guard_running=true,credentials_ready=true})
  if mode=='--dry-run'then report.result='ready';event('dry_run_ready');return end
  -- 与校园页面 term.getinfo() 保持一致：ss4 优先于 olmac，不能替换为路由器本机 MAC。
  local params={callback='recovery',login_method=1,user_account='drcom',user_password='123',ac_logout=tonumber(d.ac_logout or 0),register_mode=tonumber(d.register_mode or 0),wlan_user_ip=ip,wlan_user_ipv6='',wlan_vlan_id=before.vlanid or 0,wlan_user_mac=(before.ss4 or before.olmac or '000000000000'):gsub('[^%x]',''),wlan_ac_ip='',wlan_ac_name='',jsVersion='4.X',program_index=d.program_index or '',page_index=d.page_index or '',lang='zh',v=os.time()}
  local logout_epoch=os.time();report.logout_epoch=logout_epoch
  local response={}
  if tonumber(d.un_bind_mac)==1 and (tonumber(d.register_mode)==1 or tonumber(d.register_mode)==3 or tonumber(d.register_mode)==4) then
    local decimal_ip=0;for octet in ip:gmatch('%d+') do decimal_ip=decimal_ip*256+tonumber(octet)end
    local unbind={callback='recovery',user_account=account,wlan_user_mac=params.wlan_user_mac:upper(),wlan_user_ip=decimal_ip,jsVersion='4.X',program_index=d.program_index or '',page_index=d.page_index or '',v=os.time()}
    response=parse(fetch('https://'..host..':802/eportal/portal/mac/unbind?'..query(unbind))) or {}
    event('official_page_logout_requested',{result=tostring(response.result or ''),ret_code=tonumber(response.ret_code)})
  end
  if tonumber(response.result)~=1 and response.result~='ok' then
    response=parse(fetch('https://'..host..':802/eportal/portal/logout?'..query(params))) or {}
  end
  event('logout_requested',{result=tonumber(response.result),ret_code=tonumber(response.ret_code),error_code=tonumber(response.error_code)})
  local offline_seen=false
  local local_attempted=false
  local deadline=os.time()+120
  while os.time()<deadline do
    local online,location,dns_ok,ip_ok=probes()
    local current=auth()
    local guard=json.parse(fs.readfile('/tmp/campus-guard/status.json') or '') or {}
    local captive=location:match('^https?://calogin%.nwu%.edu%.cn/')~=nil
    local authed=current and tonumber(current.result)==1 and (current.v46ip or current.v4ip or current.ss5)==ip
    if not online or captive or (current and tonumber(current.result)==0) then offline_seen=true end
    report.offline_observed=offline_seen
    event('observe',{elapsed_seconds=os.time()-logout_epoch,internet_ok=online,dns_probe_ok=dns_ok,ip_probe_ok=ip_ok,authenticated=authed or false,captive_redirect=captive,guard_code=guard.code,guard_last_login=guard.last_login_at})
    if offline_seen and online and authed and guard.last_login_at and guard.last_login_at~=old.last_login_at then
      report.result='guard_recovery_pass';report.recovery_seconds=os.time()-logout_epoch;report.guard_login_after=guard.last_login_at
      event('automatic_recovery_pass',{recovery_seconds=report.recovery_seconds});return
    end
    if not offline_seen and os.time()-logout_epoch>20 then
      if not local_attempted and guard.last_login_at==old.last_login_at then
        local_attempted=true
        local result=parse(fetch('https://'..host..'/drcom/logout?callback=recovery&jsVersion=4.X&v='..os.time())) or {}
        logout_epoch=os.time();report.logout_epoch=logout_epoch;deadline=os.time()+120
        event('local_logout_requested',{result=tonumber(result.result),ret_code=tonumber(result.ret_code)})
      else
        report.result='logout_not_observed';event('test_inconclusive_network_remained_online');return
      end
    end
    nixio.nanosleep(3)
  end
  report.result='guard_recovery_timeout';event('guard_timeout_rescue_start')
  for attempt=1,3 do
    local ok,restored=pcall(rescue_login,d)
    if ok and restored then report.result='guard_failed_rescue_succeeded';event('rescue_restored',{attempt=attempt});return end
    nixio.nanosleep(10)
  end
  event('main_rescue_failed_standalone_watchdog_remains')
end
local ok=xpcall(execute,function()return '测试脚本异常；独立恢复进程将检查网络' end)
if not ok then report.result='script_error';event('script_error')end
report.finished_at=os.date('%Y-%m-%d %H:%M:%S');save(reportpath,json.stringify(report));save(latestpath,json.stringify(report))
print('result='..tostring(report.result)..'; report='..reportpath)
if not ok or report.result=='rescue_failed' or report.result=='guard_recovery_timeout' or report.result=='logout_not_observed' then os.exit(1)end
