# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)
RSpec::Core::RakeTask.new(:compat) do |task|
  task.pattern = 'spec/compat/**/*_spec.rb'
end

task :compat_probe do
  ruby 'script/compat_probe.rb'
end

task default: %i[spec compat_probe]
