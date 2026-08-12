# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Rjq::VM do
  it 'compiles simple path filters into bytecode instructions' do
    program = Rjq.compile('.foo | .[]')

    expect(program.instructions.map(&:op)).to include(:load_input, :field, :pipe)
    expect(program.disasm).to include('field "foo"')
    expect(program.disasm).to include('each')
    expect(program.disasm).not_to include('eval_node Field')
  end

  it 'executes bytecode for generated arrays and arithmetic' do
    expect(Rjq.run('[.foo, .bar] | .[] + 1', { 'foo' => 1, 'bar' => 2 }).to_a).to eq([2, 3])
  end

  it 'compiles update semantics without eval_node fallback' do
    program = Rjq.compile('.a |= . + 1')

    expect(program.instructions.map(&:op)).to include(:assign)
    expect(program.disasm).not_to include('eval_node')
    expect(program.run({ 'a' => 1 }).to_a).to eq([{ 'a' => 2 }])
  end

  it 'compiles path expressions to a dedicated path opcode' do
    program = Rjq.compile('path(.a[])')

    expect(program.instructions.map(&:op)).to eq([:path])
    expect(program.disasm).to include('path <block:')
    expect(program.run({ 'a' => [1, 2] }).to_a).to eq([['a', 0], ['a', 1]])
  end

  it 'drives linear each streams lazily for take-style builtins' do
    expect(Rjq.run('first(.[] | if . == 1 then . else error end)', [1, 2]).to_a).to eq([1])
    expect(Rjq.run('limit(2; .[] | if . < 3 then . else error end)', [1, 2, 3]).to_a).to eq([1, 2])
  end

  it 'yields top-level results lazily without evaluating later continuations' do
    expect(Rjq.compile('1, error').run(nil).next).to eq(1)
    expect(Rjq.compile('.[] | if . == 1 then . else error end').run([1, 2]).next).to eq(1)
  end

  it 'keeps branch, binary, and filter-call continuations lazy' do
    expect(Rjq.compile('if true then 1, error else 0 end').run(nil).next).to eq(1)
    expect(Rjq.compile('1 + (1, error)').run(nil).next).to eq(2)
    expect(Rjq.compile('def f(g): g; f(1, error)').run(nil).next).to eq(1)
  end

  it 'deduplicates constants and freezes executable bytecode' do
    compiled = Rjq.compile('["same", "same"]')

    expect(compiled.program.constants).to eq(['same'])
    expect(compiled).to be_frozen
    expect(compiled.program).to be_frozen
    expect(compiled.program.instructions).to be_frozen
    expect { compiled.program.constants << 'changed' }.to raise_error(FrozenError)
  end

  it 'shows blocks nested inside bytecode operand hashes' do
    disassembly = Rjq.compile('if true then 1 else 2 end').disasm

    expect(disassembly).to include('== arg2[0] ==')
    expect(disassembly).to include('== arg2[1] ==')
  end

  it 'rejects invalid bytecode stacks and unknown opcodes' do
    underflow = Rjq::Program.new(instructions: [Rjq::Instruction.new(op: :field, arg1: 'x')])
    unknown = Rjq::Program.new(instructions: [Rjq::Instruction.new(op: :unknown)])

    expect { Rjq::SemanticAnalyzer.new(underflow).validate! }
      .to raise_error(Rjq::CompileError, /stack underflow/)
    expect { Rjq::SemanticAnalyzer.new(unknown).validate! }
      .to raise_error(Rjq::CompileError, /unknown opcode/)
  end
end
