# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Rjq::Lexer do
  it 'tokenizes common jq syntax' do
    tokens = described_class.new('.foo[] | select(. > 1)').tokenize
    expect(tokens.map(&:type)).to include(:dot, :identifier, :lbracket, :rbracket, :pipe)
  end

  it 'keeps interpolated string segments' do
    token = described_class.new('"hi \\(.name)"').tokenize.first
    expect(token.value).to eq([[:text, 'hi '], [:expr, '.name']])
  end

  it 'keeps negative zero number literals' do
    value = described_class.new('-0').tokenize.first.value

    expect(value).to eq(0.0)
    expect(1.0 / value).to eq(-Float::INFINITY)
  end

  it 'rejects comments unless enabled' do
    expect { described_class.new('# nope').tokenize }.to raise_error(Rjq::ParseError)
    expect(described_class.new("# ok\n.", allow_comments: true).tokenize.map(&:type)).to include(:dot)
  end
end
