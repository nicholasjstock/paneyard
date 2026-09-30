require "test_helper"

class AddTest < TodoTest
  def test_adds_a_todo
    assert_equal 0, todo("add", "Buy", "milk")
    assert_equal [ "Buy milk" ], @store.items.map(&:title)
  end

  def test_needs_a_title
    assert_equal 1, todo("add")
    assert_match(/needs a title/, output)
  end
end
