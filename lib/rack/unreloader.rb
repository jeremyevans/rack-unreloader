require 'set'

module Rack
  # Reloading application that unloads constants before reloading the relevant
  # files, calling the new rack app if it gets reloaded.
  class Unreloader
    class Reloader
      # Reference to ::File as File would return Rack::File by default.
      F = ::File

      # Regexp for valid constant names, to prevent code execution.
      VALID_CONSTANT_NAME_REGEXP = /\A(?:::)?([A-Z]\w*(?:::[A-Z]\w*)*)\z/.freeze

      # Setup the reloader.  Supports :logger and :subclasses options, see
      # Rack::Unloader.new for details.
      def initialize(opts={})
        @logger = opts[:logger]
        @classes = opts[:subclasses] ?  Array(opts[:subclasses]).map{|s| s.to_s} : %w'Object'

        # Hash of files being monitored for changes, keyed by absolute path of file name,
        # with values being the last modified time (or nil if the file has not yet been loaded).
        @monitor_files = {}

        # Hash keyed by absolute path of file name, storing constants and other
        # filenames that the key loads.  Values should be hashes with :constants
        # and :features keys, and arrays of values.
        @files = {}

        # Similar to @files, but stores previous entries, used when rolling back.
        @old_entries = {}
      end

      # Tries to find a declared constant with the name specified
      # in the string. It raises a NameError when the name is not in CamelCase
      # or is not initialized.
      def constantize(s)
        s = s.to_s
        if m = VALID_CONSTANT_NAME_REGEXP.match(s)
          Object.module_eval("::#{m[1]}", __FILE__, __LINE__)
        else
          log("#{s.inspect} is not a valid constant name!")
        end
      end

      # Log the given string at info level if there is a logger.
      def log(s)
        @logger.info(s) if @logger
      end
  
      # If there are any changed files, reload them.  If there are no changed
      # files, do nothing.
      def reload!
        @monitor_files.to_a.each do |file, time|
          if file_changed?(file, time)
            safe_load(file)
          end
        end
      end

      # Require the given dependencies, monitoring them for changes.
      # Paths should be a file glob or an array of file globs.
      def require_dependencies(paths)
        options = {:cyclic => true}
        error = nil 

        Array(paths).
          flatten.
          map{|path| Dir.glob(path).sort_by{|filename| filename.count('/')}}.
          flatten.
          map{|path| F.expand_path(path)}.
          uniq.
          each do |file|

          @monitor_files[file] = nil
          begin
            safe_load(file, options)
          rescue NameError, LoadError => error
            log "Cyclic dependency reload for #{error}"
          rescue Exception => error
            break
          end
        end

        if error
          log error
          raise error
        end
      end

      # Requires the given file, logging which constants or features are added
      # by the require, and rolling back the constants and features if there
      # are any errors.
      def safe_load(file, options={})
        return unless @monitor_files.has_key?(file)
        return unless options[:force] || file_changed?(file)

        log "#{@monitor_files[file] ? 'Reloading' : 'Loading'} #{file}"
        prepare(file) # might call #safe_load recursively
        begin
          require(file)
          commit(file)
        rescue Exception
          if !options[:cyclic]
            log "Failed to load #{file}; removing partially defined constants"
          end
          rollback(file)
          raise
        end
      end

      # Removes the specified constant.
      def remove_constant(const)
        base, _, object = const.to_s.rpartition('::')
        base = base.empty? ? Object : constantize(base)
        base.send :remove_const, object
        log "Removed constant #{const}"
      rescue NameError
      end

      # Remove a feature if it is being monitored for reloading, so it
      # can be required again.
      def remove_feature(file)
        if @monitor_files.has_key?(file)
          $LOADED_FEATURES.delete(file)
          log "Removed feature #{file}"
        end
      end

      # Unload all reloadable constants and features, and clear the list
      # of files to monitor.
      def clear!
        @files.keys.each do |file|
          remove(file)
        end
        @monitor_files = {}
        @old_entries = {}
      end

      # Remove the given file, removing any constants and other files loaded
      # by the file.
      def remove(name)
        file = @files[name] || return
        file[:constants].each{|constant| remove_constant(constant)}
        file[:features].each{|feature| remove_feature(feature)}
        @files.delete(name)
        remove_feature(name) if $LOADED_FEATURES.include?(name)
      end

      # Store the currently loaded classes and features, so in case of an error
      # this state can be rolled back to.
      def prepare(name)
        file = remove(name)
        @old_entries[name] = {:constants => all_classes, :features => monitored_features}
      end

      # Commit the changed state after requiring the the file, recording the new
      # classes and features added by the file.
      def commit(name)
        entry = {
          :constants => new_classes(@old_entries[name][:constants]),
          :features  => monitored_features - @old_entries[name][:features] - [name]
        }
        @files[name] = entry
        @old_entries.delete(name)
        @monitor_files[name] = modified_at(name)
        log("New classes in #{name}: #{entry[:constants].to_a.join(' ')}") unless entry[:constants].empty?
        log("New features in #{name}: #{entry[:features].to_a.join(' ')}") unless entry[:features].empty?
      end

      # Rollback the changes made by requiring the file, restoring the previous state.
      def rollback(name)
        new_classes(@old_entries[name][:constants]).each{|klass| remove_constant(klass)}
        @old_entries.delete(name)
      end

      private

      # The current loaded features that are being monitored
      def monitored_features
        Set.new($LOADED_FEATURES) & @monitor_files.keys
      end

      # Return a set of all classes in the ObjectSpace.
      def all_classes
        rs = Set.new

        ObjectSpace.each_object(Module).each do |klass|
          if monitored_class?(klass)
            rs << klass
          end
        end

        rs
      end

      # Return whether the given klass is a monitored class that could
      # be unloaded.
      def monitored_class?(klass)
        @classes.any? do |c|
          c = constantize(c) rescue false

          if klass.is_a?(Class)
            # Reload the class if it is a subclass if the current class
            (klass < c) rescue false
          elsif c == Object
            # If reloading for all classes, reload for all modules as well
            true
          else
            # Otherwise, reload only if the module matches exactly, since
            # modules don't have superclasses.
            klass == c
          end
        end
      end

      # Return a set of all classes in the ObjectSpace that are not in the
      # given set of classes.
      def new_classes(snapshot)
        all_classes - snapshot
      end

      # Returns true if the file is new or it's modification time changed.
      def file_changed?(file, time = @monitor_files[file])
        !time || modified_at(file) > time
      end

      # Return the time the file was modified at.  This can be overridden
      # to base the reloading on something other than the file's modification
      # time.
      def modified_at(file)
        F.mtime(file)
      end
    end

    # The Rack::Unreloader::Reloader instead related to this instance.
    attr_reader :reloader

    # Setup the reloader. Options:
    # 
    # :cooldown :: The number of seconds to wait between checks for changed files.
    #              Defaults to 1.
    # :logger :: A Logger instance which will log information related to reloading.
    # :subclasses :: A string or array of strings of class names that should be unloaded.
    #                Any classes that are not subclasses of these classes will not be
    #                unloaded.  This also handles modules, but module names given must
    #                match exactly, since modules don't have superclasses.
    def initialize(opts={}, &block)
      @app_block = block
      @cooldown = opts[:cooldown] || 1
      @last = Time.at(0)
      @reloader = Reloader.new(opts)
      @reloader.reload!
    end

    # If the cooldown time has been passed, reload any application files that have changed.
    # Call the app with the environment.
    def call(env)
      if @cooldown && Time.now > @last + @cooldown
        Thread.exclusive{@reloader.reload!}
        @last = Time.now
      end
      @app_block.call.call(env)
    end

    # Add a file glob or array of file globs to monitor for changes.
    def require(depends)
      @reloader.require_dependencies(depends)
    end
  end
end
