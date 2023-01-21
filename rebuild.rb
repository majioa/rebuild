#!/usr/bin/ruby
require 'fileutils'
require 'pry'
require 'yaml'
require 'net/http'
require 'json'
require 'time'
require 'optparse'
require 'ostruct'

# req ruby >= 2.5

DEFAULT_OPTIONS = {
   plant_dir: File.join(Dir.home, 'plant'),
   task_no: nil,
   clean_plant: false,
   break_on_error: false,
   drop_nonbuilt: false,
   verbose: false,
   list_file: File.join(Dir.home, "list1"),
   to_branch: 'sisyphus',
   in_branch: 'sisyphus',
   host: "git.altlinux.org",
   hasher_root: '/tmp/.private/' + ENV['USER'],
   repo_base_path: '/ALT'
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

         opts.on("-D", "--[no-]drop-state-of-non-built", "Drops state of packages in the task when it hasn't originally built") do |bool|
            options[:drop_nonbuilt] = bool
         end

         opts.on("-v", "--[no-]verbose", "Enable verbose output") do |bool|
            options[:verbose] = bool
         end

         opts.on("-h", "--help", "This help") do |v|
            puts opts
            exit
         end
      end

   @option_parser
end

def options
   @options ||= DEFAULT_OPTIONS.dup
end

option_parser.parse!

pp options

module Shell
   def sh *args, mode: 'r+', logfile: nil, logmode: 'w+'
      $stdout.puts(args.join(' ')) if plant.verbose
      log = IO.popen({'REBUILD' => '1'}, args.map(&:to_s), mode, err: %i(child out)) do |pipe|
         pipe.close_write

         log = []
         while line = pipe.gets
            log.append(line.strip)
            $stdout.puts line if plant.verbose
         end

         log
      end
   rescue Errno::E2BIG
      log =
         begin
            `#{args.join(' ')} 2>&1`.split("\n")
         rescue
            []
         end
   ensure
      #binding.pry #if logfile.to_s =~ /install/
     File.open(logfile, logmode) { |f| f.puts(log.join("\n")) } if logfile && !log.nil? && !log.empty?
   end
end

class Plant
   include Shell

   attr_reader :options

   def plant
      self
   end

   def root
      @root ||= options.plant_dir
   end

   def poligon_dir
      return @poligon_dir if @poligon_dir && File.directory?(@poligon_dir)

      @poligon_dir = File.join(root, "poligon")
      FileUtils.mkdir_p(@poligon_dir)

      @poligon_dir
   end

   def log_dir
      return @log_dir if @log_dir && File.directory?(@log_dir)

      @log_dir = File.join(root, 'logs')
      FileUtils.mkdir_p(@log_dir)

      @log_dir
   end

   def srpm_dir
      return @srpm_dir if @srpm_dir

      @srpm_dir = File.join(root, 'srpms')

      FileUtils.mkdir_p(@srpm_dir)
      @srpm_dir
   end

   def rpm_dir
      return @rpm_dir if @rpm_dir

      @rpm_dir = File.join(root, 'rpms')

      FileUtils.mkdir_p(@rpm_dir)
      @rpm_dir
   end

   def hasher_dirs
      @hasher_dirs ||= Dir["#{hasher_root}/repo/**/RPMS.hasher"]
   end

   def status_dir
      return @status_dir if @status_dir

      @status_dir = File.join(root, 'statuses')
      FileUtils.mkdir_p(@status_dir)

      @status_dir
   end

   def git_host
      @git_host ||= "git://#{options.host}/"
   end

   def cleanup
      sh('hsh', '--initroot', '-vvvv', logfile: File.join(log_dir, 'initroot.log'))
      %w(hasher_dirs log_dir srpm_dir rpm_dir status_dir).flatten.each do |x|
         FileUtils.rm_rf(send(x))
         instance_variable_set("@#{x}", nil)
      end
   end

   def in_branch_srpm_list
      srpm_list_for(in_branch)
   end

   def to_branch_srpm_list
      srpm_list_for(to_branch)
   end

   def srpm_list_for branch
      Dir.chdir(File.join(repo_base_path, branch, 'files', 'SRPMS')) do
         Dir['*']
      end
   end

   def in_branch_match_package? name
      in_branch_srpm_list.grep(/^#{name}-[^-]*-alt[^-]*$/).any?
   end

   def initialize options
      @options = OpenStruct.new(options)
   end

   def method_missing method, *args
      value = options[method]

      value.nil? ? super : instance_variable_set("@#{method}", value)
   end
end

class Build
   include Shell

   attr_reader :plant

   def errors
      @errors ||= []
   end

   def is_require_assiging? gear, flow
     task_no && plant.options.auto_assign && !flow.map { |x| x['name']}.include?(gear.name) && is_matched?(gear)
   end

   def is_require_reassiging? gear, flow
     task_no && plant.options.auto_assign && flow.map { |x| x['name']}.include?(gear.name) && gear.lost_deps&.any?
   end

   def is_matched? gear
      (gear.states & [:built, :removed]).any?
   end

   def is_built? gear
      gear.states.include?(:built)
   end

   def is_removed? gear
      gear.states.include?(:removed)
   end

   def is_built_remotely? gear
      !(plant.drop_nonbuilt && !gear.pkgname)
   end

   def func
      @func ||= plant.in_branch != plant.to_branch && 'copy' || 'rebuild'
   end

   def error kind, message, **args
      errors << [kind, message, args]
   end

   def check_assign_to_task gear, name, flow
      res = true

      if req_no = detect_subtask_self_or_before(gear.no, flow)
         res = yield if block_given?

         aa=assign_to_task(task_no, name, subtask_no: req_no) if res
#         binding.pry
         aa
      else
         error(:assign, 'No free space before #{gear.name} with no #{gear.no}', gear)
      end
   end

   def autoassign gear, flow
      if gear.states.include?(:removed)
         /(ruby-)?(?<name_tmp>.*)/ =~ gear.name
         new_name = packetize_name(name_tmp)
         if plant.in_branch_match_package?(new_name)
            check_assign_to_task(gear, new_name, flow)
         end

         remove_in_task(task_no, gear.name)
         flow.shift
      elsif gear.states.include?(:built)
         check_assign_to_task(gear, gear.name, flow)
         flow.shift
      end
   end

   def autoreassign gear, flow
      if gear.error_type == :lost_deps
         gear.lost_deps.each do |dep|
            if new_element = preassign_dep_to_task(dep, gear, flow)
#         binding.pry
               flow.unshift(new_element)
            else
               error(:assign, 'Required gem #{o.name} is unavailable', o: dep)
            end
         end
      end
   end

   def packetize_name name
      "gem-#{name.downcase.gsub(/[_\.]+/, '-')}"
   end

   def preassign_dep_to_task dep, gear, flow
      packetized_name = packetize_name(dep.name)

      if plant.in_branch_match_package?(packetized_name)
         check_assign_to_task(gear, packetized_name, flow) do
            has = package_hash[packetized_name]

            if has && has['no'] > gear.no
               delete_subtask(has['no'])
            end

            !has || has['no'] > gear.no
         end
      end
   end

   def detect_subtask_self_or_before no_in, flow
      if no_in > 1
         noes_tmp = (noes | flow.map { |x| x['no']}.compact).sort
         no = no_in

         while no > 1 && noes_tmp.find {|x| no - 1 == x }
            no -= 1
         end

         no > 1 && no || nil
      end
   end

   def remove_in_task task_no, name
      sh('ssh', 'git_majioa@gyle.altlinux.org', '-p', '222', 'task', 'add', task_no, 'del', name)
   end

   def assign_to_task task_no, name, subtask_no: nil
      args = ['ssh', 'git_majioa@gyle.altlinux.org', '-p', '222', 'task', 'add', task_no, subtask_no&.to_s(8), func, name]

      l = sh(*args.compact)
      /added #(?<subtask_no8>\d+): build tag "(?<tag>[^"]+)"/ =~ l.last

      {
         'name' => name,
         'path' => File.join(plant.git_host, "tasks", task_no.to_s, "gears", subtask_no8, "git"),
         'tag_name' => tag,
         'no' => subtask_no8.to_i(8),
         'fetched_at' => Time.now
      }
   rescue
      $stdout.puts(l) if plant.verbose
   end

   def task_data
      return @task_data if @task_data

      if task_no
         json = Net::HTTP.get(plant.host, "/tasks/#{task_no}/info.json")
         @task_data = JSON.parse(json)
      end
   end

   def targets
      task_data && task_data["subtasks"] || []
   end

   def list_hash
      @list_hash ||=
         package_hash.merge((IO.read(plant.list_file).split("\n") - package_hash.keys).map do |name_in|
            /^(?<name_tmp>.*)-[^-]*-alt[^-]*$/ =~ name_in
            name = name_tmp || name_in
            value = (package_hash[name] || {}).merge({
               'path' => "/gears/#{name[0]}/#{name}.git",
               'name' => name
            })

            [name, value]
         end.to_h)
   end

   def no_hash
      @no_hash ||= package_hash.map {|(_name, data)| [data['no'], data] }.to_h
   end

   def package_hash
      @package_hash ||=
         targets.map do |(no, d)|
            next nil if !d["dir"]
            name = d["dir"].match(/(?<name>[^\/]+).git$/)[:name]

            data = {
               'name' => name,
               'path' => File.join(plant.git_host, "tasks", task_no.to_s, "gears", no.to_s, "git"),
               'tag_name' => d['tag_name'],
               'tag_id' => d['tag_id'],
               'no' => no.to_i(8),
               'pkgname' => d["pkgname"],
               'rebuild_from' => d["rebuild_from"],
               'fetched_at' => Time.parse(d["fetched"])
            }

            [ name, data ]
         end.compact.to_h
   end

   def noes
      @noes ||= targets.keys.map {|x|x.to_i(8) }.sort
   end

   def delete_subtask no
      sh('ssh', 'git_majioa@gyle.altlinux.org', '-p', '222', 'task', 'delsub', task_no, no.to_s(8))
      list_hash.delete_if { |_, v| v['no'] == no }
   end

   def rebuild
      plant.cleanup if plant.options.clean_plant

      File.open(File.join(plant.root, "common.yml"), "w+") {|f| f.puts(statuses.to_yaml) }
      oks = gears.values.sum  {|x| is_matched?(x) && 1 || 0 }
      @errors = gears.values.size - oks

      puts "Compilation summary: ok: #{oks}, errored #{errors}"

      install
   end

   def install
      if !plant.break_on_error || gears.empty? || @errors == 0
         rpms = gears.values.map {|v| v.rpms }.flatten.reject {|x| x =~ /debuginfo/ }
         sh('hsh-install', rpms.join(" "), logfile: File.join(plant.log_dir, 'install.log'))
      end
   end

   def statuses
      @statuses = gears.map {|x, y| [x, y.serialized] }.to_h
   end

   def gears
      @gears ||= package_flow
   end

   def package_flow
      flow = list_hash.values
      stop = nil
      res = {}

      while !flow.empty? && !stop
         element = flow.first
         gear = Gear.import(**element.transform_keys(&:to_sym), plant: plant)
         gear_proceed(gear)
         gear_post_proceed(gear, flow)
         res[gear.name] = gear

         stop = plant.break_on_error && !is_matched?(gear) && !gear.lost_deps&.any?
         #unknown_error
#         binding.pry if gear.error_type != :ok
      end

      res
   end

   def gear_proceed gear
      print(gear.name)
      if is_removed?(gear)
         # TODO search for replacement if renamed
         gear.store_status
         puts("...-")
      elsif is_built?(gear)
         puts("...V")
      else
         unless is_built_remotely?(gear) && gear.error_type == :ok
            gear.make(force: gear.error_type == :lost_deps)
         end
         gear.error_type != :ok ? puts("...X") : puts("...V")
      end
   end

   def gear_post_proceed gear, flow
      gear.store_status
      if is_require_assiging?(gear, flow)
         autoassign(gear, flow)
      elsif is_require_reassiging?(gear, flow)
         autoreassign(gear, flow)
      else
         flow.shift
      end
   end

   def task_no
      @task_no = plant.options.task_no
   end

   def initialize plant
      @plant = plant
   end
end

class Gear
   include Shell

   NAMES = %w(srpms rpms name path tag_name tag_id fetched_at states)
   RE = /E: (Невозможно найти пакет (?:ruby-?)?gem\((?<name>[^ )]+)\)(?<cond>[>=<~!]+)(?<version>[^']*)|Версия (?<cond>[>=<~!]+)'(?<version>[^']*)' для '(?:ruby-?)?gem\((?<name>[^ ']+)\)' не найдена)|: Требует: gem\((?<name>[^ )]+)\) \((?<cond>[>=<~!]+)(?<version>[^']*)\)/

   attr_reader :plant, :states, :status, :name, :path, :srpms, :rpms, :tag_name, :tag_id, :fetched_at, :pkgname, :no, :rebuild_from

   def status
      @status ||= srpms.any? && 0 || nil
   end

   def states
      @states ||=
         %i(removed cloned checked_out built).select do |state|
            send("is_#{state}?")
         end
   end

   def is_cloned?
      File.directory?(File.join(plant.poligon_dir, name))
   end

   def is_checked_out?
      Dir.chdir(File.join(plant.poligon_dir, name)) do
         !sh('git', 'branch', '--list', 'build').empty?
      end
   rescue Errno::ENOENT
      false
   end

   def is_built?
      rpms.any? && status == 0 &&
         (!@storen_status['tag_id'] ||
           @storen_status['tag_id'] == tag_id) &&
         (!@storen_status['tag_name'] ||
           @storen_status['tag_name'] == tag_name )
   end

   def is_removed?
      !plant.in_branch_match_package?(name)
   end

   def logfile
      @logfile = File.join(plant.log_dir, "#{name}.log")
   end

   def fullpath
      @fullpath ||= path =~ /^git:\/\// && path || File.join(plant.git_host, path)
   end

   def preclean
      @log = nil
      @error_type = nil
      @lost_deps = nil
   end

   def log
      @log ||= IO.read(logfile).encode("UTF-16be", invalid: :replace, replace: "?").encode('UTF-8')
   rescue Errno::ENOENT
   end

   def error_types
      @error_types ||= {}
   end

   def error_type log = self.log
      error_types[log] ||=
         case log
         when /E: Some index files failed to download. /
            :lost_indeces
         when /fatal: remote error: access denied or repository not exported/
            :not_exist
         when RE
            :lost_deps
         when nil
            :unbuilt
         else
           states.include?(:built) && :ok || status.to_i > 0 && :unknown_error || :unbuilt
         end
   end

   # from analyzing of the log
   def lost_deps
      @lost_deps ||=
         log && log.split("\n").grep(RE).map do |l|
            m = RE.match(l)
            gem_name = m[:name]
            gem_version = m[:version]
            cond = m[:cond] || '='
            req = Gem::Requirement.new(["#{cond} #{gem_version}"])

            Gem::Dependency.new(gem_name, req, :development)
         end || nil
   end

   def in_polygon
      dir = FileUtils.pwd
      FileUtils.rm_rf(plant.poligon_dir)
      FileUtils.cd(plant.poligon_dir)

      yield if block_given?

      FileUtils.cd(dir)
   end

   def make force: false
      in_polygon do
         clone
         if File.directory?(name)
            FileUtils.cd(name)
            preclean if force
            checkout(selected_tag) if force || states.include?(:cloned)
            build if force || states.include?(:checked_out)
         end
      end
   end

   def clone
      print "...cloning"
      sh('git', 'clone', fullpath, name, logfile: logfile, logmode: 'a+')

      state = error_type == :not_exist && :removed || :cloned

      @states |= [state]
   end

   def checkout tag
      logfile = File.join(plant.log_dir, "#{name}.log")

      #sh('git', 'checkout', "refs/remotes/origin/#{branch}", '-b build', logfile: logfile)
      sh('git', 'checkout', tag, '-b', 'build', logfile: logfile)

      @states |= [:checked_out]
   end

   def build
      print "...building"
      while %i(unbuilt lost_indeces).include?(error_type)
