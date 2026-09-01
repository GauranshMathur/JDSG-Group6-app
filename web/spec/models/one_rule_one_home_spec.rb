require "rails_helper"
require_relative "../../app/services/ranking"

# Finding 9 of the 2026-08-18 review: three rules, each written in more than one
# place. Each now has one home; these are the guards that keep it that way,
# because the previous binding was a comment and a comment cannot fail.
RSpec.describe "One rule, one home" do
  describe "what a tag name is" do
    it "strips and downcases, wherever it is asked" do
      expect(Tag.normalize("  Ruby ")).to eq("ruby")
    end

    it "parses a hashtag out of a post the same way" do
      post = create(:post, body: "learning #Ruby today")

      expect(post.tags.map(&:name)).to include("ruby")
    end

    it "finds that tag by a differently-cased name" do
      create(:post, body: "learning #Ruby today")

      expect(Tag.find_by(name: Tag.normalize("RUBY"))).to be_present
    end
  end

  describe "what a username is" do
    # The two definitions disagree on purpose — the model decides what may be
    # stored, the route what may be typed — so the guard is not that they are
    # equal, but that the looser one accepts everything the stricter one does.
    it "routes every username the model would accept" do
      shortest = "a" * User::USERNAME_LENGTH.min
      longest = "z" * User::USERNAME_LENGTH.max
      mixed = "ada_9"

      [ shortest, longest, mixed ].each do |username|
        expect(username).to match(User::USERNAME_FORMAT)
        expect(username).to match(User::USERNAME_ROUTE_CONSTRAINT)
      end
    end

    it "routes a capitalised handle the model would refuse, so the lookup can downcase it" do
      expect("ADA").not_to match(User::USERNAME_FORMAT)
      expect("ADA").to match(User::USERNAME_ROUTE_CONSTRAINT)
    end

    it "refuses a username the model's length rule excludes" do
      too_short = "a" * (User::USERNAME_LENGTH.min - 1)

      expect(too_short).not_to match(User::USERNAME_FORMAT)
    end
  end

  describe "the ranking formula" do
    # It used to be written twice — here and in script/scaling-curve — bound
    # only by a comment. Both now call Ranking, so this checks the seam the
    # feed depends on rather than comparing two copies.
    it "is the formula RankedFeed ranks with" do
      now = Time.current
      posted = 5.hours.ago

      expect(RankedFeed.new.send(:score, 3, 1, 2, posted, now))
        .to eq(Ranking.score(likes: 3, reposts: 1, replies: 2, age_hours: Ranking.age_hours(posted, now)))
    end

    it "ranks a newer post above an older one with the same engagement" do
      now = Time.current
      newer = Ranking.score(likes: 5, reposts: 0, replies: 0, age_hours: 1)
      older = Ranking.score(likes: 5, reposts: 0, replies: 0, age_hours: 48)

      expect(newer).to be > older
    end

    it "floors a negative age rather than producing an enormous score" do
      expect(Ranking.age_hours(1.hour.from_now, Time.current)).to eq(0)
    end
  end
end
