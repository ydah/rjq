# frozen_string_literal: true

require 'stringio'
require 'json'
require_relative 'fixture_module_resolver'

module OfficialCompat
  FIXTURE_NUMBER_KEY = '__rjq_official_fixture_number_7f94c1__'
  Observation = Struct.new(:outputs, :error, keyword_init: true)
  class ExactDecimal
    attr_reader :literal

    def initialize(literal)
      @literal = literal.to_s.freeze
      sign, integer, fraction, exponent = @literal.match(
        /\A(-?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?\z/
      ).captures
      fraction ||= ''
      digits = (integer + fraction).sub(/\A0+/, '')
      if digits.empty?
        @canonical = [0, '0', 0].freeze
      else
        removed = digits.length - digits.sub(/0+\z/, '').length
        @canonical = [sign == '-' ? -1 : 1, digits.sub(/0+\z/, ''), exponent.to_i - fraction.length + removed].freeze
      end
      freeze
    end

    def ==(other)
      other.is_a?(ExactDecimal) && @canonical == other.instance_variable_get(:@canonical)
    end
  end

  # jq.test has one success case whose expected stdout is followed by an
  # intentional, uncaught runtime error.  Upstream's fixture format does not
  # annotate it, so keep the expectation outside the checksummed fixture.
  RUNTIME_ERROR_EXPECTATIONS = {
    '.[] | . as {a:$a} ?// {a:$a} ?// {a:$a} | $a' => 'Cannot index array with string "a"',
    '.[] as {a:$a} ?// {a:$a} ?// {a:$a} | $a' => 'Cannot index array with string "a"',
    '[[3],[4],[5],6][] | . as {a:$a} ?// {a:$a} ?// {a:$a} | $a' =>
      'Cannot index array with string "a"',
    '[[3],[4],[5],6] | .[] as {a:$a} ?// {a:$a} ?// {a:$a} | $a' =>
      'Cannot index array with string "a"',
    '.[]|(try . catch (if .=="ho" then "BROKEN"|error else empty end)) | if .=="ho" then error else "\(.) there!" end' =>
      'ho'
  }.freeze

  module_function

  def groups(path)
    groups = []
    current = []
    fail_mode = false
    runtime_error = nil

    File.readlines(path, chomp: true).each do |line|
      if line.empty?
        groups << [fail_mode, current, runtime_error] unless current.empty?
        current = []
        fail_mode = false
        runtime_error = nil
        next
      end
      if line.start_with?('# Runtime error:')
        runtime_error = line.delete_prefix('# Runtime error:').strip
        next
      end
      next if line.start_with?('#')

      if line.start_with?('%%FAIL')
        fail_mode = true
        next
      end

      current << line
    end
    groups << [fail_mode, current, runtime_error] unless current.empty?
    groups
  end

  def runnable_cases(path)
    groups(path).filter_map do |fail_group, lines, runtime_error|
      next if fail_group || lines.length < 2

      program, input, *expected = lines
      runtime_error = RUNTIME_ERROR_EXPECTATIONS.fetch(program, runtime_error)
      { program: program, input: input, expected: expected, runtime_error: runtime_error }
    end
  end

  def failure_cases(path)
    groups(path).filter_map do |fail_group, lines|
      next unless fail_group
      next if lines.empty?

      program, *expected_error = lines
      { program: program, expected_error: expected_error }
    end
  end

  def run_case(program, input)
    observe_case(program, input).outputs
  end

  def observe_case(program, input)
    inputs = [convert_fixture_numbers(parse_fixture_input(input))]
    stderr = StringIO.new
    output = []
    error = nil
    inputs.each do |value|
      begin
        Rjq.compile(program, module_resolver: fixture_module_resolver).run(value, stderr: stderr).each do |item|
          output << item
        end
      rescue Rjq::RuntimeError => e
        error = e
        break
      end
    end
    Observation.new(outputs: output, error: error)
  end

  def run_failure_case(program)
    Rjq.compile(program, module_resolver: fixture_module_resolver).run(nil).to_a
  end

  def failure_category(expected_error)
    message = Array(expected_error).join("\n")
    case message
    when /Cannot use number .* as object key/ then :object_key
    when /label-.* is not defined/ then :undefined_label
    when /Module metadata must be constant/ then :metadata_constant
    when /Module metadata must be an object/ then :metadata_object
    when /Invalid escape/ then :invalid_escape
    when /Import path must be constant/ then :import_path_constant
    when /syntax error/ then :syntax
    else :unknown
    end
  end

  def error_category(error)
    message = error.message
    return :object_key if message.match?(/Cannot use number .* as object key/)
    return :undefined_label if error.is_a?(Rjq::CompileError) && message.match?(/label .* is not defined/)
    return :metadata_constant if message.include?('Module metadata must be constant')
    return :metadata_object if message.include?('Module metadata must be an object')
    return :invalid_escape if message.match?(/invalid escape/i)
    return :import_path_constant if message.include?('Import path must be constant')
    return :syntax if error.is_a?(Rjq::ParseError)

    :unknown
  end

  def compile_failure?(error)
    error.is_a?(Rjq::ParseError) || error.is_a?(Rjq::CompileError)
  end

  def expected_values(lines)
    lines.map { |line| normalize_fixture_specials(::JSON.parse(line, allow_nan: true, decimal_class: ExactDecimal)) }
  end

  def match_values?(expected, actual)
    expected.length == actual.length &&
      expected.zip(actual).all? { |left, right| independent_equal?(left, right) }
  end

  def independent_equal?(left, right)
    if fixture_number?(left) && right.is_a?(Numeric)
      return independent_numeric_equal?(left, right)
    end
    return left == right unless left.class == right.class
    return left.length == right.length && left.zip(right).all? { |a, b| independent_equal?(a, b) } if left.is_a?(Array)
    if left.is_a?(Hash)
      return left.length == right.length &&
             left.all? { |key, value| right.key?(key) && independent_equal?(value, right.fetch(key)) }
    end

    left == right
  end

  def independent_numeric_equal?(expected, actual)
    return false if nan_number?(expected) || nan_number?(actual)

    if expected.is_a?(ExactDecimal)
      return expected == ExactDecimal.new(actual.literal) if actual.respond_to?(:literal)
      return expected == ExactDecimal.new(actual.to_s) if actual.is_a?(Integer)

      return Float(expected.literal) == actual
    end
    if expected.is_a?(Integer)
      return ExactDecimal.new(expected.to_s) == ExactDecimal.new(actual.literal) if actual.respond_to?(:literal)
      return expected.to_f == actual if actual.is_a?(Float)

      return expected == actual
    end

    actual = actual.to_f if actual.respond_to?(:literal)
    expected == actual
  end

  def nan_number?(value)
    value.respond_to?(:nan?) && value.nan?
  end

  def fixture_number?(value)
    value.is_a?(Numeric) || value.is_a?(ExactDecimal)
  end

  def parse_fixture_input(source)
    normalized = normalize_fixture_numbers(source.sub(/\A\uFEFF/, ''))
    decode_fixture_number_tokens(::JSON.parse(normalized, allow_nan: true))
  end

  def decode_fixture_number_tokens(value)
    case value
    when Array
      value.map { |item| decode_fixture_number_tokens(item) }
    when Hash
      if value.length == 1 && value.key?(FIXTURE_NUMBER_KEY)
        ExactDecimal.new(value.fetch(FIXTURE_NUMBER_KEY))
      else
        value.to_h { |key, item| [key, decode_fixture_number_tokens(item)] }
      end
    else
      value
    end
  end

  def convert_fixture_numbers(value)
    case value
    when ExactDecimal
      Rjq::Number.parse(value.literal)
    when Float
      value.infinite? ? value.negative? ? -Float::MAX : Float::MAX : value
    when Array
      value.map { |item| convert_fixture_numbers(item) }
    when Hash
      value.to_h { |key, item| [key, convert_fixture_numbers(item)] }
    else
      value
    end
  end

  def normalize_fixture_specials(value)
    case value
    when Float
      value.infinite? ? value.negative? ? -Float::MAX : Float::MAX : value
    when Array
      value.map { |item| normalize_fixture_specials(item) }
    when Hash
      value.to_h { |key, item| [key, normalize_fixture_specials(item)] }
    else
      value
    end
  end

  def normalize_fixture_numbers(source)
    output = +''
    quoted = false
    escaped = false
    index = 0
    while index < source.length
      character = source[index]
      if quoted
        output << character
        if escaped
          escaped = false
        elsif character == '\\'
          escaped = true
        elsif character == '"'
          quoted = false
        end
        index += 1
        next
      end
      if character == '"'
        quoted = true
        output << character
        index += 1
        next
      end
      match = /\A-?nan\b/i.match(source[index..])
      if match
        output << 'NaN'
        index += match[0].length
        next
      end

      number = /\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.match(source[index..])
      if number
        literal = number[0]
        output << %({"#{FIXTURE_NUMBER_KEY}":"#{literal}"})
        index += literal.length
        next
      end

      output << character
      index += 1
    end
    output
  end

  def dump_values(values)
    values.map { |value| Rjq::JSON::Dumper.dump(value, indent: nil) }
  end

  def fixture_module_resolver
    @fixture_module_resolver ||= FixtureModuleResolver.new
  end
end
