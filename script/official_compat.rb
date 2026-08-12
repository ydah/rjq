# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
$LOAD_PATH.unshift(File.expand_path('../spec', __dir__))

require 'rjq'
require 'support/official_compat'

path = ARGV[0] || 'spec/fixtures/jq/jq.test'
limit = ENV['LIMIT']&.to_i
checked = 0
failures = []

OfficialCompat.groups(path).each do |fail_group, lines, runtime_error|
  next if lines.empty?

  checked += 1
  if fail_group
    program, *expected = lines
    begin
      OfficialCompat.run_failure_case(program)
      failures << [program, nil, ['expected failure'], ['SUCCESS']]
    rescue Rjq::Error => e
      expected_category = OfficialCompat.failure_category(expected)
      unless OfficialCompat.compile_failure?(e) && OfficialCompat.error_category(e) == expected_category
        failures << [program, nil, expected, ["WRONG ERROR #{e.class}: #{e.message}"]]
      end
    end
  else
    program, input, *expected = lines
    begin
      observation = OfficialCompat.observe_case(program, input)
      expected_values = OfficialCompat.expected_values(expected)
      runtime_error = OfficialCompat::RUNTIME_ERROR_EXPECTATIONS.fetch(program, runtime_error)
      error_matches = if runtime_error
                        observation.error.is_a?(Rjq::RuntimeError) && observation.error.message == runtime_error
                      else
                        observation.error.nil?
                      end
      unless error_matches && OfficialCompat.match_values?(expected_values, observation.outputs)
        actual = OfficialCompat.dump_values(observation.outputs)
        actual << "ERROR #{observation.error.class}: #{observation.error.message}" if observation.error
        failures << [program, input, expected, actual]
      end
    rescue StandardError => e
      failures << [program, input, expected, ["ERROR #{e.class}: #{e.message}"]]
    end
  end
  break if limit && checked >= limit
end

failures.first(80).each do |program, input, expected, actual|
  puts "PROGRAM #{program}"
  puts "INPUT #{input}"
  puts "EXPECTED #{expected.inspect}"
  puts "ACTUAL   #{actual.inspect}"
  puts '---'
end
puts "checked=#{checked} failures=#{failures.length}"
exit(failures.empty? ? 0 : 1)
