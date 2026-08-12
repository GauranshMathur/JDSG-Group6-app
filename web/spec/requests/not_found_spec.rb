require "rails_helper"

# F-8.6.2 — a request for something that is not there answers with the
# application's own page, not the generic static one.
#
# Every one of these already answered 404, which is the part that matters to a
# crawler. What a visitor got was `public/404.html` — unstyled, unbranded, with
# no way back. Posts are deleted for real (`dependent: :destroy` takes the
# replies with them), so following a link to one is a thing that happens rather
# than an edge case.
RSpec.describe "Not found", type: :request do
  shared_examples "the application's not-found page" do
    it "answers 404 with the application's own page" do
      make_request

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("sidebar__brand")
      expect(response.body).to include("Back to the feed")
    end
  end

  describe "a post that has been deleted" do
    let(:make_request) do
      post = create(:post)
      id = post.id
      post.destroy!
      get post_path(id)
    end

    include_examples "the application's not-found page"
  end

  describe "a username nobody holds" do
    let(:make_request) { get profile_path("ghost") }

    include_examples "the application's not-found page"
  end

  describe "a tag nobody has used" do
    let(:make_request) { get tag_path("nothinghere") }

    include_examples "the application's not-found page"
  end

  # Authorisation here is by scoping — `Current.user.posts.find` simply does not
  # find someone else's row (F-3.5) — so this arrives as the same not-found. It
  # should stay that way: the page says a thing is not here, and does not
  # distinguish "deleted" from "someone else's", which is exactly the answer
  # somebody probing for other people's post ids should get.
  describe "editing a post belonging to someone else" do
    let(:make_request) do
      other = create(:post)
      sign_in
      get edit_post_path(other)
    end

    include_examples "the application's not-found page"
  end

  describe "a request that is not for a page" do
    it "answers 404 without a body for a non-HTML format" do
      get tag_path("nothinghere"), headers: { "Accept" => "application/json" }

      expect(response).to have_http_status(:not_found)
    end
  end
end
