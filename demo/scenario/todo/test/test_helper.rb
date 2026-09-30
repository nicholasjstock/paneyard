require "minitest/autorun"
require "stringio"
require "tmpdir"
require "todo"

class TodoTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = Todo::Store.new(path: File.join(@dir, "todo.json"))
    @out = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def todo(*argv)
    @out.truncate(0)
    @out.rewind
    Todo::CLI.new(store: @store, out: @out).run(argv)
  end

  def output
    @out.string
  end
end
