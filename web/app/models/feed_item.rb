# One entry in a timeline: a post, and the account that reposted it when the
# entry is a repost rather than the post itself.
#
# `sort_time` and `score` order a timeline while it is being built and are read
# by nothing that renders one. `ProfileFeed` sorts on `sort_time`, so it passes
# it; `RankedFeed` sorts before it has posts at all — its order lives in the
# cached list of identifiers — so it passes neither, and carrying them for its
# entries would have meant caching two dead fields per entry: 6.4x the payload
# and 6.7x the time to read it back, measured at the 10,000-post seed.
FeedItem = Data.define(:post, :reposter, :sort_time, :score) do
  def initialize(post:, reposter: nil, sort_time: nil, score: 0) = super

  def repost?
    reposter.present?
  end
end
