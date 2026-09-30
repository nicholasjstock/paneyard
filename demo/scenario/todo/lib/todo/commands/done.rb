module Todo
  module Commands
    # todo done 2
    class Done
      def initialize(store, out)
        @store = store
        @out = out
      end

      def call(args)
        items = @store.items
        index = Integer(args.first.to_s, exception: false)
        raise ArgumentError, "done needs the number of a todo" unless index&.between?(1, items.size)

        items[index - 1].done = true
        @store.save(items)
        @out.puts("Done: #{items[index - 1].title}")
      end
    end
  end
end
