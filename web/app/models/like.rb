class Like < ApplicationRecord
  belongs_to :user
  belongs_to :post, counter_cache: true

  validates :user_id, uniqueness: { scope: :post_id }

  # A like moves a score only if the post it lands on is a row the ranking
  # actually reads. On an archived post it moves nothing, and busting for it
  # forces a rebuild that returns exactly what was already cached (finding 6).
  after_create_commit  { RankedFeed.bust_cache if RankedFeed.ranks?(post) }
  after_destroy_commit { RankedFeed.bust_cache if RankedFeed.ranks?(post) }
end
