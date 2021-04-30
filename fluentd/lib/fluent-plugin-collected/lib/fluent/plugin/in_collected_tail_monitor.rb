require 'fluent/plugin/input'
require 'fluent/plugin/in_monitor_agent'
require 'fluent/plugin/prometheus'

module Fluent::Plugin
  # Collect log_collected_bytes_total metric from in_tail plugin.
  class CollectedTailMonitorInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('collected_tail_monitor', self)
    include Fluent::Plugin::PrometheusLabelParser

    helpers :timer

    config_param :interval, :time, default: 5
    attr_reader :registry

    MONITOR_IVARS = [
      :tails,
    ]

    def initialize
      super
      @registry = ::Prometheus::Client.registry
    end

    def multi_workers_ready?
      true
    end

    def configure(conf)
      super
      hostname = Socket.gethostname
      expander_builder = Fluent::Plugin::Prometheus.placeholder_expander(log)
      expander = expander_builder.build({ 'hostname' => hostname, 'worker_id' => fluentd_worker_id })
      @base_labels = parse_labels_elements(conf)
      @base_labels.each do |key, value|
        unless value.is_a?(String)
          raise Fluent::ConfigError, "record accessor syntax is not available in collected_tail_monitor"
        end
        @base_labels[key] = expander.expand(value)
      end

      if defined?(Fluent::Plugin) && defined?(Fluent::Plugin::MonitorAgentInput)
        # from v0.14.6
        @monitor_agent = Fluent::Plugin::MonitorAgentInput.new
      else

        @attr = monitor_agent = Fluent::MonitorAgentInput.new
      end
    end

    def start
      super

      @metrics = {
        position: @registry.counter(
          :log_collected_bytes_total,
          'Total bytes collected from file.'
        )
      }
      timer_execute(:in_collected_tail_monitor, @interval, &method(:update_monitor_info))
      agent_info.each do |info|
        # FIXME: log a warning if 'rotate_wait' from info is < @interval in our config.
        # Something like:
        #   May miss some data at end of file: rotate_wait less than monitoring interval.
      end
    end

    def agent_info
      # Collect info for all input plugins of type 'tail'.
      @monitor_agent.plugins_info_all(opts).select {|info| info['type'] == 'tail'.freeze }
    end

    def update_monitor_info
      opts = {
        ivars: MONITOR_IVARS,
      }
      agent_info.each do |info|
        tails = info['instance_variables'][:tails]
        next if tails.nil?

        tails.clone.each do |_, watcher|
          # Access to internal variable of internal class...
          # Very fragile implementation, borrowed from the standard prometheus_tail_monitor
          pe = watcher.instance_variable_get(:@pe)
          label = labels(info, watcher.path)

          # Compare pos/inode with the last time we saw this tail
          old_pos = pe.instance_variable_get(:@_old_pos) || 0.0
          pe.instance_variable_set(:@_old_pos, pe.read_pos)
          old_inode = pe.instance_variable_get(:@_old_inode)
          pe.instance_variable_set(:@_old_inode, pe.inode)
          if pe.inode == old_inode && pe.read_pos >= old_pos
            # Same file, has not been truncated since last we looked. Add the delta.
            @metrics[:total_bytes].increment(label, pe.read_pos - old_pos)
          else
            # Changed file or truncated the existing file. Add the initial content.
            @metrics[:total_bytes].increment(label, pe.read_pos)
          end
        end
      end
    end

    def labels(plugin_info, path)
      @base_labels.merge(
        plugin_id: plugin_info['plugin_id'],
        type: plugin_info['type'],
        path: path
      )
    end
  end
end
