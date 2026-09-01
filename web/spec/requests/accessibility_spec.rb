require "rails_helper"

# Four SonarQube findings with one theme: markup a screen reader cannot use.
# They are asserted here rather than left to the scanner, because a scanner
# finding is a report and a spec is a guard — and because two of them are
# invisible to anyone looking at the page.
RSpec.describe "Accessible markup" do
  describe "the application layout" do
    it "declares the document language, so a screen reader knows how to pronounce it" do
      get posts_path

      expect(response.body).to include('<html lang="en">')
    end
  end

  describe "the composer's image picker" do
    # The control is a label wrapping a file input, and the label's only content
    # is an aria-hidden camera emoji. Sighted users see a camera; a screen
    # reader announces an unnamed file input. The title attribute on the label
    # is not an accessible name for the input inside it.
    it "gives the file input a name a screen reader can announce" do
      sign_in

      get posts_path

      file_input = response.body[/<input[^>]*type="file"[^>]*>/]

      expect(file_input).to include('aria-label="Add images"')
    end
  end
end

RSpec.describe "Accessible mail", type: :mailer do
  let(:body) do
    user = create(:user)
    PasswordsMailer.reset(user).html_part&.body&.to_s || PasswordsMailer.reset(user).body.to_s
  end

  it "declares the document language" do
    expect(body).to include('<html lang="en">')
  end

  it "has a title, so the message is identifiable when opened as a document" do
    expect(body).to match(%r{<title>[^<]+</title>})
  end
end
