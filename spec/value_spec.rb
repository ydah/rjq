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

  it 'deep-copies strings and deeply nested containers without recursion' do
    string = +'value'
    value = string
    10_000.times { value = [value] }

    copy = described_class.deep_copy(value)
    original_leaf = value
    copied_leaf = copy
    10_000.times do
      original_leaf = original_leaf.first
      copied_leaf = copied_leaf.first
    end

    expect(copied_leaf).to eq('value')
    expect(copied_leaf).not_to equal(original_leaf)
  end

  it 'rejects cyclic values and non-JSON object keys during copying' do
    cyclic = {}
    cyclic['self'] = cyclic

    expect { described_class.deep_copy(cyclic) }.to raise_error(Rjq::TypeError, /cyclic JSON value/)
    expect { described_class.deep_copy({ answer: 42 }) }.to raise_error(Rjq::TypeError, /object key must be a string/)
  end
end
