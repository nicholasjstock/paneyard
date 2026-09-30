require "date"

module Todo
  module Commands
    # todo add "Buy milk" [--due 2026-10-01]
    class Add
      def initialize(store, out)
        @store = store
        @out = out
      end

      def call(args)
        due = parse_due(args)
        title = args.join(" ").strip
        raise ArgumentError, "add needs a title" if title.empty?

        @store.save(@store.items << Item.new(title:, done: false, due:))
        @out.puts("Added: #{title}#{" (due #{due.iso8601})" if due}")
      end

      private

      def parse_due(args)
        index = args.index("--due")
        return unless index

        _flag, value = args.slice!(index, 2)
        Date.iso8601(value.to_s)
      rescue Date::Error
        raise ArgumentError, "--due needs a date like 2026-10-01"
      end
    end
  end
end
