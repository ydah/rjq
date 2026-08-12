# frozen_string_literal: true

require 'open3'
require 'rbconfig'

module DifferentialCompat
  Deviation = Struct.new(:reason, :rjq_stdout, keyword_init: true)
  Case = Struct.new(:name, :filter, :input, :flags, :deviation, keyword_init: true)
  Observation = Struct.new(:stdout, :stderr, :status, :outputs, keyword_init: true)

  CASES = [
    Case.new(name: 'module string', filter: '"module"', input: '', flags: ['-n']),
    Case.new(name: 'import string', filter: '"import"', input: '', flags: ['-n']),
    Case.new(name: 'namespace string', filter: '"$foo::bar"', input: '', flags: ['-n']),
    Case.new(name: 'top-level error', filter: 'error("x")', input: '', flags: ['-n']),
    Case.new(name: 'partial output before error', filter: '1, error("x")', input: '', flags: ['-n']),
    Case.new(name: 'halt', filter: 'halt', input: '', flags: ['-n']),
    Case.new(name: 'halt bypasses try', filter: 'try halt catch "caught"', input: '', flags: ['-n']),
    Case.new(name: 'halt_error bypasses try', filter: 'try halt_error(7) catch "caught"', input: '', flags: ['-n']),
    Case.new(name: 'trailing dot', filter: '.foo.', input: '{"foo":1}', flags: []),
    Case.new(name: 'comments', filter: '. # comment', input: '1', flags: []),
    Case.new(name: 'multi-value interpolation', filter: '"x\(1,2)y"', input: '', flags: ['-n']),
    Case.new(name: 'multi-value format interpolation', filter: '@html "x\(1,2)y"', input: '', flags: ['-n']),
    Case.new(name: 'decimal literal representation', filter: '.', input: '1.000', flags: []),
    Case.new(name: 'large exponent representation', filter: '.', input: '1e100', flags: []),
    Case.new(name: 'computed large exponent', filter: '1e100 + 0', input: '', flags: ['-n']),
    Case.new(name: 'multi-value boolean', filter: '(true,false) and (true,false)', input: '', flags: ['-n']),
    Case.new(name: 'multi-value select', filter: '1 | select(true,true)', input: '', flags: ['-n']),
    Case.new(name: 'multi-value builtin argument', filter: '"abc" | startswith(("a","b"))', input: '', flags: ['-n']),
    Case.new(name: 'multi-value slice bounds', filter: '.[(0,1):(2,3)]', input: '[0,1,2,3]', flags: []),
    Case.new(name: 'reduce branches', filter: 'reduce [1,2][] as $x (0,10; . + $x)', input: '', flags: ['-n']),
    Case.new(name: 'foreach branches', filter: 'foreach [1,2][] as $x (0,10; . + $x; .)', input: '', flags: ['-n']),
    Case.new(name: 'reduce update branches',
             filter: 'reduce (1,2) as $x ((0,10); .+$x, .+$x+100)', input: '', flags: ['-n']),
    Case.new(name: 'foreach update branches',
             filter: 'foreach (1,2) as $x ((0,10); .+$x, .+$x+100; .)', input: '', flags: ['-n']),
    Case.new(name: 'reduce empty update',
             filter: 'reduce (1,2) as $x (0; if $x==1 then empty else .+$x end)', input: '', flags: ['-n']),
    Case.new(name: 'foreach update partial error',
             filter: 'try foreach (1,2) as $x (0; .+$x,error("update boom"); .) catch .', input: '', flags: ['-n']),
    Case.new(name: 'reduce update error',
             filter: 'try reduce (1,2) as $x (0; .+$x,error("update boom")) catch .', input: '', flags: ['-n']),
    Case.new(name: 'reduce and foreach initial error order',
             filter: '[try reduce (1,2) as $x ((0,error("init boom")); .+$x) catch .,' \
                     'try foreach (1,2) as $x ((0,error("init boom")); .+$x; .) catch .]',
             input: '', flags: ['-n']),
    Case.new(name: 'effectful reduce generator',
             filter: 'reduce (input,input) as $x ((input,input); .+$x, .+$x+100)',
             input: '1 2 3 4 5 6 7 8', flags: ['-n']),
    Case.new(name: 'effectful foreach generator',
             filter: 'foreach (input,input) as $x ((input,input); .+$x, .+$x+100; .)',
             input: '1 2 3 4 5 6 7 8', flags: ['-n']),
    Case.new(name: 'lazy range', filter: 'first(range(0; 1000000000000))', input: '', flags: ['-n']),
    Case.new(name: 'lazy nth', filter: 'nth(0; (1, error("not reached")))', input: '', flags: ['-n']),
    Case.new(name: 'generated lazy nth', filter: '[nth((0,2); (0,1,2,error("not reached")))]', input: '', flags: ['-n']),
    Case.new(name: 'generated nth index error',
             filter: 'nth((0,error("index boom")); (1,error("source boom")))', input: '', flags: ['-n']),
    Case.new(name: 'nth index access',
             filter: '[0,1,2] | [nth(-0.1),nth(-1.1),nth(1.9),nth(3),nth(-4)]', input: '', flags: ['-n']),
    Case.new(name: 'nth empty index access', filter: '[] | nth(0)', input: '', flags: ['-n']),
    Case.new(name: 'nth object index access', filter: '{"a":1} | nth("a")', input: '', flags: ['-n']),
    Case.new(name: 'fractional negative nth filter',
             filter: 'nth((0,-0.1); (10,error("source boom")))', input: '', flags: ['-n']),
    Case.new(name: 'special nth filter indices',
             filter: '[(nan,infinite,-infinite,null,false,true,"1",[],{}) as $i | ' \
                     'try [nth($i;(10,20,30))] catch .]', input: '', flags: ['-n']),
    Case.new(name: 'nan nth filter error', filter: 'nth(nan; 1)', input: '', flags: ['-n']),
    Case.new(name: 'infinite nth filter',
             filter: 'nth(infinite; error("not reached"))', input: '', flags: ['-n']),
    Case.new(name: 'lazy recurse children', filter: 'limit(2; recurse(1, error("not reached")))', input: '', flags: ['-n']),
    Case.new(name: 'recurse condition branches',
             filter: '[recurse(if . < 2 then .+1 else empty end; (true,true))]', input: '0', flags: []),
    Case.new(name: 'recurse condition error',
             filter: 'try [recurse(if . < 1 then .+1 else empty end; (true,error("condition boom")))] catch .',
             input: '0', flags: []),
    Case.new(name: 'truncate filtered stream',
             filter: '1 | truncate_stream(([[0]], [[0,1], "a"], [[0,1]]))', input: '', flags: ['-n']),
    Case.new(name: 'lazy truncate stream',
             filter: 'first(0 | truncate_stream(([[0], "a"], error("not reached"))))', input: '', flags: ['-n']),
    Case.new(name: 'fractional negative truncate depth',
             filter: '(-1.9) | truncate_stream(([[0,1], "a"]))', input: '', flags: ['-n']),
    Case.new(name: 'truncate filter null input',
             filter: '2 | truncate_stream(([[0,1,2], .]))', input: '7', flags: []),
    Case.new(name: 'truncate extreme negative depth',
             filter: '(-3) | truncate_stream(([[0,1], "a"]))', input: '', flags: ['-n']),
    Case.new(name: 'truncate special depths',
             filter: '(nan, infinite, -infinite, null, "1", [], {}) | truncate_stream(([[0], "a"]))',
             input: '', flags: ['-n']),
    Case.new(name: 'truncate boolean depth error',
             filter: 'false | truncate_stream(([[0], "a"]))', input: '', flags: ['-n']),
    Case.new(name: 'truncate malformed events',
             filter: '0 | truncate_stream(([], [null], [[0], "a", "extra"]))', input: '', flags: ['-n']),
    Case.new(name: 'truncate string path',
             filter: '1 | truncate_stream((["😀x", "a"]))', input: '', flags: ['-n']),
    Case.new(name: 'truncate number event error', filter: '0 | truncate_stream(1)', input: '', flags: ['-n']),
    Case.new(name: 'truncate string event error', filter: '0 | truncate_stream("x")', input: '', flags: ['-n']),
    Case.new(name: 'truncate boolean event error', filter: '0 | truncate_stream(true)', input: '', flags: ['-n']),
    Case.new(name: 'truncate object event error', filter: '0 | truncate_stream({})', input: '', flags: ['-n']),
    Case.new(name: 'truncate null event', filter: '(0, -1) | truncate_stream(null)', input: '', flags: ['-n']),
    Case.new(name: 'repeat semantics', filter: 'limit(5; repeat(. + 1))', input: '', flags: ['-n']),
    Case.new(name: 'branching while', filter: 'while(. < 3; . + 1, . + 2)', input: '', flags: ['-n']),
    Case.new(name: 'branching until', filter: 'until(. >= 3; . + 1, . + 2)', input: '', flags: ['-n']),
    Case.new(name: 'math domain', filter: '-1 | sqrt | isnan', input: '', flags: ['-n']),
    Case.new(name: 'math functions',
             filter: '[fmax(nan;2),fmin(nan;2),fdim(5;2),copysign(2;-0),hypot(3;4)]', input: '', flags: ['-n']),
    Case.new(name: 'nearest-even rounding', filter: '[(0.5|nearbyint),(1.5|nearbyint),(-0.5|rint)]',
             input: '', flags: ['-n']),
    Case.new(name: 'UTC mktime', filter: '0 | gmtime | mktime', input: '', flags: ['-n']),
    Case.new(name: 'format csv', filter: '["a",1,true,null] | format("csv")', input: '', flags: ['-n']),
    Case.new(name: 'regex m flag', filter: '"a\nb" | test("a.b"; "m")', input: '', flags: ['-n']),
    Case.new(name: 'regex s flag', filter: '"a\nb" | test("a.b"; "s")', input: '', flags: ['-n']),
    Case.new(name: 'regex split flags', filter: '"aBa" | split("b"; "i")', input: '', flags: ['-n']),
    Case.new(name: 'regex split captures', filter: '"a1b2" | split("([0-9])"; "")', input: '', flags: ['-n']),
    Case.new(name: 'regex split empty matches',
             filter: '["abc" | split(""; ""), split(""; "n")]', input: '', flags: ['-n']),
    Case.new(name: 'regex split Unicode empty matches',
             filter: '[("é"|split("";"")), ("💩"|split("";"")), ("💩é"|split("(?=.)";""))]',
             input: '', flags: ['-n'],
             deviation: Deviation.new(
               reason: 'Ruby Regexp advances zero-width matches by codepoint; jq Oniguruma advances through UTF-8 bytes',
               rjq_stdout: "[[\"\",\"é\",\"\"],[\"\",\"💩\",\"\"],[\"\",\"💩\",\"é\"]]\n".b
             )),
    Case.new(name: 'integer remainder matrix',
             filter: '[1.5%1,(-1.5)%1,5.9%2.1,(-5.9)%2.1,0.1%(-2),(-0.1)%2,' \
                     'infinite%2,(-infinite)%3,2%infinite]', input: '', flags: ['-n']),
    Case.new(name: 'fractional zero remainder divisor', filter: '2%0.9', input: '', flags: ['-n']),
    Case.new(name: 'unary negative zero remainder',
             filter: '[-0.1%2,-1.5%1,-0.0%2]', input: '', flags: ['-n']),
    Case.new(name: 'nonfinite saturated remainder',
             filter: '[infinite%(-infinite)]', input: '', flags: ['-n']),
    Case.new(name: 'binary generator Cartesian order',
             filter: '[(infinite,-infinite)%(1,-1,infinite,-infinite)]', input: '', flags: ['-n']),
    Case.new(name: 'binary generator error order',
             filter: '(1,2)+(10,error("right boom"))', input: '', flags: ['-n']),
    Case.new(name: 'effectful binary left operand',
             filter: '(input,input)+(10,20)', input: '1 2 3 4 5 6', flags: ['-n']),
    Case.new(name: 'assignment RHS branches',
             filter: '{a:null,b:2} | [((.a,.b)=(10,20)), ((.a,.b)|=(.,.+10)),' \
                     '((.a,.b)+=(10,20)), ((.a,.b)//=(10,20))]', input: '', flags: ['-n']),
    Case.new(name: 'assignment RHS partial error',
             filter: '{a:1,b:2} | (.a,.b)+=(10,error("rhs boom"))', input: '', flags: ['-n']),
    Case.new(name: 'empty string division', filter: '["ab"/"", ""/""]', input: '', flags: ['-n']),
    Case.new(name: 'generated sub replacement', filter: '"a" | sub("a"; ["x","y"][])', input: '', flags: ['-n']),
    Case.new(name: 'generated gsub replacement',
             filter: '"ab" | gsub("(?<x>.)"; [.x|ascii_upcase,ascii_downcase][])', input: '', flags: ['-n']),
    Case.new(name: 'fractional stream counts', filter: '[nth(1.9;range(5)),limit(1.9;range(5))]',
             input: '', flags: ['-n']),
    Case.new(name: 'empty indices', filter: '"abc" | [indices("")]', input: '', flags: ['-n']),
    Case.new(name: 'negative combinations', filter: '[1,2] | combinations(-1)', input: '', flags: ['-n']),
    Case.new(name: 'unknown function without input', filter: 'does_not_exist', input: '', flags: []),
    Case.new(name: 'invalid builtin arity', filter: 'length(1)', input: '', flags: ['-n'])
  ].freeze

  module_function

  def jq_binary
    ENV.fetch('JQ_BIN', 'jq')
  end

  def jq_1_7_1?
    stdout, _stderr, status = Open3.capture3(jq_binary, '--version')
    status.success? && stdout.match?(/\bjq-1\.7\.1(?:\b|-)/)
  rescue Errno::ENOENT
    false
  end

  def observe_jq(test_case)
    observe([jq_binary, '-c', *test_case.flags, test_case.filter], test_case.input)
  end

  def observe_rjq(test_case)
    command = [RbConfig.ruby, '-Ilib', 'bin/rjq', '-c', *test_case.flags, test_case.filter]
    observe(command, test_case.input)
  end

  def observe(command, input)
    stdout, stderr, status = Open3.capture3(*command, stdin_data: input)
    Observation.new(
      stdout: stdout.b,
      stderr: normalize_stderr(stderr),
      status: status.exitstatus,
      outputs: stdout.lines(chomp: false).map(&:b)
    )
  end

  def normalize_stderr(stderr)
    return ''.b if stderr.empty?

    if (match = stderr.match(/([A-Za-z_][A-Za-z0-9_:]*\/\d+) is not defined/))
      return "compile-error:#{match[1]} is not defined\n".b
    end
    return "compile-error:syntax\n".b if stderr.match?(/syntax error|expected field or bracket expression/)

    if (match = stderr.match(/(?:runtime error: |error \(at [^)]*\): )(.*)$/))
      return "runtime-error:#{match[1]}\n".b
    end

    stderr.gsub(/\b(?:r?jq): /, '').b
  end
end
