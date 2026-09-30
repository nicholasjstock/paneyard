require "json"

module Todo
  # The list, as JSON in one file (TODO_FILE, or .todo.json here).
  class Store
    def initialize(path: ENV.fetch("TODO_FILE", ".todo.json"))
      @path = path
    end

    def items
      return [] unless File.exist?(@path)

      JSON.parse(File.read(@path)).map { |hash| Item.from_h(hash) }
    end

    def save(items)
      File.write(@path, JSON.pretty_generate(items.map(&:to_h)))
    end
  end
end
