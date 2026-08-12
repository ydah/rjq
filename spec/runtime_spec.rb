# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Rjq do
  it 'preserves exact nonnegative number literals and negative zero through abs' do
    source = '[0.1,9007199254740993,-9007199254740993,-0]'
    values = Rjq::JSON::Parser.parse_one(source)
    result = described_class.run('map(abs)', values).first

    expect(Rjq::JSON::Dumper.dump(result, indent: nil))
      .to eq('[0.1,9007199254740993,9007199254740992,-0]')
    expect { described_class.run('abs', nil).to_a }
      .to raise_error(Rjq::TypeError, 'null (null) cannot be negated')
    expect { described_class.run('abs', true).to_a }
      .to raise_error(Rjq::TypeError, 'boolean (true) cannot be negated')
  end

  it 'checks containment in deeply nested values without recursion' do
    container = 'needle in haystack'
    contained = 'needle'
    20_000.times do
      container = { 'child' => [container] }
      contained = { 'child' => [contained] }
    end

    expect(described_class.run('contains($needle)', container, variables: { 'needle' => contained }).to_a).to eq([true])
  end

  it 'sorts and merges deeply nested values without recursion' do
    lesser = 0
    greater = 1
    left = { 'left' => true }
    right = { 'right' => true }
    20_000.times do
      lesser = [{ 'value' => lesser }]
      greater = [{ 'value' => greater }]
      left = { 'child' => left }
      right = { 'child' => right }
    end

    expect(described_class.run('sort', [greater, lesser]).to_a).to eq([[lesser, greater]])
    merged = described_class.run('. * $right', left, variables: { 'right' => right }).to_a.fetch(0)
    20_000.times { merged = merged.fetch('child') }
    expect(merged).to eq({ 'left' => true, 'right' => true })
  end

  it 'reports multiline filter source locations independently of input locations' do
    filter = "\n$__loc__,\n$__loc__"

    expect(described_class.run(filter, nil).to_a).to eq([
      { 'file' => '<top-level>', 'line' => 2 },
      { 'file' => '<top-level>', 'line' => 3 }
    ])
  end

  it 'keeps the variable location through postfix expressions' do
    filter = "[\n$__loc__.line,\n$__loc__[\"line\"],\n($__loc__? | .line)\n]"

    expect(described_class.run(filter, nil).to_a).to eq([[2, 3, 4]])
  end

  it 'preserves outer source positions in normal and format interpolation' do
    normal = "\n\n\"x\\(\n$__loc__)\""
    formatted = "\n\n@json \"x\\(\n$__loc__)\""
    expected = 'x{"file":"/tmp/filter.jq","line":4}'

    expect(described_class.run(normal, nil, source_path: '/tmp/filter.jq').to_a).to eq([expected])
    expect(described_class.run(formatted, nil, source_path: '/tmp/filter.jq').to_a).to eq([expected])
    expect(described_class.run(%Q{"x\\(1 # comment\n)"}, nil).to_a).to eq(['x1'])
    expect { described_class.compile(%Q{"x\\(1 # comment\n)"}, allow_comments: false) }
      .to raise_error(Rjq::ParseError)
  end

  it 'ignores interpolation boundaries inside comments but preserves hashes in strings' do
    filters = [
      %Q{"x\\(1 # )\n)"},
      %Q{"x\\(1 # (\n)"},
      %Q{"x\\(1 # \"\n)"},
      %q{"x\("#)" | length)"},
      %Q{@json "x\\(1 # )\n)"}
    ]

    expect(filters.map { |filter| described_class.run(filter, nil).to_a }).to eq([
      ['x1'], ['x1'], ['x1'], ['x2'], ['x1']
    ])
    [%Q{"x\\(1 # )\n)"}, %Q{"x\\(1 # (\n)"}].each do |filter|
      expect { described_class.compile(filter, allow_comments: false) }
        .to raise_error(Rjq::ParseError, /comments are disabled/)
    end
  end

  it 'evaluates nested string interpolation with structural delimiters' do
    filters = [
      %q{"outer \("inner \((1 + 2)) end")"},
      %q{"outer \("a \("(" + ")") b")"},
      %q{"outer \("a \("x \(2)") b")"}
    ]

    expect(filters.map { |filter| described_class.run(filter, nil).to_a }).to eq([
      ['outer inner 3 end'], ['outer a () b'], ['outer a x 2 b']
    ])
  end

  it 'uses comment-aware interpolation boundaries in modules' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'commented.jq'), %Q{def value: "x\\(1 # ) ( \"\n)";\n})

      expect(described_class.run('include "commented"; value', nil, library_path: [dir]).to_a).to eq(['x1'])
      expect do
        described_class.compile('include "commented"; value', library_path: [dir], allow_comments: false)
      end.to raise_error(Rjq::ParseError, /comments are disabled/)
    end
  end

  it 'preserves module locations through definitions and interpolation' do
    Dir.mktmpdir do |dir|
      module_path = File.join(dir, 'where.jq')
      File.write(module_path, "def where:\n  [$__loc__,\n   (\"\\(\n$__loc__)\" | fromjson)];\n")

      locations = described_class.run('include "where"; where', nil, library_path: [dir]).to_a.fetch(0)

      expect(locations).to eq([
        { 'file' => File.realpath(module_path), 'line' => 2 },
        { 'file' => File.realpath(module_path), 'line' => 4 }
      ])

      disassembly = described_class.compile('include "where"; where', library_path: [dir]).disasm
      expect(disassembly).to include('== definition:where/0 ==', "@ #{File.realpath(module_path)}:2:")
    end
  end

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

  it 'handles special nth filter indices without leaking host exceptions' do
    filter = '[(nan,infinite,-infinite,null,false,true,"1",[],{}) as $i | ' \
             'try [nth($i;(10,20,30))] catch .]'
    expect(described_class.run(filter, nil).to_a).to eq([[
      "nth doesn't support negative indices", [], "nth doesn't support negative indices",
      "nth doesn't support negative indices", "nth doesn't support negative indices",
      "nth doesn't support negative indices", 'string ("1") and number (1) cannot be added',
      'array ([]) and number (1) cannot be added', 'object ({}) and number (1) cannot be added'
    ]])

    expect { described_class.run('nth(nan; 1)', nil).to_a }
      .to raise_error(Rjq::RuntimeError, "nth doesn't support negative indices")
    expect(described_class.run('[nth(infinite; (1,2,3))]', nil).to_a).to eq([[]])
    expect(described_class.run('try nth(infinite; error("reached")) catch .', nil).to_a).to eq(['reached'])
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

  it 'validates public runtime and compiler options before compiling' do
    expect { Rjq::Runtime.new('.', typo_option: true) }
      .to raise_error(ArgumentError, /unknown runtime option: :typo_option/)
    expect { described_class.run('.', nil, max_outputs: -1) }
      .to raise_error(ArgumentError, /max_outputs must be an Integer at least 0/)
    expect { described_class.run('.', nil, input_chunk_size: 0) }
      .to raise_error(ArgumentError, /input_chunk_size must be an Integer at least 1/)
    expect { described_class.run('.', nil, input_max_depth: 1.5) }
      .to raise_error(ArgumentError, /input_max_depth must be an Integer/)
    expect { described_class.run('.', nil, regexp_timeout: Float::NAN) }
      .to raise_error(ArgumentError, /regexp_timeout must be a finite positive number or nil/)
    expect { described_class.run('.', nil, max_call_depth: 0) }
      .to raise_error(ArgumentError, /max_call_depth must be an Integer at least 1/)
    expect { described_class.run('.', nil, max_call_depth: nil) }.not_to raise_error
    expect { described_class.run('.', nil, max_instructions: -1) }
      .to raise_error(ArgumentError, /max_instructions must be an Integer at least 0/)
    expect { described_class.run('.', nil, max_replay_cache: -1) }
      .to raise_error(ArgumentError, /max_replay_cache must be an Integer at least 0/)
    expect { described_class.run('.', nil, variables: []) }
      .to raise_error(ArgumentError, /variables must be a Hash/)
    expect { described_class.run('.', nil, instruction_budget: Object.new) }
      .to raise_error(ArgumentError, /unknown runtime option: :instruction_budget/)

    expect { Rjq::Compiler.new(compact: true) }
      .to raise_error(ArgumentError, /unknown compiler option: :compact/)
    expect { described_class.compile('.', allow_comments: nil) }
      .to raise_error(ArgumentError, /allow_comments must be true or false/)
    expect { described_class.compile('.', library_path: ['ok', 1]) }
      .to raise_error(ArgumentError, /library_path must be an Array of Strings/)
    expect { described_class.compile('.', max_filter_depth: 0) }
      .to raise_error(ArgumentError, /max_filter_depth must be a positive Integer/)

    program = described_class.compile('$x')
    expect { program.run(nil, typo_option: true) }
      .to raise_error(ArgumentError, /unknown runtime option: :typo_option/)
    variables = { 'x' => 1 }
    output = program.run(nil, variables: variables, stderr: nil)
    variables['x'] = 2
    expect(output.to_a).to eq([1])
    expect { described_class.compile('.', module_resolver: nil) }.not_to raise_error
  end

  it 'rejects excessive filter nesting as a controlled compile error' do
    parentheses = ('(' * 80) + '.' + (')' * 80)
    conditionals = ('if true then ' * 80) + '.' + (' else . end' * 80)
    scoped_functions = '(' + ('def f: .; ' * 80) + '.)'
    module_metadata = 'module {"x":' + ('[' * 80) + '0' + (']' * 80) + '}; .'

    [parentheses, conditionals, scoped_functions, module_metadata].each do |filter|
      expect { described_class.compile(filter, max_filter_depth: 32) }
        .to raise_error(Rjq::ParseError, /filter nesting exceeds 32/)
    end

    unsafe_parentheses = ('(' * 5000) + '.' + (')' * 5000)
    expect { described_class.compile(unsafe_parentheses, max_filter_depth: 100_000) }
      .to raise_error(Rjq::CompileError, /filter nesting exceeds safe parser\/compiler depth/)
  end

  it 'trampolines tail-recursive user functions while bounding non-tail calls' do
    windows_host = RbConfig::CONFIG.fetch('host_os').match?(/mswin|mingw|cygwin/)
    skip 'Ruby for Windows has insufficient host stack for the tail-recursion stress case' if windows_host

    tail_depth = 5000
    tail_recursive = "def count: if . > 0 then . - 1 | count else . end; #{tail_depth} | count"
    branching = 'def walk: if . > 0 then (. - 1, . - 2) | walk else . end; 3 | walk'
    non_tail = 'def count: if . > 0 then (. - 1 | count) + 1 else . end; 500 | count'
    compiled = described_class.compile(tail_recursive)

    expect(compiled.run(nil).to_a).to eq([0.0])
    expect(compiled.run(nil).to_a).to eq([0.0])
    expect(described_class.run(branching, nil).to_a).to eq([0.0, -1.0, 0.0, 0.0, -1.0])
    forwarded_filter = "def count(g): if . > 0 then . - 1 | count(g) else g end; #{tail_depth} | count((., . + 10))"
    expect(described_class.run(forwarded_filter, nil).to_a).to eq([0.0, 10.0])
    path_recursion = 'def descend: if length > 0 then .[0] | descend else . end; ' \
                     'reduce range(0;200) as $i ([]; [.]) | descend = 1 | 1'
    expect(described_class.run(path_recursion, nil).to_a).to eq([1])
    expect { described_class.run(non_tail, nil, max_call_depth: 32).to_a }
      .to raise_error(Rjq::ResourceLimitError, 'call depth limit exceeded (32)')
    expect { described_class.run("try (#{non_tail}) catch .", nil, max_call_depth: 32).to_a }
      .to raise_error(Rjq::ResourceLimitError, 'call depth limit exceeded (32)')
  end

  it 'counts only bytecode instructions demanded by the consumer' do
    compiled = described_class.compile('1, 2')

    expect(compiled.run(nil, max_instructions: 2).next).to eq(1)
    expect { compiled.run(nil, max_instructions: 2).to_a }
      .to raise_error(Rjq::ResourceLimitError, 'instruction limit exceeded (2)')
    expect { described_class.run('try (1, 2) catch .', nil, max_instructions: 1).to_a }
      .to raise_error(Rjq::ResourceLimitError, 'instruction limit exceeded (1)')
    expect(compiled.run(nil, max_instructions: 3).to_a).to eq([1, 2])
    expect(compiled.run(nil, max_instructions: 3).to_a).to eq([1, 2])

    stream = StringIO.new("1\n2\n")
    expect { described_class.run_stream('.', io: stream, opts: { max_instructions: 1 }).to_a }
      .to raise_error(Rjq::ResourceLimitError, 'instruction limit exceeded (1)')
    forged = Rjq::VM::InstructionBudget.new(nil)
    expect { compiled.run(nil, max_instructions: 0, instruction_budget: forged).to_a }
      .to raise_error(ArgumentError, /unknown runtime option: :instruction_budget/)
    expect { compiled.run_with_instruction_budget(nil, { max_instructions: 0 }, forged).to_a }
      .to raise_error(ArgumentError, /instruction budget must match max_instructions/)
  end

  it 'bounds replay caches without making the limit catchable by filters' do
    filter = 'try (.[][(0,1,2)]) catch .'

    expect(described_class.run('.[][(0,1)]', [[10, 11], [20, 21]], max_replay_cache: 2).to_a)
      .to eq([10, 11, 20, 21])
    expect { described_class.run(filter, [[10, 11], [20, 21]], max_replay_cache: 2).to_a }
      .to raise_error(Rjq::ResourceLimitError, 'replay cache limit exceeded (2)')
  end

  it 'does not let try or optional catch halt signals' do
    expect { described_class.run('try halt catch "caught"', nil).to_a }
      .to raise_error(Rjq::HaltError) { |error| expect(error.status).to eq(0) }
    expect { described_class.run('halt_error(7)?', nil).to_a }
      .to raise_error(Rjq::HaltError) { |error| expect(error.status).to eq(7) }
    expect { described_class.run('"stopped" | halt_error(9)', nil).to_a }
      .to raise_error(Rjq::HaltError, 'stopped') do |error|
        expect(error.status).to eq(9)
        expect(error.value).to eq('stopped')
      end
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

  it 'keeps rjq extensions out of the jq builtin list' do
    names = described_class.run('builtins', nil).to_a.fetch(0)

    expect(names).not_to include('ascii/0', 'dateadd/1', 'datesub/1', 'leaf_paths/0', 'to_number/0',
                                 'GROUP_BY/1', 'recurse_down/0', 'true/0')
    expect(Rjq::Builtins::EXTENSION_ARITIES).to include('ascii' => [0], 'dateadd' => [1],
                                                       'leaf_paths' => [0, 1])
    expect(described_class.run('ascii', 'é').to_a).to eq(['\u00e9'])
    expect(described_class.run('0 | dateadd(1)', nil).to_a).to eq([1])
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

  it 'passes JSON token budgets to normal and streaming input parsers' do
    expect do
      described_class.run_stream('.', io: StringIO.new('1234'), opts: { max_number_digits: 3 }).to_a
    end.to raise_error(Rjq::JSONParseError, /number exceeds 3 digit limit/)
    expect do
      described_class.run_stream('.', io: StringIO.new('["abcd"]'),
                                      opts: { stream: true, max_string_bytes: 3 }).to_a
    end.to raise_error(Rjq::JSONParseError, /string exceeds 3 byte limit/)
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
    if Rjq::MathFunctions.native_available?(:remainder)
      result = described_class.run(
        '[fmax(nan;2), fmin(nan;2), fdim(-3;2), fdim(5;2), fmod(5.3;2), remainder(5.3;2),' \
        ' nextafter(1;2), nexttoward(2;1), copysign(2;-0), hypot(3;4)]', nil
      ).to_a.first

      expect(result).to eq([2, 2, 0, 3, 1.2999999999999998, -0.7000000000000002,
                            1.0000000000000002, 1.9999999999999998, -2, 5])
    else
      result = described_class.run(
        '[fmax(nan;2), fmin(nan;2), fdim(-3;2), fdim(5;2), fmod(5.3;2),' \
        ' nextafter(1;2), nexttoward(2;1), copysign(2;-0), hypot(3;4)]', nil
      ).to_a.first

      expect(result).to eq([2, 2, 0, 3, 1.2999999999999998,
                            1.0000000000000002, 1.9999999999999998, -2, 5])
      expect { described_class.run('remainder(5.3;2)', nil).to_a }
        .to raise_error(Rjq::RuntimeError, /native IEEE remainder is not available/)
    end
    expect(described_class.run('[(-1|sqrt|isnan), (0|isfinite), (infinite|isfinite),' \
                               ' (0|normals), (1|normals), (infinite|finites), (1|finites)]', nil).to_a)
      .to eq([[true, true, false, 1, 1]])
    expect(described_class.run('[(0.5|nearbyint),(1.5|nearbyint),(2.5|nearbyint),(-0.5|rint)]', nil).to_a)
      .to eq([[0, 2, 2, -0.0]])
  end

  it 'uses jq fused, IEEE remainder, and scaling semantics' do
    if Rjq::MathFunctions.native_available?(:fma)
      fused = described_class.run('[fma(1e308;1e-308;-1),(1e308*1e-308-1)]', nil).to_a.fetch(0)
      expect(fused).to eq([-7.969431103331108e-17, -1.1102230246251565e-16])
    else
      expect { described_class.run('fma(1e308;1e-308;-1)', nil).to_a }
        .to raise_error(Rjq::RuntimeError, /native fused multiply-add is not available/)
    end

    if Rjq::MathFunctions.native_available?(:remainder)
      remainders = described_class.run(
        '[drem(5.3;2),drem(-5.3;2),drem(5;2),drem(7;2),drem(6;4),drem(2;infinite),drem(-0;2)]', nil
      ).to_a.fetch(0)
      expect(remainders[0..5]).to eq([-0.7000000000000002, 0.7000000000000002, 1, -1, -2, 2])
      expect(1.0 / remainders[6]).to eq(-Float::INFINITY)
    else
      expect { described_class.run('drem(5.3;2)', nil).to_a }
        .to raise_error(Rjq::RuntimeError, /native IEEE remainder is not available/)
    end

    scaling = described_class.run(
      '[scalb(3;1.9),scalb(3;-1.9),scalbln(3;1.9),scalb(2;nan),' \
      'scalb(2;infinite),scalb(2;-infinite),scalbln(2;nan),' \
      'scalbln(2;infinite),scalbln(2;-infinite)]', nil
    ).to_a.fetch(0)
    if Rjq::MathFunctions.native_available?(:scalb) && RbConfig::CONFIG.fetch('host_os').match?(/linux/)
      expect(scaling[0]).to be_nan
      expect(scaling[1]).to be_nan
      expect(scaling[2]).to eq(6)
    else
      expect(scaling[0..2]).to eq([6, 1.5, 6])
    end
    expect(scaling[3]).to be_nan
    expected_tail = if Rjq::MathFunctions.native_available?(:scalbln) &&
                      RbConfig::CONFIG.fetch('host_os').match?(/linux/)
                      [Float::MAX, 0, 0, 0, 0]
                    else
                      [Float::MAX, 0, 2, Float::MAX, 0]
                    end
    expect(scaling[4..]).to eq(expected_tail)
  end

  it 'fails explicitly when exact native fma and remainder are unavailable' do
    allow(Rjq::MathFunctions).to receive(:native_library).and_call_original
    allow(Rjq::MathFunctions).to receive(:native_library).with(:fma).and_return(nil)
    expect { described_class.run('fma(2;3;4)', nil).to_a }
      .to raise_error(Rjq::RuntimeError, /native fused multiply-add is not available/)

    allow(Rjq::MathFunctions).to receive(:native_library).with(:scalb).and_return(nil)
    expect(described_class.run('scalb(2;3)', nil).to_a).to eq([16])

    allow(Rjq::MathFunctions).to receive(:native_library).with(:scalbln).and_return(nil)
    expect(described_class.run('scalbln(2;3)', nil).to_a).to eq([16])

    allow(Rjq::MathFunctions).to receive(:native_library).with(:remainder).and_return(nil)
    matrix = '[(1e308,-1e308,infinite,nan,0,-0) as $x | ' \
             '(1e-308,-1e-308,infinite,0) as $y | ' \
             'try drem($x;$y) catch ., try remainder($x;$y) catch .]'
    failures = described_class.run(matrix, nil).to_a.fetch(0)
    expect(failures.length).to eq(48)
    expect(failures.uniq).to eq(['native IEEE remainder is not available on this platform'])
    expect { described_class.run('drem(5.3;2)', nil).to_a }
      .to raise_error(Rjq::RuntimeError, /native IEEE remainder is not available/)
    expect { described_class.run('remainder(5.3;2)', nil).to_a }
      .to raise_error(Rjq::RuntimeError, /native IEEE remainder is not available/)
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
    flags = '"a\\nb" as $s | [($s|test("^b$";"m")),($s|test("a.b";"m")),' \
            '($s|test("^b$";"s")),($s|test("a.b";"s")),' \
            '($s|test("^b$";"p")),($s|test("a.b";"p"))]'
    expect(described_class.run(flags, nil).to_a).to eq([[false, true, false, false, false, true]])
    anchors = '[("a\\n"|test("^a$";"s")),("^a$"|test("\\\\^a\\\\$";"s")),' \
              '("$"|test("[$^]";"s"))]'
    expect(described_class.run(anchors, nil).to_a).to eq([[true, true, true]])
    classes = '[("]"|test("[]^]";"s")),("^"|test("[]^]";"s")),' \
              '("A^"|test("[[:alpha:]^]+$";"s"))]'
    expect(described_class.run(classes, nil).to_a).to eq([[true, true, true]])
    inline = '"a\\nb" as $s | [($s|test("(?m:a.b)")),($s|test("(?m:^b$)")),' \
             '($s|test("(?s:a.b)")),($s|test("(?-s:a.b)")),' \
             '($s|test("(?-s:a.b)";"m")),($s|test("(?m:^b$)";"s")),' \
             '($s|test("(?-m:^b$)";"s"))]'
    expect(described_class.run(inline, nil).to_a).to eq([[false, true, true, false, false, true, false]])
    expect { described_class.run('"a" | test("a";"z")', nil).to_a }
      .to raise_error(Rjq::RuntimeError, /unsupported regular expression flag/)
    if Regexp.respond_to?(:timeout)
      expect(described_class.run('"a"|test("a")', nil, regexp_timeout: 0.1).to_a).to eq([true])
      expect { described_class.run('"a"|test("a")', nil, regexp_timeout: 0).to_a }
        .to raise_error(ArgumentError, /regexp_timeout/)
    end
    expect { described_class.run('[{}] | @csv', nil).to_a }
      .to raise_error(Rjq::TypeError, /not valid in a csv row/)
  end

  it 'supports regex split flags and ignores capture groups in split output' do
    expect(described_class.run('"aBa" | split("b"; "i")', nil).to_a).to eq([%w[a a]])
    expect(described_class.run('"a1b2" | split("([0-9])"; "")', nil).to_a).to eq([["a", "b", ""]])
    expect(described_class.run('"abc" | split(""; "")', nil).to_a).to eq([["", "a", "b", "c", ""]])
    expect(described_class.run('"abc" | split(""; "n")', nil).to_a).to eq([["abc"]])
    expect(described_class.run('"💩é" | split(""; "")', nil).to_a)
      .to eq([["", "💩", "é", ""]])
  end

  it 'does not repair malformed regular expression groups' do
    ['(', '(?<x>', '(?m'].product(%w[ m s p]).each do |pattern, flags|
      filter = '"a" | test($pattern; $flags)'
      expect { described_class.run(filter, nil, variables: { 'pattern' => pattern, 'flags' => flags }).to_a }
        .to raise_error(Rjq::RuntimeError, /regexp|group|end pattern|option/i)
    end
  end

  it 'converts regular expression timeouts into runtime errors' do
    skip 'per-expression regexp timeouts are unavailable' unless Regexp.respond_to?(:timeout)

    input = ('a' * 30_000) + '!'
    pattern = '\\A(a|aa)*\\z'
    filters = [
      'test($pattern)', 'match($pattern)', 'capture($pattern)', 'scan($pattern)',
      'split($pattern; "")', 'splits($pattern)', 'sub($pattern; "x")', 'gsub($pattern; "x")'
    ]
    filters.each do |filter|
      expect do
        described_class.run(filter, input, variables: { 'pattern' => pattern }, regexp_timeout: 0.001).to_a
      end.to raise_error(Rjq::RuntimeError, 'regular expression match timeout')
    end
  end

  it 'matches jq integer remainder and empty string division semantics' do
    filter = '[1.5%1, (-1.5)%1, 5.9%2.1, (-5.9)%2.1, 0.1%(-2), (-0.1)%2]'
    expect(described_class.run(filter, nil).to_a).to eq([[0, 0, 1, -1, 0, 0]])
    expect(described_class.run('[infinite%2, (-infinite)%3, 2%infinite]', nil).to_a).to eq([[1, -2, 2]])
    expect(described_class.run('["ab"/"", ""/""]', nil).to_a).to eq([[%w[a b], []]])
    expect { described_class.run('2%0.9', nil).to_a }
      .to raise_error(Rjq::TypeError, /divisor is zero/)
    expect(described_class.run('[-0.1%2, -1.5%1, -0.0%2]', nil).to_a).to eq([[-0.0, -0.0, -0.0]])
    expect(described_class.run('[infinite%(-infinite)]', nil).to_a).to eq([[9_223_372_036_854_776_000]])
  end

  it 'preserves jq Cartesian order for generated binary operands' do
    filter = '[(infinite,-infinite) % (1,-1,infinite,-infinite)]'
    expect(described_class.run(filter, nil).to_a)
      .to eq([[0, 0, 0, 0, 0, -1, 9_223_372_036_854_776_000, 0]])

    values = []
    output = described_class.run('(1,2) + (10,error("right boom"))', nil)
    expect { output.each { |value| values << value } }.to raise_error(Rjq::ErrorValue, 'right boom')
    expect(values).to eq([11, 12])
  end

  it 're-evaluates effectful left operands for each generated right operand' do
    io = StringIO.new('1 2 3 4 5 6')

    expect(described_class.run_stream('(input,input)+(10,20)', io: io, opts: { null_input: true }).to_a)
      .to eq([11, 12, 23, 24])
  end

  it 'branches assignment results for each compound right-hand output' do
    input = { 'a' => 1, 'b' => 2 }
    expect(described_class.run('(.a,.b) += (10,20)', input).to_a)
      .to eq([{ 'a' => 11, 'b' => 12 }, { 'a' => 21, 'b' => 22 }])
    expect(described_class.run('(.a,.b) -= (1,2)', input).to_a)
      .to eq([{ 'a' => 0, 'b' => 1 }, { 'a' => -1, 'b' => 0 }])
    expect(described_class.run('(.a,.b) *= (2,3)', input).to_a)
      .to eq([{ 'a' => 2, 'b' => 4 }, { 'a' => 3, 'b' => 6 }])
    expect(described_class.run('(.a,.b) /= (2,4)', input).to_a)
      .to eq([{ 'a' => 0.5, 'b' => 1 }, { 'a' => 0.25, 'b' => 0.5 }])

    values = []
    output = described_class.run('(.a,.b) += (10,error("rhs boom"))', input)
    expect { output.each { |value| values << value } }.to raise_error(Rjq::ErrorValue, 'rhs boom')
    expect(values).to eq([{ 'a' => 11, 'b' => 12 }])
  end

  it 'updates duplicate and nested paths progressively' do
    expect(described_class.run('{a:1,b:2}|(.a,.b)|=(.+1,error("late"))', nil).to_a)
      .to eq([{ 'a' => 2, 'b' => 3 }])
    expect(described_class.run('{a:9}|[((.a,.a)+=2),((.a,.a)-=2),((.a,.a)*=2),' \
                               '((.a,.a)/=2),((.a,.a)%=4)]', nil).to_a)
      .to eq([[{ 'a' => 13 }, { 'a' => 5 }, { 'a' => 36 }, { 'a' => 2.25 }, { 'a' => 1 }]])
    expect(described_class.run('{a:{b:1}}|(.a,.a.b)|=' \
                               'if type=="object" then .b+=1 else .+10 end', nil).to_a)
      .to eq([{ 'a' => { 'b' => 12 } }])
    expect(described_class.run('{a:[0,1,2]}|(.a[0:2],.a[0:2])+=[9]', nil).to_a)
      .to eq([{ 'a' => [0, 1, 9, 9, 2] }])
    expect(described_class.run('[0,1,2]|(.[0],.[0])|=empty', nil).to_a).to eq([[1, 2]])
    expect(described_class.run('{a:null}|(.a,.a)//=(10,20)', nil).to_a)
      .to eq([{ 'a' => 10 }, { 'a' => 20 }])
  end

  it 'preserves input order while updating duplicate paths' do
    io = StringIO.new('10 20 30')

    expect(described_class.run_stream('{a:1}|(.a,.a)+=(input,input)', io: io,
                                                                         opts: { null_input: true }).to_a)
      .to eq([{ 'a' => 21 }, { 'a' => 41 }])
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
    expect(origins[1]).to eq(File.expand_path('/tmp'))
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
    expect(described_class.run('(.[{}] = 0)?', nil).to_a).to eq([])
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
    expect(described_class.run('3 | pow((2,3); (1,2))', nil).to_a).to eq([2, 3, 4, 9])
    expect(described_class.run('@html "x\(1,2)y"', nil).to_a).to eq(%w[x1y x2y])
  end

  it 'preserves slice bound and reduce/foreach branches' do
    expect(described_class.run('.[(0,1):(2,3)]', [0, 1, 2, 3]).to_a)
      .to eq([[0, 1], [0, 1, 2], [1], [1, 2]])
    expect(described_class.run('reduce [1,2][] as $x (0,10; . + $x)', nil).to_a).to eq([3, 13])
    expect(described_class.run('foreach [1,2][] as $x (0,10; . + $x; .)', nil).to_a).to eq([1, 3, 11, 13])
  end

  it 'uses only the final update output as the next reduce and foreach state' do
    reduce = 'reduce (1,2) as $x ((0,10); .+$x, .+$x+100)'
    foreach = 'foreach (1,2) as $x ((0,10); .+$x, .+$x+100; .)'
    expect(described_class.run(reduce, nil).to_a).to eq([203, 213])
    expect(described_class.run(foreach, nil).to_a).to eq([1, 101, 103, 203, 11, 111, 113, 213])

    expect(described_class.run('reduce (1,2) as $x (10; if $x==1 then empty else [.,$x] end)', nil).to_a)
      .to eq([[nil, 2]])
    expect(described_class.run('foreach (1,2) as $x (10; if $x==1 then empty else [.,$x] end; .)', nil).to_a)
      .to eq([[nil, 2]])
    expect(described_class.run('reduce (1,2,3) as $x (10; empty)', nil).to_a).to eq([nil])
    expect(described_class.run('foreach (1,2,3) as $x (10; empty; .)', nil).to_a).to eq([])
    expect(described_class.run('try foreach (1,2) as $x (0; .+$x,error("update boom"); .) catch .', nil).to_a)
      .to eq([1, 'update boom'])
    expect(described_class.run('try reduce (1,2) as $x (0; .+$x,error("update boom")) catch .', nil).to_a)
      .to eq(['update boom'])
    expect(described_class.run('try reduce (1,2) as $x ((0,error("init boom")); .+$x) catch .', nil).to_a)
      .to eq([3, 'init boom'])
    expect(described_class.run('try foreach (1,2) as $x ((0,error("init boom")); .+$x; .) catch .', nil).to_a)
      .to eq([1, 3, 'init boom'])
    expect(described_class.run('try reduce (1,2) as $x (10; ' \
                               'if $x==1 then empty else error(.) end) catch .', nil).to_a)
      .to eq([nil])
    expect(described_class.run('try foreach (1,2) as $x (10; ' \
                               'if $x==1 then empty else error(.) end; .) catch .', nil).to_a)
      .to eq([nil])
  end

  it 're-runs effectful reduce and foreach generators for each initial output' do
    reduce_io = StringIO.new('1 2 3 4 5 6 7 8')
    reduce = 'reduce (input,input) as $x ((input,input); .+$x, .+$x+100)'
    expect(described_class.run_stream(reduce, io: reduce_io, opts: { null_input: true }).to_a).to eq([206, 215])

    foreach_io = StringIO.new('1 2 3 4 5 6 7 8')
    foreach = 'foreach (input,input) as $x ((input,input); .+$x, .+$x+100; .)'
    expect(described_class.run_stream(foreach, io: foreach_io, opts: { null_input: true }).to_a)
      .to eq([3, 103, 106, 206, 9, 109, 115, 215])

    empty_reduce_io = StringIO.new('1 2 3')
    expect(described_class.run_stream('[reduce (1,2) as $x (0; input|empty),input]',
                                      io: empty_reduce_io, opts: { null_input: true }).to_a).to eq([[nil, 3]])
    empty_foreach_io = StringIO.new('1 2 3')
    expect(described_class.run_stream('[foreach (1,2) as $x (0; input|empty; .),input]',
                                      io: empty_foreach_io, opts: { null_input: true }).to_a).to eq([[3]])
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

  it 'reports nonfinite assignment indices without leaking Ruby errors' do
    expect { described_class.run('.[-infinite] = 1', []).to_a }
      .to raise_error(Rjq::RuntimeError, 'Out of bounds negative array index')
    expect { described_class.run('.[infinite] = 1', {}).to_a }
      .to raise_error(Rjq::TypeError, 'Cannot index object with number')
    expect { described_class.run('.[infinite] = 1', []).to_a }
      .to raise_error(Rjq::TypeError, 'Cannot index array with number')
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
    expect do
      described_class.run('.[] | . as {a:$a} ?// {a:$a} | $a', [[3], 4]).to_a
    end.to raise_error(Rjq::TypeError, 'Cannot index array with string "a"')
    expect(described_class.run('.[] | . as {a:$a} ?// $a | $a', [[3], 4]).to_a).to eq([[3], 4])
    expect(described_class.run('null as {a:$a} ?// {b:$b} | [$a,$b]', nil).to_a).to eq([[nil, nil]])
    expect(described_class.run('null as [$a] ?// {b:$b} | [$a,$b]', nil).to_a).to eq([[nil, nil]])
    expect(described_class.run('path(. as {a:$a} ?// {b:$b} | .)', nil).to_a).to eq([['a']])
    expect(described_class.run('path(. as {a:[$a,$b],c:$c} | .)', nil).to_a)
      .to eq([['a', 1, 0, 'c']])
    input = { 'a' => 1, 'b' => 2 }
    expect(described_class.run('(. as {a:$x} | $x) = 0', input).to_a).to eq([{ 'a' => 0, 'b' => 2 }])
    expect(described_class.run('(. as {a:$x} ?// {b:$y} | $y) = 0', input).to_a)
      .to eq([{ 'a' => 1, 'b' => 0 }])
    expect { described_class.run('path(. as {a:$x} | .)', input).to_a }
      .to raise_error(Rjq::InvalidPathError)
  end

  it 'preserves binding-path generator order, backtracking, and partial errors' do
    input = { 'a' => 1 }
    alternatives = '. as {a:$x} ?// {b:$y} | '

    expect(described_class.run("path(#{alternatives}\u0024x,\u0024y)", input).to_a).to eq([['a'], ['b'], ['b']])
    expect(described_class.run("path(#{alternatives}\u0024y,\u0024x)", input).to_a).to eq([['b'], ['b']])
    expect(described_class.run("(#{alternatives}\u0024x,\u0024y) += 1", input).to_a)
      .to eq([{ 'a' => 2, 'b' => 2 }])

    yielded = []
    expect do
      described_class.run('path(. as {a:$x} | $x,.a)', input).each { |path| yielded << path }
    end.to raise_error(Rjq::InvalidPathError)
    expect(yielded).to eq([['a']])
  end

  it 'evaluates binding sources and dynamic patterns once while retaining nested paths' do
    source_io = StringIO.new('"a" "b"')
    expect(described_class.run_stream('path(null as $x | .[input])', io: source_io,
                                      opts: { null_input: true }).to_a).to eq([['a']])
    pattern_io = StringIO.new('"a" "b"')
    expect(described_class.run_stream('path(. as {(input):$x} | $x)', io: pattern_io,
                                      opts: { null_input: true }).to_a).to eq([['a']])
    nested = { 'a' => { 'b' => 1 } }
    expect(described_class.run('path(. as {a:$x} | $x as {b:$y} | $y)', nested).to_a)
      .to eq([['a', 'b']])
    expect(described_class.run('path(. as $x | empty)', { 'a' => 1 }).to_a).to eq([])
  end

  it 'validates nonlinear binding paths and typed alternative fallbacks' do
    expect { described_class.run('path(. as [$x,$y] | empty)', [1, 2]).to_a }
      .to raise_error(Rjq::InvalidPathError)
    expect { described_class.run('(. as [$x,$y] | empty) = 0', [1, 2]).to_a }
      .to raise_error(Rjq::InvalidPathError)
    expect { described_class.run('path(. as [$x] ?// {b:$y} | $y)', [1, 2]).to_a }
      .to raise_error(Rjq::TypeError, 'Cannot index array with string "b"')
    expect { described_class.run('path(. as {a:$x} ?// [$y] | $y)', { 'a' => 1 }).to_a }
      .to raise_error(Rjq::TypeError, 'Cannot index object with number')
  end

  it 'restarts alternative binding generators without losing prior paths' do
    yielded = []
    input = { 'a' => [1, 2], 'b' => 3 }
    expect do
      described_class.run('path(. as {a:$x} ?// {b:$y} | $y,$x)', input).each { |path| yielded << path }
    end.to raise_error(Rjq::InvalidPathError, 'Invalid path expression with result null')
    expect(yielded).to eq([['b']])

    expect(described_class.run('path(. as {a:$x} ?// $y | .)', { 'a' => 1 }).to_a).to eq([[]])
    expect(described_class.run('(. as {a:$x} ?// $y | .) = 0', { 'a' => 1 }).to_a).to eq([0])
  end

  it 'preserves partial runtime paths and isolates nested binding provenance' do
    yielded = []
    expect do
      described_class.run('path(. as $x | $x,.a)', [1, 2]).each { |path| yielded << path }
    end.to raise_error(Rjq::TypeError, 'Cannot index array with string "a"')
    expect(yielded).to eq([[]])

    nested = { 'a' => { 'b' => 1 } }
    expect { described_class.run('path(. as {a:$x} | $x as {b:$y} | $x)', nested).to_a }
      .to raise_error(Rjq::InvalidPathError)
  end

  it 'does not replay diagnostic side effects while resolving binding paths' do
    stderr = StringIO.new

    expect(described_class.run('path(. as $x | debug)', nil, stderr: stderr).to_a).to eq([[]])
    expect(stderr.string.lines.length).to eq(1)
    expect(described_class.run('path(. as $x | values)', nil).to_a).to eq([])
  end

  it 'backtracks across three binding alternatives with ordered partial paths' do
    input = [1, 2]
    expect do
      described_class.run('path(. as {a:[$x]} ?// {b:$y} ?// [$z] | $x)', input).to_a
    end.to raise_error(Rjq::InvalidPathError)

    yielded = []
    expect do
      described_class.run('path(. as {a:$x} ?// {b:$y} ?// [$z] | $z,$y,$x)', input)
                     .each { |path| yielded << path }
    end.to raise_error(Rjq::InvalidPathError)
    expect(yielded).to eq([[0]])

    yielded = []
    object = { 'a' => [1, 2], 'b' => 3 }
    expect do
      described_class.run('path(. as {a:$x} ?// [$y] ?// {b:$z} | $z,$y,$x)', object)
                     .each { |path| yielded << path }
    end.to raise_error(Rjq::InvalidPathError)
    expect(yielded).to eq([['b']])
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

  it 'reports jq-compatible errors for non-array truncate stream events' do
    {
      '1' => 'Cannot index number with number',
      '"x"' => 'Cannot index string with number',
      'true' => 'Cannot index boolean with number',
      '{}' => 'Cannot index object with number'
    }.each do |event, message|
      expect { described_class.run("0 | truncate_stream(#{event})", nil).to_a }
        .to raise_error(Rjq::TypeError, message)
    end

    expect(described_class.run('0 | truncate_stream(null)', nil).to_a).to eq([])
    expect(described_class.run('(-1) | truncate_stream(null)', nil).to_a).to eq([[nil]])
  end

  it 'supports SQL-style INDEX and IN' do
    rows = [{ 'id' => 'a', 'v' => 1 }, { 'id' => 'b', 'v' => 2 }]
    expect(described_class.run('INDEX(.id)', rows).to_a).to eq([{ 'a' => rows[0], 'b' => rows[1] }])
    expect(described_class.run('IN(["x", "y"])', 'y').to_a).to eq([true])
  end

  it 'preserves predicate and child generators in all and walk' do
    expect(described_class.run('all(.[]; (true,false))', [1]).to_a).to eq([false])
    expect(described_class.run('all(.[]; empty)', [1]).to_a).to eq([true])
    expect(described_class.run('[any, all, any(.), all(.)]', { 'a' => true, 'b' => false }).to_a)
      .to eq([[true, false, true, false]])
    expect(described_class.run('[any((true,error("late"))), all((false,error("late")))]', [0]).to_a)
      .to eq([[true, false]])
    expect { described_class.run('any(.)', nil).to_a }
      .to raise_error(Rjq::TypeError, 'Cannot iterate over null (null)')
    expect(described_class.run('walk((.,.))', [1]).to_a).to eq([[1, 1], [1, 1]])
    expect(described_class.run('walk((.,.))', { 'a' => 1 }).to_a).to eq([{ 'a' => 1 }, { 'a' => 1 }])

    array_outputs = []
    expect do
      described_class.run('walk((.,error("late")))', [1]).each { |value| array_outputs << value }
    end.to raise_error(Rjq::ErrorValue, 'late')
    expect(array_outputs).to eq([])

    object_outputs = []
    expect do
      described_class.run('walk((.,error("late")))', { 'a' => 1 }).each { |value| object_outputs << value }
    end.to raise_error(Rjq::ErrorValue, 'late')
    expect(object_outputs).to eq([{ 'a' => 1 }])

    stderr = StringIO.new
    expect(described_class.run('walk(if type=="number" then (.,debug) else . end)',
                               { 'a' => 1, 'b' => 2 }, stderr: stderr).to_a)
      .to eq([{ 'a' => 1, 'b' => 2 }])
    expect(stderr.string).to be_empty
    expect(described_class.run('walk(if type=="number" and .==1 then (.,error("late")) else . end)',
                               { 'a' => 1, 'b' => 2 }).to_a)
      .to eq([{ 'a' => 1, 'b' => 2 }])
  end

  it 'rejects non-string from_entries keys without coercion' do
    [0, true, [], {}].each do |key|
      expect { described_class.run('from_entries', [{ 'key' => key, 'value' => 1 }]).to_a }
        .to raise_error(Rjq::TypeError, /Cannot use .* as object key/)
    end
    expect { described_class.run('from_entries', [{ 'key' => false, 'value' => 1 }]).to_a }
      .to raise_error(Rjq::TypeError, 'Cannot use null (null) as object key')
    expect(described_class.run('from_entries', [{ 'key' => false, 'Key' => 'fallback', 'value' => 1 }]).to_a)
      .to eq([{ 'fallback' => 1 }])
  end

  it 'preserves every truthy paths predicate output' do
    expect(described_class.run('paths((true,true))', [1]).to_a).to eq([[0], [0]])
    expect(described_class.run('paths((false,true,false))', [1]).to_a).to eq([[0]])
    expect(described_class.run('paths(empty)', [1]).to_a).to eq([])

    expect { described_class.run('paths((true,error("root")))', 1).to_a }
      .to raise_error(Rjq::ErrorValue, 'root')
    stderr = StringIO.new
    expect(described_class.run('paths(debug)', [1], stderr: stderr).to_a).to eq([[0]])
    expect(stderr.string.lines.length).to eq(2)
  end

  it 'streams select outputs and lazily takes map_values updates' do
    selected = []
    expect do
      described_class.run('select((true,error("late")))', [1]).each { |value| selected << value }
    end.to raise_error(Rjq::ErrorValue, 'late')
    expect(selected).to eq([[1]])

    expect(described_class.run('map_values((.,error("late")))', [1]).to_a).to eq([[1]])
    expect(described_class.run('[map_values(null),map_values(false)]', [1, 2]).to_a)
      .to eq([[[nil, nil], [false, false]]])
    stderr = StringIO.new
    expect(described_class.run('map_values((.,debug))', { 'a' => 1 }, stderr: stderr).to_a)
      .to eq([{ 'a' => 1 }])
    expect(stderr.string).to be_empty
    expect(described_class.run('try map_values(.) catch ["caught",.]', 1).to_a)
      .to eq([['caught', 'Cannot iterate over number (1)']])
  end

  it 'keeps constructor and key-filter partial values internal on errors' do
    ['map((.,error("late")))', 'with_entries((.,error("late")))',
     'sort_by((.,error("late")))', 'group_by((.,error("late")))',
     'unique_by((.,error("late")))', 'min_by((.,error("late")))',
     'max_by((.,error("late")))'].each do |filter|
      outputs = []
      expect { described_class.run(filter, [1]).each { |value| outputs << value } }
        .to raise_error(Rjq::ErrorValue, 'late')
      expect(outputs).to eq([])
    end
  end

  it 'keeps filter argument partial values at their jq streaming boundaries' do
    expect { described_class.run('last((1,error("late")))', nil).to_a }
      .to raise_error(Rjq::ErrorValue, 'late')
    expect(described_class.run('IN((1,error("late"));.)', 1).to_a).to eq([true])
    expect { described_class.run('INDEX((1,error("late"));.)', nil).to_a }
      .to raise_error(Rjq::ErrorValue, 'late')

    limited = []
    expect do
      described_class.run('limit(2;(1,error("late")))', nil).each { |value| limited << value }
    end.to raise_error(Rjq::ErrorValue, 'late')
    expect(limited).to eq([1])

    until_outputs = []
    expect do
      described_class.run('until((true,error("late"));.)', 0).each { |value| until_outputs << value }
    end.to raise_error(Rjq::ErrorValue, 'late')
    expect(until_outputs).to eq([0])

    while_outputs = []
    expect do
      described_class.run('while((true,error("late"));empty)', 0).each { |value| while_outputs << value }
    end.to raise_error(Rjq::ErrorValue, 'late')
    expect(while_outputs).to eq([0])
  end

  it 'streams ordinary builtin argument products in jq order' do
    expect(described_class.run('pow((2,3);(4,5))', nil).to_a).to eq([16, 81, 32, 243])

    index_outputs = []
    expect do
      described_class.run('index((1,error("late")))', [1, 2]).each { |value| index_outputs << value }
    end.to raise_error(Rjq::ErrorValue, 'late')
    expect(index_outputs).to eq([0])

    %w[index rindex indices].each do |name|
      expect { described_class.run("#{name}({})", {}).to_a }
        .to raise_error(Rjq::TypeError, 'Cannot index object with object')
      expect { described_class.run("#{name}(1)", 1).to_a }
        .to raise_error(Rjq::TypeError, 'Cannot index number with number')
    end
    expect(described_class.run('[index([]),rindex([]),indices([])]', [0, 1]).to_a)
      .to eq([[nil, nil, []]])
  end

  it 'preserves jq-defined builtin argument order and input effects' do
    io = StringIO.new("10\n20\n30\n40\n")
    expect(described_class.run_stream('range((0,input);(2,input))', io: io, opts: { null_input: true }).to_a)
      .to eq([0, 1, *(0...10), *(20...30)])

    stderr = StringIO.new
    result = described_class.run('"ab"|scan(("a",("b"|debug));("",("i"|debug)))', nil, stderr: stderr).to_a
    expect(result).to eq(%w[a a b b])
    expect(stderr.string).to eq("[\"DEBUG:\",\"i\"]\n[\"DEBUG:\",\"b\"]\n[\"DEBUG:\",\"i\"]\n")

    expect(described_class.run('sub(("a","b");"x";("","g"))', 'ab').to_a)
      .to eq(%w[xb xb ax ax])
  end

  it 'converts invalid path and flatten inputs to controlled errors' do
    expect { described_class.run('getpath(1)', {}).to_a }
      .to raise_error(Rjq::TypeError, 'Path must be specified as an array')
    expect { described_class.run('setpath(1;0)', {}).to_a }
      .to raise_error(Rjq::TypeError, 'Path must be specified as an array')

    outputs = []
    io = StringIO.new("10\n20\n")
    stream = described_class.run_stream('setpath((["a"],input);(1,input))',
                                        io: io, opts: { null_input: true })
    expect { stream.each { |value| outputs << value } }
      .to raise_error(Rjq::TypeError, 'Path must be specified as an array')
    expect(outputs).to eq([{ 'a' => 1 }])

    expect(described_class.run('flatten("x")', {}).to_a).to eq([[]])
    expect { described_class.run('flatten("x")', [[1]]).to_a }
      .to raise_error(Rjq::TypeError, /cannot be subtracted/)
    expect { described_class.run('flatten(null)', []).to_a }
      .to raise_error(Rjq::RuntimeError, 'flatten depth must not be negative')
    expect { described_class.run('setpath([true];1)', nil).to_a }
      .to raise_error(Rjq::TypeError, 'Cannot index null with boolean')
    expect { described_class.run('has([])', {}).to_a }
      .to raise_error(Rjq::TypeError, 'Cannot check whether object has a array key')
    expect(described_class.run('[has(-0.1),has(-0.9),has(-1),has(-1.1),has(1.1)]', [0, 1]).to_a)
      .to eq([[true, true, false, false, true]])
    expect(described_class.run('[getpath([-0.1]),getpath([-1.1])]', [0, 1, 2]).to_a)
      .to eq([[0, 2]])
    expect(described_class.run('[setpath([-0.1];9),setpath([-1.1];9)]', [0, 1, 2]).to_a)
      .to eq([[[9, 1, 2], [0, 1, 9]]])
    expect(described_class.run('[delpaths([[-0.1]]),delpaths([[-1.1]]),delpaths([[1.9]])]', [0, 1, 2]).to_a)
      .to eq([[[0, 1, 2], [0, 1], [0, 2]]])
    expect(described_class.run('[.[0:-0.1],.[-0.1:-0.1]]', [0, 1, 2]).to_a)
      .to eq([[[0, 1, 2], [2]]])
    expect(described_class.run('[combinations(0.1), combinations(1.9), combinations(-0.1)]', [1, 2]).to_a)
      .to eq([[[1], [2], [1, 1], [1, 2], [2, 1], [2, 2], []]])
    expect { described_class.run('combinations(1.9)', 1).to_a }
      .to raise_error(Rjq::TypeError, 'Cannot iterate over number (1)')
    expect { described_class.run('combinations([[1,2]])', [1, 2]).to_a }
      .to raise_error(Rjq::RuntimeError, 'Range bounds must be numeric')

    deep = 20_000.times.reduce(1) { |value, _| [value] }
    expect(described_class.run('flatten', deep).to_a).to eq([[1]])
  end

  it 'collects split flag streams within one result constructor' do
    expect(described_class.run('split("a";("","i"))', 'ab').to_a).to eq([['', '', 'b']])
    expect(described_class.run('splits("a";("","i"))', 'ab').to_a).to eq(['', '', 'b'])
    expect(described_class.run('split("a";empty)', 'ab').to_a).to eq([['ab']])

    outputs = []
    expect do
      described_class.run('split("a";("",error("late")))', 'ab').each { |value| outputs << value }
    end.to raise_error(Rjq::ErrorValue, 'late')
    expect(outputs).to be_empty
  end

  it 'keeps path constructors internal while preserving path partial output once' do
    path_outputs = []
    expect do
      described_class.run('path((.a,error("late")))', { 'a' => 1 }).each { |value| path_outputs << value }
    end.to raise_error(Rjq::ErrorValue, 'late')
    expect(path_outputs).to eq([['a']])

    ['del((.a,error("late")))', 'pick((.a,error("late")))'].each do |filter|
      outputs = []
      expect { described_class.run(filter, { 'a' => 1 }).each { |value| outputs << value } }
        .to raise_error(Rjq::ErrorValue, 'late')
      expect(outputs).to eq([])
    end
  end

  it 'reconstructs and streams multiple fromstream roots before errors' do
    filter = 'fromstream(([[0],1],[[0]],[[0],2],[[0]]))'
    expect(described_class.run(filter, nil).to_a).to eq([[1], [2]])

    outputs = []
    expect do
      described_class.run('fromstream(([[],1],error("late")))', nil).each { |value| outputs << value }
    end.to raise_error(Rjq::ErrorValue, 'late')
    expect(outputs).to eq([1])
  end

  it 'supports base32 formatting' do
    expect(described_class.run('@base32 | @base32d', 'hello').to_a).to eq(['hello'])
  end

  it 'supports libm Bessel math builtins' do
    unless Rjq::MathFunctions.bessel_available?
      expect { described_class.run('1 | j0', nil).to_a }
        .to raise_error(Rjq::RuntimeError, /C math library with Bessel functions is not available/)
      next
    end

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
