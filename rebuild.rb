#!/usr/bin/ruby
require 'fileutils'
require 'pry'
require 'yaml'
require 'net/http'
require 'json'

in_branch = 'sisyphus'
to_branch = 'p10'

plant = File.join(Dir.home, 'plant')
log_dir = File.join(plant, 'logs')
srpm_dir = File.join(plant, 'srpms')
rpm_dir = File.join(plant, 'rpms')
hasher_root = '/tmp/.private/user'
hasher_dirs = ['/tmp/.private/user/repo/x86_64/RPMS.hasher/']
#rpmfolder = `find /tmp/.private/majioa/repo/ -name RPMS.hasher -type d`
task_no = ARGV[1]
list_file = File.join(Dir.home, "list1")
host = "git://git.altlinux.org/"

# cleanup optional
if ARGV.include?("-c")
   FileUtils.rm_rf(log_dir)
   FileUtils.rm_rf(srpm_dir)
   FileUtils.rm_rf(rpm_dir)
   #FileUtils.rm_rf(hasher_dirs)
   #/tmp/.private/majioa/repo/i586/RPMS.hasher/
end

FileUtils.mkdir_p(log_dir)
FileUtils.mkdir_p(srpm_dir)
FileUtils.mkdir_p(rpm_dir)
# переименован 'chroot/.out/gem-method-source-1.0.0-alt1.src.rpm' -> 'repo/SRPMS.hasher/gem-method-source-1.0.0-alt1.src.rpm'
#
package_hash = {}
if task_no
    # paths.map {|x| [x.match(/(?<name>[^\/]+).git$/)[:name], x] }.to_h
     json = Net::HTTP.get("git.altlinux.org", "/tasks/#{task_no}/info.json")
     data = JSON.parse(json)
   package_hash =
     data["subtasks"].map do |(no, d)|
      next nil if !d["dir"]
      name = d["dir"].match(/(?<name>[^\/]+).git$/)[:name]

      [ name, "git://git.altlinux.org/tasks/#{task_no}/gears/#{no}/git"]
     end.compact.to_h
end

list_hash = package_hash.merge((IO.read(list_file).split("\n") - package_hash.keys).map {|name| [name, "/gears/#{name[0]}/#{name}.git"] }.to_h)
statuses = {}

list_hash.each do |name, path|
  puts name
  begin
    statuses[name] = YAML.load(IO.read(File.join(log_dir, "#{name}.yml")))
    next if statuses[name]["status"] == 0
  rescue
  ensure
    status = {}
  end

  FileUtils.rm_rf(File.join(plant, "poligon"))
  FileUtils.mkdir_p(File.join(plant, "poligon"))

  FileUtils.cd(File.join(plant, "poligon"))
  fullpath = path =~ /^git:\/\// && path || File.join(host, path)
  puts "git clone #{fullpath} #{name}"
  `git clone #{fullpath} #{name}`

  next if !File.directory?(name)
  FileUtils.cd(name)
  branches = `cat .git/packed-refs |grep remotes/origin`.split("\n").map {|x|x.match(/\/(?<b>[^\/]+)$/)[:b]}
  selected_branch = (branches & [to_branch, 'master']).first
  if !selected_branch
    puts "No branch selected"
    next
  end

  # binding.pry
  puts "git checkout refs/remotes/origin/#{selected_branch} -b build"
  `git checkout refs/remotes/origin/#{selected_branch} -b build`
  logfile = File.join(log_dir, "#{name}.log")

  lost = true
  while lost
    `gear-hsh --commit -- -vvvv > #{logfile} 2>&1`
    status["status"] = $?.exitstatus
    #"E: Some index files failed to download. They have been ignored, or old ones used instead."
    log = IO.read(logfile).encode("UTF-16be", :invalid=>:replace, :replace=>"?").encode('UTF-8')
    lost = log =~ /Some index files failed to download. /
  end
  # filter
  files = log.split("\n").grep(/chroot\/.out.* -> /).map do |x|
    /'(?<apath>[^']+)'$/ =~ x
    apath
  end.map {|x| File.join(hasher_root, x) }

  srpms = files.grep(/\/SRPMS/)
  rpms = files.grep(/\/RPMS/)
  srpms.each do |file|
    filename = File.basename(file)
    FileUtils.mv(file, srpm_dir)
    FileUtils.ln_s(File.join(srpm_dir, filename), file)
  end
  rpms.each do |file|
    filename = File.basename(file)
    FileUtils.mv(file, rpm_dir)
    FileUtils.ln_s(File.join(rpm_dir, filename), file)
  end

  status["srpms"] = srpms
  status["rpms"] = rpms
  status["name"] = name
  File.open(File.join(log_dir, "#{name}.yml"), "w+") {|f| f.puts(status.to_yaml) }
  statuses[name] = status
  $stdout.puts "Status: #{status["status"]}"
end
File.open(File.join(log_dir, "-common.yml"), "w+") {|f| f.puts(statuses.to_yaml) }

oks = statuses.values.sum  {|x| x["status"] == 0 && 1 || 0 }
errors = statuses.values.size - oks
puts "Compilation summary: ok: #{oks}, errored #{errors}"

rpms = statuses.values.map {|v| v["rpms"] }.flatten.reject {|x| x =~ /debuginfo/ }
log=`hsh-install #{rpms.join(" ")}`
puts "Installation status #{$?}:\n#{log}"
