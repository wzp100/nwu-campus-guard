import base64
import http.client
import json
import re
import socket
import ssl
import subprocess
import sys
import urllib.parse

sys.stdout.reconfigure(encoding='utf-8')
source_ip=sys.argv[1]
host='calogin.nwu.edu.cn'
context=ssl.create_default_context()
def get(path,port=443):
    connection=http.client.HTTPSConnection(host,port,timeout=10,source_address=(source_ip,0),context=context)
    try:
        connection.request('GET',path)
        response=connection.getresponse()
        raw=response.read(262144)
        match=re.search(rb'(\{.*\})',raw,re.S)
        if not match: return None
        for encoding in ('utf-8','gbk'):
            try: return json.loads(match.group(1).decode(encoding))
            except (UnicodeDecodeError,json.JSONDecodeError): pass
        return None
    finally: connection.close()
def probe():
    connection=http.client.HTTPConnection('www.msftconnecttest.com',80,timeout=8,source_address=(source_ip,0))
    try:
        connection.request('GET','/connecttest.txt')
        r=connection.getresponse(); body=r.read(4096)
        return r.status==200 and body.strip()==b'Microsoft Connect Test',r.getheader('Location','')
    finally: connection.close()
online,location=probe()
print('校园 Wi-Fi 测试地址：'+source_ip)
if online:
    print('此 Wi-Fi 已能上网，无需重复登录。'); sys.exit(0)
parsed=urllib.parse.urlsplit(location)
if parsed.hostname!=host: raise RuntimeError('未获得可信的校园网认证跳转')
params=urllib.parse.parse_qs(parsed.query)
if params.get('userip',[''])[0]!=source_ip: raise RuntimeError('认证 IP 不匹配')
nas=params.get('nasip',[''])[0]
mac=re.sub(r'[^0-9a-fA-F]','',params.get('usermac',[''])[0])
print('认证页面可达：'+str(get('/drcom/chkstatus?callback=guard') is not None))
def b64(v): return base64.b64encode(v.encode()).decode()
payload={'callback':'guard','program_index':'','page_index':'','wlan_user_ip':b64(source_ip),'wlan_user_ipv6':'','wlan_vlan_id':'0','wlan_user_ssid':'','wlan_user_areaid':'','wlan_ac_ip':b64(nas),'wlan_ap_mac':'000000000000','gw_id':'000000000000','jsVersion':'4.X','lang':'zh'}
config=get('/eportal/portal/page/loadConfig?'+urllib.parse.urlencode(payload),802)
data=(config or {}).get('data',{})
if str(data.get('login_method'))!='1' or str(data.get('account_prefix','0'))!='0':
    raise RuntimeError('认证规则与预期不一致，未提交账号密码')
remote='lua -e \'local u=require("luci.model.uci").cursor(); local j=require("luci.jsonc"); print(j.stringify({username=u:get("campus_guard","main","username"),password=u:get("campus_guard","main","password"),suffix=u:get("campus_guard","main","suffix")}))\''
result=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','root@192.168.1.1',remote],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
credential=json.loads(result.stdout)
if not credential.get('username') or not credential.get('password'): raise RuntimeError('未保存校园网凭据')
suffix=credential.get('suffix') or ''
if suffix=='campus': suffix=''
payload={'callback':'guard','login_method':'1','user_account':credential['username']+suffix,'user_password':credential['password'],'wlan_user_ip':source_ip,'wlan_user_ipv6':'','wlan_user_mac':mac,'wlan_ac_ip':nas,'wlan_ac_name':'','jsVersion':'4.X','lang':'zh','terminal_type':'1','program_index':data.get('program_index',''),'page_index':data.get('page_index','')}
response=get('/eportal/portal/login?'+urllib.parse.urlencode(payload),802) or {}
print('认证返回 result='+str(response.get('result'))+'，ret_code='+str(response.get('ret_code')))
recovered,_=probe()
print('认证后校园 Wi-Fi 外网可达：'+str(recovered))
if str(response.get('result')) not in ('1','ok') and not recovered:
    message=str(response.get('msg',''))
    for secret in (credential['username'],credential['password']): message=message.replace(secret,'[已隐藏]')
    print('校园网返回：'+message[:200])
