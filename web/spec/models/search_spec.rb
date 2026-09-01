require "rails_helper"

# Finding 2 of the 2026-08-18 architecture review: F-6.3 records "search behaves
# identically on SQLite and PostgreSQL" as met, and it is not true. `Post.search`
# folds case on neither side and post bodies are stored verbatim, so the search
# works only because SQLite's LIKE happens to ignore ASCII case. PostgreSQL's
# does not.
#
# The defect is therefore invisible on the adapter we run: a plain
# case-insensitivity example passes here whether or not the bug is present.
# `PRAGMA case_sensitive_like = ON` makes SQLite compare the way PostgreSQL
# will, which is what lets these fail before the fix rather than on the day of
# the switch.
RSpec.describe "Search scopes" do
  around do |example|
    connection = ActiveRecord::Base.connection
    connection.execute("PRAGMA case_sensitive_like = ON")
    example.run
  ensure
    connection.execute("PRAGMA case_sensitive_like = OFF")
  end

  describe "Post.search" do
    it "finds a post when the query is cased differently from the body" do
      post = create(:post, body: "Kubernetes at scale")

      expect(Post.search("kubernetes")).to include(post)
    end

    it "finds a post when the body is cased differently from the query" do
      post = create(:post, body: "postgres migration notes")

      expect(Post.search("POSTGRES")).to include(post)
    end

    it "does not match a post that simply does not contain the term" do
      create(:post, body: "Kubernetes at scale")

      expect(Post.search("terraform")).to be_empty
    end

    it "treats LIKE wildcards in the query as literal characters" do
      literal = create(:post, body: "we hit 100% uptime")
      create(:post, body: "we hit 1 uptime")

      expect(Post.search("100%")).to contain_exactly(literal)
    end

    it "treats an underscore in the query as a literal character" do
      literal = create(:post, body: "the feature_flag is on")
      create(:post, body: "the featureXflag is on")

      expect(Post.search("feature_flag")).to contain_exactly(literal)
    end
  end

  # The scope this one was already right, and it is here because the review's
  # point is that neither had a spec — which is why the asymmetry between two
  # scopes that look symmetric went unnoticed.
  describe "User.search" do
    it "finds a user when the query is cased differently from the username" do
      user = create(:user, username: "ada")

      expect(User.search("ADA")).to include(user)
    end

    it "does not match a username that does not contain the term" do
      create(:user, username: "ada")

      expect(User.search("grace")).to be_empty
    end
  end
end

# The username-underscore case, which User.search also got wrong for the same
# reason: escaped wildcards need an ESCAPE clause to mean anything.
RSpec.describe "User.search wildcards" do
  it "treats an underscore in the query as a literal character" do
    literal = create(:user, username: "ada_l")
    create(:user, username: "adaxl")

    expect(User.search("ada_l")).to contain_exactly(literal)
  end
end
