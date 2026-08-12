# frozen_string_literal: true

require 'stringio'
require_relative 'fixture_module_resolver'

module OfficialCompat
  module_function

  def groups(path)
    groups = []
    current = []
    fail_mode = false

    File.readlines(path, chomp: true).each do |line|
      if line.empty?
        groups << [fail_mode, current] unless current.empty?
        current = []
        fail_mode = false
        next
      end
      next if line.start_with?('#')

      if line.start_with?('%%FAIL')
        fail_mode = true
        next
      end

      current << line
    end
    groups << [fail_mode, current] unless current.empty?
    groups
  end

  def runnable_cases(path)
    groups(path).filter_map do |fail_group, lines|
      next if fail_group || lines.length < 3

      program, input, *expected = lines
      { program: program, input: input, expected: expected }
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
    inputs = Rjq::JSON::Parser.parse(input).to_a
    stderr = StringIO.new
    inputs.flat_map do |value|
      output = []
      begin
        Rjq.compile(program, module_resolver: fixture_module_resolver).run(value, stderr: stderr).each do |item|
          output << item
        end
      rescue Rjq::ErrorValue
        # jq's legacy fixture runner compares values emitted before a terminal
        # error. CLI status and diagnostics are covered by differential specs.
      end
      output
    end
  end

  def run_failure_case(program)
    Rjq.compile(program, module_resolver: fixture_module_resolver).run(nil).to_a
  end

  def expected_values(lines)
    lines.map { |line| Rjq::JSON::Parser.parse_one(line) }
  end

  def match_values?(expected, actual)
    expected.length == actual.length &&
      expected.zip(actual).all? { |left, right| Rjq::Value.equal?(left, right) }
  end

  def dump_values(values)
    values.map { |value| Rjq::JSON::Dumper.dump(value, indent: nil) }
  end

  def fixture_module_resolver
    @fixture_module_resolver ||= FixtureModuleResolver.new
  end
end
