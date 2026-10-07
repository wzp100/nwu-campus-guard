-- 按认证接口累计值差分；纯计算部分可独立验证。
local M = {}
local function valid(n) return type(n)=='number' and n>=0 and n<math.huge and n~=4294967295 end
local function public_sample(s)
  return {epoch=s.epoch,time=os.date('%Y-%m-%d %H:%M:%S',s.epoch),authenticated=s.authenticated,flow_kib=s.flow_kib,time_minutes=s.time_minutes,router_uptime_seconds=s.router_uptime_seconds,wan_uptime_seconds=s.wan_uptime_seconds}
end
function M.update(store,s)
  store=store or {version=1,started_at=s.epoch,hours={},samples=0,resets=0,gaps=0,unassigned_bytes=0,unassigned_minutes=0}
  store.hours=store.hours or {}
  store.samples=(store.samples or 0)+1
  store.last_sample=public_sample(s)
  local function bucket(epoch)
    local start=math.floor(epoch/3600)*3600
    for _,h in ipairs(store.hours) do if h.epoch==start then return h end end
    local h={epoch=start,bytes=0,minutes=0,coverage_seconds=0,samples=0,resets=0,gaps=0}
    store.hours[#store.hours+1]=h
    return h
  end
  bucket(s.epoch).samples=bucket(s.epoch).samples+1
  local p=store.baseline
  if s.authenticated and valid(s.flow_kib) and valid(s.time_minutes) and s.identity and s.identity~='' then
    store.last_good=public_sample(s)
    if p and s.epoch>p.epoch then
      local dt=s.epoch-p.epoch
      if s.identity~=p.identity or s.flow_kib<p.flow_kib or s.time_minutes<p.time_minutes then
        store.resets=(store.resets or 0)+1; bucket(s.epoch).resets=bucket(s.epoch).resets+1
      else
        local bytes=(s.flow_kib-p.flow_kib)*1024
        local minutes=s.time_minutes-p.time_minutes
        if dt>180 then
          store.gaps=(store.gaps or 0)+1; bucket(s.epoch).gaps=bucket(s.epoch).gaps+1
          store.unassigned_bytes=(store.unassigned_bytes or 0)+bytes
          store.unassigned_minutes=(store.unassigned_minutes or 0)+minutes
        else
          local cursor=p.epoch
          while cursor<s.epoch do
            local stop=math.min(s.epoch,(math.floor(cursor/3600)+1)*3600)
            local span=stop-cursor
            local h=bucket(cursor)
            h.bytes=h.bytes+bytes*span/dt
            h.minutes=h.minutes+minutes*span/dt
            h.coverage_seconds=h.coverage_seconds+span
            cursor=stop
          end
        end
      end
    end
    if not p or s.epoch>p.epoch then store.baseline={epoch=s.epoch,identity=s.identity,flow_kib=s.flow_kib,time_minutes=s.time_minutes} end
  end
  local cutoff=math.floor(s.epoch/3600)*3600-90*86400
  local keep={}; for _,h in ipairs(store.hours) do if h.epoch>=cutoff then keep[#keep+1]=h end end
  table.sort(keep,function(a,b) return a.epoch<b.epoch end)
  store.hours=keep
  return store
end
function M.view(store,date)
  if not store then return {ready=false,message='尚无采样，采集开始后会建立基准'} end
  local days={}; local hourly={}; local today=os.date('%Y-%m-%d')
  date=date or today
  for hour=0,23 do hourly[hour+1]={hour=hour,label=string.format('%02d:00',hour),bytes=0,minutes=0,coverage_seconds=0,samples=0,resets=0,gaps=0} end
  for _,h in ipairs(store.hours or {}) do
    local day=os.date('%Y-%m-%d',h.epoch)
    local d=days[day] or {date=day,bytes=0,minutes=0,coverage_seconds=0,samples=0,resets=0,gaps=0}
    days[day]=d
    for _,key in ipairs({'bytes','minutes','coverage_seconds','samples','resets','gaps'}) do d[key]=d[key]+(h[key] or 0) end
    if day==date then
      local hour=tonumber(os.date('%H',h.epoch))
      for _,key in ipairs({'bytes','minutes','coverage_seconds','samples','resets','gaps'}) do hourly[hour+1][key]=hourly[hour+1][key]+(h[key] or 0) end
    end
  end
  local daily={}; for _,d in pairs(days) do local copy={};for k,v in pairs(d) do copy[k]=v end;daily[#daily+1]=copy end
  table.sort(daily,function(a,b) return a.date<b.date end)
  return {ready=true,started_at=store.started_at,started_time=os.date('%Y-%m-%d %H:%M:%S',store.started_at),date=date,today=today,latest=store.last_good,last_sample=store.last_sample,samples=store.samples,resets=store.resets,gaps=store.gaps,unassigned_bytes=store.unassigned_bytes,unassigned_minutes=store.unassigned_minutes,daily=daily,hourly=hourly,today_usage=days[today],retention_days=90,raw_retention_days=30}
end
return M
