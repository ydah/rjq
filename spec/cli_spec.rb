# frozen_string_literal: true

require 'spec_helper'

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

    expect(code).to eq(4)
    expect(out.string).to eq('')
    expect(err.string).to include('Cannot dump a string containing NUL with --raw-output0 option')
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

    expect(code).to eq(2)
    expect(out.string).to eq('')
    expect(err.string).to include('rjq: JSON parse error: Unfinished JSON term at EOF at line 1, column 5')
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
