# -*- encoding: utf-8 -*-
#
# Author:: Fletcher Nichol (<fnichol@nichol.ca>)
#
# Copyright (C) 2012, Fletcher Nichol
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
require 'pathname'
require 'rubygems'
require 'rubygems/package'
require 'rubygems/package/tar_writer'

module Kitchen

  module Driver

    # Base class for a driver that uses SSH to communication with an instance.
    # A subclass must implement the following methods:
    # * #create(state)
    # * #destroy(state)
    #
    # @author Fletcher Nichol <fnichol@nichol.ca>
    class SSHBase < Base

      default_config :sudo, true
      default_config :port, 22
      default_config :compression, 'gzip'

      def create(state)
        raise ClientError, "#{self.class}#create must be implemented"
      end

      def converge(state)
        provisioner = instance.provisioner
        provisioner.create_sandbox
        sandbox_dirs = Dir.glob("#{provisioner.sandbox_path}/*")

        Kitchen::SSH.new(*build_ssh_args(state)) do |conn|
          run_remote(provisioner.install_command, conn)
          run_remote(provisioner.init_command, conn)
          transfer_path(sandbox_dirs, provisioner[:root_path], conn)
          run_remote(provisioner.prepare_command, conn)
          run_remote(provisioner.run_command, conn)
        end
      ensure
        provisioner && provisioner.cleanup_sandbox
      end

      def setup(state)
        Kitchen::SSH.new(*build_ssh_args(state)) do |conn|
          run_remote(busser_setup_cmd, conn)
        end
      end

      def verify(state)
        Kitchen::SSH.new(*build_ssh_args(state)) do |conn|
          run_remote(busser_sync_cmd, conn)
          run_remote(busser_run_cmd, conn)
        end
      end

      def destroy(state)
        raise ClientError, "#{self.class}#destroy must be implemented"
      end

      def login_command(state)
        SSH.new(*build_ssh_args(state)).login_command
      end

      def remote_command(state, command)
        Kitchen::SSH.new(*build_ssh_args(state)) do |conn|
          run_remote(command, conn)
        end
      end

      def ssh(ssh_args, command)
        Kitchen::SSH.new(*ssh_args) do |conn|
          run_remote(command, conn)
        end
      end

      protected

      def build_ssh_args(state)
        combined = config.to_hash.merge(state)

        opts = Hash.new
        opts[:user_known_hosts_file] = "/dev/null"
        opts[:paranoid] = false
        opts[:keys_only] = true if combined[:ssh_key]
        opts[:password] = combined[:password] if combined[:password]
        opts[:forward_agent] = combined[:forward_agent] if combined.key? :forward_agent
        opts[:port] = combined[:port] if combined[:port]
        opts[:keys] = Array(combined[:ssh_key]) if combined[:ssh_key]
        opts[:logger] = logger

        [combined[:hostname], combined[:username], opts]
      end

      def env_cmd(cmd)
        env = "env"
        env << " http_proxy=#{config[:http_proxy]}" if config[:http_proxy]
        env << " https_proxy=#{config[:https_proxy]}" if config[:https_proxy]

        env == "env" ? cmd : "#{env} #{cmd}"
      end

      def run_remote(command, connection)
        return if command.nil?

        connection.exec(env_cmd(command))
      rescue SSHFailed, Net::SSH::Exception => ex
        raise ActionFailed, ex.message
      end

      def transfer_path(locals, remote, connection)
        return if locals.nil? || Array(locals).empty?
        info('Compress files before transferring')
        compressor.compress(locals) do |file|
          path = file.is_a?(String) ? file : file.path
          filename = File.basename(path)
          debug('Upload compression supports')
          compressor.supports.each { |support| connection.upload_path!(support.to_s, remote) }
          info("Transferring files to #{instance.to_str}")
          connection.upload_path!(path, remote)
          unpack_command = compressor.unpack_command(filename)
          if unpack_command
            debug('Decompressing files remotely')
            run_remote("cd #{remote} && #{unpack_command} && rm #{filename}", connection)
          end
        end
        debug('Transfer complete')
      rescue SSHFailed, Net::SSH::Exception => ex
        raise ActionFailed, ex.message
      end

      def wait_for_sshd(hostname, username = nil, options = {})
        SSH.new(hostname, username, {:logger => logger}.merge(options)).wait
      end

      def compressor
        @compressor ||= begin
          str_const = Thor::Util.camel_case(config[:compression])
          klass = Kitchen::Driver.const_get("Compression::#{str_const}")
          klass.new(instance)
        end
      end
    end
  end
end
