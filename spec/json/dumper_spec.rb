# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Rjq::JSON::Dumper do
  it 'dumps pretty JSON with sorted keys' do
    expect(described_class.dump({ 'b' => 1, 'a' => [true, nil] }, sort_keys: true)).to eq(<<~JSON.chomp)
      {
        "a": [
          true,
          null
        ],
        "b": 1
      }
    JSON
  end

  it 'dumps compact JSON' do
    expect(described_class.dump({ 'a' => 1 }, indent: nil)).to eq('{"a":1}')
  end

  it 'escapes non-ASCII characters when requested' do
    expect(described_class.dump('😀', ascii: true)).to eq('"\\ud83d\\ude00"')
  end

  it 'formats floats using a jq-like shortest form' do
    expect(described_class.dump(1.0)).to eq('1')
    expect(described_class.dump(0.1)).to eq('0.1')
  end

  it 'formats non-finite floats like jq' do
    expect(described_class.dump([Float::INFINITY, -Float::INFINITY, Float::NAN, -0.0], indent: nil))
      .to eq('[1.7976931348623157e+308,-1.7976931348623157e+308,null,-0]')
  end

  it 'preserves untouched decimal literals and normalizes their exponent' do
    expect(described_class.dump(Rjq::Number.parse('1.000'))).to eq('1.000')
    expect(described_class.dump(Rjq::Number.parse('1e100'))).to eq('1E+100')
    expect(described_class.dump(Rjq::Number.parse('123.4e-3'))).to eq('0.1234')
  end

  it 'uses exponential notation for large computed floats' do
    expect(described_class.dump(1e16)).to eq('1e+16')
    expect(described_class.dump(1e100)).to eq('1e+100')
  end

  it 'writes directly to an IO' do
    io = StringIO.new

    expect(described_class.dump({ 'a' => [1, 2] }, indent: nil, io: io)).to equal(io)
    expect(io.string).to eq('{"a":[1,2]}')
  end

  it 'dumps deeply nested arrays without Ruby recursion' do
    value = 0
    10_000.times { value = [value] }

    dumped = described_class.dump(value, indent: nil)

    expect(dumped.length).to eq(20_001)
    expect(dumped).to start_with('[[[[')
    expect(dumped).to end_with(']]]]')
  end

  it 'rejects cyclic values and non-string object keys' do
    cyclic = []
    cyclic << cyclic

    expect { described_class.dump(cyclic) }.to raise_error(Rjq::TypeError, /cyclic JSON value/)
    expect { described_class.dump({ answer: 42 }) }.to raise_error(Rjq::TypeError, /object key must be a string/)
  end

  it 'rejects invalid UTF-8 strings as runtime errors' do
    expect { described_class.dump("\xFF".b) }.to raise_error(Rjq::TypeError, /invalid UTF-8/)
  end
end
