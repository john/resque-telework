module Resque
  module Plugins
    module Telework      
      class Manager
        
        include Resque::Plugins::Telework::Redis
        
        def initialize(host)
          @HOST= host
          @SLEEP= 2
          @WORKERS= {}
          @STOPPED= []
        end
        
        def start
          send_status( 'Info', "Daemon (PID #{Process.pid}) starting on host #{@HOST}" )
          unless check_redis # Check the Redis interface version
           err= "Telework: Error: Redis interface version mismatch - exciting"
           puts err # We can't use send_status() as it relies on Redis so we just show a message
           raise err
          end
          if is_alive(@HOST)  # Only one deamon can be run on a given host at the moment (this may change)
            send_status( 'Error', "There is already a daemon running on #{@HOST}")
            send_status( 'Error', "This daemon (PID #{Process.pid}) cannot be started and will terminare now")
          end
          loop do
            i_am_alive
            check_processes
            while cmd= cmds_pop( @HOST ) do
              do_command(cmd)
            end
            sleep @SLEEP
          end
        rescue Interrupt
          send_status( 'Info', "Daemon interrupted, exiting gracefully") if @WORKERS.empty?
          send_status( 'Error', "Daemon interrupted, exiting, running workers may now unexpectedly terminate") unless @WORKERS.empty?
        rescue Exception => e
          send_status( 'Error', "Exception #{e.message}")
          send_status( 'Error', "Exception should not be thrown here, please submit a bug report")
        end
        
        def send_status( severity, message )
          puts "Telework: #{severity}: #{message}"
          info= { 'host'=> @HOST, 'severity' => severity, 'message'=> message,
                  'date'=> Time.now }
          status_push(info)
        end
        
        # cmd is a flat hash with the following: command, revision, rails_env, worker_id, worker_count, worker_queue
        def do_command( cmd )
          case cmd['command']
          when 'start_worker'
            start_worker( cmd, find_revision(cmd['revision']) )
          when 'stop_worker'
            stop_worker( cmd )
          when 'kill_worker'
            stop_worker( cmd, true )
          else
            send_status( 'Error', "Unknown command '#{cmd['command']}'" )
          end
        end
                
        def start_worker( cmd, rev_info )
          # Retrieving args
          path= rev_info['revision_path']
          log_path= rev_info['revision_log_path']
          log_path||= "."
          rev= rev_info['revision']
          id= cmd['worker_id']
          # Starting the job
          env= { "QUEUE"=> cmd['worker_queue'] }
          env["RAILS_ENV"]= cmd['rails_env'] if "(default)" != cmd['rails_env']
          opt= { :in => "/dev/null", 
                 :out => "#{log_path}/telework_#{id}_stdout.log", 
                 :err => "#{log_path}/telework_#{id}_stderr.log", 
                 :chdir => path }
          exec= cmd['exec']
          pid= spawn( env, exec, opt) # Start it!
          info= { 'pid' => pid, 'status' => 'running', 'environment' => env, 'options' => opt, 'revision_info' => rev_info }
          # Log snapshot
          info['log_snapshot']= cmd['log_snapshot'] if cmd['log_snapshot']
          info['log_snapshort_size']= cmd['log_snapshot_size'] if cmd['log_snapshot']
          @WORKERS[id]= info
          workers_add( @HOST, id, info )
          send_status( 'Info', "Starting worker #{id} (PID #{pid})" )
          # Create an helper file
          intro = "# Telework: starting worker #{id} on host #{@HOST} at #{Time.now.strftime("%a %b %e %R %Y")}"
          env.keys.each { |v| intro+= "\n# Telework: environment variable '#{v}' set to '#{env[v]}'" }
          intro+= "\n# Telework: command line is: #{exec}"
          intro+= "\n# Telework: path is: #{path}"
          intro+= "\n# Telework: log file for stdout is: #{opt[:out]}"
          intro+= "\n# Telework: log file for stderr is: #{opt[:err]}"
          intro+= "\n# Telework: PID is: #{pid}"
          intro+= "\n"
          File.open("#{log_path}/telework_#{id}.log", 'w') { |f| f.write(intro) }
        end

        def stop_worker ( cmd, kill=false )
          id= cmd['worker_id']
          info= @WORKERS[id]
          send_status( 'Error', "Worker #{id} was not found on this host" ) unless info
          return unless info
          sig= kill ? "KILL" : "QUIT"
          send_status( 'Info', "Stopping worker #{id} (PID #{info['pid']}) using signal #{sig}" )
          Process.kill( sig, info['pid'] )
          @STOPPED << id
          info['status']= kill ? 'killed' : 'exiting'
          workers_add( @HOST, id, info )
          @WORKERS[id]= info
        end
                
        def check_processes
          workers_delall( @HOST )
          @WORKERS.keys.each do |id|
            remove= false
            unexpected_death= false
            begin # Zombie hunt..
              res= Process.waitpid(@WORKERS[id]['pid'], Process::WNOHANG)
              remove= true if res 
            rescue # Not a child.. so the process is already dead (we don't know why, maybe someone did a kill -9)
              unexpected_death= true
              remove= true
            end
            if remove
              if unexpected_death
                send_status( 'Error', "Worker #{id} (PID #{@WORKERS[id]['pid']}) has unexpectedly ended" )
              else
                send_status( 'Info', "Worker #{id} (PID #{@WORKERS[id]['pid']}) has exited" ) if @STOPPED.index(id)
                send_status( 'Error', "Worker #{id} (PID #{@WORKERS[id]['pid']}) has unexpectedly exited" ) unless @STOPPED.index(id)
                @STOPPED.delete(id)
              end
              @WORKERS.delete(id)
            else
              update_log_snapshot(id)
              workers_add( @HOST, id, @WORKERS[id] )
            end
                        
          end
        end
        
        def update_log_snapshot( id )
          ls= @WORKERS[id]['log_snapshot']
          return unless ls
          last= @WORKERS[id]['last_log_snapshot']
          last||= 0
          now= Time.now.to_i
          if now >= last+ls
            puts "Updating the log for worker #{id}"
            size= @WORKERS[id]['log_snapshot_size']
            size||= 20
            # Getting the logs
            logerr= get_tail( @WORKERS[id]['options'][:err], size )
            logout= get_tail( @WORKERS[id]['options'][:out], size )
            # Write back
            info= { :date => Time.now, :log_stderr => logerr, :log_stdout => logout }
            logs_add( @HOST, id, info )
            @WORKERS[id]['last_log_snapshot']= now
          end 
        end
        
        def get_tail( f, size )
          `tail -n #{size} #{f}`
        end
      
      end
    end
  end
end
