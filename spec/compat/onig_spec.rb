# frozen_string_literal: true

require 'spec_helper'
require 'support/official_compat'

RSpec.describe 'onig.test compatibility' do
  path = File.expand_path('../fixtures/jq/onig.test', __dir__)

  OfficialCompat.runnable_cases(path).each_with_index do |test_case, index|
    it "matches onig.test case #{index + 1}: #{test_case.fetch(:program)}" do
      expected = OfficialCompat.expected_values(test_case.fetch(:expected))
      observation = OfficialCompat.observe_case(test_case.fetch(:program), test_case.fetch(:input))

      expect(OfficialCompat.match_values?(expected, observation.outputs)).to be(true)
      expect(observation.error).to be_nil
    end
  end
end
