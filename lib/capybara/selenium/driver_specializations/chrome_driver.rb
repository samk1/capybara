# frozen_string_literal: true

require 'capybara/selenium/nodes/chrome_node'
require 'capybara/selenium/patches/logs'

module Capybara::Selenium::Driver::ChromeDriver
  def self.extended(base)
    bridge = base.send(:bridge)
    bridge.extend Capybara::Selenium::ChromeLogs unless bridge.respond_to?(:log)
    bridge.extend Capybara::Selenium::IsDisplayed unless bridge.send(:commands, :is_element_displayed)
    base.options[:native_displayed] = false if base.options[:native_displayed].nil?
  end

  def fullscreen_window(handle)
    within_given_window(handle) do
      super
    rescue NoMethodError => e
      raise unless e.message.include?('full_screen_window')

      result = bridge.http.call(:post, "session/#{bridge.session_id}/window/fullscreen", {})
      result['value']
    end
  end

  def resize_window_to(handle, width, height)
    super
  rescue Selenium::WebDriver::Error::UnknownError => e
    raise unless e.message.include?('failed to change window state')

    # Chromedriver doesn't wait long enough for state to change when coming out of fullscreen
    # and raises unnecessary error. Wait a bit and try again.
    sleep 0.25
    super
  end

  def reset!
    # Use instance variable directly so we avoid starting the browser just to reset the session
    return unless @browser

    switch_to_window(window_handles.first)
    window_handles.slice(1..).each { |win| close_window(win) }
    return super if chromedriver_version < 73

    timer = Capybara::Helpers.timer(expire_in: 10)
    begin
      clear_storage unless uniform_storage_clear?
      @browser.navigate.to('about:blank')
      wait_for_empty_page(timer)
    rescue *unhandled_alert_errors
      accept_unhandled_reset_alert
      retry
    end

    execute_cdp('Storage.clearDataForOrigin', origin: '*', storageTypes: storage_types_to_clear)
  end

  def filter_full_ax_tree(role: nil, accessible_name: nil)
    role_filter = lambda do |node|
      node.dig('role', 'value') == role
    end

    accessible_name_filter = lambda do |node|
      node.dig('name', 'value') == accessible_name
    end

    visit_frames = lambda do |frame_tree, &block|
      block.call(frame_tree['frame'])
      frame_tree['childFrames'].each do |child_frame|
        visit_frames.call(child_frame, &block)
      end
    end

    frame_id = bridge.window_handle

    loader_id = execute_cdp('Page.getFrameTree').then do |frame_tree|
      frame_enumerator = Enumerator.new do |y|
        visit_frames.call(frame_tree['frameTree']) do |frame|
          y << frame
        end
      end

      frame = frame_enumerator.find { |f| f['id'] == frame_id }
      frame['loaderId']
    end

    execute_cdp('Accessibility.getFullAXTree').then do |tree|
      tree['nodes'].filter!(&role_filter) if role
      tree['nodes'].filter!(&accessible_name_filter) if accessible_name
      tree['nodes'].map do |node|
        Selenium::WebDriver::Element.new(
          bridge,
          ['f', frame_id, 'd', loader_id, 'e', node['backendDOMNodeId']].join('.')
        )
      end
    end
  end

private

  def storage_types_to_clear
    types = ['cookies']
    types << 'local_storage' if clear_all_storage?
    types.join(',')
  end

  def clear_all_storage?
    storage_clears.none? false
  end

  def uniform_storage_clear?
    storage_clears.uniq { |s| s == false }.length <= 1
  end

  def storage_clears
    options.values_at(:clear_session_storage, :clear_local_storage)
  end

  def clear_storage
    # Chrome errors if attempt to clear storage on about:blank
    # In W3C mode it crashes chromedriver
    url = current_url
    super unless url.nil? || url.start_with?('about:')
  end

  def delete_all_cookies
    execute_cdp('Network.clearBrowserCookies')
  rescue *cdp_unsupported_errors
    # If the CDP clear isn't supported do original limited clear
    super
  end

  def cdp_unsupported_errors
    @cdp_unsupported_errors ||= [Selenium::WebDriver::Error::WebDriverError]
  end

  def execute_cdp(cmd, params = {})
    if browser.respond_to? :execute_cdp
      browser.execute_cdp(cmd, **params)
    else
      args = { cmd: cmd, params: params }
      result = bridge.http.call(:post, "session/#{bridge.session_id}/goog/cdp/execute", args)
      result['value']
    end
  end

  def build_node(native_node, initial_cache = {})
    ::Capybara::Selenium::ChromeNode.new(self, native_node, initial_cache)
  end

  def chromedriver_version
    @chromedriver_version ||= begin
      caps = browser.capabilities
      caps['chrome']&.fetch('chromedriverVersion', nil).to_f
    end
  end
end

Capybara::Selenium::Driver.register_specialization :chrome, Capybara::Selenium::Driver::ChromeDriver
