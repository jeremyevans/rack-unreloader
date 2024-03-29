require 'find'
require 'monitor'

module Rack
  # Reloading application that unloads constants before reloading the relevant
  # files, calling the new rack app if it gets reloaded.
  class Unreloader
    # Mutex used to synchronize reloads
    MUTEX = Monitor.new

    # Reference to ::File as File may return Rack::File by default.
    File = ::File

    # Regexp for valid constant names, to prevent code execution.
    VALID_CONSTANT_NAME_REGEXP = /\A(?:::)?([A-Z]\w*(?:::[A-Z]\w*)*)\z/.freeze

    # Given the list of paths, find all matching files, or matching ruby files
    # in subdirecories if given a directory, and return an array of expanded
    # paths.
    def self.expand_directory_paths(paths)
      paths = expand_paths(paths)
      paths.map!{|f| File.directory?(f) ? ruby_files(f) : f}
      paths.flatten!
      paths
    end

    # Given the path glob or array of path globs, find all matching files
    # or directories, and return an array of expanded paths.
    def self.expand_paths(paths)
      paths = Array(paths).flatten
      paths.map!{|path| Dir.glob(path).sort_by!{|filename| filename.count('/')}}
      paths.flatten!
      paths.map!{|path| File.expand_path(path)}
      paths.uniq!
      paths
    end

    # The .rb files in the given directory or any subdirectory.
    def self.ruby_files(dir)
      files = []
      Find.find(dir) do |f|
        files << f if f =~ /\.rb\z/
      end
      files.sort
    end

    # Autoload the file for the given objects.  objs should be a string, symbol,
    # or array of them holding a Ruby constant name.  Access to the constant will
    # load the related file.  A non-nil logger will have output logged to it.
    def self.autoload_constants(objs, file, logger)
      strings = Array(objs).map(&:to_s)
      if strings.empty?
        # Remove file from $LOADED_FEATURES if there are no constants to autoload.
        # In general that is because the file is part of another class that will
        # handle loading the file separately, and if that class is reloaded, we
        # want to remove the loaded feature so the file can get loaded again.
        $LOADED_FEATURES.delete(file)
      else
        logger.info("Setting up autoload for #{file}: #{strings.join(' ')}") if logger
        strings.each do |s|
          obj, mod = split_autoload(s)

          if obj
            obj.autoload(mod, file)
          elsif logger
            logger.info("Invalid constant name: #{s}")
          end
        end
      end
    end

    # Split the given string into an array. The first is a module/class to add the
    # autoload to, and the second is the name of the constant to be autoloaded.
    def self.split_autoload(mod_string)
      if m = VALID_CONSTANT_NAME_REGEXP.match(mod_string)
        ns, sep, mod = m[1].rpartition('::')
        if sep.empty?
          [Object, mod]
        else
          [Object.module_eval("::#{ns}", __FILE__, __LINE__), mod]
        end
      end
    end

    # The Rack::Unreloader::Reloader instead related to this instance, if one.
    attr_reader :reloader

    # Setup the reloader. Options:
    # 
    # :autoload :: Whether to allow autoloading.  If not set to true, calls to
    #              autoload will eagerly require the related files instead of autoloading.
    # :cooldown :: The number of seconds to wait between checks for changed files.
    #              Defaults to 1.  Set to nil/false to not check for changed files.
    # :handle_reload_errors :: Whether reload to handle reload errors by returning
    #                          a 500 plain text response with the backtrace.
    # :reload :: Set to false to not setup a reloader, and just have require work
    #            directly.  Should be set to false in production mode.
    # :logger :: A Logger instance which will log information related to reloading.
    # :subclasses :: A string or array of strings of class names that should be unloaded.
    #                Any classes that are not subclasses of these classes will not be
    #                unloaded.  This also handles modules, but module names given must
    #                match exactly, since modules don't have superclasses.
    def initialize(opts={}, &block)
      @app_block = block
      @autoload = opts[:autoload]
      @logger = opts[:logger]
      if opts.fetch(:reload, true)
        @cooldown = opts.fetch(:cooldown, 1)
        @handle_reload_errors = opts[:handle_reload_errors]
        @last = Time.at(0)
        if @autoload
          require_relative('unreloader/autoload_reloader')
          @reloader = AutoloadReloader.new(opts)
        else
          require_relative('unreloader/reloader')
          @reloader = Reloader.new(opts)
        end
        reload!
      else
        @reloader = @cooldown = @handle_reload_errors = false
      end
    end

    # If the cooldown time has been passed, reload any application files that have changed.
    # Call the app with the environment.
    def call(env)
      if @cooldown && Time.now > @last + @cooldown
        begin
          MUTEX.synchronize{reload!}
        rescue StandardError, ScriptError => e
          raise unless @handle_reload_errors
          content = "#{e.class}: #{e}\n#{e.backtrace.join("\n")}"
          return [500, {'Content-Type' => 'text/plain', 'Content-Length' => content.bytesize.to_s}, [content]]
        end
        @last = Time.now
      end
      @app_block.call.call(env)
    end

    # Whether the unreloader is setup for reloading. If false, no reloading
    # is done after the initial require.
    def reload?
      !!@reloader
    end

    # Whether the unreloader is setup for autoloading. If false, autoloads
    # are treated as requires.
    def autoload?
      !!@autoload
    end

    # Add a file glob or array of file globs to monitor for changes.
    # Options:
    # :delete_hook :: When a file being monitored is deleted, call
    #                 this hook with the path of the deleted file.
    def require(paths, opts={}, &block)
      if @reloader
        @reloader.require_dependencies(paths, opts, &block)
      else
        Unreloader.expand_directory_paths(paths).each{|f| super(f)}
      end
    end

    # Add a file glob or array of file global to autoload and monitor
    # for changes. A block is required.  It will be called with the
    # path to be autoloaded, and should return the symbol for the
    # constant name to autoload. Accepts the same options as #require.
    def autoload(paths, opts={}, &block)
      raise ArgumentError, "block required" unless block

      if @autoload
        if @reloader
          @reloader.autoload_dependencies(paths, opts, &block)
        else
          Unreloader.expand_directory_paths(paths).each{|f| Unreloader.autoload_constants(yield(f), f, @logger)}
        end
      else
        require(paths, opts, &block)
      end
    end

    # Records that each path in +files+ depends on +dependency+.  If there
    # is a modification to +dependency+, all related files will be reloaded
    # after +dependency+ is reloaded.  Both +dependency+ and each entry in +files+
    # can be an array of path globs.
    def record_dependency(dependency, *files)
      if @reloader
        files = Unreloader.expand_paths(files)
        Unreloader.expand_paths(dependency).each do |path|
          @reloader.record_dependency(path, files)
        end
      end
    end

    # Record that a class is split into multiple files. +main_file+ should be
    # the main file for the class, which should require all of the other
    # files.  +files+ should be a list of all other files that make up the class.
    def record_split_class(main_file, *files)
      if @reloader
        files = Unreloader.expand_paths(files)
        files.each do |file|
          record_dependency(file, main_file)
        end
        @reloader.skip_reload(files)
      end
    end

    # Reload the application, checking for changed files and reloading them.
    def reload!
      @reloader.reload! if @reloader
    end
  end
end
