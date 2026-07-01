# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Rjq::JSON::Parser do
  it 'parses multiple JSON values from one stream' do
    expect(described_class.parse("{} 1\n[true]").to_a).to eq([{}, 1, [true]])
  end

  it 'keeps large integer literals as Integer' do
    value = described_class.parse_one("1#{'0' * 100}")
    expect(value).to be_a(Integer)
    expect(value.to_s).to eq("1#{'0' * 100}")
  end

  it 'keeps negative zero literals' do
    value = described_class.parse_one('-0')

    expect(value).to eq(0.0)
    expect(1.0 / value).to eq(-Float::INFINITY)
  end

  it 'decodes unicode surrogate pairs' do
    expect(described_class.parse_one('"\\uD83D\\uDE00"')).to eq('😀')
  end

  it 'rejects invalid JSON' do
    expect { described_class.parse_one('{]').to_a }.to raise_error(Rjq::JSONParseError)
  end

  it 'rejects literal tokens followed by identifier characters' do
    expect { described_class.parse('truefalse').to_a }.to raise_error(Rjq::JSONParseError)
    expect { described_class.parse('nullx').to_a }.to raise_error(Rjq::JSONParseError)
  end

  it 'keeps jq-compatible NaN payload parsing' do
    expect(described_class.parse_one('nan1234').nan?).to eq(true)
    expect { described_class.parse('nanx').to_a }.to raise_error(Rjq::JSONParseError)
  end

  it 'supports RFC 7464 record separators' do
    expect(described_class.parse("\x1e1\x1e2", seq: true).to_a).to eq([1, 2])
  end
end