#         binding.pry
         preclean
         sh('gear-hsh', '--commit', '--', '-vvvv', logfile: logfile)
         @states |= [:built] if (@status = $?.exitstatus) == 0
      end
   end

   # переименован 'chroot/.out/gem-method-source-1.0.0-alt1.src.rpm' -> 'repo/SRPMS.hasher/gem-method-source-1.0.0-alt1.src.rpm'
   def files
      @files ||=
         if has_log?
            log.split("\n").grep(/chroot\/.out.* -> /).map do |x|
               /'(?<apath>[^']+)'$/ =~ x
               apath
            end.map {|x| File.join(plant.hasher_root, x) }
         else
            []
         end
   end

   def srpms
      @srpms ||= files.grep(/\/SRPMS/).each do |file|
         filename = File.basename(file)
         if !File.symlink?(file)
            newfile = File.join(plant.srpm_dir, filename)

            FileUtils.mv(file, plant.srpm_dir) if File.file?(file)
            FileUtils.ln_s(newfile, file) if File.file?(newfile)
         end
      end
   end

   def rpms
      @rpms ||= files.grep(/\/RPMS/).each do |file|
         filename = File.basename(file)
         if !File.symlink?(file)
            newfile = File.join(plant.rpm_dir, filename)

            FileUtils.mv(file, plant.rpm_dir) if File.file?(file)
            FileUtils.ln_s(newfile, file) if File.file?(newfile)
         end
      end
   end

   def branches
      @branches ||=
        sh('cat', '.git/packed-refs').select {|x| x =~ %r{remotes/origin} }.map {|x|x.match(%r{/(?<b>[^/]+)$})[:b]}
   end

   def selected_tag
      @selected_tag ||= tag_name || tag_from_branch
   end

   def tag_from_branch
