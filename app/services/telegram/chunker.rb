module Telegram
  # Splits long text into pieces that each fit one Telegram message, on line
  # boundaries rather than mid-word. A fenced code block cut in two is closed
  # at the end of one piece and reopened (same info string) at the start of
  # the next, so each piece still renders on its own.
  module Chunker
    module_function

    FENCE = /\A\s*(```|~~~)(.*)\z/

    def split(text, limit: Client::MAX_MESSAGE_LENGTH - 96)
      chunks = []
      current = +""
      open_fence = nil

      text.to_s.each_line do |line|
        line.scan(/.{1,#{limit / 2}}/m).each do |piece|
          if current.length + piece.length > limit - 8 && current.present?
            chunks << (open_fence ? "#{current.chomp}\n#{open_fence[:marker]}\n" : current)
            current = open_fence ? +"#{open_fence[:marker]}#{open_fence[:info]}\n" : +""
          end
          current << piece
        end

        if (match = line.chomp.match(FENCE))
          open_fence = open_fence ? nil : { marker: match[1], info: match[2] }
        end
      end

      chunks << current if current.present?
      chunks.map(&:rstrip)
    end

    # The newest lines of a pane, trimmed from the top to fit.
    def tail(text, limit:)
      lines = text.to_s.rstrip.lines
      lines.shift while lines.sum(&:length) > limit && lines.size > 1
      lines.join.then { |kept| kept.length > limit ? kept[-limit..] : kept }
    end
  end
end
