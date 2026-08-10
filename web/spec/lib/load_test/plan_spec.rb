require "rails_helper"

# F-8.1 — the load-test seed generates shaped data at configurable scale:
# mixed account sizes from lurker to mega-account, and skewed engagement.
#
# These specs describe the *plan* — the arithmetic that decides how many
# accounts of each shape exist and how many posts and likes each one gets.
# The plan touches no database, so the shape can be asserted without seeding.
RSpec.describe LoadTest::Plan do
  describe "scale" do
    it "produces approximately the requested number of top-level posts" do
      plan = described_class.new(posts: 10_000, seed: 1)

      # Exactness is not the point — the shape is drawn from a distribution.
      # Landing within a few percent of the target is.
      expect(plan.total_posts).to be_within(500).of(10_000)
    end

    it "scales the account count with the post count" do
      small = described_class.new(posts: 1_000, seed: 1)
      large = described_class.new(posts: 10_000, seed: 1)

      expect(large.accounts.size).to be > small.accounts.size
    end

    # Engagement is drawn from the account pool, so too few accounts silently
    # caps how many likes a post can have however heavy its weight — a 400-like
    # post is impossible with 16 accounts in the database.
    it "creates an account pool large enough not to cap engagement" do
      plan = described_class.new(posts: 10_000, seed: 1)

      expect(plan.account_count).to be > 500
    end

    it "rejects a scale below the smallest sensible run" do
      expect { described_class.new(posts: 0, seed: 1) }.to raise_error(ArgumentError)
    end
  end

  describe "account shapes" do
    subject(:plan) { described_class.new(posts: 10_000, seed: 1) }

    it "includes every shape from lurker to mega-account" do
      expect(plan.accounts.map(&:shape).uniq).to match_array(%i[lurker typical heavy mega])
    end

    it "gives lurkers no posts at all" do
      lurkers = plan.accounts.select { |a| a.shape == :lurker }

      expect(lurkers).not_to be_empty
      expect(lurkers.map(&:post_count).uniq).to eq([ 0 ])
    end

    it "orders the shapes by size — a mega-account dwarfs a typical one" do
      largest_typical = plan.accounts.select { |a| a.shape == :typical }.map(&:post_count).max
      smallest_mega   = plan.accounts.select { |a| a.shape == :mega }.map(&:post_count).min

      expect(smallest_mega).to be > largest_typical * 10
    end

    it "makes lurkers the majority, mega-accounts a rounding error" do
      total = plan.accounts.size.to_f
      share = ->(shape) { plan.accounts.count { |a| a.shape == shape } / total }

      expect(share.call(:lurker)).to be > 0.4
      expect(share.call(:mega)).to be < 0.05
    end

    it "always produces at least one mega-account, even at the smallest scale" do
      plan = described_class.new(posts: 1_000, seed: 1)

      expect(plan.accounts.count { |a| a.shape == :mega }).to be >= 1
    end
  end

  describe "engagement skew" do
    subject(:plan) { described_class.new(posts: 10_000, seed: 1) }

    it "concentrates likes on a small head rather than spreading them evenly" do
      weights = plan.engagement_weights
      head    = weights.first((weights.size * 0.01).ceil)

      expect(head.sum).to be > weights.sum * 0.25
    end

    it "leaves a long tail of posts with no engagement at all" do
      unengaged = plan.engagement_weights.count(&:zero?)

      expect(unengaged).to be > plan.total_posts * 0.3
    end

    it "produces one weight per post" do
      expect(plan.engagement_weights.size).to eq(plan.total_posts)
    end
  end

  describe "reproducibility" do
    it "produces an identical plan for the same seed" do
      a = described_class.new(posts: 10_000, seed: 42)
      b = described_class.new(posts: 10_000, seed: 42)

      expect(a.accounts.map(&:post_count)).to eq(b.accounts.map(&:post_count))
      expect(a.engagement_weights).to eq(b.engagement_weights)
    end

    it "produces a different plan for a different seed" do
      a = described_class.new(posts: 10_000, seed: 1)
      b = described_class.new(posts: 10_000, seed: 2)

      expect(a.accounts.map(&:post_count)).not_to eq(b.accounts.map(&:post_count))
    end
  end
end
