module Todo
  module Commands
    # todo clear -- removes finished todos
    class Clear
      def initialize(store, out)
        @store = store
        @out = out
      end

      def call(_args)
        items = @store.items
        remaining = items.reject(&:done)
        @store.save(remaining)
        @out.puts("Cleared #{items.size - remaining.size} finished todo(s).")
      end
    end
  end
end
