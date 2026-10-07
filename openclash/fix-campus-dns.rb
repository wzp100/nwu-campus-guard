require 'yaml'

runtime = '/etc/openclash/roomrouter.yaml'
source = '/etc/openclash/config/roomrouter.yaml'
stamp = Time.now.strftime('%Y%m%d-%H%M%S')
backup = "/etc/openclash/roomrouter-backups/campus-#{stamp}"
Dir.mkdir(backup, 0700)

def copy(src, dst)
  File.binwrite(dst, File.binread(src))
  File.chmod(0600, dst)
end

def patch_config(path)
  c = YAML.load_file(path, aliases: true)
  dns = c['dns'] ||= {}
  raise 'Unsupported fake-ip-filter mode' unless [nil, 'blacklist'].include?(dns['fake-ip-filter-mode'])
  dns['fake-ip-filter'] = (Array(dns['fake-ip-filter']) + ['+.nwu.edu.cn']).uniq
  dns['nameserver-policy'] = {'+.nwu.edu.cn' => ['192.168.1.1']} .merge((dns['nameserver-policy'] || {}).reject { |k, v| k == '+.nwu.edu.cn' })
  (c['hosts'] ||= {})['calogin.nwu.edu.cn'] = '172.30.9.18'
  dns['direct-nameserver-follow-policy'] = true
  c['rules'] = (['DOMAIN-SUFFIX,nwu.edu.cn,DIRECT', 'IP-CIDR,172.30.9.18/32,DIRECT,no-resolve', 'IP-CIDR,10.10.10.10/32,DIRECT,no-resolve', 'IP-CIDR,10.8.8.8/32,DIRECT,no-resolve'] + Array(c['rules'])).uniq
  File.write(path, YAML.dump(c))
  File.chmod(0600, path)
  c
end

[source, runtime].each do |path|
  copy(path, File.join(backup, path == source ? 'source.yaml' : 'runtime.yaml'))
  patch_config(path)
end
hook = '/etc/openclash/custom/openclash_custom_overwrite.sh'
copy(hook, File.join(backup, 'overwrite.sh'))
marker = '# campus-guard DNS policy'
unless File.read(hook).include?(marker)
  File.open(hook, 'a') { |f| f.puts "\n#{marker}\nruby /usr/share/campus-guard/fix-dns-policy.rb \"$CONFIG_FILE\"" }
end

ok = system({'SAFE_PATHS' => '/usr/share/openclash:/etc/openclash'}, '/etc/openclash/clash', '-t', '-d', '/etc/openclash', '-f', runtime, out: '/tmp/campus-clash-validation.log', err: [:child, :out])
unless ok
  copy(File.join(backup, 'source.yaml'), source)
  copy(File.join(backup, 'runtime.yaml'), runtime)
  copy(File.join(backup, 'overwrite.sh'), hook)
  File.chmod(0755, hook)
  abort 'Config validation failed; restored backup'
end
c = YAML.load_file(runtime, aliases: true)
api_config = "/tmp/campus-clash-api-#{Process.pid}"
begin
File.open(api_config, File::WRONLY | File::CREAT | File::EXCL, 0600) do |f|
  token = c.fetch('secret', '').gsub('\\', '\\\\').gsub('"', '\\"')
  f.write("header = \"Authorization: Bearer #{token}\"\nheader = \"Content-Type: application/json\"\n")
  f.flush
  ok = system('curl', '--noproxy', '*', '--max-time', '15', '--fail', '-sS', '--config', f.path, '-X', 'PUT', '--data', '{"path":"/etc/openclash/roomrouter.yaml"}', 'http://127.0.0.1:9090/configs?force=true', out: '/tmp/campus-clash-reload.log', err: [:child, :out])
  abort "API reload failed; backup at #{backup}" unless ok
end
ensure
  File.unlink(api_config) if File.exist?(api_config)
end
puts "DNS policy updated and hot reloaded; backup: #{backup}"
