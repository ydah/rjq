# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Rjq do
  it 'runs identity, field access, pipes, and iteration' do
    expect(described_class.run('.foo | .[]', { 'foo' => [1, 2, 3] }).to_a).to eq([1, 2, 3])
  end

  it 'builds arrays from generated values' do
    expect(described_class.run('[range(3)]', nil).to_a).to eq([[0, 1, 2]])
  end

  it 'runs map/select/add builtins' do
    input = [{ 'x' => 1 }, { 'x' => 4 }, { 'x' => 7 }]
    expect(described_class.run('map(select(.x > 2) | .x) | add', input).to_a).to eq([11])
  end

  it 'lets try/catch handle builtin runtime errors' do
    expect(described_class.run('try flatten(-1) catch .', nil).to_a).to eq(['flatten depth must not be negative'])
    expect(described_class.run('try nth(-1; [1]) catch .', nil).to_a).to eq(["nth doesn't support negative indices"])
    expect(described_class.run('try input catch .', nil).to_a).to eq(['break'])
    expect(described_class.run('try ([1] | pick(.[-2])) catch .', nil).to_a)
      .to eq(['Out of bounds negative array index'])
  end

  it 'does not read stdin for null input unless input builtins are used' do
    io = Class.new do
      def read
        raise 'stdin was read'
      end
    end.new

    expect(described_class.run_stream('.', io: io, opts: { null_input: true }).to_a).to eq([nil])
  end

  it 'orders NaN like jq comparisons and sorting' do
    result = described_class.run(
      '[nan < 1, 1 > nan, ([nan,1] | sort | map(isnan)), ([nan,1] | min | isnan), ([nan,1] | max)]',
      nil
    ).to_a

    expect(result).to eq([[true, true, [true, false], true, 1]])
  end

  it 'validates getpath component types' do
    expect(described_class.run('try getpath([0]) catch .', { '0' => 'zero' }).to_a)
      .to eq(['Cannot index object with number'])
    expect(described_class.run('try getpath(["0"]) catch .', ['zero']).to_a)
      .to eq(['Cannot index array with string "0"'])
  end

  it 'validates direct index component types' do
    expect(described_class.run('try .[false] catch .', { 'false' => 1 }).to_a)
      .to eq(['Cannot index object with boolean'])
    expect(described_class.run('try .[null] catch .', { '' => 1 }).to_a)
      .to eq(['Cannot index object with null'])
    expect(described_class.run('try .["0"] catch .', [1]).to_a)
      .to eq(['Cannot index array with string "0"'])
    expect(described_class.run('try .[false] catch .', nil).to_a)
      .to eq(['Cannot index null with boolean'])
  end

  it 'evaluates object literals and string interpolation' do
    expect(described_class.run('{"message": "hi \(.name)"}', { 'name' => 'Ada' }).to_a)
      .to eq([{ 'message' => 'hi Ada' }])
  end

  it 'updates path expressions' do
    expect(described_class.run('.a += 2', { 'a' => 1 }).to_a).to eq([{ 'a' => 3 }])
    expect(described_class.run('.a |= empty', { 'a' => 1, 'b' => 2 }).to_a).to eq([{ 'b' => 2 }])
    expect(described_class.run('.a += empty', { 'a' => 1, 'b' => 2 }).to_a).to eq([])
  end

  it 'emits individual paths for path expressions' do
    expect(described_class.run('path(.a.b[])',
                               { 'a' => { 'b' => [10, 20] } }).to_a).to eq([['a', 'b', 0], ['a', 'b', 1]])
  end

  it 'uses variables supplied by the host' do
    program = described_class.compile('$x + 1')
    expect(program.run(nil, variables: { 'x' => 2 }).to_a).to eq([3])
  end

  it 'runs reduce and foreach' do
    expect(described_class.run('reduce .[] as $x (0; . + $x)', [1, 2, 3]).to_a).to eq([6])
    expect(described_class.run('foreach .[] as $x (0; . + $x; .)', [1, 2, 3]).to_a).to eq([1, 3, 6])
  end

  it 'supports structured bindings' do
    expect(described_class.run('. as {a: $a, b: $b} | $a + $b', { 'a' => 2, 'b' => 5 }).to_a).to eq([7])
    expect(described_class.run('. as [$a, $b] | $a * $b', [3, 4]).to_a).to eq([12])
    expect(described_class.run('reduce .[] as {v: $v} (0; . + $v)', [{ 'v' => 1 }, { 'v' => 2 }]).to_a).to eq([3])
  end

  it 'supports filter parameters in user functions' do
    expect(described_class.run('def twice(f): f, f; twice(.a)', { 'a' => 9 }).to_a).to eq([9, 9])
  end

  it 'supports label and break while preserving prior outputs' do
    expect(described_class.run('label $out | 1, break $out, 2', nil).to_a).to eq([1])
  end

  it 'supports stream round-trips' do
    input = { 'a' => [1, { 'b' => [] }], 'c' => {} }
    expect(described_class.run('tostream', { 'a' => [1, 2], 'b' => {} }).to_a).to eq(
      [[['a', 0], 1], [['a', 1], 2], [['a', 1]], [['b'], {}], [['b']]]
    )
    expect(described_class.run('[. | tostream] | fromstream(.[])', input).to_a).to eq([input])
  end

  it 'supports SQL-style INDEX and IN' do
    rows = [{ 'id' => 'a', 'v' => 1 }, { 'id' => 'b', 'v' => 2 }]
    expect(described_class.run('INDEX(.id)', rows).to_a).to eq([{ 'a' => rows[0], 'b' => rows[1] }])
    expect(described_class.run('IN(["x", "y"])', 'y').to_a).to eq([true])
  end

  it 'supports base32 formatting' do
    expect(described_class.run('@base32 | @base32d', 'hello').to_a).to eq(['hello'])
  end

  it 'supports libm Bessel math builtins' do
    values = described_class.run('[(1 | j0), (1 | j1), (1 | y0), (1 | y1), (0 | y0)]', nil).to_a.fetch(0)

    expect(values[0]).to be_within(1e-15).of(0.7651976865579666)
    expect(values[1]).to be_within(1e-15).of(0.4400505857449335)
    expect(values[2]).to be_within(1e-15).of(0.08825696421567697)
    expect(values[3]).to be_within(1e-15).of(-0.7812128213002887)
    expect(values[4]).to eq(-Float::INFINITY)
  end

  it 'loads included and imported modules' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'math.jq'), "def inc: . + 1;\ndef twice(f): f, f;\n")

      expect(described_class.compile('include "math"; inc', library_path: [dir]).run(1).to_a).to eq([2])
      expect(described_class.compile('import "math" as math; math::twice(.a)',
                                     library_path: [dir]).run({ 'a' => 3 }).to_a).to eq([3, 3])
    end
  end

  it 'reports module metadata for arbitrary loaded modules' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'dep.jq'), "def dep: 1;\n")
      File.write(File.join(dir, 'meta.jq'), <<~JQ)
        module {whatever: "ok", version: 2, nested: {items: [true, null]}};
        include "dep" {search: "./"};
        import "dep" as dep_alias;
        import "dep" as $dep_data;
        def alpha: dep;
        def beta(x; $y): x + $y;
      JQ

      metadata = described_class.compile('import "meta" as meta; modulemeta',
                                         library_path: [dir]).run('meta').to_a.first

      expect(metadata).to include('whatever' => 'ok', 'version' => 2)
      expect(metadata).to include('nested' => { 'items' => [true, nil] })
      expect(metadata.fetch('deps')).to eq(
        [
          { 'is_data' => false, 'relpath' => 'dep', 'search' => './', 'as' => 'dep' },
          { 'is_data' => false, 'relpath' => 'dep', 'as' => 'dep_alias' },
          { 'is_data' => true, 'relpath' => 'dep', 'as' => 'dep_data' }
        ]
      )
      expect(metadata.fetch('defs')).to eq(['alpha/0', 'beta/2'])
    end
  end
end
