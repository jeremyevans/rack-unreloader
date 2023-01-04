require_relative 'reloader'

module Rack
  class Unreloader
    class AutoloadReloader < Reloader
      def initialize(opts={})
        super

        # Files that autoloads have been setup for, but have not yet been loaded.
        # Hash with realpath keys and values that are arrays with the
        # a block that will return constant name strings that will autoload the 
        # file, the modified time the file, and the delete hook.
        @autoload_files = {}

        # Directories where new files will be setup for autoloading.
        # Uses same format as @monitor_dirs.
        @autoload_dirs = {}
      end

      def autoload_dependencies(paths, opts={}, &block)
        delete_hook = opts[:delete_hook]

        Unreloader.expand_paths(paths).each do |file|
          if File.directory?(file)
            @autoload_dirs[file] = [nil, [], block, delete_hook]
            check_autoload_dir(file)
          else
            # Comparisons against $LOADED_FEATURES need realpaths
            @autoload_files[File.realpath(file)] = [block, modified_at(file), delete_hook]
            Unreloader.autoload_constants(yield(file), file, @logger)
          end
        end
      end

      def remove_autoload(file, strings)
        strings = Array(strings)
        log("Removing autoload for #{file}: #{strings.join(" ")}") unless strings.empty?
        strings.each do |s|
          obj, mod = Unreloader.split_autoload(s)
          # Assume that if the autoload string was valid to create the
          # autoload, it is still valid when removing the autoload.
          obj.send(:remove_const, mod)
        end
      end

      def check_autoload_dir(dir)
        subdir_times, files, block, delete_hook = md = @autoload_dirs[dir]
        return if subdir_times && subdir_times.all?{|subdir, time| File.directory?(subdir) && modified_at(subdir) == time}
        md[0] = subdir_times(dir)

        cur_files = Unreloader.ruby_files(dir)
        return if files == cur_files

        removed_files = files - cur_files
        new_files = cur_files - files

        # Removed files that were never required should have the constant removed
        # so that accesses to the constant do not attempt to autoload a file that
        # no longer exists.
        removed_files.each do |file|
          remove_autoload(file, block.call(file)) unless @monitor_files[file]
        end

        # New files not yet loaded should have autoloads added for them.
        autoload_dependencies(new_files, :delete_hook=>delete_hook, &block) unless new_files.empty?

        files.replace(cur_files)
      end

      def reload!
        (@autoload_files.keys & $LOADED_FEATURES).each do |file|
          # Files setup for autoloads were autoloaded, move metadata to locations
          # used for required files.
          log("Autoloaded file required, setting up reloading: #{file}")
          block, *metadata = @autoload_files.delete(file)
          @constants_defined[file] = block
          @monitor_files[file] = metadata
          @files[file] = {:features=>Set.new, :constants=>Array(block.call(file))}
        end

        @autoload_dirs.each_key do |dir|
          check_autoload_dir(dir)
        end

        super
      end
    end
  end
end
