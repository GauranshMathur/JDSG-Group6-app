require "rails_helper"

# Three rate limits are declared — sign-in, registration, password reset — and
# before this file no spec could reach any of them: `rate_limit` counts through
# Rails.cache, and the test environment set :null_store, so the counter was
# thrown away on every write. As tested, the brute-force protection was
# indistinguishable from three comments. Finding 3 of the 2026-08-18 review.
#
# The limit is 10 within 3 minutes in all three cases.
RSpec.describe "Rate limiting" do
  def attempt_sign_in(email: "nobody@example.com")
    post session_path, params: { email_address: email, password: "wrong-password" }
  end

  describe "signing in" do
    it "refuses further attempts once the limit is reached" do
      10.times { attempt_sign_in }

      attempt_sign_in

      expect(response).to redirect_to(new_session_path)
      follow_redirect!
      expect(response.body).to include("Try again later.")
    end

    it "lets the attempts under the limit through to a normal failure" do
      9.times { attempt_sign_in }

      attempt_sign_in

      follow_redirect!
      expect(response.body).not_to include("Try again later.")
    end
  end

  describe "requesting a password reset" do
    it "refuses further attempts once the limit is reached" do
      10.times { post passwords_path, params: { email_address: "nobody@example.com" } }

      post passwords_path, params: { email_address: "nobody@example.com" }

      expect(response).to redirect_to(new_password_path)
      follow_redirect!
      expect(response.body).to include("Try again later.")
    end
  end

  describe "registering" do
    it "refuses further attempts once the limit is reached" do
      11.times do |i|
        post registration_path, params: {
          user: { email_address: "taken#{i}@example.com", password: "password123", password_confirmation: "password123" }
        }
      end

      expect(response).to redirect_to(new_registration_path)
      follow_redirect!
      expect(response.body).to include("Try again later.")
    end
  end
end
