class RankedFeed
  CACHE_KEY = "ranked_feed"
  CACHE_TTL = 5.minutes
  PAGE_SIZE = 20

  def initialize(page: 0)
    @page = page
  end

  def items
    @items ||= cached_feed.drop(@page * PAGE_SIZE).first(PAGE_SIZE)
  end

  def next_page
    @page + 1 if items.size == PAGE_SIZE
  end

  def self.warm
    Rails.cache.delete(CACHE_KEY)
    new.send(:cached_feed)
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

  # Reading the feed and rebuilding it are separate spans on purpose: the read
  # is what a request waits for, and it is not free even on a hit, because the
  # cached value has to be deserialized in full. Nesting the rebuild inside it
  # keeps both visible and shows which of the two a given request paid for.
  def cached_feed
    tracer.in_span("ranked_feed.read") do |span|
      hit = true

      feed = Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) do
        hit = false
        rebuild
      end

      span.set_attribute("ranked_feed.cache_hit", hit)
      span.set_attribute("ranked_feed.item_count", feed.size)
      feed
    end
  end

  def rebuild
    tracer.in_span("ranked_feed.rebuild") do |span|
      feed = compute_feed
      span.set_attribute("ranked_feed.item_count", feed.size)
      feed
    end
  end

  def compute_feed
    posts = Post.top_level.eager_load(:user)
               .includes(user: { avatar_attachment: :blob }, images_attachments: :blob).to_a
    reposts = Repost.eager_load(:user, post: :user)
                    .includes(
                      user: { avatar_attachment: :blob },
                      post: { user: { avatar_attachment: :blob }, images_attachments: :blob }
                    )
                    .where(post: Post.top_level).to_a

    feed = []

    posts.each do |post|
      feed << FeedItem.new(
        post: post,
        reposter: nil,
        sort_time: post.created_at,
        score: engagement_score(post)
      )
    end

    reposts.each do |repost|
      feed << FeedItem.new(
        post: repost.post,
        reposter: repost.user,
        sort_time: repost.created_at,
        score: engagement_score(repost.post, boost_time: repost.created_at)
      )
    end

    feed.sort_by { |item| -item.score }
  end

  def engagement_score(post, boost_time: nil)
    age_hours = ((Time.current - (boost_time || post.created_at)) / 1.hour).clamp(0, Float::INFINITY)
    engagement = post.likes_count + (post.reposts_count * 2) + post.replies_count
    (engagement + 1).to_f / ((age_hours + 2)**1.5)
  end
end
