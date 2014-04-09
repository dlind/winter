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

require 'winter/logger'
require 'fileutils'
require 'digest/md5'
require 'net/http'

module Winter

  class Dependency
    attr_accessor :artifact
    attr_accessor :group
    attr_accessor :version
    attr_accessor :repositories
    attr_accessor :package
    attr_accessor :offline
    attr_accessor :transative
    attr_accessor :destination

    def initialize
      @artifact     = nil
      @group        = nil
      @version      = 'LATEST'
      @repositories = []
      @package      = 'jar'
      @offline      = false
      @transative   = false
      @verbose      = false 
      @destination  = '.'
    end
    
    def get    
      if ! File.directory?(@destination)  
        $LOG.debug "Create the destination folder if its not already there."
        FileUtils.mkdir_p @destination  
      end
      #Try and get file in a couple different ways. If we succeed then move on. 
      #Artifacts in your local .m2 ALWAYS take precedence over a remote artifact...
      #Unless we fail so hard we end up using mvn as a last ditched effort. 
      success = getLocalM2
      success = getRestArtifactory if ! success and ! @offline 
      success = getMaven if ! success and system( 'which mvn > /dev/null' ) 
      if ! success
        $LOG.info "[failed] #{outputFilename}"
      end
      return success
    end
    
    def artifactory_path
      "#{@group.gsub(/\./,'/')}/#{@artifact}/#{@version}/#{@artifact}-#{@version}.#{@package}"
    end

    def dest_file
      File.join(@destination,outputFilename)
    end
    
    def restRequest(uri)
      begin
        response = Net::HTTP.get_response(uri)
      rescue Exception => e
        raise "Could not retrieve artifact"
      end

      $LOG.debug "#{outputFilename}: Rest request to #{uri.inspect} #{response.inspect}"
      return response.body if response.is_a?(Net::HTTPSuccess)
      raise "Rest request got a bad response code back [#{response.code}]" 
    end
    
    def getRestArtifactory 
      $LOG.debug "#{outputFilename}: Attempting to fetch via the artifactory rest api."
      #Loop through all the repos until something works
      @repositories.each { |repo| 
        begin
          open(dest_file,"wb") { |file|
            file.write(restRequest(URI.parse("#{repo}/#{artifactory_path}")))
          }
        rescue RuntimeError => e # :( Maybe do better handling later. 
          $LOG.debug "#{outputFilename}: Unable to fetch Artifact from #{repo}/#{artifactory_path}"  
          $LOG.debug e
          next
        end 
        #Check to make sure the md5sum of what we downloaded matches what's in the artifactory.
        begin
          artifactory_md5 = restRequest(URI.parse("#{repo}/#{artifactory_path}.md5"))
          my_md5 = Digest::MD5.file("#{dest_file}").hexdigest
        rescue RuntimeError => e # :( Do better handling later. 
          $LOG.error "#{outputFilename}: Blew up while attempting to get md5s."
        else
          if artifactory_md5 == my_md5
            $LOG.debug "#{outputFilename}: Successfully fetched via artifactory rest api."
            $LOG.info "[remote] #{outputFilename}"
            return true 
          end
          $LOG.error "#{outputFilename}: Comparing remote MD5 #{artifactory_md5} to local md5 #{my_md5} (#{dest_file})" 
          $LOG.error "#{outputFilename}: Comparison failed. Deleting the 'bad' jar and moving on." 
          FileUtils.rm(dest_file)
        end
      }
      return false
    end
    
    def getLocalM2 
      begin
        artifact = "#{ENV["HOME"]}/.m2/repository/#{artifactory_path}"
        $LOG.debug "#{outputFilename}: Copying #{artifact} to #{dest_file}"
        FileUtils.cp(artifact,dest_file)
      rescue Errno::ENOENT
      	$LOG.debug "#{outputFilename}: #{artifact} does not exist."
      rescue SystemCallError => e
        $LOG.error "#{outputFilename}: Failed to copy file from local m2 repository."
        $LOG.error e
      else #Yay we got it
      	$LOG.debug "#{outputFilename}: Successfully copied from local m2 repository."
        $LOG.info "[local]  #{outputFilename}"
        return true
      end
      return false
    end

    #Depricated because its slow and expensive to use... leaving it here for now.
    def getMaven
      c =  "mvn org.apache.maven.plugins:maven-dependency-plugin:2.5:get " 
      c << " -DremoteRepositories=#{@repositories.join(',').shellescape}" 
      c << " -Dtransitive=#{@transative}" 
      c << " -Dartifact=#{@group.shellescape}:#{@artifact.shellescape}:#{@version.shellescape}:#{@package.shellescape}" 
      c << " -Ddest=#{dest_file.shellescape}"

      if @offline
        c << " --offline"
      end

      if !@verbose
        #quiet mode is default
        c << " -q"
      end

      $LOG.debug c
      result = system( c )
      if result != true
        $LOG.error("Failed to retrieve artifact: #{@group}:#{@artifact}:#{@version}:#{@package}")
      else
        $LOG.debug "#{@group}:#{@artifact}:#{@version}:#{@package}"
        $LOG.info "[maven]  #{outputFilename}"
      end
      return result
    end

    def outputFilename
      "#{@artifact}-#{@version}.#{@package}"
    end
  end

end

