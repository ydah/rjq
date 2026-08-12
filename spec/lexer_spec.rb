# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Rjq::Lexer do
  it 'tokenizes common jq syntax' do
    tokens = described_class.new('.foo[] | select(. > 1)').tokenize
    expect(tokens.map(&:type)).to include(:dot, :identifier, :lbracket, :rbracket, :pipe)
    expect(tokens.first).to have_attributes(start_offset: 0, end_offset: 1, filename: '<top-level>')
  end

  it 'keeps interpolated string segments' do
    token = described_class.new('"hi \\(.name)"').tokenize.first
    expect(token.value.first).to eq([:text, 'hi '])
    kind, fragment = token.value.last
    expect(kind).to eq(:expr)
    expect(fragment).to have_attributes(source: '.name', filename: '<top-level>', line: 1, column: 7,
                                        start_offset: 6)
  end

  it 'ignores interpolation delimiters and quotes inside comments' do
    source = %Q{"x\\(1 # ) ( \"\n)"}
    fragment = described_class.new(source).tokenize.first.value.last.last

    expect(fragment.source).to eq("1 # ) ( \"\n")
  end

  it 'scans nested interpolation structurally inside quoted strings' do
    source = %q{"outer \("a \("x \(2) ( )") b")"}
    fragment = described_class.new(source).tokenize.first.value.last.last

    expect(fragment.source).to eq(%q{"a \("x \(2) ( )") b"})
  end

  it 'tokenizes negative zero as unary minus and a number literal' do
    tokens = described_class.new('-0').tokenize

    expect(tokens.first).to have_attributes(type: :operator, value: '-')
    expect(tokens[1]).to have_attributes(type: :number, value: 0)
  end

  it 'accepts comments by default and can disable them explicitly' do
    expect(described_class.new("# ok\n.").tokenize.map(&:type)).to include(:dot)
    expect { described_class.new('# nope', allow_comments: false).tokenize }.to raise_error(Rjq::ParseError)
  end
end
