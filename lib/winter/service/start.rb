# Copyright 2013 LiveOps, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not 
# use this file except in compliance with the License.  You may obtain a copy 
# of the License at:
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software 
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT 
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the 
# License for the specific language governing permissions and limitations 
# under the License.

require 'winter/constants'
require 'winter/logger'
require 'winter/service/stop'
require 'shellwords'

# TODO This needs a larger refactor to make it more functional and less reliant
# upon class variables (@foo). HELP!

module Winter
  class Service

    def initialize
      #put defaults here
      @config = {}
      @config['java_home']   = ENV['JAVA_HOME'] 
      @config['service']     = 'default'
      @config['log.level']   = 1
      @config['64bit']       = true
      @config['jvm.mx']      = '1g'
      @config['console']     = '/dev/null'
      @config['web.port']    = 8080
      @config['osgi.port']   = 6070
      @config['jdb.port']    = 6071
      @config['jmx.port']    = 6072
      @config['service.conf.dir']    = "conf"

      #@config['log.dir'] = File.join(WINTERFELL_DIR,RUN_DIR,@config['service'],'logs')
      @directives = {}
    end

    def start(winterfile, options)
      begin
        dsl = DSL.evaluate winterfile, options
      rescue Exception=>e
        $LOG.error e
        exit
      end

      dsl[:dependencies].each do |dep|
        $LOG.debug "dependency: #{dep.group}.#{dep.artifact}"
      end
      @felix = dsl[:felix]

      @config.merge! dsl[:config] # add Winterfile 'directive' commands
      @config.merge! options # overwrite @config with command-line options
      @config.each do |k,v|
        k = k.shellescape if k.is_a? String
        v = v.shellescape if v.is_a? String
      end
      $LOG.debug @config

      @service_dir = File.join(File.split(winterfile)[0],RUN_DIR,@config['service']).shellescape

      @config['log.dir'] = File.join(@service_dir,'logs')

      @directives.merge! dsl[:directives]

      java_cmd = generate_java_invocation
      
      if @config['daemonize']
        java_cmd <<  " 2>&1 " #"don't eat the log thats evil"
      else 
        java_cmd << " > #{@config['console']} 2>&1"
      end
      $LOG.debug java_cmd

      # 
      if( File.exists?(File.join(@service_dir, "pid")) )
        $LOG.error "PID file already exists. Is the process running?"
        exit
      end

      # Normally, we'd just use Process.daemon for ruby 1.9, but for some
      # reason the OSGi container we're using crashes when the CWD is changed
      # to '/'. So, we'll just leave the CWD alone.
      #Process.daemon(Dir.getwd,nil)
      
      exec(java_cmd) if @config['daemonize'] #Let the child eat winter so things are awesome for daemontools
      #We never hit the past this point if  we went to daemonize mode.
      
      #If we're not trying to run as a daemon just fork and let the subprocess be eaten
      java_pid = fork do
        exec(java_cmd)
      end

      pid_file = File.open(File.join(@service_dir, "pid"), "w")
      pid = java_pid
      pid_file.write(pid)
      pid_file.close      

      $LOG.info "Started #{@config['service']} (#{pid})"
    end

    def find_java
      if !@config['java_home'].nil? && File.exists?(File.join(@config['java_home'],'bin','java'))
        return File.join(@config['java_home'],'bin','java')
      end
      if !ENV['JAVA_HOME'].nil? && File.exists?(File.join(ENV['JAVA_HOME'],'bin','java'))
        return File.join(ENV['JAVA_HOME'],'bin','java')
      end
      env = `env java -version 2>&1`
      if env['version']
        return "java"
      end
      raise "JRE could not be found. Please set JAVA_HOME or configure java_home."
    end

    def generate_java_invocation
      java_bin = find_java

      felix_jar = File.join(@felix.destination,"#{@felix.artifact}-#{@felix.version}.#{@felix.package}")

      # start building the command
      cmd = [ "exec #{java_bin.shellescape} -server" ] 
      cmd << (@config["64bit"]==true ? " -d64 -XX:+UseCompressedOops":'')
      cmd << " -XX:MaxPermSize=256m -XX:NewRatio=3"
      cmd << " -Xmx#{@config['jvm.mx']}" 
      cmd << opt("felix.fileinstall.dir", "#{@service_dir}/#{BUNDLES_DIR}")

      config_properties = File.join(@service_dir, "conf", F_CONFIG_PROPERTIES)
      cmd << opt("felix.config.properties", "file:" + config_properties)
      cmd << opt("felix.log.level", felix_log_level(@config['log.level']))

      # TODO remove these options when the logger bundle is updated to use the classpath
      logger_properties = File.join(@service_dir, "conf", F_LOGGER_PROPERTIES)
      logback_xml       = File.join(@service_dir, "conf", F_LOGBACK_XML)
      cmd << opt("log4j.configuration",       logger_properties)
      cmd << opt("logback.configurationFile", logback_xml)
    
      cmd << opt("web.port",         @config["web.port"])
      cmd << opt("osgi.port",        @config["osgi.port"])
      cmd << opt("log.dir",          @config['log.dir'])
      cmd << opt("service.conf.dir", File.join(@service_dir, "conf"))
      cmd << opt(OPT_BUNDLE_DIR,     "#{@service_dir}/bundles")
      cmd << add_directives( @directives )
      cmd << @config["osgi.shell.telnet.ip"]?" -Dosgi.shell.telnet.ip=#{@config["osgi.shell.telnet.ip"]}":''
      #cmd.push(add_code_coverage())
      cmd << (@config["jdb.port"] ? " -Xdebug -Xrunjdwp:transport=dt_socket,address=#{@config["jdb.port"]},server=y,suspend=n" : '')
      cmd << (@config["jmx.port"] ? " -Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.port=#{@config["jmx.port"]} -Dcom.sun.management.jmxremote.ssl=false -Dcom.sun.management.jmxremote.authenticate=false" : '')
      cmd << " -cp #{@service_dir}/conf:#{felix_jar.to_s.shellescape} org.apache.felix.main.Main"
      cmd << " -b #{@service_dir}/libs"
      cmd << " #{@service_dir}/felix_cache"
        
      return cmd.join(" \\\n ")
    end 

    def add_directives( dir )
      tmp = ""
      dir.each do |key, value|
        tmp << " -D"+Shellwords.escape(key)
        if value
          tmp << "="+Shellwords.escape(value.to_s)
        end
      end
      tmp
    end

    def opt(key, value)
      " -D#{Shellwords.escape(key.to_s)}=#{Shellwords.escape(value.to_s)}"
    end

    def felix_log_level(level)
      if level =~ /[1-4]/
        return level
      end
      if !level.is_a? String
        return 1
      end
      case level.upcase
      when "ERROR"
        return 1
      when "WARN"
        return 2
      when "INFO"
        return 3
      when "DEBUG"
        return 4
      else
        return 1
      end
  end

  end
end
