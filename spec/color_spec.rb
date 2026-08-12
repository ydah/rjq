# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Rjq::Color do
  around do |example|
    original = ENV['JQ_COLORS']
    example.run
  ensure
    original.nil? ? ENV.delete('JQ_COLORS') : ENV['JQ_COLORS'] = original
  end

  it 'uses the eighth color for object keys' do
    ENV['JQ_COLORS'] = '1:2:3:4:5:6:7:8'

    colored = described_class.colorize('{"key":"value"}')

    expect(colored).to include("\e[8m\"key\"\e[0m")
    expect(colored).to include("\e[5m\"value\"\e[0m")
  end

  it 'rejects unsafe color parameters and falls back to defaults' do
    ENV['JQ_COLORS'] = '1:2:3:4:5:6:7:8mBAD'

    colored = described_class.colorize('null')

    expect(colored).to eq("\e[#{described_class::DEFAULT.first}mnull\e[0m")
  end
end
