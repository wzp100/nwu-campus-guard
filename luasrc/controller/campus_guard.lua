module('luci.controller.campus_guard', package.seeall)
function index()
    entry({'admin','services','campus_guard'}, cbi('campus_guard'), _('校园网守护'), 25).dependent=true
    entry({'admin','services','campus_guard','status'}, call('status')).leaf=true
    entry({'admin','services','campus_guard','statistics'}, call('statistics')).leaf=true
    entry({'admin','services','campus_guard','export'}, call('export')).leaf=true
    entry({'admin','services','campus_guard','check'}, post('check')).leaf=true
    entry({'admin','services','campus_guard','clear'}, post('clear')).leaf=true
end
local function valid_date(value)
    if not value or not value:match('^%d%d%d%d%-%d%d%-%d%d$') then return nil end
    local y,m,d=value:match('^(%d+)%-(%d+)%-(%d+)$')
    local epoch=os.time({year=tonumber(y),month=tonumber(m),day=tonumber(d),hour=12})
    return epoch and os.date('%Y-%m-%d',epoch)==value and value or nil
end
local function load_store()
    local fs=require 'nixio.fs'
    local j=require 'luci.jsonc'
    local dir=dofile('/usr/share/campus-guard/collect-metrics.lua').data_dir()
    return j.parse(fs.readfile(dir..'/stats.json') or '')
end
function statistics()
    local fs=require 'nixio.fs'
    local j=require 'luci.jsonc'
    local store=load_store()
    local metrics=dofile('/usr/share/campus-guard/metrics.lua')
    local date=valid_date(luci.http.formvalue('date'))
    local result=metrics.view(store,date)
    result.error=fs.readfile('/tmp/campus-guard/metrics-error') or ''
    luci.http.prepare_content('application/json')
    luci.http.write(j.stringify(result))
end
function export()
    local store=load_store()
    local metrics=dofile('/usr/share/campus-guard/metrics.lua')
    local date=valid_date(luci.http.formvalue('date')) or os.date('%Y-%m-%d')
    local result=metrics.view(store,date)
    local grain=luci.http.formvalue('grain')=='daily' and 'daily' or 'hourly'
    luci.http.header('Content-Disposition','attachment; filename="campus-usage-'..grain..'-'..date..'.csv"')
    luci.http.prepare_content('text/csv; charset=utf-8')
    luci.http.write('\239\187\191时间,流量_MiB,在线时长_分钟,有效采集_秒,采样次数,计数重置次数,长间断次数\r\n')
    for _,r in ipairs(result[grain] or {}) do
        local label=grain=='daily' and r.date or date..' '..r.label
        local bytes=r.coverage_seconds>0 and string.format('%.6f',r.bytes/1048576) or ''
        local minutes=r.coverage_seconds>0 and string.format('%.6f',r.minutes) or ''
        luci.http.write(label..','..bytes..','..minutes..','..r.coverage_seconds..','..r.samples..','..r.resets..','..r.gaps..'\r\n')
    end
end
function status()
    local fs=require 'nixio.fs'
    local j=require 'luci.jsonc'
    local s=j.parse(fs.readfile('/tmp/campus-guard/status.json') or '') or {}
    s.history=j.parse(fs.readfile('/tmp/campus-guard/history.json') or '') or {}
    luci.http.prepare_content('application/json')
    luci.http.write(j.stringify(s))
end
function check()
    luci.sys.call('/usr/bin/lua /usr/share/campus-guard/campus-guard.lua >/dev/null 2>&1 &')
    luci.http.prepare_content('application/json')
    luci.http.write('{"started":true}')
end
function clear()
    local fs=require 'nixio.fs'
    local target=luci.http.formvalue('target')
    luci.http.prepare_content('application/json')
    if target~='history' and target~='stats' then
        luci.http.status(400,'Bad Request'); luci.http.write('{"ok":false}'); return
    end
    -- 与检测进程共用锁，避免清空的同时被正在运行的检测写回旧数据。
    local base='/tmp/campus-guard'
    local lock=base..'/lock'
    fs.mkdir(base,'700')
    if not fs.mkdir(lock,'700') then luci.http.write('{"ok":false,"busy":true}'); return end
    fs.writefile(lock..'/pid',tostring(require('nixio').getpid()))
    if target=='history' then
        fs.unlink(base..'/history.json')
    else
        local dir=dofile('/usr/share/campus-guard/collect-metrics.lua').data_dir()
        fs.unlink(dir..'/stats.json')
        local names=fs.dir(dir)
        if names then
            for name in names do
                if name:match('^samples%-%d%d%d%d%-%d%d%-%d%d%.jsonl$') then fs.unlink(dir..'/'..name) end
            end
        end
        fs.unlink(base..'/metrics-error')
    end
    fs.unlink(lock..'/pid'); fs.rmdir(lock)
    luci.http.write('{"ok":true}')
end
