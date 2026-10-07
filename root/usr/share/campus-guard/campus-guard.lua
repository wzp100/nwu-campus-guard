#!/usr/bin/lua
-- 校园网检测及重登；所有出站请求从主路由 WAN 发出。
local json = require 'luci.jsonc'
local fs = require 'nixio.fs'
local nixio = require 'nixio'
local uci = require 'luci.model.uci'.cursor()
local base = '/tmp/campus-guard'
fs.mkdir(base, '700')
fs.chmod(base, '700')
local function read(p) return fs.readfile(p) or '' end
local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function run(s)
  local p = io.popen(s)
  if not p then return '' end
  local v = p:read('*a') or ''; p:close(); return v
end
local function save(p, v)
  fs.writefile(p .. '.new', v); fs.chmod(p .. '.new', '600'); fs.rename(p .. '.new', p)
end
local function enc(s) return tostring(s or ''):gsub('([^%w%-_%.~])', function(c) return string.format('%%%02X', string.byte(c)) end) end
local function query(t)
  local r = {}; for k,v in pairs(t) do r[#r+1] = enc(k) .. '=' .. enc(v) end
  table.sort(r); return table.concat(r, '&')
end
local function jsonp(raw)
  local body = raw:match('\r?\n\r?\n(.*)') or raw
  local obj = body:match('(%b{})')
  return obj and json.parse(obj) or nil
end
local function cfg(k, d) return uci:get('campus_guard', 'main', k) or d end
local pid = tostring(nixio.getpid())
local lock = base .. '/lock'
if not fs.mkdir(lock, '700') then
  local old = read(lock .. '/pid'):match('^%d+$')
  if old and fs.access('/proc/' .. old) then os.exit(0) end
  fs.unlink(lock .. '/pid'); fs.rmdir(lock)
  if not fs.mkdir(lock, '700') then os.exit(0) end
end
fs.writefile(lock .. '/pid', pid)
local old = json.parse(read(base .. '/status.json')) or {}
local state = {checked_at=os.date('%Y-%m-%d %H:%M:%S'), epoch=os.time(), auto_login=cfg('auto_login','1')=='1', credentials_ready=cfg('username','')~='' and cfg('password','')~='', last_login_at=old.last_login_at, retry_after=old.retry_after, failures=old.failures or 0}
local wan = json.parse(run('ubus call network.interface.wan status 2>/dev/null')) or {}
local device = wan.l3_device or 'eth0'
local ip = wan['ipv4-address'] and wan['ipv4-address'][1] and wan['ipv4-address'][1].address or ''
assert(device:match('^[%w_.%-]+$'))
state.wan_ip = ip; state.wan_device = device
local portal_ip = cfg('portal_ip','172.30.9.18')
assert(portal_ip:match('^%d+%.%d+%.%d+%.%d+$'))
local host = 'calogin.nwu.edu.cn'
local observed_auth
local function fetch(url)
  -- 密码只进入权限 600 的临时 curl 配置，不进入命令行或日志。
  local f = base .. '/request-' .. pid .. '.cfg'
  local escaped = url:gsub('\\','\\\\'):gsub('"','\\"'):gsub('[\r\n]','')
  save(f, 'url = "' .. escaped .. '"\n')
  local cmd = 'curl --noproxy ' .. quote('*') .. ' --interface ' .. quote(device) .. ' --connect-timeout 4 --max-time 10 --max-filesize 262144 --silent --include --config ' .. quote(f)
  if url:match('^https://' .. host:gsub('%.','%%.') .. '[:/]') then
    cmd = cmd .. ' --resolve ' .. quote(host .. ':443:' .. portal_ip) .. ' --resolve ' .. quote(host .. ':802:' .. portal_ip)
  end
  local raw = run(cmd .. ' 2>/dev/null'); fs.unlink(f)
  return raw
end
local function probes()
  local a = fetch('http://www.msftconnecttest.com/connecttest.txt')
  local b = fetch('http://1.1.1.1/')
  local location = a:match('[Ll]ocation:%s*([^\r\n]+)') or b:match('[Ll]ocation:%s*([^\r\n]+)') or ''
  local captive = location:match('^https?://calogin%.nwu%.edu%.cn/') ~= nil
  local online = a:match('HTTP/%S+%s+200') and a:match('\r?\n\r?\nMicrosoft Connect Test%s*$') ~= nil
  local secondary = b:match('HTTP/%S+%s+301') and b:match('[Ll]ocation:%s*https://1%.1%.1%.1/') ~= nil
  return online or secondary or false, captive, location, online or false, secondary or false
end
local function page_config(nas)
  return jsonp(fetch('https://' .. host .. ':802/eportal/portal/page/loadConfig?' .. query({callback='guard',program_index='',page_index='',wlan_user_ip=nixio.bin.b64encode(ip),wlan_user_ipv6='',wlan_vlan_id='0',wlan_user_ssid='',wlan_user_areaid='',wlan_ac_ip=nixio.bin.b64encode(nas or ''),wlan_ap_mac='000000000000',gw_id='000000000000',jsVersion='4.X',lang='zh',v=os.time()})))
end
local function main()
  if wan.up ~= true or ip == '' or read('/sys/class/net/' .. device .. '/carrier'):match('^0') then
    state.code='wan_down'; state.message='WAN 链路或 DHCP 地址不可用'; return
  end
  local online, captive, location, dns_ok, raw_ok = probes()
  state.internet_ok=online; state.dns_probe_ok=dns_ok; state.ip_probe_ok=raw_ok
  local auth = jsonp(fetch('https://' .. host .. '/drcom/chkstatus?callback=guard&jsVersion=4.X&lang=zh'))
  observed_auth=auth
  state.portal_reachable = auth ~= nil
  local auth_ip = auth and (auth.v46ip or auth.v4ip or auth.ss5)
  local auth_online = auth and tonumber(auth.result)==1 and auth_ip==ip
  state.authenticated=auth_online or false
  if online then
    state.code='online'; state.message=auth_online and '主路由已认证，外网正常' or '外网可达，认证状态待核实'
    state.offline_count=0; state.failures=0; state.retry_after=0; return
  end
  if auth_online then state.code='upstream_failure'; state.message='认证仍有效，外网探测失败；检查校园出口或 DNS'; return end
  if not captive then state.code='network_failure'; state.message='外网探测失败，尚未发现可信校园网认证跳转'; return end
  state.offline_count = (old.wan_ip==ip and (old.offline_count or 0) or 0)+1
  state.code='authentication_required'; state.message='检测到校园网认证跳转'
  if not state.credentials_ready then state.message='检测到认证失效，请先配置学号和密码'; return end
  if not state.auto_login then state.message='需要认证，自动登录已关闭'; return end
  if state.offline_count<2 then state.message='首次发现认证跳转，等待下一次检测确认'; return end
  if os.time() < (tonumber(state.retry_after) or 0) then state.message='需要认证，处于重试冷却期'; return end
  if not auth or tonumber(auth.result)~=0 then state.message='认证状态不明确，暂缓自动登录'; return end
  -- 只使用已观察到的校园网跳转参数，校验它对应当前 WAN 地址。
  local location_ip = location:match('[?&]userip=([%d%.]+)')
  if location_ip~=ip then state.code='portal_mismatch'; state.message='认证跳转的 IP 与主路由 WAN 不一致'; return end
  local nas = location:match('[?&]nasip=([%d%.]+)') or ''
  local mac = (location:match('[?&]usermac=([%x%-:]+)') or ''):gsub('[%-:]','')
  local conf = page_config(nas)
  local d = conf and conf.data
  if not d then state.code='portal_config_error'; state.message='无法读取认证规则，暂缓登录'; return end
  local method = tonumber(d.login_method)
  if method~=0 and method~=1 then state.code='unsupported_method'; state.message='认证方式已变化，需要人工检查'; return end
  if tonumber(d.en_md5 or 0)~=0 or tonumber(d.enable_captcha or 0)~=0 or tonumber(d.captcha or 0)~=0 or tonumber(d.captcha_switch or 0)~=0 then
    state.code='manual_auth_required'; state.message='认证需要额外校验，请在校园网页面登录'; return
  end
  local suffix=cfg('suffix','campus')
  if suffix=='campus' then suffix='' end
  local username=cfg('username','') .. suffix
  local password=cfg('password','')
  if tonumber(d.account_prefix or 0)~=0 then state.code='manual_auth_required'; state.message='学校启用了账号前缀，需重新确认认证规则'; return end
  local args={callback='guard',program_index=d.program_index or '',page_index=d.page_index or '',jsVersion='4.X',lang='zh',terminal_type='1',v=os.time()}
  local url
  if method==1 then
    args.login_method=1; args.user_account=username; args.user_password=password
    args.wlan_user_ip=ip; args.wlan_user_ipv6=''; args.wlan_user_mac=mac; args.wlan_ac_ip=nas; args.wlan_ac_name=''
    url='https://' .. host .. ':802/eportal/portal/login?'
  else
    args.DDDDD=username; args.upass=password; args['0MKKey']='123456'; args.R1=''; args.R2=''; args.R3=''; args.R6='0'; args.para=''; args.v6ip=''
    url='https://' .. host .. '/drcom/login?'
  end
  state.last_login_at=os.date('%Y-%m-%d %H:%M:%S')
  local response=jsonp(fetch(url .. query(args)))
  state.last_login_result=response and tonumber(response.result) or -1
  state.last_login_ret_code=response and tonumber(response.ret_code) or nil
  local now_online = probes()
  if now_online then
    state.code='reconnected'; state.message='自动认证后外网已恢复'; state.internet_ok=true; state.failures=0; state.offline_count=0; state.retry_after=0
  else
    state.code='login_failed'; state.message='认证后外网未恢复，请检查密码、账号状态或设备数限制'
    state.failures=state.failures+1; state.retry_after=os.time()+math.min(1800,60*2^math.min(state.failures,5))
  end
end
local ok = xpcall(main, function() return '检测程序异常' end)
if not ok then state.code='internal_error'; state.message='检测程序异常，请检查配置或运行依赖' end
local metrics_ok=pcall(function()
  dofile('/usr/share/campus-guard/collect-metrics.lua').collect(observed_auth,state,wan)
end)
state.metrics_error=read(base..'/metrics-error')
if not metrics_ok then state.metrics_error='流量采集异常；网络检测和自动登录继续运行' end
save(base .. '/status.json',json.stringify(state))
if state.code~=old.code or state.last_login_at~=old.last_login_at then
  local history=json.parse(read(base .. '/history.json')) or {}
  history[#history+1]={time=state.checked_at,code=state.code,message=state.message,wan_ip=state.wan_ip}
  while #history>100 do table.remove(history,1) end
  save(base .. '/history.json',json.stringify(history))
  os.execute('logger -t campus-guard ' .. quote(state.code .. ': ' .. state.message))
end
fs.unlink(lock .. '/pid'); fs.rmdir(lock)
print(json.stringify(state))
