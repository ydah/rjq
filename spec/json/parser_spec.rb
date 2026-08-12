# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Rjq::JSON::Parser do
  it 'parses multiple JSON values from one stream' do
    expect(described_class.parse("{} 1\n[true]").to_a).to eq([{}, 1, [true]])
  end

  it 'keeps the original representation of large numeric literals' do
    value = described_class.parse_one("1#{'0' * 100}")
    expect(value).to be_a(Rjq::Number)
    expect(value.to_s).to eq("1#{'0' * 100}")
  end

  it 'limits number digits incrementally before numeric conversion' do
    expect(described_class.parse_one('-12.3e4', max_number_digits: 4).literal).to eq('-12.3e4')
    expect { described_class.parse_one("0\n12.3e4", max_number_digits: 3) }
      .to raise_error(Rjq::JSONParseError, /number exceeds 3 digit limit at line 2, column 6/)

    input = StringIO.new('1' * 1_000_000)
    expect { described_class.parse(input, chunk_size: 3, max_number_digits: 10).to_a }
      .to raise_error(Rjq::JSONParseError, /number exceeds 10 digit limit at line 1, column 11/)
    expect(input.pos).to be <= 12
  end

  it 'limits decoded string bytes across raw and escaped Unicode' do
    expect(described_class.parse_one('"😀"', max_string_bytes: 4)).to eq('😀')
    expect(described_class.parse_one('"\\u00e9"', max_string_bytes: 2)).to eq('é')
    expect { described_class.parse_one('"😀"', max_string_bytes: 3, chunk_size: 1) }
      .to raise_error(Rjq::JSONParseError, /string exceeds 3 byte limit at line 1, column 2/)
    expect { described_class.parse_one('{"é":1}', max_string_bytes: 1) }
      .to raise_error(Rjq::JSONParseError, /string exceeds 1 byte limit at line 1, column 3/)
  end

  it 'validates parser resource options' do
    expect { described_class.parse_one('0', max_number_digits: -1) }
      .to raise_error(ArgumentError, /max_number_digits must be a non-negative Integer or nil/)
    expect { described_class.parse_one('""', max_string_bytes: 1.5) }
      .to raise_error(ArgumentError, /max_string_bytes must be a non-negative Integer or nil/)
    expect { described_class.parse_one('null', chunk_size: 0) }
      .to raise_error(ArgumentError, /chunk_size must be a positive Integer/)
  end

  it 'rejects adjacent JSON atoms that are not separated' do
    expect { described_class.parse('1true').to_a }.to raise_error(Rjq::JSONParseError)
    expect { described_class.parse('1-2').to_a }.to raise_error(Rjq::JSONParseError)
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

  it 'can resynchronize malformed JSON text sequences' do
    errors = []
    input = "\x1e1\n\x1ex\n\x1e2\n"

    values = described_class.parse(input, seq: true, on_error: ->(message) { errors << message }).to_a

    expect(values).to eq([1, 2])
    expect(errors.length).to eq(1)
    expect(errors.first).to include('expected number')
  end

  it 'reads IO incrementally and stops when the consumer stops' do
    io = Class.new do
      attr_reader :reads

      def initialize(value)
        @io = StringIO.new(value)
        @reads = []
      end

      def read(length)
        @reads << length
        @io.read(length)
      end
    end.new("1 #{'0' * 100_000}")

    expect(described_class.parse(io, chunk_size: 2).first).to eq(1)
    expect(io.reads).to eq([2])
  end

  it 'parses UTF-8 split across chunk boundaries' do
    expect(described_class.parse(StringIO.new('"😀"'), chunk_size: 2).to_a).to eq(['😀'])
  end

  it 'parses a byte-order mark split across chunk boundaries' do
    expect(described_class.parse(StringIO.new("\xEF\xBB\xBF1".b), chunk_size: 1).to_a).to eq([1])
  end

  it 'reports invalid UTF-8 from an IO as a JSON parse error' do
    expect { described_class.parse(StringIO.new("\xFF".b), chunk_size: 1).to_a }
      .to raise_error(Rjq::JSONParseError, /invalid UTF-8/)
  end

  it 'enforces the jq-compatible container depth limit' do
    accepted = ('[' * 256) + '0' + (']' * 256)
    rejected = ('[' * 257) + '0' + (']' * 257)

    expect(described_class.parse_one(accepted)).to be_a(Array)
    expect { described_class.parse_one(rejected) }
      .to raise_error(Rjq::JSONParseError, /exceeds depth limit for parsing/)
  end
end
