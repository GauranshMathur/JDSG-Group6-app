class AddCreatedAtIndexToReposts < ActiveRecord::Migration[8.1]
  # The ranked window filters reposts by when the repost happened (F-8.7.1),
  # which makes reposts.created_at a timeline column — and those get indexes.
  def change
    add_index :reposts, :created_at
  end
end
