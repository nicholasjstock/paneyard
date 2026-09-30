require "test_helper"

class ClearTest < TodoTest
  def test_removes_finished_todos
    todo("add", "Buy milk")
    todo("add", "Walk the dog")
    todo("done", "1")
    todo("clear")
    assert_equal [ "Walk the dog" ], @store.items.map(&:title)
    assert_equal "Cleared 1 finished todo(s).\n", output
  end

  def test_keeps_everything_when_nothing_is_done
    todo("add", "Buy milk")
    todo("clear")
    assert_equal 1, @store.items.size
  end
end
