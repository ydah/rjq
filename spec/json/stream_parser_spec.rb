# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Rjq::JSON::StreamParser do
  it 'emits events without reading the complete input' do
    io = StringIO.new('[1,2,3,4,5]')

    event = described_class.parse(io, chunk_size: 1).take(1)

    expect(event).to eq([[[0], 1]])
    expect(io.pos).to be < io.size
  end

  it 'reports and recovers from malformed JSON sequences' do
    errors = []
    input = "\x1e1\n\x1ex\n\x1e2\n"

    events = described_class.parse(input, seq: true, stream_errors: true,
                                          on_error: ->(message) { errors << message }).to_a

    expect(events.first).to eq([[], 1])
    expect(events[1].first).to include('Invalid numeric literal')
    expect(events[1].last).to eq([])
    expect(events.last).to eq([[], 2])
    expect(errors).to eq([])
  end

  it 'recovers at the next line after ordinary stream errors' do
    input = "[1, xxx, 2]\n3\n"

    events = described_class.parse(input, stream_errors: true).to_a

    expect(events).to eq([[[0], 1], ['Invalid numeric literal at line 1, column 8', [1]], [[], 3]])
  end

  it 'reports the line at which each event becomes available' do
    input = "\n\n[1,\n2]\n"

    events = described_class.parse(input, locations: true).to_a

    expect(events.map(&:value)).to eq([[[0], 1], [[1], 2], [[1]]])
    expect(events.map(&:line)).to eq([3, 4, 4])
  end

  it 'reports excessive nesting as a stream parse error' do
    input = ('[' * 257) + '0' + (']' * 257)

    event = described_class.parse(input, stream_errors: true).to_a.last

    expect(event.first).to include('Exceeds depth limit for parsing')
    expect(event.last.length).to eq(256)
  end

  it 'enforces token limits across chunks with stream paths and locations' do
    number = described_class.parse(StringIO.new('[12345]'), chunk_size: 2, stream_errors: true,
                                                                  max_number_digits: 4).to_a.last
    string = described_class.parse(StringIO.new('["😀"]'), chunk_size: 1, stream_errors: true,
                                                                  max_string_bytes: 3).to_a.last

    expect(number).to eq(['Number exceeds 4 digit limit at line 1, column 6', [0]])
    expect(string).to eq(['string exceeds 3 byte limit at line 1, column 3', [0]])
  end

  it 'raises controlled parse errors for limits when stream errors are disabled' do
    expect { described_class.parse('{"key":"value"}', max_string_bytes: 3).to_a }
      .to raise_error(Rjq::JSONParseError, /string exceeds 3 byte limit at line 1, column 12/)
    expect { described_class.parse('1.2e3', max_number_digits: 2).to_a }
      .to raise_error(Rjq::JSONParseError, /Number exceeds 2 digit limit at line 1, column 5/)
  end
end
