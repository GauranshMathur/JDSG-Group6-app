class Repost < ApplicationRecord
  belongs_to :user
  belongs_to :post, counter_cache: true

  validates :user_id, uniqueness: { scope: :post_id }

  # Two ways a repost matters: it is an entry of its own while it is inside the
  # window — which is how an archived post re-enters the feed — and it changes
  # the post's repost counter, which scores the post's own row. Withdrawing an
  # old repost of an archived post does neither.
  #
  # Asked about the repost as well as the post, because on destroy the row is
  # already gone: ranks? alone would answer false for an entry the ordering
  # still holds.
  after_create_commit  { RankedFeed.bust_cache if RankedFeed.ranks_repost?(self) || RankedFeed.ranks?(post) }
  after_destroy_commit { RankedFeed.bust_cache if RankedFeed.ranks_repost?(self) || RankedFeed.ranks?(post) }
end
