Gem::Specification.new do |s|
  s.name        = 'vautil'
  s.version     = '0.30'
  s.date        = '2016-05-31'
  s.summary     = 'A VA Utility/Library'
  s.description = <<-EOF
VA utility and library of awesomeness.
EOF
  s.author      = 'CD Eng'
  s.email       = 'cd-eng@coredial.com'
  s.license     = 'Proprietary'
  s.executables << 'vautil.rb'
  s.add_runtime_dependency 'scutil', '>= 0.4.7'
  s.files = %w(
bin/vautil.rb
lib/vautil.rb
lib/vautil/fraud.rb
lib/vautil/odbc.rb
lib/vautil/server.rb
vautil.gemspec
config.example
delete_realtime.php
)
end
