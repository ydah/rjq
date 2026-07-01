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
end
