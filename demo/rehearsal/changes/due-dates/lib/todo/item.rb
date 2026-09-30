require "date"

module Todo
  Item = Struct.new(:title, :done, :due, keyword_init: true) do
    def self.from_h(hash)
      new(title: hash.fetch("title"), done: hash.fetch("done", false), due: hash["due"] && Date.parse(hash["due"]))
    end

    def to_h
      { "title" => title, "done" => done, "due" => due&.iso8601 }.compact
    end

    def to_s
      "[#{done ? 'x' : ' '}] #{title}#{" (due #{due.iso8601})" if due}"
    end
  end
end
