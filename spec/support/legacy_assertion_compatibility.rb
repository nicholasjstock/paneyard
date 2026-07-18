module LegacyAssertionCompatibility
  def assert(value, message = nil)
    expect(value).to be_truthy, message
  end

  def refute(value, message = nil)
    expect(value).to be_falsey, message
  end
  alias_method :assert_not, :refute

  def assert_equal(expected, actual, message = nil)
    expect(actual).to eq(expected), message
  end

  def assert_nil(actual, message = nil)
    expect(actual).to be_nil, message
  end

  def assert_not_nil(actual, message = nil)
    expect(actual).not_to be_nil, message
  end

  def assert_empty(actual, message = nil)
    expect(actual).to be_empty, message
  end

  def assert_includes(collection, item, message = nil)
    expect(collection).to include(item), message
  end

  def assert_not_includes(collection, item, message = nil)
    expect(collection).not_to include(item), message
  end

  def assert_match(pattern, actual, message = nil)
    expect(actual).to match(pattern), message
  end

  def assert_in_delta(expected, actual, delta = 0.001, message = nil)
    expect(actual).to be_within(delta).of(expected), message
  end

  def assert_operator(actual, operator, expected, message = nil)
    expect(actual.public_send(operator, expected)).to be(true), message
  end

  def assert_raises(*errors, &block)
    raised = nil
    expect { block.call }.to raise_error(*errors) { |error| raised = error }
    raised
  end

  def assert_nothing_raised(&block)
    expect(&block).not_to raise_error
  end

  def assert_difference(expression, difference = 1)
    before = expression.call
    yield
    expect(expression.call - before).to eq(difference)
  end
end
