# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rbconfig'
require 'rspec/core/rake_task'

task :syntax do
  Dir['lib/**/*.rb', 'bin/*', 'script/*.rb', 'benchmark/*.rb', 'spec/**/*.rb'].sort.each do |file|
    next if system(RbConfig.ruby, '-c', file, out: File::NULL, err: File::NULL)

    abort "syntax check failed: #{file}"
  end
end

RSpec::Core::RakeTask.new(:spec)
RSpec::Core::RakeTask.new(:compat) do |task|
  task.pattern = 'spec/compat/**/*_spec.rb'
end

task :compat_probe do
  ruby 'script/compat_probe.rb'
end

RSpec::Core::RakeTask.new(:differential) do |task|
  task.pattern = 'spec/differential/**/*_spec.rb'
end

task default: %i[syntax spec compat_probe]
