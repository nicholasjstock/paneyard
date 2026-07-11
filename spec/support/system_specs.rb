require "turbo/system_test_helper"
require "selenium/webdriver"

module RackTestTurboBypass
  def connect_turbo_cable_stream_sources(...)
    return if Capybara.current_driver == :rack_test

    super
  end
end

Turbo::SystemTestHelper.prepend(RackTestTurboBypass)

Capybara.register_driver :headless_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument("--headless=new")
  options.add_argument("--window-size=1400,1400")
  options.add_argument("--disable-gpu")
  options.add_argument("--no-sandbox")
  options.add_argument("--disable-dev-shm-usage")

  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

Capybara.server = :puma, { Silent: true }

RSpec.configure do |config|
  config.before(:each, type: :system) do
    Capybara.reset_sessions!

    driver = RSpec.current_example.metadata[:js] ? :headless_chrome : :rack_test
    driven_by(driver)

    ActiveJob::Base.queue_adapter = RSpec.current_example.metadata[:live_agent] ? :inline : :test
  end
end
