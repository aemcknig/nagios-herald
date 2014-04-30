['ganglia_graph', 'splunk_alert_frequency'].each {|h| NagiosHerald::Util::load_helper(h)}

module NagiosHerald
  class Formatter
    #class CheckDisk < NagiosHerald::Formatter::DefaultFormatter    # pre-refactor
    class CheckDisk < NagiosHerald::Formatter
      include NagiosHerald::Logging

      # Parse the output of the nagios check
      # Simple output - ends with :
      # DISK CRITICAL - free space: / 7002 MB (18% inode=60%): /data 16273093 MB (26% inode=99%):
      # Long output - delimited by |
      # # DISK CRITICAL - free space: / 7051 MB (18% inode=60%); /data 16733467 MB (27% inode=99%);| /=31220MB;36287;2015;0;40319 /dev/shm=81MB;2236;124;0;2485 /data=44240486MB;54876558;3048697;0;60973954
      def get_partitions_data(input)
        partitions = []
        space_data = /.*free space:\s*(?<size>[^|:]*)(\||:)/.match(input)
        if space_data
          space_str = space_data[:size]
          splitter = (space_str.count(';') > 0)? ';' : ':'
          space_str.split(splitter).each do |part|
            partition_regex = Regexp.new('(?<partition>\S+)\s+(?<free_unit>.*)\s+\((?<free_percent>\d+)\%.*')
            data = partition_regex.match(part)
            hash_data = Hash[ data.names.zip( data.captures ) ]
            partitions << hash_data if hash_data
          end
        end
        return partitions
      end

      def get_partitions_stackedbars_chart(partitions_data)
        # Sort results by the most full partition
        partitions_data.sort! { |a,b| a[:free_percent] <=> b[:free_percent] }
        # generate argument as string
        volumes_space_str = partitions_data.map {|x| "#{x[:partition]}=#{100 - x[:free_percent].to_i}"}.compact
        output_file = File.join(@sandbox, "host_status.png")
        command = ""
        command += NagiosHerald::Util::get_script_path('draw_stack_bars')
        command +=  " --width=500 --output=#{output_file} "
        command += volumes_space_str.join(" ")
        %x(#{command})
        if $? == 0
          return output_file
        else
          return nil
        end
      end

      def get_ganglia_graphs(hostname)
        begin
          ganglia = NagiosHerald::Helpers::GangliaGraph.new
          graph =  ganglia.get_graphs( [hostname], 'part_max_used', @sandbox, '1day')
          return graph
        rescue Exception => e
          logger.error "Exception encountered retrieving Ganglia graphs - #{e.message}"
          return []
        end
      end

      def format_additional_info
        output  = get_nagios_var("NAGIOS_#{@state_type}OUTPUT")
        add_text "Additional info:\n #{unescape_text(output)}\n\n" if output

        # Collect partitions data and plot a chart
        # if the check has recovered, $NAGIOS_SERVICEOUTPUT doesn't contain the data we need to parse for images; just give us the A-OK message
        if output =~ /DISK OK/
            add_html %Q(Additional info:<br><b><font color="green"> #{output}</font><br><br>)
        else
          partitions = get_partitions_data(output)
          partitions_chart = get_partitions_stackedbars_chart(partitions)
          if partitions_chart
            add_attachment partitions_chart
            add_html %Q(<img src="#{partitions_chart}" width="500" alt="partitions_remaining_space" /><br><br>)
          else
            add_html "Additional info:<br> #{output}<br><br>" if output
          end
        end

        # Collect ganglia data
        hostname  = get_nagios_var("NAGIOS_HOSTNAME")
        # TODO : address building up hostnames in a robust, future-proof manner
        fqdn    = hostname + ".etsy.com"
        ganglia_graphs = get_ganglia_graphs(fqdn)
        ganglia_graphs.each do |g|
          add_attachment g
          add_html %Q(<img src="#{g}" alt="ganglia_graph" /><br><br>)
        end
      end

      def format_additional_details
        long_output   = get_nagios_var("NAGIOS_LONG#{@state_type}OUTPUT")
        lines = long_output.split('\n') # the "newlines" in this value are literal '\n' strings
        # if we've been passed threshold information use it to color-format the df output
        threshold_line =  lines.grep( /THRESHOLDS - / ) # THRESHOLDS - WARNING:50%;CRITICAL:40%;
        threshold_line.each do |line|
          /WARNING:(?<warning_threshold>\d+)%;CRITICAL:(?<critical_threshold>\d+)%;/ =~ line
          @warning_threshold = warning_threshold
          @critical_threshold = critical_threshold
        end

        # if the thresholds are provided, color me... badd!
        if @warning_threshold and @critical_threshold
          output_lines = []
          output_lines << "<pre>"
          lines.each do |line|
            if line =~ /THRESHOLDS/
              output_lines << line
              next  # just throw this one in unchanged and move along
            end
            /(?<percent>\d+)%/ =~ line
            if defined?( percent ) and !percent.nil?
              percent_free = 100 - percent.to_i
              if percent_free <= @critical_threshold.to_i
                output_line = %Q(<b><font color="red">#{line}</font>  Free disk space <font color="red">(#{percent_free}%)</font> is <= CRITICAL threshold (#{@critical_threshold}%).</b>)
                output_lines << output_line
              elsif percent_free <= @warning_threshold.to_i
                output_line = %Q(<b><font color="orange">#{line}</font>  Free disk space <font color="orange">(#{percent_free}%)</font> is <= WARNING threshold ( #{@warning_threshold}%).</b>)
                output_lines << output_line
              else
                output_lines << line
              end
            else
              output_lines << line
            end
          end

          output_lines << "</pre>"
          output_string = output_lines.join( "<br>" )
          add_html output_string
        else  # just spit out what we got from df
          add_text "Additional Details:\n#{unescape_text(long_output)}\n" if long_output
          add_html "Additional Details:<br><pre>#{unescape_text(long_output)}</pre><br><br>" if long_output
        end
        format_alert_frequency

      end

      def format_alert_frequency
        # find out how frequently we've seen alerts for this service check
        add_html "<h4>Alert Frequency</h4>"
        hostname  = get_nagios_var("NAGIOS_HOSTNAME")
        service_name  = get_nagios_var("NAGIOS_SERVICEDISPLAYNAME") # expecting 'Disk Space'

        splunk_url      = Config.splunk.url
        splunk_username = Config.splunk.username
        splunk_password = Config.splunk.password
        reporter = NagiosHerald::Helpers::SplunkReporter.new( splunk_url, splunk_username, splunk_password )
        splunk_data = reporter.get_alert_frequency(hostname, service_name, {:duration => 7})

        if splunk_data
          msg = "HOST '#{hostname}' has experienced "
          msg += splunk_data[:events_count].map{|k,v|  v.to_s + ' ' + k}.join(', ')
          msg += ' alerts'
          msg += " for SERVICE '#{service_name}'" unless service_name.nil?
          msg += " in the last #{splunk_data[:period]}."

          add_text "#{msg}\n"
          add_html "#{msg}<br>"
        else
          add_text "No matching alerts found.\n"
          add_html "No matching alerts found.<br>"
        end
      end
    end
  end
end
