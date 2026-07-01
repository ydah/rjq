# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'rjq'

path = ARGV[0] || 'spec/fixtures/jq/jq.test'
limit = ENV['LIMIT']&.to_i

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

checked = 0
failures = []
groups.each do |fail_group, lines|
  next if lines.empty?

  program, input, *expected = lines
  checked += 1
  if fail_group
    begin
      Rjq.compile(program).run(nil).to_a
      failures << [program, nil, ['expected failure'], ['SUCCESS']]
    rescue Rjq::Error
      # expected
    end
  elsif lines.length >= 3
    begin
      inputs = Rjq::JSON::Parser.parse(input).to_a
      actual = inputs.flat_map { |value| Rjq.run(program, value).to_a }
      expected_values = expected.map { |line| Rjq::JSON::Parser.parse_one(line) }
      unless expected_values.length == actual.length && expected_values.zip(actual).all? { |left, right| Rjq::Value.equal?(left, right) }
        failures << [program, input, expected, actual.map { |value| Rjq::JSON::Dumper.dump(value, indent: nil) }]
      end
    rescue Exception => e
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
