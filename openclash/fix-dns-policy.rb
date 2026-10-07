require 'yaml'
# 校园域名交给主路由解析；主路由地址可用环境变量 CAMPUS_DNS 覆盖。
CAMPUS_DNS = ENV.fetch('CAMPUS_DNS', '192.168.1.1')
path = ARGV.fetch(0)
c = YAML.load_file(path, aliases: true)
d = c['dns'] ||= {}
raise 'Unsupported fake-ip-filter mode' unless [nil, 'blacklist'].include?(d['fake-ip-filter-mode'])
d['fake-ip-filter'] = (Array(d['fake-ip-filter']) + ['+.nwu.edu.cn']).uniq
d['nameserver-policy'] = {'+.nwu.edu.cn' => [CAMPUS_DNS]} .merge((d['nameserver-policy'] || {}).reject { |k, v| k == '+.nwu.edu.cn' })
(c['hosts'] ||= {})['calogin.nwu.edu.cn'] = '172.30.9.18'
d['direct-nameserver-follow-policy'] = true
c['rules'] = (['DOMAIN-SUFFIX,nwu.edu.cn,DIRECT', 'IP-CIDR,172.30.9.18/32,DIRECT,no-resolve', 'IP-CIDR,10.10.10.10/32,DIRECT,no-resolve', 'IP-CIDR,10.8.8.8/32,DIRECT,no-resolve'] + Array(c['rules'])).uniq
File.write(path, YAML.dump(c))
File.chmod(0600, path)
