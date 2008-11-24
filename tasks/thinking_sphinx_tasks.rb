require 'fileutils'

namespace :thinking_sphinx do
  task :app_env do
    Rake::Task[:environment].invoke if defined?(RAILS_ROOT)
    Rake::Task[:merb_init].invoke    if defined?(Merb)
    @indexer = (`which indexer` rescue '/usr/local/bin/indexer').strip
    @searchd = (`which searchd` rescue '/usr/local/bin/searchd').strip
  end
  
  desc "Start a Sphinx searchd daemon using Thinking Sphinx's settings"
  task :start => :app_env do
    config = ThinkingSphinx::Configuration.new
    
    FileUtils.mkdir_p config.searchd_file_path
    raise RuntimeError, "searchd is already running." if sphinx_running?
    
    Dir["#{config.searchd_file_path}/*.spl"].each { |file| File.delete(file) }
    
    cmd = "#{@searchd} --config #{config.config_file}"
    puts cmd
    system cmd
    
    sleep(2)
    
    if sphinx_running?
      puts "Started successfully (pid #{sphinx_pid})."
    else
      puts "Failed to start searchd daemon. Check #{config.searchd_log_file}."
    end
  end
  
  desc "Stop Sphinx using Thinking Sphinx's settings"
  task :stop => :app_env do
    raise RuntimeError, "searchd is not running." unless sphinx_running?
    pid = sphinx_pid
    system "kill #{pid}"
    puts "Stopped search daemon (pid #{pid})."
  end
  
  desc "Restart Sphinx"
  task :restart => [:app_env, :stop, :start]
  
  desc "Generate the Sphinx configuration file using Thinking Sphinx's settings"
  task :configure => :app_env do
    ThinkingSphinx::Configuration.new.build
  end
  
  namespace :index do

    desc "Index data for all or 1 Sphinx deltas. Set MODEL env variable to specify which index, defaults to all"
    task :delta => [:app_env, :configure] do
      raise RuntimeError, "ThinkingSphinx deltas not enabled!" unless ThinkingSphinx.deltas_enabled?
      
      if ENV['MODEL']
        index_name = get_index_name(ENV['MODEL'])
				ts_index(index_name, true)
      else
        puts "Reindexing deltas of #{ThinkingSphinx.indexed_models.size} indexes"
        ThinkingSphinx.indexed_models.each do |index|
          ts_index(index, true)
        end
      end
    end

    desc "Merges the core and delta indexes for all or 1 Sphinx deltas. Set MODEL env variable to specify which index, defaults to all"
    task :merge => [:app_env, :configure] do
      raise RuntimeError, "ThinkingSphinx deltas not enabled - nothing to merge!" unless ThinkingSphinx.deltas_enabled?
      
      if ENV['MODEL']
        index_name = get_index_name(ENV['MODEL'])
        ts_merge(index_name)
      else
        puts "Merging all #{ThinkingSphinx.indexed_models.size} indexes"
        ThinkingSphinx.indexed_models.each do |index|
          ts_merge(index)
        end
      end
    end
    
    desc "Index data for all Sphinx indexes."
    task :all => "thinking_sphinx:index"
  end
  
  desc "Index data for all or 1 Sphinx indexes. Set MODEL env variable to specify which index, defaults to all"
  task :index => [:app_env, :configure] do  
    index_name = ENV['MODEL'] ? get_index_name(ENV['MODEL']) : '--all'
    ts_index(index_name)
  end
    
end

