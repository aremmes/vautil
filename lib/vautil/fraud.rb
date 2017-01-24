
class VAUtil
  module Fraud
    def shutdown_international(branch_id)
      if (!branch_id.nil? && (branch_id > 0))
        run_update_query("UPDATE branch SET international = '', allowInternational = 0 WHERE branchId = #{branch_id}")
        true
      else
        false
      end
    end
    
    def block_international_with_branch_id(branch_id)
      return if branch_id.nil?
      run_codegen branch_id if shutdown_international branch_id
    end
    
    def block_international_with_tn(number)
      branch_id = get_branch_id_with_tn number
      context = get_context_with_branch_id branch_id
      reseller_name = get_reseller_name_with_branch_id branch_id
      customer_name = get_customer_name_with_branch_id branch_id
      body = <<HERE
International calling has been disabled for customer #{context} due to excessive calls from #{number}.

Details:
  Customer Name: #{customer_name}
  Context: #{context}
  Branch: #{branch_id}
  Reseller Nmae: #{reseller_name}

HERE
      notify body, "Potential fraud on context: #{context}", 'support@coredial.com', 'noc-notify@coredial.com'
      block_international_with_branch_id(branch_id)
    end
    
    def detect_fraud
      current_frauds = detect_fraud_for_interval(:current)
      past_frauds = detect_fraud_for_interval(:past)
      
      current_frauds[:block].each do |cur|
        next unless still_matters?(cur, past_frauds, :block)
        block_international_with_branch_id(cur.branch_id)
        notify_support(cur, :block)
      end
      
      current_frauds[:warn].each do |cur|
        next unless still_matters?(cur, past_frauds, :warn)
        notify_support(cur, :warn)
      end
    end

    def detect_domestic_fraud
      current_frauds = detect_domestic_fraud_for_interval(:current)
      past_frauds = detect_domestic_fraud_for_interval(:past)

      current_frauds[:warn].each do |cur|
        next unless still_matters?(cur, past_frauds, :warn)
        notify_support_domestic(cur, :warn, VAUtil.config['dom_npa_list'])
      end
    end

    
    def still_matters?(current_record, past_frauds, type)
      # If there is no past activity return true.
      return true if past_frauds[type].empty?
      
      # This block handles the edge case where there is a different fraud event in 
      # the past_frauds hash, i.e., current_record.branch_id != any p.branch_id.
      # If there's no entry in past_frauds just return true to act.
      match = false
      past_frauds[type].each do |p|
        match = true if (current_record.branch_id == p.branch_id)
      end
      return true if !match
      
      # We have past activity for this record.  Act accordingly.
      # TODO: Ineffecient, call #each and return true on first match.
      frauds = past_frauds[type].select do |p|
        (current_record.branch_id == p.branch_id) && (current_record.total > p.total)
      end
      frauds.empty? ? false : true
    end

    def detect_fraud_for_interval(interval)
      call_records = get_call_records :standard, interval, :international
      call_records += get_call_records :fax, interval, :international
      
      frauds = call_records.check_thresholds
      return(frauds)
    end
    
    def detect_domestic_fraud_for_interval(interval)
      call_records = get_call_records :standard, interval, :domestic
      call_records += get_call_records :fax, interval, :domestic
      
      if VAUtil.config['debug']
        call_records.each do |ccr|
          puts ccr
          puts "==="
        end
      end
      
      frauds = call_records.check_thresholds
      return(frauds)
    end

    # Sends email notification to list of *to_addrs from VAUtils.  Subject is set to default if nil.
    def notify(bodystr, subject=nil, *to_addrs)
      from = '"VAUtil" <vautil@' + `/bin/hostname`.chomp + '>'
      to = to_addrs.map { |a| '<' + a + '>' }.join(', ')
      message = <<HERE
From: #{from}
To: #{to}
Subject: #{subject.nil? ? "VAUtil Notification" : subject }
Date: #{Time.now}
Message-Id: <#{(0...20).map{ (('0'..'9').to_a + ('a'..'z').to_a).to_a[rand(36)] }.join}@coredial.com>

