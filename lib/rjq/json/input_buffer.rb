# frozen_string_literal: true

module Rjq
  module JSON
    class InputBuffer
      DEFAULT_CHUNK_SIZE = 16_384

      def initialize(io_or_string, chunk_size: DEFAULT_CHUNK_SIZE)
        @io = io_or_string if io_or_string.respond_to?(:read)
        @chunk_size = chunk_size
        @offset = 0
        @eof = !@io
        @buffer = @io ? +''.b : io_or_string.to_s.dup
        normalize_encoding!
      end

      def [](index, length = nil)
        if index.is_a?(Range)
          range_end = index.end
          range_end -= 1 if index.exclude_end?
          ensure_index(range_end)
          return @buffer[local_index(index.begin)..local_index(index.end)] unless index.exclude_end?

          return @buffer[local_index(index.begin)...local_index(index.end)]
        end

        ensure_index(index + length - 1) if length
        ensure_index(index) unless length
        length ? @buffer[local_index(index), length] : @buffer[local_index(index)]
      end

      def discard_before(index)
        return if index <= @offset

        local = [index - @offset, @buffer.length].min
        @buffer = @buffer[local..].to_s
        @offset += local
      end

      private

      def ensure_index(index)
        return if index.negative?

        read_more while !@eof && index >= @offset + @buffer.length
      end

      def read_more
        loop do
          chunk = @io.read(@chunk_size)
          if chunk.nil? || chunk.empty?
            @eof = true
            validate_encoding!
            return
          end

          @buffer = @buffer.b << chunk.b
          @buffer.force_encoding(Encoding::UTF_8)
          return if @buffer.valid_encoding?

          validate_encoding! unless incomplete_utf8_suffix?
        end
      end

      def normalize_encoding!
        @buffer = @buffer.encode(Encoding::UTF_8)
        validate_encoding!
      rescue EncodingError => e
        raise JSONParseError, e.message
      end

      def validate_encoding!
        raise JSONParseError, 'invalid UTF-8 input' unless @buffer.valid_encoding?
      end

      def incomplete_utf8_suffix?
        bytes = @buffer.bytes
        start = [bytes.length - 3, 0].max
        (start...bytes.length).any? do |index|
          lead = bytes[index]
          expected = case lead
                     when 0xC2..0xDF then 2
                     when 0xE0..0xEF then 3
                     when 0xF0..0xF4 then 4
                     end
          next false unless expected

          suffix = bytes[index..]
          suffix.length < expected && suffix.drop(1).all? { |byte| byte.between?(0x80, 0xBF) } &&
            bytes[0...index].pack('C*').force_encoding(Encoding::UTF_8).valid_encoding?
        end
      end

      def local_index(index)
        index - @offset
      end
    end
  end
end
