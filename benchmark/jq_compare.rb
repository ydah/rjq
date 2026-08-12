# frozen_string_literal: true

require 'benchmark'
require 'open3'
require 'rbconfig'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'rjq'

Scenario = Struct.new(:name, :jq_filter, :input, keyword_init: true)

SCENARIOS = [
  Scenario.new(
    name: 'select-map',
    jq_filter: 'map(select(.value >= 500) | {id, value}) | length',
    input: Rjq::JSON::Dumper.dump(
      Array.new(1_000) { |index| { 'id' => index, 'value' => index % 997, 'name' => "row-#{index}" } },
      indent: nil
    )
  ),
  Scenario.new(
    name: 'recursive-paths',
    jq_filter: '[paths(scalars)] | length',
    input: Rjq::JSON::Dumper.dump(
      { 'root' => Array.new(100) { |index| { 'a' => index, 'b' => [index, index + 1], 'c' => { 'd' => index * 2 } } } },
      indent: nil
    )
  ),
  Scenario.new(
    name: 'regex-gsub',
    jq_filter: 'gsub("(?<word>[A-Za-z]+)"; "\(.word|ascii_downcase)")',
    input: Rjq::JSON::Dumper.dump(('Alpha BRAVO Charlie ' * 500).strip, indent: nil)
  )
].freeze

ITERATIONS = Integer(ENV.fetch('ITERATIONS', '10'))
ROOT = File.expand_path('..', __dir__)
RJQ = [RbConfig.ruby, File.join(ROOT, 'bin/rjq'), '-c'].freeze
JQ = ['jq', '-c'].freeze

def jq_available?
  system('jq', '--version', out: File::NULL, err: File::NULL)
end

def run_command(command, filter, input)
  stdout, stderr, status = Open3.capture3(*(command + [filter]), stdin_data: input)
  raise "#{command.first} failed: #{stderr}" unless status.success?

  stdout
end

def measure(command, scenario)
  run_command(command, scenario.jq_filter, scenario.input)
  Array.new(ITERATIONS) do
    Benchmark.realtime { run_command(command, scenario.jq_filter, scenario.input) }
  end
end

def milliseconds(seconds)
  (seconds * 1000).round(2)
end

jq_available = jq_available?

def percentile(samples, fraction)
  sorted = samples.sort
  sorted[[(sorted.length * fraction).ceil - 1, 0].max]
end

puts '| scenario | rjq median ms | rjq p95 ms | jq median ms | jq p95 ms | jq/rjq |'
puts '| --- | ---: | ---: | ---: | ---: | ---: |'

SCENARIOS.each do |scenario|
  rjq_times = measure(RJQ, scenario)
  rjq_median = percentile(rjq_times, 0.5)
  if jq_available
    rjq_output = run_command(RJQ, scenario.jq_filter, scenario.input)
    jq_output = run_command(JQ, scenario.jq_filter, scenario.input)
    raise "output mismatch for #{scenario.name}" unless rjq_output == jq_output

    jq_times = measure(JQ, scenario)
    jq_median = percentile(jq_times, 0.5)
    ratio = jq_median / rjq_median
    puts "| #{scenario.name} | #{milliseconds(rjq_median)} | #{milliseconds(percentile(rjq_times, 0.95))} | " \
         "#{milliseconds(jq_median)} | #{milliseconds(percentile(jq_times, 0.95))} | #{ratio.round(2)} |"
  else
    puts "| #{scenario.name} | #{milliseconds(rjq_median)} | #{milliseconds(percentile(rjq_times, 0.95))} | " \
         'n/a | n/a | n/a |'
  end
end
