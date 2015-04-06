spec = Gem::Specification.new do |s|
  s.name = 'rack-unreloader'
  s.version = '1.3.0'
  s.platform = Gem::Platform::RUBY
  s.has_rdoc = true
  s.extra_rdoc_files = ["README.rdoc", "CHANGELOG", "MIT-LICENSE"]
  s.rdoc_options += ["--quiet", "--line-numbers", "--inline-source", '--title', 'Rack::Unreloader: Reload application when files change, unloading constants first', '--main', 'README.rdoc']
  s.license = "MIT"
  s.summary = "Reload application when files change, unloading constants first"
  s.author = "Jeremy Evans"
  s.email = "code@jeremyevans.net"
  s.homepage = "http://github.com/jeremyevans/rack-unreloader"
  s.files = %w(MIT-LICENSE CHANGELOG README.rdoc Rakefile) + Dir["{spec,lib}/**/*.rb"]
  s.description = <<END
Rack::Unreloader is a rack middleware that reloads application files when it
detects changes, unloading constants defined in those files before reloading.
END
end
