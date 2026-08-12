class RankedFeed
  # The key changed with the cached value's shape (N-6.8). A process holding
  # the old whole-object cache must not have it read as an ordering, and it
  # expires on its own within the TTL.
  CACHE_KEY = "ranked_feed_order"
  CACHE_TTL = 5.minutes
  PAGE_SIZE = 20

  def initialize(page: 0)
    @page = page
  end

  def items
    @items ||= hydrate(ordering.drop(@page * PAGE_SIZE).first(PAGE_SIZE))
  end

  def next_page
    # Answered from the ordering's length rather than from how many items came
    # back, so a page shortened by a deleted row does not end the timeline.
    @page + 1 if ordering.size > (@page + 1) * PAGE_SIZE
  end

  def self.warm
    Rails.cache.delete(CACHE_KEY)
    new.send(:ordering)
  end

  def self.bust_cache
    # Worth a span of its own: every like, repost, reply and post lands here,
    # so the rate of invalidation is what decides how often a reader pays for a
    # rebuild rather than a cache hit (F-8.2).
    tracer.in_span("ranked_feed.bust") do
      Rails.cache.delete(CACHE_KEY)
    end
  end

  # Asked for on every call rather than held in config.x: an unset
  # `config.x.anything` returns an auto-vivified OrderedOptions, which is
  # truthy, so a `config.x.tracer || fallback` never reaches its fallback and
  # quietly answers `in_span` with nil instead of yielding. The tracer provider
  # is the right place to ask anyway — it hands back a real tracer when the SDK
  # is configured and a no-op one when it is not.
  def self.tracer
    OpenTelemetry.tracer_provider.tracer("twitter-clone-web")
  end

  private

  def tracer
    self.class.tracer
  end

  # What is cached is the ranked *order* — one `[post_id, reposter_id]` pair per
  # entry — and not the posts themselves.
  #
  # The whole-object version of this cached every entry with its author, avatar
  # and images under a single key. Nothing can read part of a cached value, so
  # every request rebuilt all of it in memory before taking twenty: 763 ms at
  # the 10,000-post seed, of which the page slice was 0.0 ms, and growing in
  # step with the database. Identifiers make the read cheap and the page a
  # bounded lookup; the cost of showing twenty posts now tracks twenty posts.
  # Recorded with numbers in docs/stress-testing.md.
  def ordering
    @ordering ||= tracer.in_span("ranked_feed.read") do |span|
      hit = true

      order = Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) do
        hit = false
        rebuild
      end

      span.set_attribute("ranked_feed.cache_hit", hit)
      span.set_attribute("ranked_feed.item_count", order.size)
      order
    end
  end

  def rebuild
    tracer.in_span("ranked_feed.rebuild") do |span|
      order = compute_ordering
      span.set_attribute("ranked_feed.item_count", order.size)
      order
    end
  end

  # Ranking needs four numbers per post — likes, reposts, replies and age — so
  # it reads four numbers per post. Loading each row as a model object, with its
  # author and attachments eager-loaded, was 2,859 ms at the 10,000-post seed
  # against 377 ms for the counters alone, and every one of those objects was
  # discarded after its score was computed.
  def compute_ordering
    now = Time.current
    scored = []

    Post.top_level.pluck(:id, :likes_count, :reposts_count, :replies_count, :created_at)
        .each do |id, likes, reposts, replies, created_at|
      scored << [ score(likes, reposts, replies, created_at, now), id, nil ]
    end

    Repost.where(post_id: Post.top_level.select(:id)).joins(:post)
          .pluck(:user_id, :post_id, :created_at,
                 "posts.likes_count", "posts.reposts_count", "posts.replies_count")
          .each do |user_id, post_id, reposted_at, likes, reposts, replies|
      scored << [ score(likes, reposts, replies, reposted_at, now), post_id, user_id ]
    end

    scored.sort_by! { |entry| -entry.first }
    scored.map { |_score, post_id, reposter_id| [ post_id, reposter_id ] }
  end

  def score(likes, reposts, replies, at, now)
    age_hours = ((now - at) / 1.hour).clamp(0, Float::INFINITY)
    engagement = likes + (reposts * 2) + replies
    (engagement + 1).to_f / ((age_hours + 2)**1.5)
  end

  # Two queries, whatever the page: the posts it shows, and the accounts that
  # reposted them.
  #
  # An entry naming a row that has since been deleted is dropped rather than
  # rendered — the ordering is a snapshot, and a post can go between the
  # rebuild that recorded it and the request that reads it. Caching whole
  # objects hid this by serving a copy of the deleted post.
  def hydrate(entries)
    return [] if entries.empty?

    posts = Post.where(id: entries.map(&:first))
                .eager_load(:user)
                .includes(user: { avatar_attachment: :blob }, images_attachments: :blob)
                .index_by(&:id)

    reposter_ids = entries.filter_map(&:last)
    reposters = reposter_ids.any? ? User.where(id: reposter_ids).index_by(&:id) : {}

    entries.filter_map do |post_id, reposter_id|
      post = posts[post_id]
      next if post.nil?

      reposter = reposter_id && reposters[reposter_id]
      next if reposter_id && reposter.nil?

      FeedItem.new(post: post, reposter: reposter)
    end
  end
end
