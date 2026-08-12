# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Rjq::Parser do
  it 'parses representative manual examples' do
    filters = [
      '.',
      '.foo.bar',
      '.[0]',
      '.[1:3]',
      '.[]',
      '.foo | .[]',
      '[range(3)]',
      '{"x": .foo}',
      'if . then 1 else 0 end',
      'def double: . * 2; double'
    ]

    expect(filters.map { |filter| described_class.new(filter).parse }).to all(be_a(Rjq::AST::Program))
  end


  it 'attaches source spans to parsed expressions and variables' do
    program = described_class.new("\n$__loc__", source_name: '/tmp/filter.jq').parse

    expect(program.body.source_span).to have_attributes(
      filename: '/tmp/filter.jq', line: 2, column: 1, start_offset: 1, end_offset: 9
    )
  end

  it 'parses leading-decimal jq number literals' do
    value = described_class.new('.00005').parse.body.value

    expect(value).to be_a(Rjq::Number)
    expect(value.literal).to eq('0.00005')
  end
end
