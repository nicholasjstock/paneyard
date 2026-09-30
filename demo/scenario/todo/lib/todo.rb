require_relative "todo/item"
require_relative "todo/store"
Dir[File.join(__dir__, "todo/commands/*.rb")].sort.each { |file| require file }

module Todo
  class CLI
    def initialize(store: Store.new, out: $stdout)
      @store = store
      @out = out
    end

    def run(argv)
      name, *args = argv
      command = Commands.find(name)
      return usage unless command

      command.new(@store, @out).call(args)
      0
    rescue ArgumentError => error
      @out.puts("todo: #{error.message}")
      1
    end

    private

    def usage
      @out.puts("usage: todo <#{Commands.names.join('|')}> [args]")
      1
    end
  end

  module Commands
    def self.names
      constants.map { |name| name.to_s.downcase }.sort
    end

    def self.find(name)
      const_get(name.to_s.capitalize) if name && names.include?(name)
    end
  end
end
