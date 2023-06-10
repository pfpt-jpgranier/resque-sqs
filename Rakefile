#
# Setup
#

load 'lib/tasks/redis_sqs.rake'

$LOAD_PATH.unshift 'lib'
require 'resque_sqs/tasks'

def command?(command)
  system("type #{command} > /dev/null 2>&1")
end


#
# Tests
#

require 'rake/testtask'

task :default => :test

Rake::TestTask.new do |test|
  test.verbose = true
  test.libs << "test"
  test.libs << "lib"
  test.test_files = FileList['test/**/*_test.rb']
end

if command? :kicker
  desc "Launch Kicker (like autotest)"
  task :kicker do
    puts "Kicking... (ctrl+c to cancel)"
    exec "kicker -e rake test lib examples"
  end
end


#
# Install
#

task :install => [ 'redis_sqs:install', 'dtach_sqs:install' ]


#
# Documentation
#

begin
  require 'sdoc_helpers'
rescue LoadError
end


#
# Publishing
#

desc "Push a new version to Gemcutter"
task :sqs_publish do
  require 'resque_sqs/version'

  sh "gem build resque_sqs.gemspec"
  sh "gem push resque_sqs-#{ResqueSqs::Version}.gem"
  sh "git tag v#{ResqueSqs::Version}"
  sh "git push origin v#{ResqueSqs::Version}"
  sh "git push origin master"
  sh "git clean -fd"
end
