# frozen_string_literal: true

module LoadTest
  # The arithmetic behind the load-test seed (F-8.1).
  #
  # A real timeline is not uniform: most accounts never post, a few post
  # constantly, and engagement piles onto a handful of posts while most get
  # none. Seeding uniformly random data hides exactly the problems milestone 8
  # exists to find — a feed that loads every post and every repost into memory
  # behaves very differently against one mega-account's thousand posts than
  # against a thousand accounts' one post each.
  #
  # This class decides the shape and touches no database, so the distribution
  # can be asserted in specs without seeding anything. The seed script consumes
  # the plan and performs the writes.
  class Plan
    MINIMUM_POSTS = 100

    # Share of accounts by shape, and how many posts each shape writes.
    # Ranges are inclusive and sampled per account.
    SHAPES = {
      lurker:  { share: 0.60, posts: (0..0) },
      typical: { share: 0.30, posts: (1..40) },
      heavy:   { share: 0.09, posts: (100..500) },
      mega:    { share: 0.01, posts: (2_000..5_000) }
    }.freeze

    # Fraction of posts that receive no engagement whatsoever. The rest draw a
    # weight of r ** SKEW_EXPONENT over a uniform r: the higher the exponent,
    # the thinner the head that holds most of the engagement. At 16 the top 1%
    # of posts carry roughly a third of it, which is the Pareto-ish shape real
    # timelines have and uniform random data does not.
    UNENGAGED_SHARE = 0.55
    SKEW_EXPONENT = 16

    Account = Struct.new(:shape, :post_count, keyword_init: true)

    attr_reader :accounts, :engagement_weights

    def initialize(posts:, seed: 1)
      raise ArgumentError, "posts must be at least #{MINIMUM_POSTS}" if posts < MINIMUM_POSTS

      @target_posts = posts
      @random = Random.new(seed)
      @accounts = build_accounts
      @engagement_weights = build_engagement_weights
    end

    def total_posts
      @total_posts ||= accounts.sum(&:post_count)
    end

    def account_count
      accounts.size
    end

    private

    # How many accounts exist is decided *independently* of how many posts they
    # write, and the post counts are then scaled to hit the target. Deriving the
    # account count from the post target instead — dividing by the mean posts
    # per account — gives far too few accounts, because that mean is dominated
    # by mega-accounts: 1,000 posts came out as 16 accounts, which silently
    # capped every post at 16 likes however popular the plan said it was.
    #
    # Rounding each shape's count — and the floor of one account per shape —
    # leaves the total some way off the target, so a final scale factor pins it.
    # The shape is a set of *relative* sizes; scaling every account by the same
    # factor preserves the ordering and the proportions while hitting the
    # requested absolute scale.
    def build_accounts
      cohorts = [ (@target_posts / POSTS_PER_ACCOUNT.to_f).round, MINIMUM_ACCOUNTS ].max

      accounts = SHAPES.flat_map do |shape, config|
        # At least one of every shape exists at any scale — a stress run
        # without a mega-account would miss the case it is looking for.
        count = [ (cohorts * config[:share]).round, 1 ].max

        Array.new(count) do
          Account.new(shape: shape, post_count: sample_range(config[:posts]))
        end
      end

      rescale(accounts)
    end

    # Accounts per post of the target, and a floor so the smallest runs still
    # have a usable pool to draw engagement from.
    POSTS_PER_ACCOUNT = 12
    MINIMUM_ACCOUNTS = 40

    def rescale(accounts)
      raw_total = accounts.sum(&:post_count)
      return accounts if raw_total.zero?

      factor = @target_posts.to_f / raw_total

      accounts.each do |account|
        next if account.post_count.zero?

        # A poster always posts: rounding must never turn one into a lurker.
        account.post_count = [ (account.post_count * factor).round, 1 ].max
      end
    end

    # One weight per post. Zero means "no engagement"; the non-zero weights are
    # r ** SKEW_EXPONENT over a uniform r, which puts most of the total on a
    # thin head. The seed script turns these into like, repost and reply counts.
    def build_engagement_weights
      Array.new(total_posts) do
        if @random.rand < UNENGAGED_SHARE
          0.0
        else
          @random.rand**SKEW_EXPONENT
        end
      end.sort.reverse
    end

    def sample_range(range)
      return range.min if range.min == range.max

      @random.rand(range)
    end
  end
end
