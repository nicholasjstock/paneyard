module Todo
  module Commands
    # todo list
    class List
      def initialize(store, out)
        @store = store
        @out = out
      end

      def call(_args)
        items = @store.items
        return @out.puts("Nothing to do.") if items.empty?

        items.each_with_index { |item, index| @out.puts("#{index + 1}. #{item}") }
      end
    end
  end
end