namespace :ts do
  desc "Start a Sphinx searchd daemon using Thinking Sphinx's settings"
  task :start   => "thinking_sphinx:start"
  desc "Stop Sphinx using Thinking Sphinx's settings"
  task :stop    => "thinking_sphinx:stop"
  desc "Index data for all or 1 Sphinx index using Thinking Sphinx's settings.  Set MODEL env variable to specify which index, defaults to all"
  task :in      => "thinking_sphinx:index"
  desc "Index data for all or 1 Sphinx indexes. Set MODEL env variable to specify which index, defaults to all"
  task :index   => "thinking_sphinx:index"
  desc "Index data for all or 1 Sphinx deltas. Set MODEL env variable to specify which index, defaults to all"
  task :id      => "thinking_sphinx:index:delta"
  desc "Merges the core and delta indexes for all or 1 Sphinx deltas. Set MODEL env variable to specify which index, defaults to all"
  task :im      => "thinking_sphinx:index:merge"
  desc "Restart Sphinx"
  task :restart => "thinking_sphinx:restart"
  desc "Generate the Sphinx configuration file using Thinking Sphinx's settings"
  task :config  => "thinking_sphinx:configure"
end


def ts_index(index, delta=false)
  indexer_running?
  config = ThinkingSphinx::Configuration.new
  FileUtils.mkdir_p config.searchd_file_path
  cmd = "#{@indexer} --config '#{config.config_file}'"
  cmd << " --rotate" if sphinx_running?
  cmd << " #{index_name(index, delta)}"
  puts cmd
  system cmd

  check_rotate if sphinx_running?
end

def ts_merge(index, delta=nil)
  indexer_running?
  delta ||= delta_name(index)
  config = ThinkingSphinx::Configuration.new
  
  cmd = "#{@indexer} --config '#{config.config_file}'"
  cmd << " --rotate" if sphinx_running?
  cmd << " --merge #{index_name(index)} #{delta} --merge-dst-range deleted 0 0"
  puts cmd
  system cmd

  check_rotate if sphinx_running?
end

# Pass it an +index+ or model name and it will return
# the actual index name Thinking Sphinx used in the config.
def index_name(index, delta=false)
  return index if index =~ /^--\w+/ # for '--all'
  i = "#{index.to_s.strip.classify.constantize.indexes.first.name}"
  i << (delta ? "_delta" : "_core")
  i
end

# Pass it an +index+ or model name and it will return
# the actual delta name Thinking Sphinx used in the config.
def delta_name(index)
  index_name(index, true)
end

# Similar to the above, but a little more useful feedback on error.
# Redundant?
def get_index_name(str)
  raise "You must set a model name variable like: MODEL=user" if str.to_s.strip.blank?
  klass = str.to_s.strip.classify.constantize
  raise "The class '#{klass}' has no Thinking Sphinx indexes defined" if !klass.indexes || klass.indexes.empty?
  klass.indexes.first.name    
end

def sphinx_pid
  config = ThinkingSphinx::Configuration.new
  
  if File.exists?(config.pid_file)
    `cat #{config.pid_file}`[/\d+/]
  else
    nil
  end
end

def sphinx_running?
  sphinx_pid && `ps -p #{sphinx_pid} | wc -l`.to_i > 1
end

# Raises an exception if the Sphinx indexer is already running
def indexer_running?
  ps_check = `ps aux | grep -v 'grep' | grep indexer`.split(/\n/)
  raise RuntimeError, "Indexer is already running:\n\n #{ps_check.join('\n')}" if ps_check.size > 0
  return false
end

# Snagged from UltraSphinx...just warns of possible problems though,
# instead of deleting the potentially corrupt indexes.
def check_rotate
  sleep(5)
  config = ThinkingSphinx::Configuration.new
  
  failed = Dir[config.searchd_file_path + "/*.new.*"]
  if failed.any?
    # puts "warning; indexes failed to rotate! Deleting new indexes"
    # puts "try 'killall searchd' and then 'rake thinking_sphinx:start'"
    # failed.each {|f| File.delete f }
    err =  "Problem rotating indexes!\n"
    err << "Look in #{config.searchd_file_path} for files with 'new' in their name - they shouldn't be there!  You may need to reindex."
    puts "WARNING: #{err}"
    # raise RuntimeError, err
  end
  return true
end
