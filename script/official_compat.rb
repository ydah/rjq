# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
$LOAD_PATH.unshift(File.expand_path('../spec', __dir__))

require 'rjq'
require 'support/official_compat'

path = ARGV[0] || 'spec/fixtures/jq/jq.test'
limit = ENV['LIMIT']&.to_i
checked = 0
failures = []

OfficialCompat.groups(path).each do |fail_group, lines|
  next if lines.empty?

  program, input, *expected = lines
  checked += 1
  if fail_group
    begin
      OfficialCompat.run_failure_case(program)
      failures << [program, nil, ['expected failure'], ['SUCCESS']]
    rescue Rjq::Error
      # expected
    end
  elsif lines.length >= 3
    begin
      actual = OfficialCompat.run_case(program, input)
      expected_values = OfficialCompat.expected_values(expected)
      unless OfficialCompat.match_values?(expected_values, actual)
        failures << [program, input, expected, OfficialCompat.dump_values(actual)]
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
