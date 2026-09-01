require "rails_helper"

# The same property the feed budget asserts (N-6.1, N-6.2), on the page added
# in milestone 4: rendering a profile must cost a constant number of queries
# however many posts it shows.
RSpec.describe "Profile query budget" do
  it "issues a constant number of queries regardless of the number of posts" do
    ada = create(:user, username: "ada")

    create_list(:post, 1, user: ada)
    one_post = count_queries { get profile_path("ada") }

    create_list(:post, ProfileFeed::PAGE_SIZE - 1, user: ada)
    full_page = count_queries { get profile_path("ada") }

    expect(one_post).to eq(full_page)
  end

  it "stays constant signed in" do
    ada = create(:user, username: "ada")
    create_list(:post, ProfileFeed::PAGE_SIZE, user: ada)

    sign_in
    one_page = count_queries { get profile_path("ada") }
    expect(one_page).to be > 0
  end

  it "does not issue a separate count query to decide on the pagination link" do
    ada = create(:user, username: "ada")
    create_list(:post, ProfileFeed::PAGE_SIZE + 1, user: ada)

    sql = queries_in { get profile_path("ada") }

    expect(response.body).to include("Load more")
    expect(sql.grep(/\bCOUNT\s*\(/i)).to be_empty
  end
end

# Finding 5 of the 2026-08-18 architecture review. The budget above asserts a
# constant *query* count, and the query count was genuinely constant while the
# service loaded every post an account had ever written to return twenty. Rows
# read is the axis that grew, so it is the one this pins.
RSpec.describe "Profile rows read" do
  it "reads a bounded number of posts however many the account has written" do
    ada = create(:user, username: "ada")
    create_list(:post, ProfileFeed::PAGE_SIZE, user: ada)
    small = rows_instantiated_in(Post) { get profile_path("ada") }

    create_list(:post, ProfileFeed::PAGE_SIZE * 4, user: ada)
    large = rows_instantiated_in(Post) { get profile_path("ada") }

    expect(large).to eq(small)
  end

  it "reads a bounded number of posts however many the account has reposted" do
    ada = create(:user, username: "ada")
    create_list(:post, ProfileFeed::PAGE_SIZE, user: ada)
    create_list(:post, 3).each { |post| create(:repost, user: ada, post: post) }
    small = rows_instantiated_in(Repost) { get profile_path("ada") }

    create_list(:post, ProfileFeed::PAGE_SIZE * 4).each { |post| create(:repost, user: ada, post: post) }
    large = rows_instantiated_in(Repost) { get profile_path("ada") }

    expect(large).to eq(small)
  end
end
