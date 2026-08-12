# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Rjq::Value do
  it 'returns jq type names' do
    expect(described_class.type_of(nil)).to eq('null')
    expect(described_class.type_of(false)).to eq('boolean')
    expect(described_class.type_of(1)).to eq('number')
    expect(described_class.type_of('x')).to eq('string')
    expect(described_class.type_of([])).to eq('array')
    expect(described_class.type_of({})).to eq('object')
  end

  it 'compares values in jq type order' do
    values = [nil, false, true, 1, 'a', [], {}]
    expect(values.each_cons(2).all? { |a, b| described_class.compare(a, b).negative? }).to be(true)
  end

  it 'uses jq-style equality for nested numeric values' do
    expect(described_class.equal?(1, 1.0)).to be(true)
    expect(described_class.equal?([1], [1.0])).to be(true)
    expect(described_class.equal?({ 'a' => 1 }, { 'a' => 1.0 })).to be(true)
  end

  it 'compares untouched large literals exactly and keeps comparison consistent with equality' do
    left = Rjq::Number.parse('13911860366432393')
    right = Rjq::Number.parse('13911860366432392')

    expect(described_class.equal?(left, right)).to be(false)
    expect(described_class.compare(left, right)).to be_positive
    expect(described_class.equal?(left, right)).to eq(described_class.compare(left, right).zero?)
  end

  it 'treats only null and false as falsey' do
    expect(described_class.truthy?(nil)).to be(false)
    expect(described_class.truthy?(false)).to be(false)
    expect(described_class.truthy?(0)).to be(true)
    expect(described_class.truthy?('')).to be(true)
  end
end
