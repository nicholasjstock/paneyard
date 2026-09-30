module Todo
  module Commands
    # todo add "Buy milk"
    class Add
      def initialize(store, out)
        @store = store
        @out = out
      end

      def call(args)
        title = args.join(" ").strip
        raise ArgumentError, "add needs a title" if title.empty?

        @store.save(@store.items << Item.new(title:, done: false))
        @out.puts("Added: #{title}")
      end
    end
  end
end
