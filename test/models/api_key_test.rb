require "test_helper"

class ApiKeyTest < ActiveSupport::TestCase
  TEST_TOKEN = "pht_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

  test "generates a displayable key once and stores only a digest" do
    key = users(:alice).api_keys.create!(name: "Build agent")

    assert_match ApiKey::TOKEN_FORMAT, key.plain_key
    assert_equal key.plain_key.first(ApiKey::PREFIX_LENGTH), key.key_prefix
    assert_equal ApiKey.digest(key.plain_key), key.key_digest
    assert_nil ApiKey.find(key.id).plain_key
  end

  test "authenticates active keys and rejects revoked or malformed keys" do
    assert_equal api_keys(:alice_agent), ApiKey.authenticate(TEST_TOKEN)

    api_keys(:alice_agent).revoke!

    assert_nil ApiKey.authenticate(TEST_TOKEN)
    assert_nil ApiKey.authenticate("wrong")
    assert_nil ApiKey.authenticate(nil)
  end


  test "destroying a scoped folder revokes keys instead of widening their access" do
    key = users(:alice).api_keys.create!(name: "Scoped", folder: folders(:projects))
    plain_key = key.plain_key

    folders(:projects).destroy

    assert_predicate key.reload, :revoked?
    assert_nil key.folder_id
    assert_nil ApiKey.authenticate(plain_key)
  end

  test "scoped folders must belong to the same user" do
    key = users(:alice).api_keys.build(name: "Folder agent", folder: folders(:projects))
    assert key.valid?

    other = User.create!(email_address: "other@example.com", password: "password123", password_confirmation: "password123")
    key.user = other

    assert_not key.valid?
    assert key.errors[:folder].any?
  end
end
