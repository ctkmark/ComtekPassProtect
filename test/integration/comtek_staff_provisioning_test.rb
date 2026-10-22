# frozen_string_literal: true

require "test_helper"
require "rotp"

class ComtekStaffProvisioningTest < ActionDispatch::IntegrationTest
  def setup
    @admin = users(:mr_admin)
    @standard = users(:luca)
  end

  test "admin can create a standard account without public registration" do
    sign_in @admin

    assert_difference -> { User.count }, 1 do
      post admin_users_path, params: {
        user: {
          email: "New.Staff@example.org ",
          role: "standard",
          password: "Unique-Staff-Password-012345",
          password_confirmation: "Unique-Staff-Password-012345"
        }
      }
    end

    assert_response :see_other
    created = User.find_by!(email: "new.staff@example.org")
    assert_not created.admin?
    assert created.valid_password?("Unique-Staff-Password-012345")
    assert_user_confirmed created
  end

  test "admin can create an additional administrator" do
    sign_in @admin

    assert_difference -> { User.count }, 1 do
      post admin_users_path, params: {
        user: {
          email: "second-admin@example.org",
          role: "admin",
          password: "Unique-Admin-Password-012345",
          password_confirmation: "Unique-Admin-Password-012345"
        }
      }
    end

    assert_response :see_other
    created = User.find_by!(email: "second-admin@example.org")
    assert created.admin?
    assert_user_confirmed created
  end

  test "normal user cannot create staff accounts or assign roles" do
    sign_in @standard

    assert_no_difference -> { User.count } do
      post "/admin/users", params: {
        user: {email: "unauthorised@example.org", role: "admin",
          password: "Unique-Password-012345", password_confirmation: "Unique-Password-012345"}
      }
    end

    assert_response :not_found
  end

  test "anonymous users cannot create accounts" do
    assert_no_difference -> { User.count } do
      post "/admin/users", params: {
        user: {email: "anonymous@example.org", role: "standard",
          password: "Unique-Password-012345", password_confirmation: "Unique-Password-012345"}
      }
    end

    assert_response :not_found
  end

  test "invalid role and mismatched password do not create accounts" do
    sign_in @admin

    assert_no_difference -> { User.count } do
      post admin_users_path, params: {
        user: {email: "elevate@example.org", role: "super-admin",
          password: "Unique-Password-012345", password_confirmation: "Unique-Password-012345"}
      }
    end
    assert_response :redirect

    assert_no_difference -> { User.count } do
      post admin_users_path, params: {
        user: {email: "invalid@example.org", role: "standard",
          password: "Unique-Password-012345", password_confirmation: "Different-Password-012345"}
      }
    end
    assert_response :unprocessable_content
    assert_select 'input[type=password][value]', count: 0
  end
end
