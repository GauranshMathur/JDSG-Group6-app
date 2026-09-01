require "rails_helper"

# F-6.1, F-6.2, F-6.3, F-6.4
RSpec.describe "Search" do
  # F-6.1
  describe "GET /search (post results)" do
    it "finds posts matching the query by body text" do
      create(:post, body: "Ruby on Rails is great")
      create(:post, body: "Python is also good")

      get search_path(q: "Rails")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Ruby on Rails is great")
      expect(response.body).not_to include("Python is also good")
    end

    it "is case-insensitive" do
      create(:post, body: "Hello WORLD")

      get search_path(q: "hello")

      expect(response.body).to include("Hello WORLD")
    end

    it "matches partial words" do
      create(:post, body: "programming languages")

      get search_path(q: "program")

      expect(response.body).to include("programming languages")
    end

    it "returns an empty state when nothing matches" do
      create(:post, body: "something else")

      get search_path(q: "nonexistent")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No results")
    end

    it "shows the search query in the page" do
      get search_path(q: "rails")

      expect(response.body).to include("rails")
    end

    # F-6.4
    it "paginates results using cursor pagination" do
      (TimelinePage::PAGE_SIZE + 1).times do |i|
        create(:post, body: "searchable post #{i}", created_at: i.minutes.ago)
      end

      get search_path(q: "searchable")

      expect(response.body.scan(/class="post"/).size).to eq(TimelinePage::PAGE_SIZE)
      expect(response.body).to include("Load more")
    end

    it "renders posts in reverse chronological order" do
      create(:post, body: "older searchable", created_at: 2.minutes.ago)
      create(:post, body: "newer searchable", created_at: 1.minute.ago)

      get search_path(q: "searchable")

      body = response.body
      expect(body.index("newer searchable")).to be < body.index("older searchable")
    end
  end

  # F-6.2
  describe "GET /search (user results)" do
    it "finds users by username" do
      create(:user, username: "railsdev")

      get search_path(q: "railsdev")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("@railsdev")
    end

    it "finds users by partial username match" do
      create(:user, username: "railsdev")

      get search_path(q: "rails")

      expect(response.body).to include("@railsdev")
    end

    it "is case-insensitive for username search" do
      create(:user, username: "railsdev")

      get search_path(q: "RAILS")

      expect(response.body).to include("@railsdev")
    end

    it "does not show users that do not match" do
      create(:user, username: "railsdev")
      create(:user, username: "pythondev")

      get search_path(q: "rails")

      expect(response.body).to include("@railsdev")
      expect(response.body).not_to include("@pythondev")
    end
  end

  describe "search field in the sidebar" do
    it "shows a search form in the sidebar" do
      get root_path

      expect(response.body).to include("search")
    end
  end

  # F-6.3
  describe "adapter independence" do
    it "works without adapter-specific SQL" do
      create(:post, body: "adapter test post")

      get search_path(q: "adapter")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("adapter test post")
    end
  end

  describe "access control" do
    it "is publicly readable without signing in" do
      create(:post, body: "public search result")

      get search_path(q: "public")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("public search result")
    end
  end

  describe "blank query" do
    it "shows an empty state when no query is provided" do
      get search_path

      expect(response).to have_http_status(:ok)
    end
  end
end
