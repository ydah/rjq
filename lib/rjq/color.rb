# frozen_string_literal: true

module Rjq
  module Color
    DEFAULT = ['1;30', '0;39', '0;39', '0;39', '0;32', '1;39', '1;39', '1;34'].freeze

    module_function

    def colorize(json)
      colors = (ENV['RJQ_COLORS'] || ENV.fetch('JQ_COLORS', nil)).to_s.split(':')
      colors = DEFAULT unless valid_colors?(colors)
      json.gsub(/"(?:\\.|[^"\\])*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\b(?:null|true|false)\b|[\[\]{}]/) do |token|
        remainder = json[Regexp.last_match.end(0)..].to_s
        object_key = token.start_with?('"') && remainder.match?(/\A\s*:/)
        color = color_for(token, colors, object_key: object_key)
        color ? "\e[#{color}m#{token}\e[0m" : token
      end
    end

    def color_for(token, colors, object_key: false)
      case token
      when 'null' then colors[0]
      when 'false' then colors[1]
      when 'true' then colors[2]
      when /\A-?\d/ then colors[3]
      when /\A"/ then object_key ? colors[7] : colors[4]
      when '[', ']' then colors[5]
      when '{', '}' then colors[6]
      end
    end

    def valid_colors?(colors)
      colors.length >= 8 && colors.first(8).all? { |color| color.match?(/\A\d{1,3}(?:;\d{1,3})*\z/) }
    end
  end
end
