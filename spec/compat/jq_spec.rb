# frozen_string_literal: true

require 'spec_helper'
require 'support/official_compat'

RSpec.describe 'jq.test compatibility' do
  path = File.expand_path('../fixtures/jq/jq.test', __dir__)

  it 'keeps exact expected decimal tokens independent of binary floats' do
    exact = OfficialCompat.expected_values(['0.10000000000000001', '1e401'])

    expect(OfficialCompat.match_values?(exact, [Rjq::Number.parse('0.1'), Rjq::Number.parse('1e400')])).to be(false)
    expect(OfficialCompat.match_values?(exact, [0.1, Float::INFINITY])).to be(true)
    expect(OfficialCompat.match_values?([9_007_199_254_740_993], [9_007_199_254_740_992.0])).to be(true)
    expect(OfficialCompat.match_values?(OfficialCompat.expected_values(['1.0']), [1])).to be(true)
    expect(OfficialCompat.match_values?([Float::NAN], [Float::NAN])).to be(false)
  end

  it 'compares nested fixture structures without using rjq equality' do
    expected = OfficialCompat.expected_values(['{"a":[1,2.0]}'])

    expect(OfficialCompat.match_values?(expected, [{ 'a' => [1, 2] }])).to be(true)
    expect(OfficialCompat.match_values?([[]], [{}])).to be(false)
    expect(OfficialCompat.match_values?([{ 'a' => 1 }], [{ 'b' => 1 }])).to be(false)
  end

  it 'parses fixture integer inputs with jq numeric precision' do
    parsed = OfficialCompat.convert_fixture_numbers(OfficialCompat.parse_fixture_input('-9007199254740993'))

    expect(parsed).to be_a(Rjq::Number)
    expect(Rjq.run('abs', parsed).to_a).to eq([9_007_199_254_740_992.0])
  end

  it 'normalizes fixture infinities to jq JSON limits' do
    positive = OfficialCompat.convert_fixture_numbers(OfficialCompat.parse_fixture_input('Infinity'))
    negative = OfficialCompat.convert_fixture_numbers(OfficialCompat.parse_fixture_input('-Infinity'))

    expect([positive, negative]).to eq([Float::MAX, -Float::MAX])
    expect(OfficialCompat.expected_values(['Infinity', '-Infinity'])).to eq([Float::MAX, -Float::MAX])
    expect(OfficialCompat.match_values?([Float::MAX], [Rjq::Number.parse('1e400')])).to be(false)
  end

  OfficialCompat.runnable_cases(path).each_with_index do |test_case, index|
    it "matches jq.test case #{index + 1}: #{test_case.fetch(:program)}" do
      expected = OfficialCompat.expected_values(test_case.fetch(:expected))
      observation = OfficialCompat.observe_case(test_case.fetch(:program), test_case.fetch(:input))

      expect(OfficialCompat.match_values?(expected, observation.outputs)).to be(true)
      if test_case.fetch(:runtime_error)
        expect(observation.error).to be_a(Rjq::RuntimeError)
        expect(observation.error.message).to eq(test_case.fetch(:runtime_error))
      else
        expect(observation.error).to be_nil
      end
    end
  end

  OfficialCompat.failure_cases(path).each_with_index do |test_case, index|
    it "rejects jq.test %%FAIL case #{index + 1}: #{test_case.fetch(:program)}" do
      expected_category = OfficialCompat.failure_category(test_case.fetch(:expected_error))
      expect(expected_category).not_to eq(:unknown)
      expect { OfficialCompat.run_failure_case(test_case.fetch(:program)) }
        .to raise_error(Rjq::Error) do |error|
          expect(OfficialCompat.compile_failure?(error)).to be(true)
          expect(OfficialCompat.error_category(error)).to eq(expected_category)
        end
    end
  end
end
