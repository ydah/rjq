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

  it 'keeps generators lazy and removes fixed iteration cutoffs' do
    expect(described_class.run('first(range(0; 1000000000000))', nil).to_a).to eq([0])
    expect(described_class.run('nth(0; (1, error("not reached")))', nil).to_a).to eq([1])
    expect(described_class.run('[nth((0,2); (0,1,2,error("not reached")))]', nil).to_a).to eq([[0, 2]])
    expect(described_class.run('limit(2; recurse(1, error("not reached")))', nil).to_a).to eq([nil, 1])
    expect(described_class.run('limit(5; repeat(. + 1))', nil).to_a).to eq([1, 1, 1, 1, 1])
    expect(described_class.run('while(. < 3; . + 1, . + 2)', nil).to_a).to eq([nil, 1, 2, 2])
    expect(described_class.run('until(. >= 3; . + 1, . + 2)', nil).to_a).to eq([3, 4, 3, 3, 4])
  end

  it 'preserves recurse condition branches and delayed errors' do
    filter = '[recurse(if . < 2 then . + 1 else empty end; (true, true))]'
    expect(described_class.run(filter, 0).to_a).to eq([[0, 1, 2, 2, 1, 2, 2]])

    filter = 'try [recurse(if . < 1 then . + 1 else empty end; (true, error("condition boom")))] catch .'
    expect(described_class.run(filter, 0).to_a).to eq(['condition boom'])
  end

  it 'emits selected nth values before a later generated-index error' do
    values = []
    output = described_class.run('nth((0, error("index boom")); (1, error("source boom")))', nil)

    expect { output.each { |value| values << value } }.to raise_error(Rjq::ErrorValue, 'index boom')
    expect(values).to eq([1])
  end

  it 'distinguishes nth index access from nth filter selection' do
    filter = '[0,1,2] | [nth(-0.1), nth(-1.1), nth(1.9), nth(3), nth(-4)]'
    expect(described_class.run(filter, nil).to_a).to eq([[0, 2, 1, nil, nil]])
    expect(described_class.run('[] | nth(0)', nil).to_a).to eq([nil])
    expect(described_class.run('{"a":1} | nth("a")', nil).to_a).to eq([1])

    values = []
    output = described_class.run('nth((0, -0.1); (10, error("source boom")))', nil)
    expect { output.each { |value| values << value } }
      .to raise_error(Rjq::RuntimeError, "nth doesn't support negative indices")
    expect(values).to eq([10])
  end

  it 'traverses deeply nested values without Ruby recursion' do
    nested = 0
    10_000.times { nested = [nested] }

    expect(described_class.run('recurse', nested).to_a.length).to eq(10_001)
    expect(described_class.run('leaf_paths', nested).to_a).to eq([[0] * 10_000])
  end


  it 'streams deeply nested values without Ruby recursion' do
    nested = 0
    2_000.times { nested = [nested] }

    events = described_class.run('tostream', nested).to_a

    expect(events.first).to eq([[0] * 2_000, 0])
    expect(events.last).to eq([[0]])
    expect(events.length).to eq(2_001)
  end

  it 'lets try/catch handle builtin runtime errors' do
    expect(described_class.run('try flatten(-1) catch .', nil).to_a).to eq(['flatten depth must not be negative'])
    expect(described_class.run('try nth(-1; [1]) catch .', nil).to_a).to eq(["nth doesn't support negative indices"])
    expect(described_class.run('try input catch .', nil).to_a).to eq(['break'])
    expect(described_class.run('try ([1] | pick(.[-2])) catch .', nil).to_a)
      .to eq(['Out of bounds negative array index'])
  end

  it 'preserves partial output and then propagates top-level error' do
    output = described_class.run('1, error("x")', nil)

    expect { output.to_a }.to raise_error(Rjq::ErrorValue, 'x')
    yielded = []
    expect { output.each { |value| yielded << value } }.to raise_error(Rjq::ErrorValue, 'x')
    expect(yielded).to eq([1])
  end

  it 'supports an optional output budget for embedded callers' do
    output = described_class.run('range(5)', nil, max_outputs: 2)
    yielded = []

    expect { output.each { |value| yielded << value } }
      .to raise_error(Rjq::RuntimeError, /output limit exceeded/)
    expect(yielded).to eq([0, 1])
  end

  it 'does not let try or optional catch halt signals' do
    expect { described_class.run('try halt catch "caught"', nil).to_a }
      .to raise_error(Rjq::HaltError) { |error| expect(error.status).to eq(0) }
    expect { described_class.run('halt_error(7)?', nil).to_a }
      .to raise_error(Rjq::HaltError) { |error| expect(error.status).to eq(7) }
  end

  it 'accepts comments and keyword field names while rejecting a trailing dot' do
    expect(described_class.run('. # comment', 1).to_a).to eq([1])
    expect(described_class.run('.null, .true, .module',
                               { 'null' => 1, 'true' => 2, 'module' => 3 }).to_a).to eq([1, 2, 3])
    expect { described_class.compile('.foo.') }.to raise_error(Rjq::ParseError)
  end

  it 'does not rewrite module keywords or namespace syntax in strings and comments' do
    expect(described_class.run('"module", "import", "$foo::bar"', nil).to_a)
      .to eq(['module', 'import', '$foo::bar'])
    expect(described_class.run("# include \"a\";\n.", 1).to_a).to eq([1])
  end

  it 'rejects malformed module directives instead of treating them as identity' do
    expect { described_class.compile('include 1; .') }
      .to raise_error(Rjq::ParseError, /expected string/)
    expect { described_class.compile('include "a"') }
      .to raise_error(Rjq::ParseError, /expected semicolon/)
  end

  it 'treats interpolated quoted fields as dynamic indices' do
    expect(described_class.run('."a\(1, 2)"', { 'a1' => 1, 'a2' => 2 }).to_a).to eq([1, 2])
  end

  it 'rejects unknown functions and invalid builtin arities during compilation' do
    expect { described_class.compile('does_not_exist') }
      .to raise_error(Rjq::CompileError, 'does_not_exist/0 is not defined')
    expect { described_class.compile('length(1)') }
      .to raise_error(Rjq::CompileError, 'length/1 is not defined')
    expect { described_class.compile('pow(2)') }
      .to raise_error(Rjq::CompileError, 'pow/1 is not defined')
  end

  it 'reports builtin names with their declared arities' do
    names = described_class.run('builtins', nil).to_a.fetch(0)

    expect(names).to include('halt/0', 'input/0', 'pow/2', 'fma/3', 'JOIN/4', 'error/0', 'halt_error/0',
                             'first/1', 'last/1', 'bsearch/1', 'capture/2', 'format/1', 'copysign/2',
                             'erf/0', 'finites/0', 'get_search_list/0', 'jn/2', 'nextafter/2')
    expect(names).not_to include('halt/1', 'pow/1')
  end

  it 'does not read stdin for null input unless input builtins are used' do
    io = Class.new do
      def read
        raise 'stdin was read'
      end
    end.new

    expect(described_class.run_stream('.', io: io, opts: { null_input: true }).to_a).to eq([nil])
  end

  it 'stops reading inputs when a downstream filter has enough values' do
    io_class = Class.new(StringIO) do
      attr_reader :reads

      def initialize(content)
        super
        @reads = 0
      end

      def read(length = nil, buffer = nil)
        @reads += 1
        super
      end
    end
    io = io_class.new("1 2 3 4 5")

    result = described_class.run_stream('first(inputs)', io: io,
                                                         opts: { null_input: true, input_chunk_size: 2 }).to_a

    expect(result).to eq([1])
    expect(io.pos).to be < io.size
  end

  it 'closes owned input streams when a consumer stops early' do
    io = StringIO.new("1\n2\n")
    runtime = Rjq::Runtime.new('.')

    expect(runtime.run_io_streams([[io, 'input.json', true]]).take(1)).to eq([1])
    expect(io).to be_closed
  end

  it 'orders NaN like jq comparisons and sorting' do
    result = described_class.run(
      '[nan < 1, 1 > nan, ([nan,1] | sort | map(isnan)), ([nan,1] | min | isnan), ([nan,1] | max)]',
      nil
    ).to_a

    expect(result).to eq([[true, true, [true, false], true, 1]])
  end

  it 'implements jq math filtering, rounding, and domain semantics' do
    result = described_class.run(
      '[fmax(nan;2), fmin(nan;2), fdim(-3;2), fdim(5;2), fmod(5.3;2), remainder(5.3;2),' \
      ' nextafter(1;2), nexttoward(2;1), copysign(2;-0), hypot(3;4)]', nil
    ).to_a.first

    expect(result).to eq([2, 2, 0, 3, 1.2999999999999998, -0.7000000000000002,
                          1.0000000000000002, 1.9999999999999998, -2, 5])
    expect(described_class.run('[(-1|sqrt|isnan), (0|isfinite), (infinite|isfinite),' \
                               ' (0|normals), (1|normals), (infinite|finites), (1|finites)]', nil).to_a)
      .to eq([[true, true, false, 1, 1]])
    expect(described_class.run('[(0.5|nearbyint),(1.5|nearbyint),(2.5|nearbyint),(-0.5|rint)]', nil).to_a)
      .to eq([[0, 2, 2, -0.0]])
  end

  it 'keeps date conversion independent of the host timezone' do
    expect(described_class.run('[0 | gmtime | mktime]', nil).to_a).to eq([[0]])
    expect(described_class.run('"2015-03-05T23:51:47Z" | strptime("%Y-%m-%dT%H:%M:%SZ")', nil).to_a)
      .to eq([[2015, 2, 5, 23, 51, 47, 4, 63]])
  end

  it 'supports jq format validation and two-argument capture' do
    expect(described_class.run('["a",1,true,null] | [format("csv"), format("tsv"), format("sh")]', nil).to_a)
      .to eq([['"a",1,true,', "a\t1\ttrue\t", "'a' 1 true null"]])
    expect(described_class.run('"Ab" | capture("(?<x>a)"; "i")', nil).to_a).to eq([{ 'x' => 'A' }])
    expect(described_class.run('[("a\nb"|test("a.b";"m")), ("a\nb"|test("a.b";"s"))]', nil).to_a)
      .to eq([[true, false]])
    expect { described_class.run('"a" | test("a";"z")', nil).to_a }
      .to raise_error(Rjq::RuntimeError, /unsupported regular expression flag/)
    expect { described_class.run('[{}] | @csv', nil).to_a }
      .to raise_error(Rjq::TypeError, /not valid in a csv row/)
  end

  it 'preserves generated regex replacements and validates base64 input' do
    expect(described_class.run('"a" | sub("a"; ["x","y"][])', nil).to_a).to eq(%w[x y])
    expect(described_class.run('"ab" | gsub("(?<x>.)"; [.x|ascii_upcase,ascii_downcase][])', nil).to_a)
      .to eq(%w[AB ab])
    expect(described_class.run('try ("@@" | @base64d) catch .', nil).to_a)
      .to eq(['string ("@@") is not valid base64 data'])
  end

  it 'matches fractional stream counts and edge-case collection builtins' do
    expect(described_class.run('[nth(1.9;range(5)),limit(1.9;range(5))]', nil).to_a).to eq([[2, 0, 1]])
    expect(described_class.run('[1,2] | combinations(-1)', nil).to_a).to eq([[]])
    expect(described_class.run('"abc" | [indices("")]', nil).to_a).to eq([[[]]])
    expect(described_class.run('[[infinite],[-infinite],[-1],[1114112],[55296]] | map(implode)', nil).to_a)
      .to eq([["�", "�", "�", "�", "�"]])
  end

  it 'reports program origins and the configured module search list' do
    opts = { source_path: '/tmp/filter.jq', library_path: ['lib'] }
    origins = described_class.run('[get_jq_origin, get_prog_origin, get_search_list]', nil, opts).to_a.first

    expect(origins[0]).to be_a(String)
    expect(origins[1]).to eq('/tmp')
    expect(origins[2]).to eq([File.expand_path('lib')])
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

  it 'rejects non-JSON and cyclic host inputs before evaluation' do
    cyclic = []
    cyclic << cyclic

    expect { described_class.run('.', cyclic).to_a }.to raise_error(Rjq::TypeError, /cyclic JSON value/)
    expect { described_class.run('.', { answer: 42 }).to_a }
      .to raise_error(Rjq::TypeError, /object key must be a string/)
  end

  it 'runs reduce and foreach' do
    expect(described_class.run('reduce .[] as $x (0; . + $x)', [1, 2, 3]).to_a).to eq([6])
    expect(described_class.run('foreach .[] as $x (0; . + $x; .)', [1, 2, 3]).to_a).to eq([1, 3, 6])
  end

  it 'preserves all boolean, select, and builtin argument outputs' do
    expect(described_class.run('(true,false) and (true,false)', nil).to_a).to eq([true, false, false])
    expect(described_class.run('1 | select(true,true)', nil).to_a).to eq([1, 1])
    expect(described_class.run('"abc" | startswith(("a","b"))', nil).to_a).to eq([true, false])
    expect(described_class.run('[1,2] | has((0,1,2))', nil).to_a).to eq([true, true, false])
    expect(described_class.run('3 | pow((2,3); (1,2))', nil).to_a).to eq([2, 4, 3, 9])
    expect(described_class.run('@html "x\(1,2)y"', nil).to_a).to eq(%w[x1y x2y])
  end

  it 'preserves slice bound and reduce/foreach branches' do
    expect(described_class.run('.[(0,1):(2,3)]', [0, 1, 2, 3]).to_a)
      .to eq([[0, 1], [0, 1, 2], [1], [1, 2]])
    expect(described_class.run('reduce [1,2][] as $x (0,10; . + $x)', nil).to_a).to eq([3, 13])
    expect(described_class.run('foreach [1,2][] as $x (0,10; . + $x; .)', nil).to_a).to eq([1, 3, 11, 13])
  end

  it 'uses slice components for paths and assignments' do
    input = [0, 1, 2, 3]
    expect(described_class.run('path(.[(0,1):(2,3)])', input).to_a).to eq(
      [
        [{ 'start' => 0, 'end' => 2 }], [{ 'start' => 0, 'end' => 3 }],
        [{ 'start' => 1, 'end' => 2 }], [{ 'start' => 1, 'end' => 3 }]
      ]
    )
    expect(described_class.run('.[(0,1):(2,3)] = [9]', input).to_a).to eq([[9, 9]])
    expect(described_class.run('setpath([{start:1,end:3}]; [9])', input).to_a).to eq([[0, 9, 3]])
  end

  it 'maps object values and removes empty map_values results' do
    expect(described_class.run('map(.+1)', { 'a' => 1, 'b' => 2 }).to_a).to eq([[2, 3]])
    expect(described_class.run('map_values(empty)', [1, 2]).to_a).to eq([[]])
    expect(described_class.run('map_values(if . == 1 then empty else . + 1 end)',
                               { 'a' => 1, 'b' => 2 }).to_a).to eq([{ 'b' => 3 }])
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

  it 'truncates a filtered stream lazily using the input depth' do
    filter = '1 | truncate_stream(([[0]], [[0,1], "a"], [[0,1]]))'

    expect(described_class.run(filter, nil).to_a).to eq([[[1], 'a'], [[1]]])
    expect(described_class.run('first(0 | truncate_stream(([[0], "a"], error("not reached"))))', nil).to_a)
      .to eq([[[0], 'a']])
    expect(described_class.run('(-1.9) | truncate_stream(([[0,1], "a"]))', nil).to_a)
      .to eq([[[0, 1], 'a']])
  end

  it 'matches jq truncate stream boundary and malformed event behavior' do
    event = [[[0], 'value']]
    expect(described_class.run('nan | truncate_stream(([[0], "value"]))', nil).to_a).to eq(event)
    expect(described_class.run('infinite | truncate_stream(([[0], "value"]))', nil).to_a).to eq([])
    expect(described_class.run('(-infinite) | truncate_stream(([[0], "value"]))', nil).to_a).to eq(event)
    expect(described_class.run('null | truncate_stream(([[0], "value"]))', nil).to_a).to eq(event)
    expect(described_class.run('"1" | truncate_stream(([[0], "value"]))', nil).to_a).to eq([])
    expect { described_class.run('false | truncate_stream(([[0], "value"]))', nil).to_a }
      .to raise_error(Rjq::TypeError, 'Array/string slice indices must be integers')

    expect(described_class.run('(-3) | truncate_stream(([[0,1], "value"]))', nil).to_a)
      .to eq([[[0, 1], 'value']])
    expect(described_class.run('1 | truncate_stream((["😀x", "value"]))', nil).to_a)
      .to eq([['x', 'value']])
    expect(described_class.run('0 | truncate_stream(([], [null], [[0], "value", "extra"]))', nil).to_a)
      .to eq([[[0], 'value', 'extra']])
  end

  it 'evaluates the truncate stream filter with null input' do
    expect(described_class.run('2 | truncate_stream(([[0,1,2], .]))', 7).to_a).to eq([[[2], nil]])
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

  it 'does not expose compatibility fixture modules in the production resolver' do
    expect { described_class.compile('include "a"; .', library_path: []) }
      .to raise_error(Rjq::CompileError, /module "a" not found/)
  end

  it 'loads data modules as variables and namespaced functions' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'data.json'), '{"x":2}')

      result = described_class.compile('import "data" as $d; [$d.x, $d::d.x]', library_path: [dir]).run(nil).to_a
      expect(result).to eq([[2, 2]])
    end
  end

  it 'resolves module dependencies relative to the importing module' do
    Dir.mktmpdir do |dir|
      nested = File.join(dir, 'nested')
      Dir.mkdir(nested)
      File.write(File.join(nested, 'dep.jq'), 'def value: 4;')
      File.write(File.join(nested, 'math.jq'), 'include "dep"; def doubled: value * 2;')

      program = described_class.compile('import "nested/math" as math; math::doubled', library_path: [dir])
      expect(program.run(nil).to_a).to eq([8])
    end
  end

  it 'rejects traversal and symlink escapes from module roots' do
    Dir.mktmpdir do |parent|
      root = File.join(parent, 'root')
      outside = File.join(parent, 'outside')
      Dir.mkdir(root)
      Dir.mkdir(outside)
      File.write(File.join(outside, 'escape.jq'), 'def escaped: true;')
      File.symlink(File.join(outside, 'escape.jq'), File.join(root, 'linked.jq'))

      expect { described_class.compile('include "../outside/escape"; .', library_path: [root]) }
        .to raise_error(Rjq::CompileError, /escapes configured library roots/)
      expect { described_class.compile('include "linked"; .', library_path: [root]) }
        .to raise_error(Rjq::CompileError, /escapes configured library roots/)
    end
  end

  it 'enforces the configured module size limit' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'large.jq'), 'def value: 123456789;')
      resolver = Rjq::ModuleResolver.new(paths: [dir], use_default_paths: false, max_bytes: 8)

      expect { described_class.compile('include "large"; value', module_resolver: resolver) }
        .to raise_error(Rjq::CompileError, /exceeds 8 byte limit/)
    end
  end

  it 'detects canonical module cycles and reports module source filenames' do
    Dir.mktmpdir do |dir|
      a_path = File.join(dir, 'a.jq')
      b_path = File.join(dir, 'b.jq')
      bad_path = File.join(dir, 'bad.jq')
      File.write(a_path, 'include "b"; def a: 1;')
      File.write(b_path, 'include "a"; def b: 2;')
      File.write(bad_path, 'def broken: ;')

      expect { described_class.compile('include "a"; .', library_path: [dir]) }
        .to raise_error(Rjq::CompileError, /circular module import/)
      expect { described_class.compile('include "bad"; .', library_path: [dir]) }
        .to raise_error(Rjq::ParseError, /#{Regexp.escape(bad_path)}/)
    end
  end

  it 'rejects non-constant metadata and unknown module metadata lookups' do
    expect { described_class.compile('module {value: now}; .') }
      .to raise_error(Rjq::CompileError, /metadata must be constant/)
    expect { described_class.run('"missing" | modulemeta', nil).to_a }
      .to raise_error(Rjq::RuntimeError, 'module not found: missing')
  end

  it 'reports module metadata for arbitrary loaded modules' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'dep.jq'), "def dep: 1;\n")
      File.write(File.join(dir, 'dep.json'), '{"data":true}')
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
