require "test_helper"

class DoneTest < TodoTest
  def test_marks_a_todo_done
    todo("add", "Buy milk")
    todo("done", "1")
    assert @store.items.first.done
  end

  def test_rejects_a_missing_number
    todo("add", "Buy milk")
    assert_equal 1, todo("done", "2")
  end
end
