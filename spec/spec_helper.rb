# frozen_string_literal: true

if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    enable_coverage :branch
    minimum_coverage line: 86, branch: 73
  end
end

require 'stringio'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'rjq'
require 'rjq/cli'

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
end
