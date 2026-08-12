# frozen_string_literal: true

require 'spec_helper'
require_relative '../support/differential_compat'

RSpec.describe 'jq 1.7.1 differential compatibility' do
  before do
    skip 'jq 1.7.1 is not available; set JQ_BIN to the pinned oracle' unless DifferentialCompat.jq_1_7_1?
  end

  DifferentialCompat::CASES.each do |test_case|
    it "matches #{test_case.name}" do
      oracle = DifferentialCompat.observe_jq(test_case)
      actual = DifferentialCompat.observe_rjq(test_case)

      expect(actual.stderr).to eq(oracle.stderr)
      expect(actual.status).to eq(oracle.status)
      if test_case.deviation
        expect(test_case.deviation.reason).not_to be_empty
        expect(actual.stdout).to eq(test_case.deviation.rjq_stdout)
        expect(actual.stdout).not_to eq(oracle.stdout)
      else
        expect(actual.stdout).to eq(oracle.stdout)
        expect(actual.outputs).to eq(oracle.outputs)
      end
    end
  end
end
