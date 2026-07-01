# frozen_string_literal: true

module Rjq
  class Error < StandardError; end

  class ParseError < Error; end

  class CompileError < Error; end

  class RuntimeError < Error; end

  class TypeError < RuntimeError; end

  class InvalidPathError < TypeError
    attr_reader :result

    def initialize(message, result)
      @result = result
      super(message)
    end
  end

  class ErrorValue < RuntimeError
    attr_reader :value, :outputs

    def initialize(value, outputs: nil)
      @value = value
      @outputs = outputs
      super(value.to_s)
    end
  end

  class HaltError < RuntimeError
    attr_reader :value, :status

    def initialize(value = nil, status = 5)
      @value = value
      @status = status
      super(value.nil? ? 'halt_error' : value.to_s)
    end
  end

  class JSONParseError < Error; end

  class BreakSignal < RuntimeError
    attr_reader :label, :value, :outputs

    def initialize(label, value = nil, outputs: nil)
      @label = label
      @value = value
      @outputs = outputs
      super("break #{label}")
    end
  end
end
