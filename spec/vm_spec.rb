# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Rjq::VM do
  it 'preserves variable source locations in bytecode' do
    instruction = Rjq.compile("\n$__loc__", source_path: '/tmp/filter.jq').instructions.first

    expect(instruction.loc).to have_attributes(filename: '/tmp/filter.jq', line: 2, column: 1)
  end

  it 'assigns locations to every nested instruction and displays them' do
    compiled = Rjq.compile(".foo | [\n$__loc__.line + 1,\ntry .[] catch .\n]", source_path: '/tmp/filter.jq')
    locations = []
    visit = lambda do |value|
      case value
      when Rjq::Instruction
        locations << value.loc
        visit.call(value.arg1)
        visit.call(value.arg2)
      when Rjq::BytecodeBlock
        visit.call(value.instructions)
      when Rjq::BytecodeFunctionDefinition
        visit.call(value.body)
      when Array
        value.each { |item| visit.call(item) }
      when Hash
        value.each_value { |item| visit.call(item) }
      end
    end
    visit.call(compiled.instructions)

    expect(locations).not_to be_empty
    expect(locations).to all(be_a(Rjq::AST::SourceSpan))
    expect(compiled.disasm).to include('@ /tmp/filter.jq:2:1', '@ /tmp/filter.jq:3:1')
  end

  it 'inherits source locations for generated instructions and disassembles definitions' do
    compiled = Rjq.compile("\ndef local:\n  if true then .foo else . end;\nlocal",
                           source_path: '/tmp/filter.jq')
    definition = compiled.program.definitions.find { |item| item.name == 'local' }

    expect(definition.body.instructions).not_to be_empty
    expect(definition.body.instructions.map(&:loc)).to all(be_a(Rjq::AST::SourceSpan))
    expect(definition.body.instructions.flat_map do |instruction|
      instruction.arg1.is_a?(Rjq::BytecodeBlock) ? instruction.arg1.instructions : []
    end.map(&:loc)).to all(be_a(Rjq::AST::SourceSpan))
    expect(compiled.disasm).to include('== definition:local/0 ==', '@ /tmp/filter.jq:3:')
  end

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

  it 'marks only structurally tail-positioned function calls for trampolining' do
    compiled = Rjq.compile('def f: if . then (. | f) else (f + 1) end; f')
    definition = compiled.program.definitions.first
    branch = definition.body.instructions.first
    then_call = branch.arg2.first.instructions.last.arg1.instructions.last
    else_call = branch.arg2.last.instructions.first.arg2.first.instructions.first

    expect(then_call.op).to eq(:tail_call)
    expect(else_call.op).to eq(:call)
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

  it 'validates lexical label bindings before execution' do
    expect { Rjq.compile('. as $foo | break $foo') }
      .to raise_error(Rjq::CompileError, /label \$foo is not defined/)
    expect(Rjq.run('label $foo | (def stop: break $foo; stop), 1', nil).to_a).to eq([])
  end


  it 'rejects computed constant non-string object keys during compilation' do
    ['{([]):1}', '{([0,1]):1}', '{({}):1}', '{(0+0):1}', '{(0|.):1}', '{(1<2):1}', '{(null):1}'].each do |filter|
      expect { Rjq.compile(filter) }.to raise_error(Rjq::CompileError, /Cannot use .* as object key/)
    end
    expect { Rjq.compile('{(-1):1}').run(nil).to_a }.to raise_error(Rjq::TypeError)
    ['{(0//1):1}', '{(false//0):1}', '{(true and false):1}', '{(false or 0):1}'].each do |filter|
      expect { Rjq.compile(filter) }.not_to raise_error
      expect { Rjq.run(filter, nil).to_a }.to raise_error(Rjq::TypeError)
    end
    expect(Rjq.run('{("a"+"b"):1}', nil).to_a).to eq([{ 'ab' => 1 }])
  end

  it 'infers constant object-key types without evaluating generated values' do
    expect_any_instance_of(Rjq::AST::BinaryOp).not_to receive(:eval)

    expect { Rjq.compile('{("a"*1000000000):1}') }.not_to raise_error
  end
end
