
require 'mysql2'
require 'net/smtp'
require 'scutil'
require 'json'
require 'stringio'

require 'vautil/fraud'
require 'vautil/odbc'
require 'vautil/server'

class VAUtil
  include Fraud
  include ODBC
  
  attr_accessor :db_link
  
  class << self
    attr_accessor :config
  end
  
  DEFAULT_CONFIG = '/etc/vautil/config'
  
  def initialize(config_file=nil)
    @db_link = nil
    @fs_pbxdb_cache = {}
    @fs_cdrdb_cache = {}
    config_file = DEFAULT_CONFIG if (config_file.nil?)
    parse_config(config_file)
  end
  
  def parse_config(filename)
    confstr = ""
    File.open(filename) do |file|
      file.each_line do |l|
        next if l =~ /^\s*;|#/
        confstr += l
      end
    end
    
    begin
      VAUtil.config = JSON.parse(confstr)
    rescue JSON::ParserError => err
      puts "Bad config file: " + err.message.split("\n")[0]
      exit(1)
    end
  end
  
  def check_config(config_file=nil)
    config_file = DEFAULT_CONFIG if (config_file.nil?)
    parse_config(config_file)
    puts "Config OK"
    exit(0)
  end
  
  # Runs Codegen on _branch_id_ and returns command ret_val.
  def run_codegen(branch_id)
    command = "sudo su - apache -c 'php /var/www/voiceaxis/debug/run_codegen.php FROM_CLI -b #{branch_id}' 1> /dev/null"
    Scutil.exec_command(VAUtil.config['web_host'], VAUtil.config['web_ssh_user'], command, nil, { :keys => [VAUtil.config['web_ssh_key_file']] })
  end
  
  def check_db_has_pbx_entry(branch_id, context, server)
    command = "echo 'select * from pbx where pbxId = #{branch_id}' | isql dialplan-connector | grep -q #{context}"
    retval = Scutil.exec_command(server, VAUtil.config['fs_ssh_user'], command)
    retval.zero?
  end
  
  def is_asterisk14_feature_server(fqdn)
    is_feature_server(fqdn, :asterisk14)
  end
  
  def is_asterisk18_feature_server(fqdn)
    is_feature_server(fqdn, :asterisk18)
  end
  
  def is_feature_server(fqdn, platform=:all)
    list = []
    case (platform)
    when :asterisk14
      list = get_asterisk14_feature_servers()
    when :asterisk18
      list = get_asterisk18_feature_servers()
    when :all
      list = get_all_feature_servers()
    else
      puts "Invalid feature server platform."
      return false
    end
    list.each do |fs|
      return true if ((fs.fqdn == fqdn) && (fs.type == Server::TYPE_FEATURE))
    end
    return false
  end
  
  def get_asterisk14_feature_servers()
    get_feature_servers_by_platform(:asterisk14)
  end
  
  def get_asterisk18_feature_servers()
    get_feature_servers_by_platform(:asterisk18)
  end
  
  def get_all_feature_servers()
    list = get_asterisk14_feature_servers()
    list << get_asterisk18_feature_servers()
    list.flatten!
  end
  
  def get_feature_servers_by_platform(platform)
    case platform
    when :asterisk14
      platform_string = 'Asterisk 1.4'
    when :asterisk18
      platform_string = 'Asterisk 1.8'
    else
      print "Unknown platform\n"
      return nil
    end
    
    results = list_query("SELECT serverId, hostname, ipAddress, serverTypeId FROM server s LEFT JOIN platform p ON (s.platformId = p.platformId) WHERE s.serverTypeId = #{Server::TYPE_FEATURE} AND p.name LIKE '#{platform_string}%'")
    fs_list = []
    
    results.each do |row|
      fs_list << Server.new(row[0], row[1], row[2], row[3], platform)
    end
    return fs_list
  end
  
  def get_dblink(db_info=nil)
    if (!db_info.nil?)
      db = Mysql2::Client.new(:host     => db_info.hostname,
                              :database => db_info.dbname,
                              :username => db_info.username,
                              :password => db_info.password)
      return db
    else
      return @db_link unless @db_link.nil?
      @db_link = Mysql2::Client.new(:host     => VAUtil.config['db_host'],
                                    :database => VAUtil.config['db_name'],
                                    :username => VAUtil.config['db_user'],
                                    :password => VAUtil.config['db_pass'])
      return @db_link
    end
  end
  
  def prune_peers(server_hostname, context_name)
    command = "sudo /usr/sbin/asterisk -rx 'sip prune realtime like #{context_name}'"
    Scutil.exec_command(server_hostname, VAUtil.config['fs_ssh_user'], command)
  end 
  
  def dialplan_reload(server_hostname)
    command = "sudo touch /var/voiceaxis/#{server_hostname}.extreload.lock"
    Scutil.exec_command(VAUtil.config['web_host'], VAUtil.config['web_ssh_user'], 
      command, nil, { :keys => [VAUtil.config['web_ssh_key_file']] })
  end

  def features_reload(server_hostname)
    command = "sudo touch /var/voiceaxis/#{server_hostname}.featuresreload.lock"
    Scutil.exec_command(VAUtil.config['web_host'], VAUtil.config['web_ssh_user'], 
      command, nil, { :keys => [VAUtil.config['web_ssh_key_file']] })
  end

  def meetme_reload(server_hostname)
    command = "sudo touch /var/voiceaxis/#{server_hostname}.confreload.lock"
    Scutil.exec_command(VAUtil.config['web_host'], VAUtil.config['web_ssh_user'], 
      command, nil, { :keys => [VAUtil.config['web_ssh_key_file']] })
  end
  
  def moh_reload(server_hostname)
    command = "sudo touch /var/voiceaxis/#{server_hostname}.mohreload.lock"
    Scutil.exec_command(VAUtil.config['web_host'], VAUtil.config['web_ssh_user'], 
      command, nil, { :keys => [VAUtil.config['web_ssh_key_file']] })
  end
  
  def moh_sync(server_hostname, server_id)
    command = "sudo /var/voiceaxis/bin/moh-config-sync.sh #{server_id} #{server_hostname}"
    Scutil.exec_command(VAUtil.config['web_host'], VAUtil.config['web_ssh_user'],
      command, nil, { :keys => [VAUtil.config['web_ssh_key_file']] })
  end
  
  def get_server_with_branch_id(branch_id)
    run_select_query("SELECT s.hostname FROM server AS s LEFT JOIN branch AS b ON (b.featureServerId = s.serverId) WHERE b.branchId = #{branch_id}")
  end
  
  def get_reseller_name_with_branch_id(branch_id)
    run_select_query("SELECT r.companyName FROM branch b JOIN reseller r ON (b.resellerId = r.resellerId) WHERE branchId = #{branch_id}")
  end
  
  def get_customer_name_with_branch_id(branch_id)
    run_select_query("SELECT c.companyName FROM branch b JOIN customer c ON (b.customerId = c.customerId) WHERE branchId = #{branch_id}")
  end  
  
  def get_branch_id_with_context(context_name)
    run_select_query("SELECT branchId FROM branch WHERE description = '#{context_name}'")
  end
  
  def get_customer_id_with_branch_id(branch_id)
    run_select_query("SELECT customerId FROM branch WHERE branchId = #{branch_id}")
  end
  
  def get_context_with_branch_id(branch_id)
    return nil if branch_id.class == String
    run_select_query("SELECT description FROM branch WHERE branchId = #{branch_id}")
  end
  
  def get_branch_id_with_tn(number)
    branch_id = run_select_query("SELECT b.branchId FROM branch b LEFT JOIN inventory i ON (b.customerId = i.assignedTo) WHERE i.identifier = '#{number}'")
  end
  
  def get_branch_id_with_call_example(fs, src, dst)
    db_info = get_fs_cdrdb_info(fs)

    # return nil if we can't get one
    if db_info.nil?
      return nil
    end
    
    db_link = get_dblink db_info
    dst.sub! /^1/, ''
    
    context = run_select_query("SELECT accountcode FROM cdr WHERE calldate > DATE_SUB(NOW(), INTERVAL '1:05' HOUR_MINUTE) AND src = '#{src}' AND dst REGEXP '^1?#{dst}'", db_link)
    
    # If we still can't find it check if it was a forwarded call.
    if context.nil? || (context =~ /^agw\d+$/)
      # If src is non-numeric, i.e, NOCALLERID, don't search on it.
      if src !~ /^\d+$/
        return run_select_query("SELECT cd_branchId FROM cdr WHERE calldate > DATE_SUB(NOW(), INTERVAL '1:05' HOUR_MINUTE) AND lastdata LIKE '%#{dst}%'", db_link)
      else
        return run_select_query("SELECT cd_branchId FROM cdr WHERE calldate > DATE_SUB(NOW(), INTERVAL '1:05' HOUR_MINUTE) AND src = '#{src}' AND lastdata LIKE '%#{dst}%'", db_link)
      end
    end
    get_branch_id_with_context context
  end
  
  def get_fs_pbxdb_info(fs)
    if (!@fs_pbxdb_cache.key?(fs))
      info = list_query("SELECT dialplanDbHost, dialplanDbUser, dialplanDbPass, dialplanDbName, dialplanDbPort FROM server WHERE hostname = '#{fs}'")
      info.flatten!
      @fs_pbxdb_cache[fs] = DBInfo.new(*info)
    end
    @fs_pbxdb_cache[fs]
  end
  
  def get_fs_cdrdb_info(fs)
    if (!@fs_cdrdb_cache.key?(fs))
      info = list_query("SELECT cdrDbHost, cdrDbUser, cdrDbPass, cdrDbName, cdrDbPort FROM server WHERE hostname = '#{fs}'")
      info.flatten!
      # guard against bad data in the agw cdr
      if info.empty? or info[0].empty?
        return nil
      end
      @fs_cdrdb_cache[fs] = DBInfo.new(*info)
    end
    @fs_cdrdb_cache[fs]
  end
  
  def list_query(query, db_link=nil)
    db_link = get_dblink if db_link.nil?
    begin
      value = []
      rows = db_link.query(query)
      rows.each(:as => :array) do |row|
        value << row
      end
      return value
    rescue Mysql2::Error => e
      print "DB error: #{e.message}\n"
    end      
  end
  
  def run_select_query(query, db_link=nil)
    db_link = get_dblink if db_link.nil?
    begin
      value = nil
      rows = db_link.query(query)
      rows.each(:as => :array) do |row|
        value = row[0]
        # only take the first result...
        break
      end
      return value
    rescue Mysql2::Error => e
      print "DB error: #{e.message}\n"
    end
  end
  
  def run_update_query(query, db_link=nil)
    db_link = get_dblink if db_link.nil?
    begin
      db_link.query(query)
    rescue Mysql2::Error => e
      print "DB error: #{e.message}\n"
    end
  end
end

class DBInfo
  attr_reader :hostname,:username,:password,:dbname,:port
  def initialize(hostname, username, password, dbname, port='3306')
    @hostname = hostname
    @username = username
    @password = password
    @dbname   = dbname
    @port     = port
  end
end
