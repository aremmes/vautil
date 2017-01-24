
class VAUtil
  module ODBC
    ACTIVE_CUSTOMER = 1
    DIALPLAN_REALTIME = 1
    DIALPLAN_ODBC = 2

    def make_odbc_batch_with_context(context_list, log_file)
      reload_servers = Hash.new
      
      context_list.each do |context_name|
        branch_id = get_branch_id_with_context context_name
        server_hostname = get_server_with_branch_id branch_id
        puts "Processing #{context_name}, branch: #{branch_id}, server: #{server_hostname}"
        if !should_change branch_id
          puts "- either inactive or already ODBC"
          next
        end
        
        set_odbc branch_id
        puts "- set vadb to ODBC"
        delete_realtime branch_id
        puts "- ran delete realtime"
        run_codegen branch_id
        puts "- ran codegen"
        prune_peers server_hostname, context_name
        puts "- pruned peers"
        
        reload_servers[server_hostname] = true
        log_file.puts context_name
      end
      
      reload_servers.keys.each do |server_hostname|
        dialplan_reload server_hostname
        puts "Dialplan reload on #{server_hostname}"
      end
    end
    
    def make_odbc_batch(file)
      context_list = read_config_file(file)
      output_file_name = "/var/tmp/odbc-conversion."
      output_file_name += Time.now.strftime('%Y%m%d-%H%M')
      log_file = File.new(output_file_name, "w+")
      make_odbc_batch_with_context(context_list, log_file)
      puts "completed context names in #{output_file_name}"
      log_file.close
    end
    
    def validate_odbc(file)
      context_list = read_config_file(file)
      context_list.each do |context_name|
        branch_id = get_branch_id_with_context context_name
        server = get_server_with_branch_id branch_id
        valid = true
        valid = valid && check_dialplan_is_odbc(context_name, server)
        valid = valid && check_db_has_pbx_entry(branch_id, context_name, server)
        puts "Failed one or more checks #{context_name} on #{server}" unless valid
      end
    end
    
    def check_dialplan_is_odbc(context_name, server)
      command = "sudo /usr/sbin/asterisk -rx 'show dialplan #{context_name}' | grep -q 'Received call from endpoint'"
      retval = Scutil.exec_command(server, VAUtil.config['fs_ssh_user'], command, '/dev/null')
      retval.zero?
    end
    
    def should_change(branch_id)
      return ( (get_dialplan_type(branch_id) != DIALPLAN_ODBC) &&
               (is_active branch_id) )
    end
    
    def is_active(branch_id)
      status = run_select_query("SELECT c.statusId FROM customer AS c LEFT JOIN branch AS b ON (c.customerId = b.customerId) WHERE branchId = #{branch_id}")
      status == ACTIVE_CUSTOMER
    end
    
    def make_odbc(context_name)
      branch_id = get_branch_id_with_context context_name
      if (get_dialplan_type(branch_id) != DIALPLAN_ODBC)
        set_odbc branch_id
        delete_realtime branch_id
        run_codegen branch_id
        server_hostname = get_server_with_branch_id branch_id
        dialplan_reload server_hostname
        prune_peers server_hostname, context_name
      end
    end
    
    def set_odbc(branch_id)
      run_update_query("UPDATE branch SET dialplanTypeId = #{DIALPLAN_ODBC} WHERE branchID = #{branch_id}")
    end
    
    def get_dialplan_type(branch_id)
      run_select_query("SELECT dialplanTypeId FROM branch WHERE branchId = #{branch_id}")
    end
    
    def delete_realtime(branch_id)
      command = "sudo su - apache -c 'php /var/www/voiceaxis/tools/delete_realtime.php FROM_CLI #{branch_id}'"
      Scutil.exec_command(VAUtil.config['web_host'], VAUtil.config['web_ssh_user'], command, '/dev/null', { :keys => [VAUtil.config['web_ssh_key_file']] })
    end
  end
end
