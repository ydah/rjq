# frozen_string_literal: true

require 'open3'
require 'rbconfig'

module DifferentialCompat
  Case = Struct.new(:name, :filter, :input, :flags, keyword_init: true)
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
    Case.new(name: 'lazy range', filter: 'first(range(0; 1000000000000))', input: '', flags: ['-n']),
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
