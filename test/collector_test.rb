# frozen_string_literal: true

require_relative "test_helper"

class CollectorTest < Minitest::Test
  ROOT = File.expand_path("fixtures/app", __dir__)

  def collector(ignore) = DeadCode::Collector.new(ROOT, DeadCode::Config.load(ROOT, nil), ignore:)

  def test_ignores_directories_files_and_globs
    c = collector(["app/services/legacy/", "./app/models/post.rb", "app/**/*_controller.rb"])
    assert c.ignored?("app/services/legacy/importer.rb")
    assert c.ignored?("app/models/post.rb")
    assert c.ignored?("app/controllers/admin/reports_controller.rb")
    refute c.ignored?("app/services/legacy_importer.rb") # a directory prefix only matches whole segments
    refute c.ignored?("app/models/post_policy.rb")

    sources = c.files("source_globs")
    assert_includes sources, "app/models/sponsored_post.rb"
    refute_includes sources, "app/models/post.rb"
    refute(sources.any? { |f| f.start_with?("app/services/legacy/") || f.end_with?("_controller.rb") })
  end

  # Ignored files are not references either: the dispatch in Sorter no longer keeps sort_by_score "likely".
  def test_ignored_files_neither_define_nor_reference_code
    config = DeadCode::Config.load(ROOT, nil)
    findings, = DeadCode.analyze(ROOT, config:, routes: nil, ignore: ["app/services/sorter.rb"])
    names = findings.to_h { |f| [f.name, f.confidence] }
    assert_equal :unused, names["Post#sort_by_score"]
    refute names.key?("Sorter")
  end
end
