# frozen_string_literal: true

require "io/console"

module Deadspace
  class Report
    SECTIONS = { module: "Modules", class: "Classes", controller_action: "Controller actions without a route",
                 method: "Methods" }.freeze
    CSV_HEADERS = %w[confidence kind name file line reason referenced_in_tests definition_count].freeze
    TEST_CSV_HEADERS = %w[test_file lines first_line last_line match entire_file confidence kind name file line].freeze

    def initialize(findings, index:, routes:, root:, elapsed:)
      @findings = findings
      @index = index
      @routes = routes
      @root = root
      @elapsed = elapsed
    end

    COLLAPSE_AT = 8 # likely-unused findings sharing one reason print as a single block
    INDENT = "    " # finding details sit under the bullet
    TONE = { unused: :red, likely_unused: :yellow }.freeze
    SUBTITLES = {
      unused: "Nothing reaches these outside of tests.",
      likely_unused: "Not referenced statically, but Rails or Ruby could reach them at runtime. Review by hand."
    }.freeze

    # Each finding is a block of short lines (name, location, reason, tests) wrapped to the terminal width,
    # so the report stays readable in a narrow pane.
    def print_terminal(io = $stdout, color: io.tty?, verbose: false, width: nil)
      @color = color
      @width = (width || terminal_width(io)).clamp(40, 120)
      @io = io

      print_header
      %i[unused likely_unused].each { |confidence| print_group(confidence) }
      print_warnings(verbose)
      print_summary
    end

    # Writes the findings to `path` and the removable tests to a sibling `*_tests.csv`. Returns that path.
    def write_csv(path)
      CSV.open(path, "w") do |csv|
        csv << CSV_HEADERS
        @findings.each do |f|
          csv << [f.confidence, f.kind, f.name, f.location.path, f.location.line, f.reason, f.referenced_in_tests,
                  f.definition_count]
        end
      end

      tests_path = self.class.tests_csv_path(path)
      CSV.open(tests_path, "w") do |csv|
        csv << TEST_CSV_HEADERS
        @findings.each do |f|
          (f.tests || []).each do |t|
            csv << [t.path, t.lines, t.first_line, t.last_line, t.match, t.whole_file, f.confidence, f.kind, f.name,
                    f.location.path, f.location.line]
          end
        end
      end
      tests_path
    end

    def self.tests_csv_path(path) = path.sub(/(\.csv)?\z/i, "_tests.csv")

    private

    def print_header
      stats = @index.stats
      @io.puts bold("Dead code report")
      line(@root, "  ", :cyan)
      counts = ["#{stats[:ruby_files]} Ruby", "#{stats[:templates]} templates",
                "#{stats[:reference_files]} reference-only", "#{stats[:js_files]} JS",
                "#{stats[:test_files]} test files"]
      line(counts.join(" · "), "  ", :dim)
      line("#{route_summary} · #{format("%.1f", @elapsed)}s", "  ", :dim)
      @io.puts
    end

    def print_group(confidence)
      group = @findings.select { |f| f.confidence == confidence }
      rule("#{confidence == :unused ? "UNUSED" : "LIKELY UNUSED"} (#{group.size})", TONE[confidence])
      line(SUBTITLES[confidence], "", :dim)
      line("none", "  ", :dim) if group.empty?

      SECTIONS.each do |kind, title|
        section = group.select { |f| f.kind == kind }
        next if section.empty?

        @io.puts
        @io.puts "  #{paint("1;4", title)} #{dim("(#{section.size})")}"
        collapsed = confidence == :likely_unused ? collapsible(section) : {}
        section.each { |f| print_finding(f) unless collapsed.key?(f.reason) }
        collapsed.each { |reason, fs| print_collapsed(reason, fs, kind, confidence) }
      end
      @io.puts
    end

    # Findings sharing one reason (`matches dynamic dispatch \Asort_by_.+\z`) print as a single block.
    def collapsible(section) = section.group_by(&:reason).select { |_, fs| fs.size >= COLLAPSE_AT }

    def print_finding(finding)
      @io.puts
      @io.puts "  #{paint(TONE[finding.confidence], "●")} #{bold(finding.name)}"
      line(finding.location.to_s, INDENT, :cyan)
      line(finding.reason, INDENT)
      notes = []
      notes << "referenced in tests" if finding.referenced_in_tests
      notes << "#{finding.definition_count} definitions" if finding.definition_count > 1
      line(notes.join(" · "), INDENT, :magenta) if notes.any?
      print_tests(finding)
    end

    # Test blocks that go away with the finding.
    def print_tests(finding)
      tests = finding.tests || []
      return if tests.empty?

      line("Remove with it:", INDENT, :dim)
      tests.each do |t|
        notes = []
        notes << "entire file" if t.whole_file
        notes << "example calls it" if t.match == :calls
        note = notes.join(", ")
        if note.empty? || "#{INDENT}  #{t}  #{note}".length <= @width
          @io.puts "#{INDENT}  #{paint(:green, t)}#{"  #{dim(note)}" unless note.empty?}"
        else
          @io.puts "#{INDENT}  #{paint(:green, t)}"
          line(note, "#{INDENT}    ", :dim)
        end
      end
    end

    def print_collapsed(reason, findings, kind, confidence)
      noun = SECTIONS.fetch(kind).downcase
      @io.puts
      @io.puts "  #{paint(TONE[confidence], "●")} #{bold("#{findings.size} more #{noun}")}"
      line(reason, INDENT)
      line("e.g.", INDENT, :dim)
      findings.first(3).each { |f| line(f.name, "#{INDENT}  ") }
      with_tests = findings.count { |f| f.tests&.any? }
      extra = with_tests.positive? ? "#{with_tests} with removable tests · " : ""
      line("#{extra}full list in --csv", INDENT, :dim)
    end

    def print_warnings(verbose)
      warnings = @index.warnings + (@routes&.warnings || [])
      return if warnings.empty?

      if verbose
        rule("WARNINGS (#{warnings.size})", :dim)
        warnings.each { |w| line(w, "  ") }
      else
        line("#{warnings.size} warning(s) suppressed; rerun with --verbose to see them", "", :dim)
      end
      @io.puts
    end

    def print_summary
      counts = @findings.group_by(&:confidence).transform_values(&:size)
      removable = @findings.select { |f| f.confidence == :unused }.sum { |f| f.tests&.size || 0 }
      rule("SUMMARY", :bold)
      @io.puts "  #{paint(:red, "#{counts.fetch(:unused, 0)} unused")} · " \
               "#{paint(:yellow, "#{counts.fetch(:likely_unused, 0)} likely unused")}"
      line("#{removable} test block(s) removable with the unused findings", "  ", :green)
    end

    def rule(title, tone)
      text = "━━ #{title} "
      @io.puts paint(tone == :bold ? 1 : "1;#{COLORS.fetch(tone)}", text + ("━" * [@width - text.length, 0].max))
    end

    # Word-wraps plain text to the width, then paints each line (escape codes don't count towards the width).
    def line(text, indent, tone = nil)
      wrap(text.to_s, @width - indent.length).each do |part|
        @io.puts "#{indent}#{tone ? paint(tone, part) : part}"
      end
    end

    def wrap(text, width)
      width = [width, 20].max
      text.split.each_with_object([+""]) do |word, lines|
        if lines.last.empty?
          lines.last << word
        elsif lines.last.length + 1 + word.length <= width
          lines.last << " " << word
        else
          lines << word.dup
        end
      end
    end

    def terminal_width(io)
      cols = io.winsize[1] if io.respond_to?(:winsize) && io.tty?
      cols = ENV["COLUMNS"].to_i if cols.to_i.zero? && ENV["COLUMNS"]
      cols.to_i.positive? ? cols : 80
    rescue StandardError
      80
    end

    def route_summary
      return "route analysis skipped" unless @routes

      dynamic = @routes.dynamic ? " (dynamic :controller route: every action counts as routed)" : ""
      "#{@routes.size} routes from #{@routes.source}#{dynamic}"
    end

    COLORS = { bold: 1, dim: 2, red: 31, green: 32, yellow: 33, magenta: 35, cyan: 36 }.freeze
    private_constant :COLORS

    def paint(tone, text)
      return text unless @color

      code = tone.is_a?(Symbol) ? COLORS.fetch(tone) : tone
      "\e[#{code}m#{text}\e[0m"
    end

    def bold(text) = paint(:bold, text)
    def dim(text) = paint(:dim, text)
  end
end
