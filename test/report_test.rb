# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class ReportTest < Minitest::Test
  ROOT = File.expand_path("fixtures/app", __dir__)

  def render(color: false, width: 50)
    config = DeadCode::Config.load(ROOT, nil)
    routes = DeadCode::RouteParser.new(ROOT, DeadCode::Collector.new(ROOT, config).files("routes_globs")).parse
    findings, index = DeadCode.analyze(ROOT, config:, routes:)
    io = StringIO.new
    DeadCode::Report.new(findings, index:, routes:, root: "/app", elapsed: 0.1).print_terminal(io, color:, width:)
    io.string
  end

  def test_each_finding_is_a_multi_line_block_with_its_tests
    block = render[/^  ● DeadService\n(?:    .*\n)+/]
    expected = [
      "  ● DeadService",
      "    app/services/dead_service.rb:1",
      "    never referenced (2 method(s))",
      "    referenced in tests",
      "    Remove with it:",
      "      spec/models/post_spec.rb:5  example calls it",
      "      spec/services/dead_service_spec.rb:1-5", # the note doesn't fit in 50 columns
      "        entire file"
    ]
    assert_equal expected, block.lines.map(&:chomp)
  end

  def test_wraps_prose_to_the_width
    lines = render(width: 50).lines.map(&:chomp)
    breakable = lines.select { |l| l.strip.include?(" ") }
    assert_empty(breakable.select { |l| l.length > 50 })
    assert_includes lines, "    STI subclass of Post (may be instantiated from"
  end

  def test_color_only_when_asked
    refute_includes render(color: false), "\e["
    colored = render(color: true)
    assert_includes colored, "\e[1;31m━━ UNUSED"
    assert_includes colored, "\e[36mapp/services/dead_service.rb:1\e[0m"
    assert_includes colored, "\e[32mspec/services/dead_service_spec.rb:1-5\e[0m"
  end
end
