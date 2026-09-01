require "rails_helper"

# A page number that is not a page number must not reach a feed. Both
# controllers carried the same unvalidated expression, so both carried the same
# defect: page=-1 reached entries.drop(-20), which raises ArgumentError — a 500
# on the feed and on every profile. Finding 4 of the 2026-08-18 architecture
# review; the neighbouring inputs are pinned here so the fix cannot trade one
# for another.
RSpec.describe "Timeline paging" do
  describe "the feed" do
    before { create(:post) }

    it "serves a page for a negative page number rather than failing" do
      get posts_path(page: -1)

      expect(response).to have_http_status(:ok)
    end

    it "serves a page for a non-numeric page number" do
      get posts_path(page: "banana")

      expect(response).to have_http_status(:ok)
    end

    it "still serves page zero and a page far past the end" do
      get posts_path(page: 0)
      expect(response).to have_http_status(:ok)

      get posts_path(page: 99_999)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "a profile" do
    before do
      user = create(:user, username: "ada")
      create(:post, user: user)
    end

    it "serves a page for a negative page number rather than failing" do
      get profile_path("ada", page: -1)

      expect(response).to have_http_status(:ok)
    end

    it "serves a page for a non-numeric page number" do
      get profile_path("ada", page: "banana")

      expect(response).to have_http_status(:ok)
    end

    it "still serves page zero and a page far past the end" do
      get profile_path("ada", page: 0)
      expect(response).to have_http_status(:ok)

      get profile_path("ada", page: 99_999)
      expect(response).to have_http_status(:ok)
    end
  end
end
