# frozen_string_literal: true

require "test_helper"

# Comtek branding must be consistent even when the application responds
# with a static public error document instead of the Rails app layout.
class ComtekBrandingTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "admin shell uses Comtek PassProtect lockup and favicon" do
    sign_in users(:mr_admin)

    get admin_root_path
    assert_response :success
    assert_select "title", text: /Comtek PassProtect/
    assert_select "aside .comtek-product-lockup .comtek-product-company", text: "Comtek"
    assert_select "aside .comtek-product-lockup .comtek-product-service", text: "PassProtect"
    assert_select 'link[rel="icon"][href*="comtek-passprotect-icon.svg"]'

    get madmin_root_path
    assert_response :success
    assert_select "title", text: /Comtek PassProtect/
    assert_select "aside .comtek-product-lockup .comtek-product-company", text: "Comtek"
    assert_select "aside .comtek-product-lockup .comtek-product-service", text: "PassProtect"
    assert_select 'link[rel="icon"][href*="comtek-passprotect-icon.svg"]'
  end

  test "standalone error pages carry Comtek PassProtect branding" do
    %w[404.html 422.html 500.html 406-unsupported-browser.html maintenance.html].each do |filename|
      html = Rails.root.join("public", filename).read
      assert_includes html, "Comtek PassProtect", filename
      assert_includes html, "comtek-passprotect-icon.svg", filename
      assert_includes html, "#4B157B", filename
      assert_not_includes html, "Password Pusher", filename
      assert_not_includes html, "docs.pwpush.com", filename
    end
  end

  test "login page includes a CSRF form field" do
    get new_user_session_path
    assert_response :success
    assert_select 'form input[name="authenticity_token"]'
    assert_select 'meta[name="csrf-token"]'
  end
end