#{bodystr}
HERE
      Net::SMTP.start(VAUtil.config['mail_host'], 25, 'coredial.com') do |smtp|
        smtp.send_message(message, from, to_addrs)
      end
    end
    
    def notify_support(ccr, type)
      case type
      when :block
        body = <<HERE
International calling has been disabled for customer:
#{ccr}
HERE
        subject = "Potential fraud on context: #{ccr.context}"
      when :warn
        body = <<HERE
International calling exceeds warning threshold for customer:
#{ccr}
HERE
        subject = "International warning threshold exceeded for context: #{ccr.context}"
      end
      notify body, subject, 'support@coredial.com', 'noc-notify@coredial.com'
    end

    def notify_support_domestic(ccr, type, npa_list)
      npas = npa_list.join ', '
      case type
      when :block, :warn
        body = <<HERE
Calls to any of the following domestic NPAs are considered poisonous: #{npas}
Domestic calling to poison NPAs (over the course of 3 hours) exceeds warning threshold for customer:
#{ccr}
HERE
        subject = "Potential Domestic Fraud for context: #{ccr.context}"
      end
      notify body, subject, 'support@coredial.com', 'noc-notify@coredial.com'
    end

    
    # Gets call records for a specific time interval and for a specific type of CDR.
    def get_call_records(type=:standard, interval=:current, subset=:international)
      if subset == :international
        # Prefix the NPAs with "1" optionally (we're using regexp on the terms).
        search_list = VAUtil.config['intl_npa_list'].map { |m| "1?" << m }
        # for internationl do a search for anything prefixed 011
        search_list << "011"
        thresholds = VAUtil.config['threshold']
        if (interval == :past)
          data_range = "1:05" # hours and minutes
          end_interval = "5"
        else
          data_range = 1 # In hours
        end
      else
        search_list = VAUtil.config['dom_npa_list'].map { |m| "1?" << m }
        thresholds = VAUtil.config['dom_threshold']
        if (interval == :past)
          data_range = "3:15" # hours and minutes
          end_interval = "15"
        else
          data_range = 3 # In hours
        end
      end

      call_records = CallRecords.new(self, interval, thresholds)

      # Past or present?
      if (interval == :past)
        time_span = "calldate > DATE_SUB(NOW(), INTERVAL '#{data_range}' HOUR_MINUTE) AND calldate <= DATE_SUB(NOW(), INTERVAL #{end_interval} MINUTE)"
      else
        time_span = "calldate > DATE_SUB(NOW(), INTERVAL '#{data_range}' HOUR)"
      end
      
      # TODO: de-dup
      if (type == :fax)
        VAUtil.config['fax_dsn_list'].each do |fax|
          db_link = get_dblink(DBInfo.new(fax['host'], fax['user'], fax['pass'], fax['name']))

          search_list.each do |term|
            query = "SELECT src, COUNT(src) FROM cdr WHERE dcontext LIKE '%faxout%' AND lastdata REGEXP '^SIP/9#{term}' AND #{time_span} GROUP BY src"
            results = list_query(query, db_link)
            results.each do |r|
              src = r[0]
              count = r[1]

              # Get the branch of for this src.  If that fails requery the gateway and find it with
              # call details.
              branch_id = get_branch_id_with_tn(src)
              if branch_id.nil?
                dst = run_select_query("SELECT dst FROM cdr WHERE dcontext LIKE '%faxout%' AND lastdata REGEXP '^SIP/9#{term}' AND #{time_span} AND src = '#{src}'", db_link)
                branch_id = get_branch_id_with_call_example(fax['host'], src, dst)
              end
              # it's possible call example path will fail too, skip if necessary
              if !branch_id.nil?
                call_records.add(src, count, branch_id)
              end
            end
          end
          db_link.close
        end
      else
        VAUtil.config['agw_dsn_list'].each do |agw|
          db_link = get_dblink(DBInfo.new(agw['host'], agw['user'], agw['pass'], agw['name']))

          search_list.each do |term|
            query = "SELECT src, COUNT(src), accountcode FROM cdr WHERE dst REGEXP '^#{term}' AND #{time_span} AND dcontext REGEXP '^sbc' GROUP BY src"
            results = list_query(query, db_link)
            results.each do |r|
              src = r[0]
              count = r[1]
              fs = r[2]
              
              # Get the branch of for this src.  If that fails requery the gateway and find it with
              # call details.
              branch_id = get_branch_id_with_tn(src)
              if branch_id.nil?
                dst = run_select_query("SELECT dst FROM cdr WHERE dst REGEXP '^#{term}' AND #{time_span} AND src = '#{src}' AND accountcode = '#{fs}'", db_link)
                
                branch_id = get_branch_id_with_call_example("#{fs}.coredial.com", src, dst)
              end 
              # it's possible call example path will fail too, skip if necessary
              if !branch_id.nil?
                call_records.add(src, count, branch_id)
              end
            end
          end
          db_link.close
        end
      end
      call_records
    end

    # Container class
    class CallRecords
      include Enumerable
      attr_reader :interval,:records

      def initialize(vautil, interval, thresholds)
        @records = []
        @vautil = vautil
        @interval = interval
        @thresholds = thresholds
      end
      
      def each
        @records.each do |c|
          yield c
        end
      end
      
      def find(branch_id)
        @records.each do |record|
          return record if record.branch_id == branch_id
        end
        nil
      end
      
      def add(number, count, branch_id)
        if (ccr = find branch_id)
          ccr.add(number, count)
        else
          if @thresholds.key? branch_id.to_s
            warn, block = @thresholds[branch_id.to_s].values_at('warn', 'block')
          else
            warn, block = @thresholds['_default_'].values_at('warn', 'block')
          end
          block ||= Float::INFINITY # If not set, never allow block to be exceeded

          ccr = CustomerCallRecord.new(branch_id, @vautil, warn, block)
          ccr.add(number, count)
          @records << ccr
        end
      end
      
      def check_thresholds
        frauds = {
          :warn  => @records.select { |x| x.exceeds_warn_threshold? },
          :block => @records.select { |x| x.exceeds_block_threshold? }
        }
      end
      
      def +(other)
        if (other.kind_of?(self.class) && (@interval == other.interval))
          @records += other.records
          return self
        else
          raise ArgumentError
        end
      end
    end
    
    class CustomerCallRecord
      attr_reader :context,:total,:branch_id,:customer_name,:reseller_name,:warn_value,:block_value
      def initialize(branch_id, vautil, warn, block)
        @branch_id = branch_id
        @context = @branch_id.nil? ? nil : vautil.get_context_with_branch_id(branch_id)
        @customer_name = @branch_id.nil? ? nil : vautil.get_customer_name_with_branch_id(branch_id)
        @reseller_name = @branch_id.nil? ? nil : vautil.get_reseller_name_with_branch_id(branch_id)

        @warn_value = warn
        @block_value = block

        @total = 0
        @records = {}
      end
      
      def add(number, count)
        if @records.key? number
          @records[number] += count
        else
          @records[number] = count
        end
        @total += count
      end
      
      def exceeds_warn_threshold?
        (@total >= @warn_value) && (@total < @block_value)
      end
      
      def exceeds_block_threshold?
        @total >= @block_value
      end
      
      def to_s
        @context.nil? ? msg = "UNKNOWN: (UNKNOWN): #{@total}\n" : msg = "#{@context} (#{@branch_id}): #{@total}\n"
        @records.each {|number, count| msg += "- #{number}: #{count}\n" }
        msg += <<HERE

Details:
  Customer Name: #{@customer_name}
  Context: #{@context}
  Branch: #{@branch_id}
  Reseller Name: #{@reseller_name}

  Warn Threshold: #{@warn_value}
  Block Threshold: #{@block_value}
HERE
        msg
      end
    end
  end
end
