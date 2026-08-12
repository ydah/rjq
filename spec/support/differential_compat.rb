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
