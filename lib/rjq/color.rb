# frozen_string_literal: true

module Rjq
  module Color
    DEFAULT = ['1;30', '0;39', '0;39', '0;39', '0;32', '1;39', '1;39', '1;34'].freeze

    module_function

    def colorize(json)
      colors = (ENV['RJQ_COLORS'] || ENV.fetch('JQ_COLORS', nil)).to_s.split(':')
      colors = DEFAULT if colors.length < 8
      json.gsub(/"(?:\\.|[^"\\])*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\b(?:null|true|false)\b|[\[\]{}]/) do |token|
        color = color_for(token, colors)
        color ? "\e[#{color}m#{token}\e[0m" : token
      end
    end

    def color_for(token, colors)
      case token
      when 'null' then colors[0]
      when 'false' then colors[1]
      when 'true' then colors[2]
      when /\A-?\d/ then colors[3]
      when /\A"/ then colors[4]
      when '[', ']' then colors[5]
      when '{', '}' then colors[6]
      end
    end
  end
end
