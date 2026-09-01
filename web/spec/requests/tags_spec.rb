require "rails_helper"

# F-5.4, F-5.5
RSpec.describe "Tags" do
  # F-5.4
  describe "hashtag rendering in post bodies" do
    it "renders hashtags as links" do
      create(:post, body: "Hello #rails world")

      get posts_path

      expect(response.body).to include(">#rails</a>")
    end

    it "links to the tag page" do
      create(:post, body: "Check #ruby")

      get posts_path

      expect(response.body).to include(tag_path("ruby"))
    end

    it "renders multiple hashtags as separate links" do
      create(:post, body: "#rails and #ruby")

      get posts_path

      expect(response.body).to include(tag_path("rails"))
      expect(response.body).to include(tag_path("ruby"))
    end

    it "renders hashtags on the post detail page" do
      post_record = create(:post, body: "Hello #rails")

      get post_path(post_record)

      expect(response.body).to include(">#rails</a>")
    end
  end

  # F-5.5
  describe "GET /tags/:name" do
    it "lists posts carrying the tag" do
      create(:post, body: "First #rails post")
      create(:post, body: "Second #rails post")
      create(:post, body: "No tag here")

      get tag_path("rails")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("First")
      expect(response.body).to include("Second")
      expect(response.body).not_to include("No tag here")
    end

    it "is case-insensitive — /tags/Rails finds #rails posts" do
      create(:post, body: "Hello #rails")

      get tag_path("Rails")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Hello")
    end

    it "returns 404 for a tag that does not exist" do
      get tag_path("nonexistent")

      expect(response).to have_http_status(:not_found)
    end

    it "paginates using the same cursor as the main feed" do
      tag_post = nil
      (TimelinePage::PAGE_SIZE + 1).times do |i|
        tag_post = create(:post, body: "#rails post #{i}", created_at: i.minutes.ago)
      end

      get tag_path("rails")

      expect(response.body.scan(/class="post"/).size).to eq(TimelinePage::PAGE_SIZE)
      expect(response.body).to include("Load more")
    end

    it "shows like and repost buttons on tagged posts" do
      create(:post, body: "#rails is great")

      get tag_path("rails")

      expect(response.body).to include("like-button")
      expect(response.body).to include("repost-button")
    end

    it "is publicly readable without signing in" do
      create(:post, body: "#rails")

      get tag_path("rails")

      expect(response).to have_http_status(:ok)
    end
  end
end
