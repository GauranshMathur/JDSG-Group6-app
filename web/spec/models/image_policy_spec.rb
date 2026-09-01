require "rails_helper"
require "vips"

# F-7.3 (WebP) and F-7.4 (EXIF stripping) were both recorded as met while the
# only evidence was `expect(variant).to be_present` — true of any lazily-built
# variant — and `expect(user).to respond_to(:avatar_thumbnail)`. Neither
# processed an image or looked at what came out. Finding 7 of the 2026-08-18
# review.
#
# These process the image and read the result. The source is generated with
# real EXIF tags, because a stripping test against a file that never had
# metadata proves nothing.
RSpec.describe "Image policy" do
  # A small JPEG carrying camera metadata, the way a phone upload would.
  def jpeg_with_exif
    image = Vips::Image.black(64, 64).add(128).cast("uchar")
                       .copy(interpretation: :srgb).bandjoin([ 128, 128 ]).copy
    image.set_type(GObject::GSTR_TYPE, "exif-ifd0-Make", "TestCam")
    image.set_type(GObject::GSTR_TYPE, "exif-ifd0-Model", "TestModel")
    image.jpegsave_buffer
  end

  def exif_fields(bytes)
    Vips::Image.new_from_buffer(bytes, "").get_fields.grep(/\Aexif/)
  end

  it "the fixture really does carry metadata, or the rest of this proves nothing" do
    expect(exif_fields(jpeg_with_exif)).not_to be_empty
  end

  describe "a post image" do
    let(:post) do
      create(:post).tap do |p|
        p.images.attach(io: StringIO.new(jpeg_with_exif), filename: "photo.jpg", content_type: "image/jpeg")
      end
    end

    it "is converted to WebP when rendered (F-7.3)" do
      processed = post.image_variants.first.processed

      expect(Vips::Image.new_from_buffer(processed.download, "").get("vips-loader")).to eq("webpload_buffer")
    end

    it "carries no EXIF metadata when rendered (F-7.4)" do
      processed = post.image_variants.first.processed

      expect(exif_fields(processed.download)).to be_empty
    end
  end

  describe "an avatar" do
    let(:user) do
      create(:user).tap do |u|
        u.avatar.attach(io: StringIO.new(jpeg_with_exif), filename: "face.jpg", content_type: "image/jpeg")
      end
    end

    it "is converted to WebP and stripped of metadata" do
      processed = user.avatar_thumbnail.processed

      expect(Vips::Image.new_from_buffer(processed.download, "").get("vips-loader")).to eq("webpload_buffer")
      expect(exif_fields(processed.download)).to be_empty
    end
  end
end

# The allow-list was written in four places — two model constants and two
# hardcoded accept attributes — so adding a format was a five-place edit with no
# compiler help.
RSpec.describe "Accepted image types", type: :request do
  it "are one list, and the file inputs are built from it" do
    sign_in

    get posts_path

    expect(response.body).to include("accept=\"#{ImagePolicy::ACCEPT}\"")
  end
end
