require "test_helper"

class ListTest < TodoTest
  def test_lists_todos_numbered
    todo("add", "Buy milk")
    todo("add", "Walk the dog")
    todo("list")
    assert_equal "1. [ ] Buy milk\n2. [ ] Walk the dog\n", output
  end

  def test_says_when_there_is_nothing
    todo("list")
    assert_equal "Nothing to do.\n", output
  end
end
