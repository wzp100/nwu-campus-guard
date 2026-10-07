local json=require 'luci.jsonc'
local original_print=print
local results={}
local function scenario(name, opt)
  local files={}
  local dirs={}
  local login_calls=0
  local cfg={username=opt.credentials and 'test-user' or '',password=opt.credentials and 'test-password' or '',suffix='',auto_login='1',portal_ip='172.30.9.18'}
  files['/tmp/campus-guard/status.json']=json.stringify({wan_ip='10.0.0.2',offline_count=opt.previous_offline or 0,failures=0})
  files['/sys/class/net/eth0/carrier']=opt.wan_down and '0' or '1'
  package.loaded['nixio.fs']={mkdir=function(p) if dirs[p] then return nil end dirs[p]=true return true end,chmod=function() return true end,readfile=function(p) return files[p] end,writefile=function(p,v) files[p]=v return true end,rename=function(a,b) files[b]=files[a]; files[a]=nil; return true end,unlink=function(p) files[p]=nil return true end,rmdir=function(p) dirs[p]=nil return true end,access=function() return false end}
  package.loaded['nixio']={getpid=function() return 999999 end,bin={b64encode=function() return 'MTAuMC4wLjI=' end}}
  package.loaded['luci.model.uci']={cursor=function() return {get=function(_,_,_,k) return cfg[k] end} end}
  io.popen=function(cmd)
    assert(not cmd:find('test%-password'), 'Password leaked into command line')
    local result
    if cmd:find('ubus call') then result=json.stringify({up=not opt.wan_down,l3_device='eth0',['ipv4-address']={{address='10.0.0.2'}}})
    else
      local url=files['/tmp/campus-guard/request-999999.cfg'] or ''
      if url:find('/portal/login',1,true) then
        login_calls=login_calls+1
        assert(url:find('user_account=test%-user'), 'Unexpected account prefix')
        assert(url:find('user_password=test%-password'), 'Missing password')
        result='HTTP/1.1 200 OK\r\n\r\nguard({"result":1});'
      elseif url:find('/page/loadConfig',1,true) then
        result='HTTP/1.1 200 OK\r\n\r\nguard(' .. json.stringify({data={login_method='1',account_prefix=opt.prefix and '1' or '0',program_index='test',page_index='test',en_md5='0',enable_captcha=opt.captcha and '1' or '0'}}) .. ');'
      elseif url:find('/drcom/chkstatus',1,true) then
        result='HTTP/1.1 200 OK\r\n\r\nguard(' .. json.stringify({result=opt.auth_online and 1 or 0,v46ip='10.0.0.2'}) .. ');'
      elseif opt.online or (login_calls>0 and opt.login_recovers) then
        if url:find('msftconnecttest',1,true) then result='HTTP/1.1 200 OK\r\n\r\nMicrosoft Connect Test'
        else result='HTTP/1.1 301 Moved\r\nLocation: https://1.1.1.1/\r\n\r\n' end
      elseif opt.captive then
        result='HTTP/1.0 302 Moved\r\nLocation: https://calogin.nwu.edu.cn/a79.htm?userip=10.0.0.2&nasip=10.0.0.254&usermac=00-11-22-33-44-55\r\n\r\n'
      else result='' end
    end
    return {read=function() return result end,close=function() return true end}
  end
  os.execute=function() return 0 end
  print=function() end
  dofile('/usr/share/campus-guard/campus-guard.lua')
  local state=json.parse(files['/tmp/campus-guard/status.json'])
  assert(state.code==opt.expected,name .. ': expected ' .. opt.expected .. ', got ' .. tostring(state.code))
  assert(login_calls==(opt.expected_calls or 0),name .. ': wrong login count')
  for k in pairs(files) do assert(not k:find('/request%-'), 'Temporary request file not removed') end
  results[#results+1]=name .. ': PASS'
end
scenario('online does not login',{online=true,auth_online=true,credentials=true,expected='online'})
scenario('WAN down does not login',{wan_down=true,credentials=true,expected='wan_down'})
scenario('generic outage does not login',{credentials=true,expected='network_failure'})
scenario('valid auth with outage does not login',{auth_online=true,credentials=true,expected='upstream_failure'})
scenario('missing credentials does not login',{captive=true,expected='authentication_required'})
scenario('first captive detection waits',{captive=true,credentials=true,expected='authentication_required'})
scenario('confirmed captive uses plain account and verifies recovery',{captive=true,credentials=true,previous_offline=1,login_recovers=true,expected='reconnected',expected_calls=1})
scenario('failed recovery enters cooldown',{captive=true,credentials=true,previous_offline=1,expected='login_failed',expected_calls=1})
scenario('new prefix requirement stops login',{captive=true,credentials=true,previous_offline=1,prefix=true,expected='manual_auth_required'})
scenario('captcha requirement stops login',{captive=true,credentials=true,previous_offline=1,captcha=true,expected='manual_auth_required'})
for _,r in ipairs(results) do original_print(r) end
original_print('10 scenarios passed; no live credentials or network mutations used')
