require "rake"
require "rake/clean"

CLEAN.include ["rack-unreloader-*.gem", "rdoc", "coverage"]

desc "Build rack-unreloader gem"
task :package=>[:clean] do |p|
  sh %{#{FileUtils::RUBY} -S gem build rack-unreloader.gemspec}
end

### Specs

desc "Run specs"
task :spec do
  sh "#{FileUtils::RUBY} #{'-w' if RUBY_VERSION >= '3'} #{'-W:strict_unused_block' if RUBY_VERSION >= '3.4'} spec/unreloader_spec.rb"
end

desc "Run specs with coverage"
task :spec_cov do
  ENV['COVERAGE'] = '1'
  sh "#{FileUtils::RUBY} spec/unreloader_spec.rb"
end

task :default => :spec

### RDoc

RDOC_DEFAULT_OPTS = ["--quiet", "--line-numbers", "--inline-source", '--title', 'Rack::Unreloader: Reload application when files change, unloading constants first']

begin
  gem 'hanna'
  RDOC_DEFAULT_OPTS.concat(['-f', 'hanna'])
rescue Gem::LoadError
end

require "rdoc/task"
RDOC_OPTS = RDOC_DEFAULT_OPTS + ['--main', 'README.rdoc']

RDoc::Task.new do |rdoc|
  rdoc.rdoc_dir = "rdoc"
  rdoc.options += RDOC_OPTS
  rdoc.rdoc_files.add %w"README.rdoc CHANGELOG MIT-LICENSE lib/**/*.rb"
end
