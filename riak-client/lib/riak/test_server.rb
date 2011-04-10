# Copyright 2010 Sean Cribbs, Sonian Inc., and Basho Technologies, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

require 'tempfile'
require 'expect'
require 'open3'
require 'riak/util/tcp_socket_extensions'

module Riak
  class TestServer
    APP_CONFIG_DEFAULTS = {
      :riak_core => {
        :web_ip => "127.0.0.1",
        :web_port => 9000,
        :handoff_port => 9001,
        :ring_creation_size => 64
      },
      :riak_kv => {
        :storage_backend => :riak_kv_test_backend,
        :pb_ip => "127.0.0.1",
        :pb_port => 9002,
        :js_vm_count => 8,
        :js_max_vm_mem => 8,
        :js_thread_stack => 16,
        :riak_kv_stat => true,
        # Turn off map caching
        :map_cache_size => 0,     # 0.14
        :vnode_cache_entries => 0 # 0.13
      },
      :luwak => {
        :enabled => false
      }
    }
    VM_ARGS_DEFAULTS = {
      "-name" => "riaktest#{rand(1000000).to_s}@127.0.0.1",
      "-setcookie" => "#{rand(1000000).to_s}_#{rand(1000000).to_s}",
      "+K" => true,
      "+A" => 64,
      "-smp" => "enable",
      "-env ERL_MAX_PORTS" => 4096,
      "-env ERL_FULLSWEEP_AFTER" => 10,
      "-pa" => File.expand_path("../../../erl_src", __FILE__)
    }
    DEFAULTS = {
      :app_config => APP_CONFIG_DEFAULTS,
      :vm_args => VM_ARGS_DEFAULTS,
      :temp_dir => File.join(Dir.tmpdir,'riaktest'),
    }
    attr_accessor :temp_dir, :app_config, :vm_args, :cin, :cout, :cerr, :cpid

    def initialize(options={})
      options   = deep_merge(DEFAULTS.dup, options)
      @temp_dir = File.expand_path(options[:temp_dir])
      @bin_dir  = File.expand_path(options[:bin_dir])
      options[:app_config][:riak_core][:ring_state_dir] ||= File.join(@temp_dir, "data", "ring")
      @app_config = options[:app_config]
      @vm_args    = options[:vm_args]
      # For synchronizing start/stop/recycle
      @mutex = Mutex.new
      cleanup # Should prevent some errors related to unclean startup
    end

    # Sets up the proper scripts, configuration and directories for
    # the test server.  Call at the top of your test suite (not in a
    # setup method).
    def prepare!
      unless @prepared
        create_temp_directories
        @riak_script = File.join(@temp_bin, 'riak')
        write_riak_script
        write_vm_args
        write_app_config
        @prepared = true
      end
    end

    # Starts the test server if it is not already running, and waits
    # for it to respond to pings.
    def start
      if @prepared && !@started
        @mutex.synchronize do
          @cin, @cout, @cerr, @cpid = Open3.popen3("#{@riak_script} console")
          @cin.puts
          @cin.flush
          wait_for_erlang_prompt
          @started = true
        end
      end
    end

    # Stops the test server if it is running.
    def stop
      if @started
        @mutex.synchronize do
          begin
            @cin.puts "init:stop()."
            @cin.flush
          rescue Errno::EPIPE
          ensure
            register_stop
          end
        end
        true
      end
    end

    # Whether the server has been started.
    def started?
      @started
    end

    # Causes the entire contents of the Riak in-memory backends to be
    # dumped by performing a soft restart.
    def recycle
      if @started
        @mutex.synchronize do
          begin
            if @app_config[:riak_kv][:storage_backend] == :riak_kv_test_backend
              @cin.puts "riak_kv_test_backend:reset()."
              @cin.flush
              wait_for_erlang_prompt
            else
              @cin.puts "init:restart()."
              @cin.flush
              wait_for_erlang_prompt
              wait_for_startup
            end
          rescue Errno::EPIPE
            warn "Broken pipe when recycling, is Riak alive?"
            register_stop
            return false
          end
        end
        true
      else
        start
      end
    end

    # Cleans up any files and directories generated by the test
    # server.
    def cleanup
      stop if @started
      FileUtils.rm_rf(@temp_dir)
      @prepared = false
    end

    private
    def create_temp_directories
      %w{bin etc log data pipe}.each do |dir|
        instance_variable_set("@temp_#{dir}", File.expand_path(File.join(@temp_dir, dir)))
        FileUtils.mkdir_p(instance_variable_get("@temp_#{dir}"))
      end
    end

    def write_riak_script
      File.open(@riak_script, 'wb') do |f|
        File.readlines(File.join(@bin_dir, 'riak')).each do |line|
          line.sub!(/(RUNNER_SCRIPT_DIR=)(.*)/, '\1' + @temp_bin)
          line.sub!(/(RUNNER_ETC_DIR=)(.*)/, '\1' + @temp_etc)
          line.sub!(/(RUNNER_USER=)(.*)/, '\1')
          line.sub!(/(RUNNER_LOG_DIR=)(.*)/, '\1' + @temp_log)
          line.sub!(/(PIPE_DIR=)(.*)/, '\1' + @temp_pipe)
          if line.strip == "RUNNER_BASE_DIR=${RUNNER_SCRIPT_DIR%/*}"
            line = "RUNNER_BASE_DIR=#{File.expand_path("..",@bin_dir)}\n"
          end
          f.write line
        end
      end
      FileUtils.chmod(0755,@riak_script)
    end

    def write_vm_args
      File.open(File.join(@temp_etc, 'vm.args'), 'wb') do |f|
        f.write @vm_args.map {|k,v| "#{k} #{v}" }.join("\n")
      end
    end

    def write_app_config
      File.open(File.join(@temp_etc, 'app.config'), 'wb') do |f|
        f.write to_erlang_config(@app_config) + '.'
      end
    end

    def deep_merge(source, target)
      source.merge(target) do |key, old_val, new_val|
        if Hash === old_val && Hash === new_val
          deep_merge(old_val, new_val)
        else
          new_val
        end
      end
    end

    def to_erlang_config(hash, depth = 1)
      padding = '    ' * depth
      parent_padding = '    ' * (depth-1)
      values = hash.map do |k,v|
        printable = case v
                    when Hash
                      to_erlang_config(v, depth+1)
                    when String
                      "\"#{v}\""
                    else
                      v.to_s
                    end
        "{#{k}, #{printable}}"
      end.join(",\n#{padding}")
      "[\n#{padding}#{values}\n#{parent_padding}]"
    end

    def wait_for_startup
      TCPSocket.wait_for_service_with_timeout(:host => @app_config[:riak_core][:web_ip],
                                              :port => @app_config[:riak_core][:web_port], :timeout => 10)
    end

    def wait_for_erlang_prompt
      @cout.expect(/\(#{Regexp.escape(vm_args["-name"])}\)\d+>/)
    end

    def register_stop
      %w{@cin @cout @cerr}.each {|io| if instance_variable_get(io); instance_variable_get(io).close; instance_variable_set(io, nil) end }
      _cpid = @cpid; @cpid = nil
      at_exit { _cpid.join if _cpid && _cpid.alive? }
      @started = false
    end
  end
end
