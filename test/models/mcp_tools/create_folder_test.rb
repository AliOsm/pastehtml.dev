require "test_helper"

class McpTools::CreateFolderTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    @ctx = { user: @alice }
  end

  test "creates an empty folder owned by the user" do
    response = create(name: "New Folder")

    assert_not response.error?
    structured = response.structured_content
    assert_equal "New Folder", structured[:name]
    assert_equal 0, structured[:pastes_count]

    folder = Folder.find(structured[:id])
    assert_equal @alice, folder.user
  end

  test "a duplicate name (case-insensitive) is a validation error" do
    @alice.folders.create!(name: "Work")

    response = create(name: "work")

    assert response.error?
    assert_equal "validation_failed", response.structured_content[:code]
    assert_equal "name", response.structured_content[:field]
  end

  test "another user may reuse the same name" do
    users(:bob).folders.create!(name: "Shared Name")

    response = create(name: "Shared Name")

    assert_not response.error?
  end

  # A concurrent creator can slip a duplicate past the uniqueness validation's
  # SELECT, so the INSERT raises RecordNotUnique at the DB layer. That race must
  # surface as the SAME stable validation error a plain duplicate does -- never
  # an uncaught exception (which would become an internal MCP error).
  test "a RecordNotUnique race returns the same validation error, not an exception" do
    response = simulating_uniqueness_race(Folder, :save) { create(name: "Distinct Name") }

    assert response.error?
    assert_equal "validation_failed", response.structured_content[:code]
    assert_equal "name", response.structured_content[:field]
  end

  test "annotations mark it a write, non-idempotent, non-destructive, closed-world tool" do
    annotations = McpTools::CreateFolder.annotations_value

    assert_equal false, annotations.read_only_hint
    assert_equal false, annotations.destructive_hint
    assert_equal false, annotations.idempotent_hint
    assert_equal false, annotations.open_world_hint
  end

  private
    def create(**args)
      McpTools::CreateFolder.call(**args, server_context: @ctx)
    end

    # Forces the next call to `method` on `klass` to raise RecordNotUnique once,
    # the way a concurrent INSERT would at the DB layer after the app-level
    # uniqueness validation already passed. Restores the method afterward.
    def simulating_uniqueness_race(klass, method)
      defined_here = klass.instance_methods(false).include?(method)
      original = klass.instance_method(method)
      raised = false
      klass.send(:define_method, method) do |*args, **kwargs, &block|
        unless raised
          raised = true
          raise ActiveRecord::RecordNotUnique, "PG::UniqueViolation"
        end
        original.bind(self).call(*args, **kwargs, &block)
      end
      yield
    ensure
      defined_here ? klass.send(:define_method, method, original) : klass.send(:remove_method, method)
    end
end
