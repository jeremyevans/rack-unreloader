require File.join(File.dirname(File.expand_path(__FILE__)), 'spec_helper')

describe Rack::Unreloader do
  it "should not reload files automatically if cooldown option is nil" do
    ru(:cooldown => nil).call({}).must_equal [1]
    update_app(code(2))
    ru.call({}).must_equal [1]
    @ru.reload!
    ru.call({}).must_equal [2]
  end

  it "should not setup a reloader if reload option is false" do
    @filename = 'spec/app_no_reload.rb'
    ru(:reload => false).call({}).must_equal [1]
    file = 'spec/app_no_reload2.rb'
    File.open(file, 'wb'){|f| f.write('ANR2 = 2')}
    ru.require 'spec/app_no_*2.rb'
    ANR2.must_equal 2
  end

  it "should unload constants contained in file and reload file if file changes" do
    ru.call({}).must_equal [1]
    update_app(code(2))
    ru.call({}).must_equal [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AUnloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z}
  end

  it "should stop monitoring file for changes if it is deleted constants contained in file and reload file if file changes" do
    ru.call({}).must_equal [1]
    File.delete('spec/app.rb')
    proc{ru.call({})}.must_raise NameError
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AUnloading.*spec/app\.rb\z},
              "Removed constant App"
  end

  it "should check constants using ObjectSpace if require proc returns :ObjectSpace" do
    base_ru
    update_app(code(1))
    @ru.require(@filename){|f| :ObjectSpace}
    ru.call({}).must_equal [1]
    update_app(code(2))
    ru.call({}).must_equal [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AUnloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z}
  end

  it "should pickup files added as dependencies" do
    ru.call({}).must_equal [1]
    update_app("RU.require 'spec/app2.rb'; class App; def self.call(env) [@a, App2.call(env)] end; @a ||= []; @a << 2; end")
    update_app("class App2; def self.call(env) @a end; @a ||= []; @a << 3; end", 'spec/app2.rb')
    ru.call({}).must_equal [[2], [3]]
    update_app("class App2; def self.call(env) @a end; @a ||= []; @a << 4; end", 'spec/app2.rb')
    ru.call({}).must_equal [[2], [4]]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AUnloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ALoading.*spec/app2\.rb\z},
              %r{\ANew classes in .*spec/app2\.rb: App2\z},
              %r{\ANew classes in .*spec/app\.rb: (App App2|App2 App)\z},
              %r{\ANew features in .*spec/app\.rb: .*spec/app2\.rb\z},
              %r{\AUnloading.*spec/app2\.rb\z},
              "Removed constant App2",
              %r{\ALoading.*spec/app2\.rb\z},
              %r{\ANew classes in .*spec/app2\.rb: App2\z}
  end

  it "should support :subclasses option and only unload subclasses of given class" do
    ru(:subclasses=>'App').call({}).must_equal [1]
    update_app("RU.require 'spec/app2.rb'; class App; def self.call(env) [@a, App2.call(env)] end; @a ||= []; @a << 2; end")
    update_app("class App2 < App; def self.call(env) @a end; @a ||= []; @a << 3; end", 'spec/app2.rb')
    ru.call({}).must_equal [[1, 2], [3]]
    update_app("class App2 < App; def self.call(env) @a end; @a ||= []; @a << 4; end", 'spec/app2.rb')
    ru.call({}).must_equal [[1, 2], [4]]
    update_app("RU.require 'spec/app2.rb'; class App; def self.call(env) [@a, App2.call(env)] end; @a ||= []; @a << 2; end")
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\AUnloading.*spec/app\.rb\z},
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ALoading.*spec/app2\.rb\z},
              %r{\ANew classes in .*spec/app2\.rb: App2\z},
              %r{\ANew classes in .*spec/app\.rb: App2\z},
              %r{\ANew features in .*spec/app\.rb: .*spec/app2\.rb\z},
              %r{\AUnloading.*spec/app2\.rb\z},
              "Removed constant App2",
              %r{\ALoading.*spec/app2\.rb\z},
              %r{\ANew classes in .*spec/app2\.rb: App2\z}
  end

  it "should log invalid constant names in :subclasses options" do
    ru(:subclasses=>%w'1 Object').call({}).must_equal [1]
    logger.uniq!
    log_match 'Invalid constant name: 1',
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z}
  end

  it "should unload modules before reloading similar to classes" do
    ru(:code=>"module App; def self.call(env) @a end; @a ||= []; @a << 1; end").call({}).must_equal [1]
    update_app("module App; def self.call(env) @a end; @a ||= []; @a << 2; end")
    ru.call({}).must_equal [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AUnloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z}
  end

  it "should unload specific modules by name via :subclasses option" do
    ru(:subclasses=>'App', :code=>"module App; def self.call(env) @a end; @a ||= []; @a << 1; end").call({}).must_equal [1]
    update_app("module App; def self.call(env) @a end; @a ||= []; @a << 2; end")
    ru.call({}).must_equal [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AUnloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z}
  end

  it "should not unload modules by name if :subclasses option used and module not present" do
    ru(:subclasses=>'Foo', :code=>"module App; def self.call(env) @a end; @a ||= []; @a << 1; end").call({}).must_equal [1]
    update_app("module App; def self.call(env) @a end; @a ||= []; @a << 2; end")
    ru.call({}).must_equal [1, 2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\AUnloading.*spec/app\.rb\z},
              %r{\ALoading.*spec/app\.rb\z}
  end

  it "should unload partially loaded modules if loading fails, and allow future loading" do
    ru.call({}).must_equal [1]
    update_app("module App; def self.call(env) @a end; @a ||= []; raise 'foo'; end")
    proc{ru.call({})}.must_raise RuntimeError
    defined?(::App).must_be_nil
    update_app(code(2))
    ru.call({}).must_equal [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AUnloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\AFailed to load .*spec/app\.rb; removing partially defined constants\z},
              "Removed constant App",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z}
  end

  it "should support :handle_reload_errors option to return backtrace if there is an error reloading" do
    ru(:handle_reload_errors=>true).call({}).must_equal [1]
    update_app("module App; def self.call(env) @a end; @a ||= []; raise 'foo'; end")
    rack_response = ru.call({})
    rack_response[0].must_equal 500
    rack_response[1]['Content-Type'].must_equal 'text/plain'
    rack_response[1]['Content-Length'].must_match(rack_response[2][0].bytesize.to_s)
    rack_response[2][0].must_match(/\/spec\/app\.rb:1/)
    defined?(::App).must_be_nil
    update_app(code(2))
    ru.call({}).must_equal [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AUnloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\AFailed to load .*spec/app\.rb; removing partially defined constants\z},
              "Removed constant App",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z}
  end

  it "should unload classes in namespaces" do
    ru(:code=>"class Array::App; def self.call(env) @a end; @a ||= []; @a << 1; end", :block=>proc{Array::App}).call({}).must_equal [1]
    update_app("class Array::App; def self.call(env) @a end; @a ||= []; @a << 2; end")
    ru.call({}).must_equal [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: Array::App\z},
              %r{\AUnloading.*spec/app\.rb\z},
              "Removed constant Array::App",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: Array::App\z}
  end

  it "should not unload class defined in dependency if already defined in parent" do
    base_ru
    update_app("class App; def self.call(env) @a end; @a ||= []; @a << 2; RU.require 'spec/app2.rb'; end")
    update_app("class App; @a << 3 end", 'spec/app2.rb')
    @ru.require 'spec/app.rb'
    ru.call({}).must_equal [2, 3]
    update_app("class App; @a << 4 end", 'spec/app2.rb')
    ru.call({}).must_equal [2, 3, 4]
    update_app("class App; def self.call(env) @a end; @a ||= []; @a << 2; RU.require 'spec/app2.rb'; end")
    ru.call({}).must_equal [2, 4]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ALoading.*spec/app2\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\ANew features in .*spec/app\.rb: .*spec/app2\.rb\z},
              %r{\AUnloading.*spec/app2\.rb\z},
              %r{\ALoading.*spec/app2\.rb\z},
              %r{\AUnloading.*spec/app\.rb\z},
              %r{\AUnloading.*spec/app2\.rb\z},
              "Removed constant App",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ALoading.*spec/app2\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\ANew features in .*spec/app\.rb: .*spec/app2\.rb\z}
  end

  it "should allow specifying proc for which constants get removed" do
    base_ru
    update_app("class App; def self.call(env) [@a, App2.a] end; @a ||= []; @a << 1; end; class App2; def self.a; @a end; @a ||= []; @a << 2; end")
    @ru.require('spec/app.rb'){|f| File.basename(f).sub(/\.rb/, '').capitalize}
    ru.call({}).must_equal [[1], [2]]
    update_app("class App; def self.call(env) [@a, App2.a] end; @a ||= []; @a << 3; end; class App2; def self.a; @a end; @a ||= []; @a << 4; end")
    ru.call({}).must_equal [[3], [2, 4]]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AUnloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z}
  end

  it "should handle anonymous classes" do
    base_ru(:block=>proc{$app})
    update_app("$app = Class.new do def self.call(env) @a end; @a ||= []; @a << 1; end")
    @ru.require('spec/app.rb')
    ru.call({}).must_equal [1]
    update_app("$app = Class.new do def self.call(env) @a end; @a ||= []; @a << 2; end")
    ru.call({}).must_equal [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\AUnloading.*spec/app\.rb\z},
              %r{\ALoading.*spec/app\.rb\z}
  end

  it "should log when attempting to remove a class that doesn't exist" do
    base_ru
    update_app(code(1))
    @ru.require('spec/app.rb'){|f| 'Foo'}
    ru.call({}).must_equal [1]
    update_app(code(2))
    ru.call({}).must_equal [1, 2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\AConstants not defined after loading .*spec/app\.rb: Foo\z},
              %r{\AUnloading.*spec/app\.rb\z},
              "Error removing constant: Foo",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\AConstants not defined after loading .*spec/app\.rb: Foo\z}
  end

  it "should log when specifying a constant that already exists" do
    base_ru
    update_app(code(1))
    ::App2 = 1
    @ru.require('spec/app.rb'){|f| 'App2'}
    ru.call({}).must_equal [1]
    log_match %r{\AConstants already defined before loading .*spec/app\.rb: App2\z},
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App2\z}
  end

  it "should handle recorded dependencies" do
    base_ru
    update_app("module A; B = 1; end", 'spec/app_mod.rb')
    update_app("class App; A = ::A; def self.call(env) A::B end; end")
    ru.require 'spec/app_mod.rb'
    ru.require 'spec/app.rb'
    ru.record_dependency 'spec/app_mod.rb', 'spec/app.rb'
    ru.call({}).must_equal 1
    update_app("module A; B = 2; end", 'spec/app_mod.rb')
    ru.call({}).must_equal 2
    update_app("module A; include C; end", 'spec/app_mod.rb')
    update_app("module C; B = 3; end", 'spec/app_mod2.rb')
    ru.record_dependency 'spec/app_mod2.rb', 'spec/app_mod.rb'
    ru.require 'spec/app_mod2.rb'
    ru.call({}).must_equal 3
    update_app("module C; B = 4; end", 'spec/app_mod2.rb')
    ru.call({}).must_equal 4
  end

  it "should handle modules where name raises an exception" do
    m = Module.new{def self.name; raise end}
    ru(:code=>"module App; def self.call(env) @a end; @a ||= []; @a << 1; end").call({}).must_equal [1]
    update_app("module App; def self.call(env) @a end; @a ||= []; @a << 2; end")
    ru.call({}).must_equal [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AUnloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z}
    m
  end

  describe "with a directory" do
    include Minitest::Hooks

    before(:all) do
      Dir.mkdir('spec/dir')
      Dir.mkdir('spec/dir/subdir')
      Dir.mkdir('spec/dir/subdir2')
    end

    after do
      Dir['spec/dir/**/*.rb'].each{|f| File.delete(f)}
    end

    after(:all) do
      Dir.rmdir('spec/dir/subdir')
      Dir.rmdir('spec/dir/subdir2')
      Dir.rmdir('spec/dir')
    end

    it "should have unreloader require with directories if reload option is false" do
      file = 'spec/dir/app_no_reload3.rb'
      File.open(file, 'wb'){|f| f.write('ANR3 = 3')}
      base_ru(:reload => false)
      ru.require 'spec/dir'
      ANR3.must_equal 3
    end

    it "should handle recorded dependencies in directories" do
      base_ru
      update_app("module A; B = 1; end", 'spec/dir/subdir/app_mod.rb')
      update_app("class App; A = ::A; def self.call(env) A::B end; end")
      ru.require 'spec/dir/subdir'
      ru.require 'spec/app.rb'
      ru.record_dependency 'spec/dir/subdir', 'spec/app.rb'
      ru.call({}).must_equal 1
      update_app("module A; B = 2; end", 'spec/dir/subdir/app_mod.rb')
      ru.call({}).must_equal 2
      update_app("module A; include C; end", 'spec/dir/subdir/app_mod.rb')
      update_app("module C; B = 3; end", 'spec/dir/subdir2/app_mod2.rb')
      ru.require 'spec/dir/subdir2/app_mod2.rb'
      ru.record_dependency 'spec/dir/subdir2/app_mod2.rb', 'spec/dir/subdir'
      ru.call({}).must_equal 3
      update_app("module C; B = 4; end", 'spec/dir/subdir2/app_mod2.rb')
      ru.call({}).must_equal 4
    end

    it "should handle recorded dependencies in directories when files are added or removed later" do
      base_ru
      update_app("class App; A = defined?(::A) ? ::A : Module.new{self::B = 0}; def self.call(env) A::B end; end")
      ru.record_dependency 'spec/dir/subdir', 'spec/app.rb'
      ru.record_dependency 'spec/dir/subdir2', 'spec/dir/subdir'
      ru.require 'spec/app.rb'
      ru.require 'spec/dir/subdir'
      ru.require 'spec/dir/subdir2'
      ru.call({}).must_equal 0
      update_app("module A; B = 1; end", 'spec/dir/subdir/app_mod.rb')
      ru.call({}).must_equal 1
      update_app("module A; B = 2; end", 'spec/dir/subdir/app_mod.rb')
      ru.call({}).must_equal 2
      update_app("module C; B = 3; end", 'spec/dir/subdir2/app_mod2.rb')
      ru.call({}).must_equal 2
      update_app("module A; include C; end", 'spec/dir/subdir/app_mod.rb')
      ru.call({}).must_equal 3
      update_app("module C; B = 4; end", 'spec/dir/subdir2/app_mod2.rb')
      ru.call({}).must_equal 4
      File.delete 'spec/dir/subdir/app_mod.rb'
      ru.call({}).must_equal 0
    end

    it "should handle classes split into multiple files" do
      base_ru
      update_app("class App; RU.require('spec/dir'); def self.call(env) \"\#{a if respond_to?(:a)}\#{b if respond_to?(:b)}1\".to_i end; end")
      ru.require 'spec/app.rb'
      ru.record_split_class 'spec/app.rb', 'spec/dir'
      ru.call({}).must_equal 1
      update_app("class App; def self.a; 2 end end", 'spec/dir/appa.rb')
      ru.call({}).must_equal 21
      update_app("class App; def self.a; 3 end end", 'spec/dir/appa.rb')
      ru.call({}).must_equal 31
      update_app("class App; def self.b; 4 end end", 'spec/dir/appb.rb')
      ru.call({}).must_equal 341
      update_app("class App; def self.a; 5 end end", 'spec/dir/appa.rb')
      update_app("class App; def self.b; 6 end end", 'spec/dir/appb.rb')
      ru.call({}).must_equal 561
      update_app("class App; end", 'spec/dir/appa.rb')
      ru.call({}).must_equal 61
      File.delete 'spec/dir/appb.rb'
      ru.call({}).must_equal 1
    end

    it "should pick up changes to files in that directory" do
      base_ru
      update_app("class App; @a = {}; def self.call(env=nil) @a end; end; RU.require 'spec/dir'")
      update_app("App.call[:foo] = 1", 'spec/dir/a.rb')
      @ru.require('spec/app.rb')
      ru.call({}).must_equal(:foo=>1)
      update_app("App.call[:foo] = 2", 'spec/dir/a.rb')
      ru.call({}).must_equal(:foo=>2)
      log_match %r{\ALoading.*spec/app\.rb\z},
                %r{\ALoading.*spec/dir/a\.rb\z},
                %r{\ANew classes in .*spec/app\.rb: App\z},
                %r{\ANew features in .*spec/app\.rb: .*spec/dir/a\.rb\z},
                %r{\AUnloading .*/spec/dir/a.rb\z},
                %r{\ALoading .*/spec/dir/a.rb\z}
    end

    it "should pick up changes to files in subdirectories" do
      base_ru
      update_app("class App; @a = {}; def self.call(env=nil) @a end; end; RU.require 'spec/dir'")
      update_app("App.call[:foo] = 1", 'spec/dir/subdir/a.rb')
      @ru.require('spec/app.rb')
      ru.call({}).must_equal(:foo=>1)
      update_app("App.call[:foo] = 2", 'spec/dir/subdir/a.rb')
      ru.call({}).must_equal(:foo=>2)
      log_match %r{\ALoading.*spec/app\.rb\z},
                %r{\ALoading.*spec/dir/subdir/a\.rb\z},
                %r{\ANew classes in .*spec/app\.rb: App\z},
                %r{\ANew features in .*spec/app\.rb: .*spec/dir/subdir/a\.rb\z},
                %r{\AUnloading .*/spec/dir/subdir/a.rb\z},
                %r{\ALoading .*/spec/dir/subdir/a.rb\z}
    end

    it "should pick up new files added to the directory" do
      base_ru
      update_app("class App; @a = {}; def self.call(env=nil) @a end; end; RU.require 'spec/dir'")
      @ru.require('spec/app.rb')
      ru.call({}).must_equal({})
      update_app("App.call[:foo] = 2", 'spec/dir/a.rb')
      ru.call({}).must_equal(:foo=>2)
      log_match %r{\ALoading.*spec/app\.rb\z},
                %r{\ANew classes in .*spec/app\.rb: App\z},
                %r{\ALoading.*spec/dir/a\.rb\z}
    end

    it "should pick up new files added to subdirectories" do
      base_ru
      update_app("class App; @a = {}; def self.call(env=nil) @a end; end; RU.require 'spec/dir'")
      @ru.require('spec/app.rb')
      ru.call({}).must_equal({})
      update_app("App.call[:foo] = 2", 'spec/dir/subdir/a.rb')
      ru.call({}).must_equal(:foo=>2)
      log_match %r{\ALoading.*spec/app\.rb\z},
                %r{\ANew classes in .*spec/app\.rb: App\z},
                %r{\ALoading.*spec/dir/subdir/a\.rb\z}
    end

    it "should drop files deleted from the directory" do
      base_ru
      update_app("class App; @a = {}; def self.call(env=nil) @a end; end; RU.require 'spec/dir'")
      update_app("App.call[:foo] = 1", 'spec/dir/a.rb')
      @ru.require('spec/app.rb')
      ru.call({}).must_equal(:foo=>1)
      File.delete('spec/dir/a.rb')
      update_app("App.call[:foo] = 2", 'spec/dir/b.rb')
      ru.call({}).must_equal(:foo=>2)
      log_match %r{\ALoading.*spec/app\.rb\z},
                %r{\ALoading.*spec/dir/a\.rb\z},
                %r{\ANew classes in .*spec/app\.rb: App\z},
                %r{\ANew features in .*spec/app\.rb: .*spec/dir/a\.rb\z},
                %r{\AUnloading .*/spec/dir/a.rb\z},
                %r{\ALoading.*spec/dir/b\.rb\z}
    end

    it "should drop files deleted from subdirectories" do
      base_ru
      update_app("class App; @a = {}; def self.call(env=nil) @a end; end; RU.require 'spec/dir'")
      update_app("App.call[:foo] = 1", 'spec/dir/subdir/a.rb')
      @ru.require('spec/app.rb')
      ru.call({}).must_equal(:foo=>1)
      File.delete('spec/dir/subdir/a.rb')
      update_app("App.call[:foo] = 2", 'spec/dir/subdir/b.rb')
      ru.call({}).must_equal(:foo=>2)
      log_match %r{\ALoading.*spec/app\.rb\z},
                %r{\ALoading.*spec/dir/subdir/a\.rb\z},
                %r{\ANew classes in .*spec/app\.rb: App\z},
                %r{\ANew features in .*spec/app\.rb: .*spec/dir/subdir/a\.rb\z},
                %r{\AUnloading .*/spec/dir/subdir/a.rb\z},
                %r{\ALoading.*spec/dir/subdir/b\.rb\z}
    end
  end
end
