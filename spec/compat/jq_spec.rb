# frozen_string_literal: true

require 'spec_helper'
require 'support/official_compat'

RSpec.describe 'jq.test compatibility' do
  path = File.expand_path('../fixtures/jq/jq.test', __dir__)

  OfficialCompat.runnable_cases(path).each_with_index do |test_case, index|
    it "matches jq.test case #{index + 1}: #{test_case.fetch(:program)}" do
      expected = OfficialCompat.expected_values(test_case.fetch(:expected))
      actual = OfficialCompat.run_case(test_case.fetch(:program), test_case.fetch(:input))

      expect(OfficialCompat.match_values?(expected, actual)).to be(true)
    end
  end

  OfficialCompat.failure_cases(path).each_with_index do |test_case, index|
    it "rejects jq.test %%FAIL case #{index + 1}: #{test_case.fetch(:program)}" do
      expect { OfficialCompat.run_failure_case(test_case.fetch(:program)) }
        .to raise_error(Rjq::Error)
    end
  end
end
