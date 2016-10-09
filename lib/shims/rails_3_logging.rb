require "active_support/core_ext/class/attribute_accessors"
require "active_support/core_ext/module/delegation"
require "active_support/core_ext/object/blank"
require "logger"
require "concurrent"

ActiveSupport.send(:remove_const, :TaggedLogging)

module LoggerSilence
  extend ActiveSupport::Concern

  included do
    cattr_accessor :silencer
    self.silencer = true
  end

  # Silences the logger for the duration of the block.
  def silence(temporary_level = Logger::ERROR)
    if silencer
      begin
        old_local_level            = local_level
        self.local_level           = temporary_level

        yield self
      ensure
        self.local_level = old_local_level
      end
    else
      yield self
    end
  end
end

module ActiveSupport
  module LoggerThreadSafeLevel # :nodoc:
    extend ActiveSupport::Concern

    def after_initialize
      @local_levels = ::Concurrent::Map.new(initial_capacity: 2)
    end

    def local_log_id
      Thread.current.__id__
    end

    def local_level
      @local_levels[local_log_id]
    end

    def local_level=(level)
      if level
        @local_levels[local_log_id] = level
      else
        @local_levels.delete(local_log_id)
      end
    end

    def level
      local_level || super
    end
  end
end

module ActiveSupport
  class Logger < ::Logger
    include ActiveSupport::LoggerThreadSafeLevel
    include LoggerSilence

    # Returns true if the logger destination matches one of the sources
    #
    #   logger = Logger.new(STDOUT)
    #   ActiveSupport::Logger.logger_outputs_to?(logger, STDOUT)
    #   # => true
    def self.logger_outputs_to?(logger, *sources)
      logdev = logger.instance_variable_get("@logdev")
      logger_source = logdev.dev if logdev.respond_to?(:dev)
      sources.any? { |source| source == logger_source }
    end

    # Broadcasts logs to multiple loggers.
    def self.broadcast(logger) # :nodoc:
      Module.new do
        define_method(:add) do |*args, &block|
          logger.add(*args, &block)
          super(*args, &block)
        end

        define_method(:<<) do |x|
          logger << x
          super(x)
        end

        define_method(:close) do
          logger.close
          super()
        end

        define_method(:progname=) do |name|
          logger.progname = name
          super(name)
        end

        define_method(:formatter=) do |formatter|
          logger.formatter = formatter
          super(formatter)
        end

        define_method(:level=) do |level|
          logger.level = level
          super(level)
        end

        define_method(:local_level=) do |level|
          logger.local_level = level if logger.respond_to?(:local_level=)
          super(level) if respond_to?(:local_level=)
        end

        define_method(:silence) do |level = Logger::ERROR, &block|
          if logger.respond_to?(:silence)
            logger.silence(level) do
              if respond_to?(:silence)
                super(level, &block)
              else
                block.call(self)
              end
            end
          else
            if respond_to?(:silence)
              super(level, &block)
            else
              block.call(self)
            end
          end
        end
      end
    end

    def initialize(*args)
      super
      @formatter = SimpleFormatter.new
      after_initialize if respond_to? :after_initialize
    end

    def add(severity, message = nil, progname = nil, &block)
      return true if @logdev.nil? || (severity || UNKNOWN) < level
      super
    end

    Logger::Severity.constants.each do |severity|
      class_eval(<<-EOT, __FILE__, __LINE__ + 1)
        def #{severity.downcase}?                # def debug?
          Logger::#{severity} >= level           #   DEBUG >= level
        end                                      # end
      EOT
    end

    # Simple formatter which only displays the message.
    class SimpleFormatter < ::Logger::Formatter
      # This method is invoked when a log event occurs
      def call(severity, timestamp, progname, msg)
        "#{String === msg ? msg : msg.inspect}\n"
      end
    end
  end
end

module ActiveSupport
  # Wraps any standard Logger object to provide tagging capabilities.
  #
  #   logger = ActiveSupport::TaggedLogging.new(Logger.new(STDOUT))
  #   logger.tagged('BCX') { logger.info 'Stuff' }                            # Logs "[BCX] Stuff"
  #   logger.tagged('BCX', "Jason") { logger.info 'Stuff' }                   # Logs "[BCX] [Jason] Stuff"
  #   logger.tagged('BCX') { logger.tagged('Jason') { logger.info 'Stuff' } } # Logs "[BCX] [Jason] Stuff"
  #
  # This is used by the default Rails.logger as configured by Railties to make
  # it easy to stamp log lines with subdomains, request ids, and anything else
  # to aid debugging of multi-user production applications.
  module TaggedLogging
    module Formatter # :nodoc:
      # This method is invoked when a log event occurs.
      def call(severity, timestamp, progname, msg)
        super(severity, timestamp, progname, "#{tags_text}#{msg}")
      end

      def tagged(*tags)
        new_tags = push_tags(*tags)
        yield self
      ensure
        pop_tags(new_tags.size)
      end

      def push_tags(*tags)
        tags.flatten.reject(&:blank?).tap do |new_tags|
          current_tags.concat new_tags
        end
      end

      def pop_tags(size = 1)
        current_tags.pop size
      end

      def clear_tags!
        current_tags.clear
      end

      def current_tags
        # We use our object ID here to avoid conflicting with other instances
        thread_key = @thread_key ||= "activesupport_tagged_logging_tags:#{object_id}".freeze
        Thread.current[thread_key] ||= []
      end

      private
      def tags_text
        tags = current_tags
        if tags.any?
          tags.collect { |tag| "[#{tag}] " }.join
        end
      end
    end

    def self.new(logger)
      # Ensure we set a default formatter so we aren't extending nil!
      logger.formatter ||= ActiveSupport::Logger::SimpleFormatter.new
      logger.formatter.extend Formatter
      logger.extend(self)
    end

    delegate :push_tags, :pop_tags, :clear_tags!, to: :formatter

    def tagged(*tags)
      formatter.tagged(*tags) { yield self }
    end

    def flush
      clear_tags!
      super if defined?(super)
    end
  end
end

ActiveSupport.send(:remove_const, :BufferedLogger)
ActiveSupport::BufferedLogger = ActiveSupport::Logger
