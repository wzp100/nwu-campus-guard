local M={}
local json=require 'luci.jsonc'
local fs=require 'nixio.fs'
local reducer=dofile('/usr/share/campus-guard/metrics.lua')
local root='/mnt/nvme0n1-4/Configs/campus-guard'
local tmp='/tmp/campus-guard/metrics-error'
local function save(path,value)
  assert(fs.writefile(path..'.new',value)); assert(fs.chmod(path..'.new','600')); assert(fs.rename(path..'.new',path))
end
function M.collect(auth,state,wan)
  -- 依附原检测循环，不另发认证请求；至少间隔 60 秒采样。
  if not fs.access('/mnt/nvme0n1-4/Configs') then
    fs.writefile(tmp,'NVMe 统计目录不可用，暂未保存流量数据'); return
  end
  fs.mkdir(root,'700'); fs.chmod(root,'700')
  local path=root..'/stats.json'
  local raw=fs.readfile(path)
  local store=raw and json.parse(raw) or nil
  if raw and not store then fs.writefile(tmp,'统计文件无法解析，请检查磁盘；保留原文件'); return end
  if store and store.last_sample then
    if state.epoch<store.last_sample.epoch then fs.writefile(tmp,'系统时间回退，暂停采样直到时间恢复'); return end
    if state.epoch-store.last_sample.epoch<60 then return end
  end
  local s={epoch=state.epoch,authenticated=state.authenticated==true,identity=auth and tostring(auth.uid or auth.AC or ''),flow_kib=auth and tonumber(auth.flow),time_minutes=auth and tonumber(auth.time),router_uptime_seconds=tonumber((fs.readfile('/proc/uptime') or ''):match('^[%d%.]+')),wan_uptime_seconds=tonumber(wan.uptime)}
  if not s.authenticated then s.flow_kib=nil; s.time_minutes=nil; s.identity=nil end
  store=reducer.update(store,s)
  save(path,json.stringify(store))
  -- 原始采样不记录学号或密码。
  local sample=store.last_sample
  local journal=root..'/samples-'..os.date('%Y-%m-%d',state.epoch)..'.jsonl'
  local f=assert(io.open(journal,'a')); f:write(json.stringify(sample),'\n'); f:close(); fs.chmod(journal,'600')
  local cutoff=os.date('%Y-%m-%d',state.epoch-30*86400)
  for name in fs.dir(root) do
    local day=name:match('^samples%-(%d%d%d%d%-%d%d%-%d%d)%.jsonl$')
    if day and day<cutoff then fs.unlink(root..'/'..name) end
  end
  fs.unlink(tmp)
end
return M
