require File.join(File.dirname(File.expand_path(__FILE__)), '../lib/rack/unreloader')
require 'rubygems'
$: << 'lib'
ENV['MT_NO_PLUGINS'] = '1' # Work around stupid autoloading of plugins
gem 'minitest'
require 'minitest/global_expectations/autorun'
require 'minitest/hooks'

module ModifiedAt
  def set_modified_time(file, time)
    time = Time.now + time if time.is_a?(Integer)
    modified_times[File.expand_path(file)] = time
  end

  def modified_times
    @modified_times ||= {}
  end

  private

  def modified_at(file)
    modified_times[file] || super
  end
end

class Minitest::Spec
  def code(i)
    "class App; def self.call(env) @a end; @a ||= []; @a << #{i}; end"
  end

  def update_app(code, file=@filename)
    ru.reloader.set_modified_time(file, @i += 1) if ru.reloader
    File.open(file, 'wb'){|f| f.write(code)}
  end

  def logger
    return @logger if @logger
    @logger = []
    def @logger.method_missing(meth, log)
      self << log
    end
    @logger
  end

  def base_ru(opts={})
    block = opts[:block] || proc{App}
    @ru = Rack::Unreloader.new({:logger=>logger, :cooldown=>0}.merge(opts), &block)
    @ru.reloader.extend ModifiedAt if @ru.reloader
    Object.const_set(:RU, @ru)
  end

  def ru(opts={})
    return @ru if @ru
    base_ru(opts)
    update_app(opts[:code]||code(1))
    @ru.require @filename
    @ru
  end

  def log_match(*logs)
    @logger.length.must_equal logs.length
    logs.zip(@logger).each{|l, log| l.is_a?(String) ? log.must_equal(l) : log.must_match(l)}
  end

  before do
    @i = 0
    @filename = 'spec/app.rb'
  end

  after do
    ru.reloader.clear! if ru.reloader
    Object.send(:remove_const, :RU)
    Object.send(:remove_const, :App) if defined?(::App)
    Object.send(:remove_const, :App2) if defined?(::App2)
    Dir['spec/app*.rb'].each{|f| File.delete(f)}
  end
end
