spec = Gem::Specification.new do |s|
  s.name = 'rack-unreloader'
  s.version = '2.0.0'
  s.platform = Gem::Platform::RUBY
  s.extra_rdoc_files = ["README.rdoc", "CHANGELOG", "MIT-LICENSE"]
  s.rdoc_options += ["--quiet", "--line-numbers", "--inline-source", '--title', 'Rack::Unreloader: Reload application when files change, unloading constants first', '--main', 'README.rdoc']
  s.license = "MIT"
  s.summary = "Reload application when files change, unloading constants first"
  s.author = "Jeremy Evans"
  s.email = "code@jeremyevans.net"
  s.homepage = "http://github.com/jeremyevans/rack-unreloader"
  s.files = %w(MIT-LICENSE CHANGELOG README.rdoc) + Dir["lib/**/*.rb"]
  s.description = <<END
Rack::Unreloader is a rack middleware that reloads application files when it
detects changes, unloading constants defined in those files before reloading.
END
  s.metadata = {
    'bug_tracker_uri'   => 'https://github.com/jeremyevans/rack-unreloader/issues',
    'changelog_uri'     => 'https://github.com/jeremyevans/rack-unreloader/blob/master/CHANGELOG',
    'mailing_list_uri'  => 'https://github.com/jeremyevans/rack-unreloader/discussions',
    'source_code_uri'   => 'https://github.com/jeremyevans/rack-unreloader'
  }
  s.required_ruby_version = ">= 1.9.2"
  s.add_development_dependency "minitest", '>=5.6.1'
  s.add_development_dependency "minitest-hooks"
  s.add_development_dependency "minitest-global_expectations"
end
