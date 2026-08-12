# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'open3'
require 'rjq'

CASES = [
  ['.foo.bar', '{"foo":{"bar":1}}'],
  ['.["foo"]', '{"foo":1}'],
  ['.foo?', '1'],
  ['.[]?', '{}'],
  ['..', '{"a":[1]}'],
  ['[.[] | .+1]', '[1,2]'],
  ['{user, title}', '{"user":"u","title":"t"}'],
  ['{"x": .a, y: .b}', '{"a":1,"b":2}'],
  ['1+2*3', 'null'],
  ['(1+2)*3', 'null'],
  ['5/2', 'null'],
  ['5%2', 'null'],
  ['1==1.0', 'null'],
  ['null < false', 'null'],
  ['true and false', 'null'],
  ['true or false', 'null'],
  ['not', 'false'],
  ['empty', 'null'],
  ['try error("x") catch .', 'null'],
  ['try .[]?', '1'],
  ['def fact($n): if $n <= 1 then 1 else $n * fact($n-1) end; fact(5)', 'null'],
  ['path(.a[0].b)', '{"a":[{"b":1}]}'],
  ['paths', '{"a":[1]}'],
  ['leaf_paths', '{"a":[1]}'],
  ['delpaths([["a"]])', '{"a":1,"b":2}'],
  ['setpath([0,"a"]; 1)', '[]'],
  ['.a //= 2', '{"a":null}'],
  ['.a //= 2', '{}'],
  ['map(select(.x))', '[{"x":true},{"x":false},{"y":1}]'],
  ['any(.[]; . > 2)', '[1,3]'],
  ['all(.[]; . > 0)', '[1,3]'],
  ['min_by(.x)', '[{"x":2},{"x":1}]'],
  ['max_by(.x)', '[{"x":2},{"x":1}]'],
  ['contains([2])', '[1,2,3]'],
  ['inside({"a":1,"b":2})', '{"a":1}'],
  ['combinations', '[[1,2],[3,4]]'],
  ['combinations(2)', '[1,2]'],
  ['first(range(3))', 'null'],
  ['last(range(3))', 'null'],
  ['nth(2; range(5))', 'null'],
  ['limit(0; range(5))', 'null'],
  ['recurse(.[]?; . != null)', '[1,[2]]'],
  ['walk(if type == "number" then .+1 else . end)', '{"a":[1]}'],
  ['ltrimstr("ab")', '"abc"'],
  ['rtrimstr("bc")', '"abc"'],
  ['ascii_downcase', '"ABC"'],
  ['ascii_upcase', '"abc"'],
  ['@sh', %q(["a b","c'"])],
  ['@base64d', '"aGk="'],
  ['@base32', '"hi"'],
  ['match("a";"g")', '"aba"'],
  ['capture("(?<x>a+)")', '"aa"'],
  ['scan("a.")', '"abac"'],
  ['now | type', 'null'],
  ['"2024-01-15T12:34:56Z" | fromdateiso8601 | todateiso8601', 'null'],
  ['"2024-01-15" | strptime("%Y-%m-%d") | strftime("%Y")', 'null']
].freeze

failures = []
spec_extensions = ['leaf_paths', '@base32'].freeze
CASES.each do |filter, input|
  jq_out, jq_err, jq_status = Open3.capture3('jq', '-c', filter, stdin_data: input)
  out =
    begin
      Rjq::JSON::Parser.parse(input).to_a
                       .flat_map { |value| Rjq.run(filter, value).to_a }
                       .map { |value| Rjq::JSON::Dumper.dump(value, indent: nil) }
                       .join("\n")
    rescue StandardError => e
      "ERROR #{e.class}: #{e.message}\n"
    end
  out += "\n" unless out.empty? || out.end_with?("\n")
  next if spec_extensions.include?(filter) && !out.start_with?('ERROR ')

  failures << [filter, input, jq_status.exitstatus, jq_out, out, jq_err] unless jq_status.success? && jq_out == out
end

puts failures.first(100).map { |filter, input, status, jq_out, out, jq_err|
  "FILTER #{filter}\nINPUT=#{input}\nJQ_STATUS=#{status}\nJQ=#{jq_out.inspect}\nRJQ=#{out.inspect}\nERR=#{jq_err}"
}.join("\n---\n")
puts "failures=#{failures.length}/#{CASES.length}"
exit(failures.empty? ? 0 : 1)
