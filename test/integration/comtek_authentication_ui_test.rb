# frozen_string_literal: true

require "test_helper"

class ComtekAuthenticationUiTest < ActionDispatch::IntegrationTest
  test "sign out uses a normal browser form rather than Turbo" do
    sign_in users(:mr_admin)
    get root_path
    assert_response :success
    assert_select 'form[action*="sign_out"][data-turbo="false"]'
  end

  test "two factor entry links request fresh pages" do
    sign_in users(:mr_admin)

    get edit_user_registration_path
    assert_response :success
    assert_select 'a[href*="two_factor"][data-turbo="false"]'
  end

  test "two factor setup screens are not cached" do
    sign_in users(:mr_admin)
    get backup_codes_user_two_factor_path
    assert_response :success
    assert_equal "no-store, private", response.headers["Cache-Control"]
  end
end
