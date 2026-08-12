# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Rjq::CLI do
  it 'runs a compact-output filter against stdin' do
    out = StringIO.new
    err = StringIO.new
    code = described_class.new(['-c', '.foo'], stdin: StringIO.new('{"foo":[1,2]}'), stdout: out, stderr: err).run

    expect(code).to eq(0)
    expect(err.string).to eq('')
    expect(out.string).to eq("[1,2]\n")
  end

  it 'binds --argjson values' do
    out = StringIO.new
    code = described_class.new(['-n', '-c', '--argjson', 'x', '2', '$x + 3'], stdin: StringIO.new, stdout: out,
                                                                              stderr: StringIO.new).run

    expect(code).to eq(0)
    expect(out.string).to eq("5\n")
  end

  it 'consumes remaining inputs with inputs' do
    out = StringIO.new
    code = described_class.new(['-c', 'inputs'], stdin: StringIO.new("1\n2\n3\n"), stdout: out,
                                                 stderr: StringIO.new).run

    expect(code).to eq(0)
    expect(out.string).to eq("2\n3\n")
  end

  it 'keeps stdin available to inputs with null input' do
    out = StringIO.new
    code = described_class.new(['-n', '-c', '[inputs]'], stdin: StringIO.new("1\n2\n3\n"), stdout: out,
                                                       stderr: StringIO.new).run

    expect(code).to eq(0)
    expect(out.string).to eq("[1,2,3]\n")
  end

  it 'treats multiple files as one logical input stream' do
    Dir.mktmpdir do |dir|
      first = File.join(dir, 'first.json')
      second = File.join(dir, 'second.json')
      File.write(first, "1\n")
      File.write(second, "2\n3\n")
      out = StringIO.new

      code = described_class.new(['-c', 'inputs', first, second], stdin: StringIO.new, stdout: out,
                                                                   stderr: StringIO.new).run

      expect(code).to eq(0)
      expect(out.string).to eq("2\n3\n")
    end
  end

  it 'slurps JSON and raw input globally across files' do
    Dir.mktmpdir do |dir|
      first = File.join(dir, 'first')
      second = File.join(dir, 'second')
      File.write(first, "1\n")
      File.write(second, "2\n")

      json_out = StringIO.new
      json_code = described_class.new(['-sc', '.', first, second], stdin: StringIO.new, stdout: json_out,
                                                                  stderr: StringIO.new).run
      raw_out = StringIO.new
      raw_code = described_class.new(['-Rsrc', '.', first, second], stdin: StringIO.new, stdout: raw_out,
                                                                    stderr: StringIO.new).run

      expect(json_code).to eq(0)
      expect(json_out.string).to eq("[1,2]\n")
      expect(raw_code).to eq(0)
      expect(raw_out.string).to eq("1\n2\n\n")
    end
  end

  it 'runs null-input once without opening files unless input is requested' do
    missing = File.join(Dir.tmpdir, "rjq-missing-#{Process.pid}")
    out = StringIO.new

    code = described_class.new(['-nc', '.', missing], stdin: StringIO.new, stdout: out,
                                                       stderr: StringIO.new).run

    expect(code).to eq(0)
    expect(out.string).to eq("null\n")

    err = StringIO.new
    code = described_class.new(['-nc', 'input', missing], stdin: StringIO.new, stdout: StringIO.new,
                                                           stderr: err).run
    expect(code).to eq(2)
    expect(err.string).to include('No such file')
  end

  it 'accepts a dash as stdin among input files' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'input.json')
      File.write(path, "1\n")
      out = StringIO.new

      code = described_class.new(['-c', '.', path, '-'], stdin: StringIO.new("2\n"), stdout: out,
                                                            stderr: StringIO.new).run

      expect(code).to eq(0)
      expect(out.string).to eq("1\n2\n")
    end
  end

  it 'preserves earlier output when a later file has invalid JSON' do
    Dir.mktmpdir do |dir|
      first = File.join(dir, 'first.json')
      second = File.join(dir, 'second.json')
      File.write(first, "1\n")
      File.write(second, '{')
      out = StringIO.new
      err = StringIO.new

      code = described_class.new(['-c', '.', first, second], stdin: StringIO.new, stdout: out, stderr: err).run

      expect(code).to eq(5)
      expect(out.string).to eq("1\n")
      expect(err.string).to include('JSON parse error')
    end
  end

  it 'tracks input filenames and line numbers across files and input calls' do
    Dir.mktmpdir do |dir|
      first = File.join(dir, 'first.json')
      second = File.join(dir, 'second.json')
      File.write(first, "1\n2\n")
      File.write(second, "3\n")
      out = StringIO.new

      filter = '[input, input_filename, input_line_number, input, input_filename, input_line_number]'
      code = described_class.new(['-nc', filter, first, second], stdin: StringIO.new, stdout: out,
                                                               stderr: StringIO.new).run

      expect(code).to eq(0)
      expect(out.string).to eq("[1,\"#{first}\",1,2,\"#{first}\",2]\n")
    end
  end

  it 'prints debug output to stderr and passes through input' do
    out = StringIO.new
    err = StringIO.new
    code = described_class.new(['-c', 'debug'], stdin: StringIO.new("1\n"), stdout: out, stderr: err).run

    expect(code).to eq(0)
    expect(out.string).to eq("1\n")
    expect(err.string).to eq("[\"DEBUG:\",1]\n")
  end

  it 'supports raw-output0 NUL separators' do
    out = StringIO.new
    code = described_class.new(['-n', '--raw-output0', '"a", "b"'], stdin: StringIO.new, stdout: out,
                                                                    stderr: StringIO.new).run

    expect(code).to eq(0)
    expect(out.string).to eq("a\0b\0")
  end

  it 'rejects raw-output0 strings containing NUL' do
    out = StringIO.new
    err = StringIO.new
    code = described_class.new(['-n', '--raw-output0', '"a\u0000b"'], stdin: StringIO.new, stdout: out,
                                                                          stderr: err).run

    expect(code).to eq(5)
    expect(out.string).to eq('')
    expect(err.string).to include('Cannot dump a string containing NUL with --raw-output0 option')
  end

  it 'uses jq-compatible statuses for runtime and input parse errors' do
    out = StringIO.new
    err = StringIO.new
    code = described_class.new(['-n', '1, error("x")'], stdin: StringIO.new, stdout: out, stderr: err).run

    expect(code).to eq(5)
    expect(out.string).to eq("1\n")
    expect(err.string).to include('runtime error: x')

    err = StringIO.new
    code = described_class.new(['.'], stdin: StringIO.new('{'), stdout: StringIO.new, stderr: err).run
    expect(code).to eq(5)
    expect(err.string).to include('JSON parse error')
  end

  it 'uses halt statuses and does not let try catch halt' do
    code = described_class.new(['-n', 'try halt catch "caught"'], stdin: StringIO.new, stdout: StringIO.new,
                                                               stderr: StringIO.new).run
    expect(code).to eq(0)

    code = described_class.new(['-n', 'try halt_error(7) catch "caught"'], stdin: StringIO.new,
                                                                        stdout: StringIO.new,
                                                                        stderr: StringIO.new).run
    expect(code).to eq(7)
  end

  it 'treats invalid --argjson as an option error' do
    err = StringIO.new
    code = described_class.new(['-n', '--argjson', 'x', '{', '$x'], stdin: StringIO.new, stdout: StringIO.new,
                                                                    stderr: err).run

    expect(code).to eq(2)
    expect(err.string).to include('invalid JSON text passed to --argjson')
  end

  it 'finds the filter after -- and keeps -f positionals as input files' do
    Dir.mktmpdir do |dir|
      input_path = File.join(dir, 'input.json')
      filter_path = File.join(dir, 'filter.jq')
      File.write(input_path, '{"foo":1}')
      File.write(filter_path, '.foo')

      out = StringIO.new
      code = described_class.new(['-c', '--', '.foo', input_path], stdin: StringIO.new, stdout: out,
                                                                    stderr: StringIO.new).run
      expect(code).to eq(0)
      expect(out.string).to eq("1\n")

      out = StringIO.new
      code = described_class.new(['-c', '-f', filter_path, input_path], stdin: StringIO.new, stdout: out,
                                                                         stderr: StringIO.new).run
      expect(code).to eq(0)
      expect(out.string).to eq("1\n")
    end
  end

  it 'supports join-output without separators' do
    out = StringIO.new
    code = described_class.new(['-n', '-j', '"a", "b"'], stdin: StringIO.new, stdout: out, stderr: StringIO.new).run

    expect(code).to eq(0)
    expect(out.string).to eq('ab')
  end

  it 'preserves negative zero literals' do
    out = StringIO.new
    code = described_class.new(['-n', '-c', '[-0]'], stdin: StringIO.new, stdout: out, stderr: StringIO.new).run

    expect(code).to eq(0)
    expect(out.string).to eq("[-0]\n")
  end

  it 'emits jq-compatible --stream close markers' do
    out = StringIO.new
    err = StringIO.new
    code = described_class.new(['-c', '--stream', '.'], stdin: StringIO.new('{"a":[1,2],"b":{}}'), stdout: out,
                                                        stderr: err).run

    expect(code).to eq(0)
    expect(err.string).to eq('')
    expect(out.string).to eq(<<~OUTPUT)
      [["a",0],1]
      [["a",1],2]
      [["a",1]]
      [["b"],{}]
      [["b"]]
    OUTPUT
  end

  it 'emits jq-compatible --stream-errors arrays' do
    out = StringIO.new
    err = StringIO.new
    code = described_class.new(['-c', '--stream-errors', '.'], stdin: StringIO.new('{"a":[1,'), stdout: out,
                                                               stderr: err).run

    expect(code).to eq(0)
    expect(err.string).to eq('')
    expect(out.string).to eq(<<~OUTPUT)
      [["a",0],1]
      ["Unfinished JSON term at EOF at line 1, column 8",["a",1]]
    OUTPUT
  end

  it 'reports stream parse errors unless --stream-errors is enabled' do
    out = StringIO.new
    err = StringIO.new
    code = described_class.new(['-c', '--stream', '.'], stdin: StringIO.new('{"a":'), stdout: out, stderr: err).run

    expect(code).to eq(5)
    expect(out.string).to eq('')
    expect(err.string).to include('rjq: JSON parse error: Unfinished JSON term at EOF at line 1, column 5')
  end

  it 'warns and continues after malformed JSON sequence records' do
    out = StringIO.new
    err = StringIO.new
    input = "\x1e1\n\x1ex\n\x1e2\n"

    code = described_class.new(['-c', '--seq', '.'], stdin: StringIO.new(input), stdout: out, stderr: err).run

    expect(code).to eq(0)
    expect(out.string).to eq("\x1e1\n\x1e2\n")
    expect(err.string).to include('rjq: ignoring parse error:')
  end

  it 'consumes --args after the filter like jq' do
    out = StringIO.new
    code = described_class.new(['-n', '--args', '$ARGS.positional', 'a', 'b'], stdin: StringIO.new, stdout: out,
                                                                               stderr: StringIO.new).run

    expect(code).to eq(0)
    expect(out.string).to eq("[\n  \"a\",\n  \"b\"\n]\n")
  end

  it 'consumes --jsonargs after the filter like jq' do
    out = StringIO.new
    code = described_class.new(['-n', '-c', '--jsonargs', '$ARGS.positional', '1', '{"a":2}'], stdin: StringIO.new,
                                                                                               stdout: out, stderr: StringIO.new).run

    expect(code).to eq(0)
    expect(out.string).to eq("[1,{\"a\":2}]\n")
  end

  it 'prints build configuration' do
    out = StringIO.new

    expect do
      described_class.new(['--build-configuration'], stdin: StringIO.new, stdout: out, stderr: StringIO.new).run
    end
      .to raise_error(SystemExit) { |error| expect(error.status).to eq(0) }
    expect(out.string).to include('--with-oniguruma=')
  end

  it 'prints jq-compatible help with all documented options' do
    out = StringIO.new

    expect { described_class.new(['--help'], stdin: StringIO.new, stdout: out, stderr: StringIO.new).run }
      .to raise_error(SystemExit) { |error| expect(error.status).to eq(0) }
    expect(out.string).to include('--raw-output0')
    expect(out.string).to include('--slurpfile name file')
    expect(out.string).to include('--rawfile name file')
    expect(out.string).to include('--args')
    expect(out.string).to include('--jsonargs')
    expect(out.string).to include('--exit-status')
    expect(out.string).to include('--')
  end

  it 'returns option exit status for unknown and incomplete options' do
    err = StringIO.new
    code = described_class.new(['--foo', '-n', '.'], stdin: StringIO.new, stdout: StringIO.new, stderr: err).run

    expect(code).to eq(2)
    expect(err.string).to include('Unknown option --foo')

    err = StringIO.new
    code = described_class.new(['--arg'], stdin: StringIO.new, stdout: StringIO.new, stderr: err).run

    expect(code).to eq(2)
    expect(err.string).to include('--arg takes two parameters')
  end

  it 'supports jq --run-tests compatibility mode' do
    out = StringIO.new
    code = described_class.new(['--run-tests'], stdin: StringIO.new(".\n1\n1\n"), stdout: out, stderr: StringIO.new).run

    expect(code).to eq(0)
    expect(out.string).to eq("Test #1: '.' at line number 1\n1 of 1 tests passed (0 malformed, 0 skipped)\n")
  end
end