#     binding.pry
      branch = rebuild_from || ([plant.to_branch, 'master', plant.in_branch] & branches).first

      sh('git', 'describe', '--tags', '--abbrev=0', "origin/#{branch}")
   end

   def name
      @name ||= status.name
   end

   def serialized
      NAMES.reduce({}) do |res, name|
         value = instance_variable_get("@#{name}") rescue send(name)
         res.merge(name => value)
      end
   end

   def store_status
      File.open(status_file, "w+") {|f| f.puts(serialized.to_yaml) }
   end

   def status_file
      File.join(plant.status_dir, "#{name}.yml")
   end

   def touch_status
      %w(srpms rpms status states).each {|x| send(x) }
   end

   def has_log?
      File.file?(logfile)
   end

   def is_originally_built?
      !@pkgname.nil?
   end

   def is_renamed?
      @pkgname && @pkgname != @name
   end

   def initialize status_in, name: raise, plant: raise, **args
      @plant = plant
      @name = name
      @storen_status = status_in

      status_in.merge(args).each do |name, value|
         next if name =~ /(states|rpms)/
         instance_variable_set("@#{name}", value)
      end

      touch_status if has_log?
   end

   class << self
      def load_status name, plant
         YAML.load(IO.read(File.join(plant.status_dir, "#{name}.yml")), permitted_classes: [Time])
      rescue ArgumentError
         YAML.load(IO.read(File.join(plant.status_dir, "#{name}.yml")))
      rescue Errno::ENOENT
         {}
      end

      #def import name: raise, path: nil, tag_name: nil, tag_id: nil, fetched_at: nil, plant: raise
      def import name: raise, plant: raise, **args
         status = load_status(name, plant)

         self.new(status, name: name, plant: plant, **args)
      end
   end
end

plant = Plant.new(options)
Build.new(plant).rebuild
