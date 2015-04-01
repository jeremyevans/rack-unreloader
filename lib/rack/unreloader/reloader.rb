require 'set'

module Rack
  class Unreloader
    class Reloader
      F = ::File

      # Regexp for valid constant names, to prevent code execution.
      VALID_CONSTANT_NAME_REGEXP = /\A(?:::)?([A-Z]\w*(?:::[A-Z]\w*)*)\z/.freeze

      # Options hash to force loading of files even if they haven't changed.
      FORCE = {:force=>true}.freeze

      # Setup the reloader.  Supports :logger and :subclasses options, see
      # Rack::Unloader.new for details.
      def initialize(opts={})
        @logger = opts[:logger]
        @classes = opts[:subclasses] ?  Array(opts[:subclasses]).map(&:to_s) : %w'Object'

        # Hash of files being monitored for changes, keyed by absolute path of file name,
        # with values being the last modified time (or nil if the file has not yet been loaded).
        @monitor_files = {}

        # Hash of directories being monitored for changes, keyed by absolute path of directory name,
        # with values being the an array with the last modified time (or nil if the directory has not
        # yet been loaded), an array of files in the directory, and a block to pass to
        # require_dependency for new files.
        @monitor_dirs = {}

        # Hash of procs returning constants defined in files, keyed by absolute path
        # of file name.  If there is no proc, must call ObjectSpace before and after
        # loading files to detect changes, which is slower.
        @constants_defined = {}

        # Hash keyed by absolute path of file name, storing constants and other
        # filenames that the key loads.  Values should be hashes with :constants
        # and :features keys, and arrays of values.
        @files = {}

        # Similar to @files, but stores previous entries, used when rolling back.
        @old_entries = {}

        # Records dependencies on files.  Keys are absolute paths, values are arrays of absolute paths,
        # where each entry depends on the key, so that if the key path is modified, all values are
        # reloaded.
        @dependencies = {}

        # Array of the order in which to load dependencies
        @dependency_order = []

        # Array of absolute paths which should be unloaded, but not reloaded on changes,
        # because files that depend on them will load them automatically.
        @skip_reload = []
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

      # Record a dependency the given files, such that each file in +files+
      # depends on +path+.  If +path+ changes, each file in +files+ should
      # be reloaded as well.
      def record_dependency(path, files)
        files = (@dependencies[path] ||= []).concat(files)
        files.uniq!

        order = @dependency_order
        i = order.find_index{|v| files.include?(v)} || -1
        order.insert(i, path)
        order.concat(files)
        order.uniq!

        if F.directory?(path)
          (@monitor_files.keys & Unreloader.ruby_files(path)).each do |file|
            record_dependency(file, files)
          end
        end

        nil
      end
  
      # If there are any changed files, reload them.  If there are no changed
      # files, do nothing.
      def reload!
        changed_files = []

        @monitor_dirs.keys.each do |dir|
          check_monitor_dir(dir, changed_files)
        end

        @monitor_files.each do |file, time|
          if file_changed?(file, time)
            changed_files << file
          end
        end

        return if changed_files.empty?

        unless @dependencies.empty?
          changed_files = reload_files(changed_files)
          changed_files.flatten!
          changed_files.map!{|f| F.directory?(f) ? Unreloader.ruby_files(f) : f}
          changed_files.flatten!
          changed_files.uniq!
          
          order = @dependency_order
          order &= changed_files
          changed_files = order + (changed_files - order)
        end

        unless @skip_reload.empty?
          skip_reload = @skip_reload.map{|f| F.directory?(f) ? Unreloader.ruby_files(f) : f}
          skip_reload.flatten!
          skip_reload.uniq!
          changed_files -= skip_reload
        end

        changed_files.each do |file|
          safe_load(file, FORCE)
        end
      end

      # Require the given dependencies, monitoring them for changes.
      # Paths should be a file glob or an array of file globs.
      def require_dependencies(paths, &block)
        options = {:cyclic => true}
        error = nil 

        Unreloader.expand_paths(paths).each do |file|
          if F.directory?(file)
            @monitor_dirs[file] = [nil, [], block]
            check_monitor_dir(file)
            next
          else
            @constants_defined[file] = block
            @monitor_files[file] = nil
          end

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

      # Skip reloading the given files.  Should only be used if other files
      # depend on these files and the other files require these files when
      # loaded.
      def skip_reload(files)
        @skip_reload.concat(files)
        @skip_reload.uniq!
        nil
      end

      private

      # Tries to find a declared constant with the name specified
      # in the string. It raises a NameError when the name is not in CamelCase
      # or is not initialized.
      def constantize(s)
        s = s.to_s
        if m = VALID_CONSTANT_NAME_REGEXP.match(s)
          Object.module_eval("::#{m[1]}", __FILE__, __LINE__)
        else
          log("Invalid constant name: #{s}")
        end
      end

      # Log the given string at info level if there is a logger.
      def log(s)
        @logger.info(s) if @logger
      end

      # Check a monitored directory for changes, adding new files and removing
      # deleted files.
      def check_monitor_dir(dir, changed_files=nil)
        time, files, block = @monitor_dirs[dir]

        cur_files = Unreloader.ruby_files(dir)
        return if files == cur_files

        removed_files = files - cur_files
        new_files = cur_files - files

        if changed_files
          changed_files.concat(dependency_files(removed_files))
        end

        removed_files.each do |f|
          remove(f)
          @monitor_files.delete(f)
          @dependencies.delete(f)
          @dependency_order.delete(f)
        end

        require_dependencies(new_files, &block)

        new_files.each do |file|
          if deps = @dependencies[dir]
            record_dependency(file, deps)
          end
        end

        if changed_files
          changed_files.concat(dependency_files(new_files))
        end

        files.replace(cur_files)
      end

      # Requires the given file, logging which constants or features are added
      # by the require, and rolling back the constants and features if there
      # are any errors.
      def safe_load(file, options={})
        return unless @monitor_files.has_key?(file)
        return unless options[:force] || file_changed?(file)

        prepare(file) # might call #safe_load recursively
        log "Loading #{file}"
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
        log "Error removing constant: #{const}"
      end

      # Remove a feature if it is being monitored for reloading, so it
      # can be required again.
      def remove_feature(file)
        if @monitor_files.has_key?(file)
          log "Unloading #{file}"
          $LOADED_FEATURES.delete(file)
        end
      end

      # Remove the given file, removing any constants and other files loaded
      # by the file.
      def remove(name)
        file = @files[name] || return
        remove_feature(name) if $LOADED_FEATURES.include?(name)
        file[:features].each{|feature| remove_feature(feature)}
        remove_constants(name){file[:constants]}
        @files.delete(name)
      end

      # Remove constants defined in file.  Uses the stored block if there is
      # one for the file name, or the given block.
      def remove_constants(name)
        yield.each{|constant| remove_constant(constant)}
      end

      # True if the constant is already defined, false if not
      def constant_defined?(const)
        constantize(const)
        true
      rescue
        false
      end

      # Store the currently loaded classes and features, so in case of an error
      # this state can be rolled back to.
      def prepare(name)
        file = remove(name)
        @old_entries[name] = {:features => monitored_features}
        if constants = constants_for(name)
          defs = constants.select{|c| constant_defined?(c)}
          unless defs.empty?
            log "Constants already defined before loading #{name}: #{defs.join(" ")}"
          end
          @old_entries[name][:constants] = constants
        else
          @old_entries[name][:all_classes] = all_classes
        end
      end

      # Returns nil if ObjectSpace should be used to load the constants.  Returns an array of
      # constant name symbols loaded by the file if they have been manually specified.
      def constants_for(name)
        if (pr = @constants_defined[name]) && (constants = pr.call(name)) != :ObjectSpace
          Array(constants)
        end
      end

      # The constants that were loaded by the given file.  If ObjectSpace was used to check
      # all classes loaded previously, then check for new classes loaded since.  If the constants 
      # were explicitly specified, then use them directly
      def constants_loaded_by(name)
        if @old_entries[name][:all_classes]
          new_classes(@old_entries[name][:all_classes])
        else
          @old_entries[name][:constants]
        end
      end

      # Commit the changed state after requiring the the file, recording the new
      # classes and features added by the file.
      def commit(name)
        entry = {:features => monitored_features - @old_entries[name][:features] - [name], :constants=>constants_loaded_by(name)}

        @files[name] = entry
        @old_entries.delete(name)
        @monitor_files[name] = modified_at(name)

        defs, not_defs = entry[:constants].partition{|c| constant_defined?(c)}
        unless not_defs.empty?
          log "Constants not defined after loading #{name}: #{not_defs.join(' ')}"
        end
        unless defs.empty?
          log("New classes in #{name}: #{defs.join(' ')}") 
        end
        unless entry[:features].empty?
          log("New features in #{name}: #{entry[:features].to_a.join(' ')}") 
        end
      end

      # Rollback the changes made by requiring the file, restoring the previous state.
      def rollback(name)
        remove_constants(name){constants_loaded_by(name)}
        @old_entries.delete(name)
      end

      # The current loaded features that are being monitored
      def monitored_features
        Set.new($LOADED_FEATURES) & @monitor_files.keys
      end

      # Return a set of all classes in the ObjectSpace.
      def all_classes
        rs = Set.new

        ::ObjectSpace.each_object(Module).each do |mod|
          if !mod.name.to_s.empty? && monitored_module?(mod)
            rs << mod
          end
        end

        rs
      end

      # Return whether the given klass is a monitored class that could
      # be unloaded.
      def monitored_module?(mod)
        @classes.any? do |c|
          c = constantize(c) rescue false

          if mod.is_a?(Class)
            # Reload the class if it is a subclass if the current class
            (mod < c) rescue false
          elsif c == Object
            # If reloading for all classes, reload for all modules as well
            true
          else
            # Otherwise, reload only if the module matches exactly, since
            # modules don't have superclasses.
            mod == c
          end
        end
      end

      # Recursively reload dependencies for the changed files.
      def reload_files(changed_files)
        changed_files.map do |file|
          if deps = @dependencies[file]
            [file] + reload_files(deps)
          else
            file
          end
        end
      end

      # The dependencies for the changed files, excluding the files themselves.
      def dependency_files(changed_files)
        files = reload_files(changed_files)
        files.flatten!
        files - changed_files
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
  end
end
