module ExceptionNotification
  class Rack
    class CascadePassException < Exception; end

    attr_reader :available_options

    def initialize(app, options = {})
      @app = app

      @available_options = [
        :ignore_exceptions,
        :error_grouping,
        :error_grouping_period,
        :error_grouping_cache,
        :notification_trigger,
        :ignore_if,
        :ignore_crawlers,
        :ignore_cascade_pass
      ]

      notifiers = options.dup.delete_if{ |opt_name, _|
        available_options.include?(opt_name.to_sym)
      }

      ExceptionNotifier.ignored_exceptions = options.fetch(:ignore_exceptions) if options.key?(:ignore_exceptions)
      ExceptionNotifier.error_grouping = options.fetch(:error_grouping) if options.key?(:error_grouping)
      ExceptionNotifier.error_grouping_period = options.fetch(:error_grouping_period) if options.key?(:error_grouping_period)
      ExceptionNotifier.notification_trigger = options.fetch(:notification_trigger) if options.key?(:notification_trigger)

      if options.key?(:error_grouping_cache)
        ExceptionNotifier.error_grouping_cache = options.fetch(:error_grouping_cache)
      elsif defined?(Rails)
        ExceptionNotifier.error_grouping_cache = Rails.cache
      end

      if options.key?(:ignore_if)
        rack_ignore = options.fetch(:ignore_if)
        ExceptionNotifier.ignore_if do |exception, opts|
          opts.key?(:env) && rack_ignore.call(opts[:env], exception)
        end
      end

      if options.key?(:ignore_crawlers)
        ignore_crawlers = options.fetch(:ignore_crawlers)
        ExceptionNotifier.ignore_if do |exception, opts|
          opts.key?(:env) && from_crawler(opts[:env], ignore_crawlers)
        end
      end

      @ignore_cascade_pass = options.fetch(:ignore_cascade_pass) { true }

      notifiers.each do |notifier_name, opts|
        ExceptionNotifier.register_exception_notifier(notifier_name, opts)
      end
    end

    def call(env)
      _, headers, _ = response = @app.call(env)

      if !@ignore_cascade_pass && headers['X-Cascade'] == 'pass'
        msg = "This exception means that the preceding Rack middleware set the 'X-Cascade' header to 'pass' -- in " <<
          "Rails, this often means that the route was not found (404 error)."
        raise CascadePassException, msg
      end

      response
    rescue Exception => exception
      if ExceptionNotifier.notify_exception(exception, :env => env)
        env['exception_notifier.delivered'] = true
      end

      raise exception unless exception.is_a?(CascadePassException)
      response
    end

    private

    def from_crawler(env, ignored_crawlers)
      agent = env['HTTP_USER_AGENT']
      Array(ignored_crawlers).any? do |crawler|
        agent =~ Regexp.new(crawler)
      end
    end
  end
end
