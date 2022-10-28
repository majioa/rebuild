#!/usr/bin/ruby
require 'fileutils'
require 'pry'
require 'yaml'
require 'net/http'
require 'json'
require 'time'
require 'optparse'

DEFAULT_OPTIONS = {
   plant_dir: File.join(Dir.home, 'plant'),
   task_no: nil,
   clean_plant: false,
   break_on_error: false,
   list_file: File.join(Dir.home, "list1"),
   to_branch: 'sisyphus',
   in_branch: 'sisyphus',
   host: "git.altlinux.org",
   hasher_root: '/tmp/.private/' + ENV['USER'],
}

def option_parser
   @option_parser ||=
      OptionParser.new do |opts|
         opts.banner = "Usage: setup.rb [options & actions]"

         opts.on("-p", "--plant-dir=FOLDER", String, "Plant folder to proceed the sources") do |folder|
            options[:plant_dir] = folder
         end

         opts.on("-t", "--task-no=NUMBER", Integer, "Task number to prebuild the sources") do |no|
            options[:task_no] = no
         end

         opts.on("-l", "--list-file=FILE", String, "List file to rebuild") do |file|
            options[:list_file] = file
         end

         opts.on("-i", "--in-branch=NAME", String, "Original branch name for rebuild") do |name|
            options[:in_branch] = name
         end

         opts.on("-o", "--to-branch=NAME", String, "Target branch name for rebuild") do |name|
            options[:to_branch] = name
         end

         opts.on("-c", "--[no-]clean-plant", "Clean the plant before rebuild") do |bool|
            options[:clean_plant] = bool
         end

         opts.on("-b", "--[no-]break-on-error", "Breaks build procedure on error") do |bool|
            options[:break_on_error] = bool
         end

         opts.on("-a", "--[no-]assign", "Assign all successive packages to the specified task to build") do |bool|
            options[:assign] = bool
         end

         opts.on("-A", "--[no-]auto-assign", "When building will auto assign all successly built packages to the specified task to build") do |bool|
            options[:auto_assign] = bool
         end

         opts.on("-h", "--help", "This help") do |v|
            puts opts
            exit
         end
      end

   #if @argv
   #   @option_parser.default_argv.replace(@argv)
   #elsif @option_parser.default_argv.empty?
   #   @option_parser.default_argv << "-h"
   #end

   @option_parser
end

def options
   @options ||= DEFAULT_OPTIONS.dup
end

option_parser.parse!

pp options

in_branch = options[:in_branch]
to_branch = options[:to_branch]
plant = options[:plant_dir]
log_dir = File.join(plant, 'logs')
srpm_dir = File.join(plant, 'srpms')
rpm_dir = File.join(plant, 'rpms')
hasher_root = options[:hasher_root]
hasher_dirs = Dir["#{options[:hasher_root]}/repo/**/RPMS.hasher"]
task_no = options[:task_no]
list_file = options[:list_file]
break_on_error = options[:break_on_error]
host = options[:host]
git_host = "git://#{host}/"
assign = options[:assign]
auto_assign = options[:auto_assign]
func = in_branch != to_branch && 'copy' || 'rebuild'

# переименован 'chroot/.out/gem-method-source-1.0.0-alt1.src.rpm' -> 'repo/SRPMS.hasher/gem-method-source-1.0.0-alt1.src.rpm'
#
package_hash = {}
if task_no
   json = Net::HTTP.get(host, "/tasks/#{task_no}/info.json")
   data = JSON.parse(json)

   package_hash =
      data["subtasks"].map do |(no, d)|
         next nil if !d["dir"]
         name = d["dir"].match(/(?<name>[^\/]+).git$/)[:name]

         data = {
            'path' => File.join(git_host, "tasks", task_no.to_s, "gears", no.to_s, "git"),
            'tag_name' => d['tag_name'],
            'tag_id' => d['tag_id'],
            'fetched_at' => Time.parse(d["fetched"])
         }

         [ name, data ]
      end.compact.to_h
end

list_hash =
   package_hash.merge((IO.read(list_file).split("\n") - package_hash.keys).map do |name|
      [name, { 'path' => "/gears/#{name[0]}/#{name}.git" }]
   end.to_h)
statuses = {}
status = nil

def assign_to_task task_no, func, name
   puts "Assigning #{name} to task #{task_no}"

   puts "ssh git_majioa@gyle.altlinux.org -p 222 task add #{task_no} #{func} #{name}"
   `ssh git_majioa@gyle.altlinux.org -p 222 task add #{task_no} #{func} #{name}`
end

if assign && task_no
   list_hash.each do |name, path|
      puts "Analyzing #{name}"
      begin
         statuses[name] = YAML.load(IO.read(File.join(log_dir, "#{name}.yml")))
         next if statuses[name]["status"] != 0
      rescue
         next
      ensure
      end

      next if package_hash.keys.include?(name)

      assign_to_task(task_no, func, name)
   end

   exit
end

# cleanup optional
if options[:clean_plant]
   FileUtils.rm_rf(log_dir)
   FileUtils.rm_rf(srpm_dir)
   FileUtils.rm_rf(rpm_dir)
   FileUtils.rm_rf(hasher_dirs)
end

FileUtils.mkdir_p(log_dir)
FileUtils.mkdir_p(srpm_dir)
FileUtils.mkdir_p(rpm_dir)
list_hash.each do |name, data|
   puts name
   begin
      statuses[name] = YAML.load(IO.read(File.join(log_dir, "#{name}.yml")))
      if statuses[name]["status"] == 0 &&
         statuses[name]['tag_id'] == data['tag_id'] &&
         statuses[name]['fetched_at'] == data['fetched_at']
         if task_no && auto_assign && !package_hash.keys.include?(name)
            assign_to_task(task_no, func, name)
         end

         next
      end
   rescue
   ensure
      status = {}
   end

   FileUtils.rm_rf(File.join(plant, "poligon"))
   FileUtils.mkdir_p(File.join(plant, "poligon"))
   FileUtils.cd(File.join(plant, "poligon"))

   path = data['path']
   fullpath = path =~ /^git:\/\// && path || File.join(git_host, path)
   puts "git clone #{fullpath} #{name}"
   `git clone #{fullpath} #{name}`

   next if !File.directory?(name)
   FileUtils.cd(name)
   branches = `cat .git/packed-refs |grep remotes/origin`.split("\n").map {|x|x.match(/\/(?<b>[^\/]+)$/)[:b]}
   selected_branch = ([to_branch, 'master', in_branch] & branches).first
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
   status = status.merge(data)

   File.open(File.join(log_dir, "#{name}.yml"), "w+") {|f| f.puts(status.to_yaml) }
   statuses[name] = status
   $stdout.puts "Status: #{status["status"]}"

   break if break_on_error && status["status"] != 0

   if task_no && auto_assign && status["status"] == 0 && !package_hash.keys.include?(name)
      assign_to_task(task_no, func, name)
   end
end

File.open(File.join(log_dir, "-common.yml"), "w+") {|f| f.puts(statuses.to_yaml) }

oks = statuses.values.sum  {|x| x["status"] == 0 && 1 || 0 }
errors = statuses.values.size - oks
puts "Compilation summary: ok: #{oks}, errored #{errors}"

if !status || !break_on_error || status.empty? || status["status"] == 0
   rpms = statuses.values.map {|v| v["rpms"] }.flatten.reject {|x| x =~ /debuginfo/ }
   log=`hsh-install #{rpms.join(" ")}`
   puts "Installation status #{$?}:\n#{log}"
end
