require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "normalizes and validates email addresses" do
    user = User.new(email_address: "  Person@Example.COM ", password: "password123", password_confirmation: "password123")

    assert user.valid?
    assert_equal "person@example.com", user.email_address
  end

  test "limits passwords by bcrypt byte length" do
    user = User.new(email_address: "emoji@example.com", password: "🔒" * 19, password_confirmation: "🔒" * 19)

    assert_not user.valid?
    assert user.errors[:password].any?
  end

  test "rejects a duplicate email address regardless of case" do
    user = User.new(email_address: "ALICE@example.com", password: "password123", password_confirmation: "password123")

    assert_not user.valid?
    assert user.errors[:email_address].any?
  end
end
