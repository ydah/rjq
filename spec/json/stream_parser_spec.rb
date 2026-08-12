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

  it 'reports excessive nesting as a stream parse error' do
    input = ('[' * 257) + '0' + (']' * 257)

    event = described_class.parse(input, stream_errors: true).to_a.last

    expect(event.first).to include('Exceeds depth limit for parsing')
    expect(event.last.length).to eq(256)
  end
end
