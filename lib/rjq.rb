# frozen_string_literal: true

require_relative 'rjq/version'
require_relative 'rjq/errors'
require_relative 'rjq/value'
require_relative 'rjq/json/parser'
require_relative 'rjq/json/stream_parser'
require_relative 'rjq/json/dumper'
require_relative 'rjq/color'
require_relative 'rjq/path'
require_relative 'rjq/math_functions'
require_relative 'rjq/lexer'
require_relative 'rjq/ast'
require_relative 'rjq/parser'
require_relative 'rjq/builtins'
require_relative 'rjq/opcodes'
require_relative 'rjq/semantic_analyzer'
require_relative 'rjq/compiler'
require_relative 'rjq/vm'
require_relative 'rjq/modules'
require_relative 'rjq/runtime'

module Rjq
  class << self
    def compile(filter_string, opts = {})
      Compiler.new(opts).compile(filter_string)
    end

    def run(filter_string, input_value, opts = {})
      compile(filter_string, opts).run(input_value, opts)
    end

    def run_stream(filter_string, io:, opts: {}, &block)
      Runtime.new(filter_string, opts).run_stream(io, &block)
    end
  end
end
