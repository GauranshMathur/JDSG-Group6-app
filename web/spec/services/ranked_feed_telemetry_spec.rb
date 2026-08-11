require "rails_helper"

# F-8.2 — the ranked feed reports what it costs: how long a rebuild took, how
# many items it produced, and whether a request was served from cache.
#
# These are the signals milestone 8 is measuring, so they are asserted rather
# than eyeballed in a log. The exporter here is in-memory; in a real run it is
# the console or an OTLP collector, chosen by configuration (ADR 0009).
RSpec.describe "RankedFeed telemetry" do
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }

  # The test environment uses :null_store, so nothing is ever cached and every
  # read would report a miss. Same swap as the caching specs.
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  before do
    OpenTelemetry.tracer_provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    )
    RankedFeed.bust_cache
  end

  after { RankedFeed.bust_cache }

  def spans_named(name)
    exporter.finished_spans.select { |span| span.name == name }
  end

  it "records a span when the feed is rebuilt" do
    RankedFeed.new.items

    expect(spans_named("ranked_feed.rebuild").size).to eq(1)
  end

  it "reports how many items the rebuild produced" do
    create_list(:post, 3)
    RankedFeed.bust_cache

    RankedFeed.new.items

    span = spans_named("ranked_feed.rebuild").last
    expect(span.attributes["ranked_feed.item_count"]).to eq(3)
  end

  it "marks the first request as a cache miss" do
    RankedFeed.new.items

    span = spans_named("ranked_feed.read").last
    expect(span.attributes["ranked_feed.cache_hit"]).to be(false)
  end

  it "marks a repeated request as a cache hit, and does not rebuild again" do
    RankedFeed.new.items
    exporter.reset

    RankedFeed.new.items

    expect(spans_named("ranked_feed.read").last.attributes["ranked_feed.cache_hit"]).to be(true)
    expect(spans_named("ranked_feed.rebuild")).to be_empty
  end

  # The cache is busted by every like, repost, reply and post, so a feed under
  # write traffic spends its time in the rebuild path. That is the thing worth
  # counting, and it only shows up if invalidation is visible too.
  it "records a span when engagement busts the cache" do
    RankedFeed.new.items
    exporter.reset

    create(:like)

    expect(spans_named("ranked_feed.bust").size).to be >= 1
  end
end
