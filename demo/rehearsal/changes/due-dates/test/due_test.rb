require "test_helper"

class DueTest < TodoTest
  def test_adds_a_todo_with_a_due_date
    todo("add", "Pay rent", "--due", "2026-10-01")
    assert_equal Date.new(2026, 10, 1), @store.items.first.due
  end

  def test_lists_the_due_date
    todo("add", "Pay rent", "--due", "2026-10-01")
    todo("list")
    assert_equal "1. [ ] Pay rent (due 2026-10-01)\n", output
  end

  def test_rejects_a_bad_date
    assert_equal 1, todo("add", "Pay rent", "--due", "someday")
    assert_match(/--due needs a date/, output)
  end
end
