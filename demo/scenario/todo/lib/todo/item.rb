module Todo
  Item = Struct.new(:title, :done, keyword_init: true) do
    def self.from_h(hash)
      new(title: hash.fetch("title"), done: hash.fetch("done", false))
    end

    def to_h
      { "title" => title, "done" => done }
    end

    def to_s
      "[#{done ? 'x' : ' '}] #{title}"
    end
  end
end
