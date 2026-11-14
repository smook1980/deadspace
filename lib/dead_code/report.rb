# frozen_string_literal: true

module DeadCode
  class Report
    SECTIONS = { module: "Modules", class: "Classes", controller_action: "Controller actions without a route",
                 method: "Methods" }.freeze
    HEADINGS = {
      unused: "UNUSED - nothing reaches it outside of tests",
      likely_unused: "LIKELY UNUSED - not referenced statically, but Rails/Ruby could reach it dynamically; " \
                     "review by hand"
    }.freeze
    CSV_HEADERS = %w[confidence kind name file line reason referenced_in_tests definition_count].freeze
    TEST_CSV_HEADERS = %w[test_file lines first_line last_line match entire_file confidence kind name file line].freeze

    def initialize(findings, index:, routes:, root:, elapsed:)
      @findings = findings
      @index = index
      @routes = routes
      @root = root
      @elapsed = elapsed
    end

    COLLAPSE_AT = 8 # likely-unused findings sharing one reason print as a single summary line

    def print_terminal(io = $stdout, color: io.tty?, verbose: false)
      @color = color
      stats = @index.stats
      io.puts bold("Dead code report: #{@root}")
      io.puts "#{stats[:ruby_files]} Ruby files, #{stats[:templates]} templates, " \
              "#{stats[:reference_files]} reference-only files, #{stats[:js_files]} JS files, " \
              "#{stats[:test_files]} test files, #{route_summary} (#{format("%.1f", @elapsed)}s)"
      io.puts

      %i[unused likely_unused].each do |confidence|
        group = @findings.select { |f| f.confidence == confidence }
        heading = confidence == :unused ? red(HEADINGS[confidence]) : yellow(HEADINGS[confidence])
        io.puts "#{bold(heading)} (#{group.size})"
        io.puts "  none" if group.empty?
        SECTIONS.each do |kind, title|
          section = group.select { |f| f.kind == kind }
          next if section.empty?

          io.puts "  #{bold(title)} (#{section.size})"
          width = [section.map { |f| f.location.to_s.length }.max, 70].min
          collapsed = {}
          if confidence == :likely_unused
            collapsed = section.group_by(&:reason).select { |_, fs| fs.size >= COLLAPSE_AT }
          end
          section.each do |f|
            next if collapsed.key?(f.reason)

            notes = [f.reason]
            notes << "referenced in tests" if f.referenced_in_tests
            notes << "#{f.definition_count} definitions" if f.definition_count > 1
            io.puts "    #{dim(f.location.to_s.ljust(width))}  #{f.name}  #{dim("- #{notes.join("; ")}")}"
            print_tests(io, f)
          end
          collapsed.each do |reason, fs|
            examples = fs.first(3).map(&:name).join(", ")
            with_tests = fs.count { |f| f.tests&.any? }
            tests_note = with_tests.positive? ? "; #{with_tests} with removable tests" : ""
            io.puts "    #{fs.size} more #{dim("- #{reason}")} (e.g. #{examples}#{tests_note}; full list in --csv)"
          end
        end
        io.puts
      end

      warnings = @index.warnings + (@routes&.warnings || [])
      if warnings.any?
        if verbose
          io.puts bold("Warnings")
          warnings.each { |w| io.puts "  #{w}" }
        else
          io.puts dim("#{warnings.size} warning(s) suppressed; rerun with --verbose to see them")
        end
      end
      io.puts summary_line
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

    def summary_line
      counts = @findings.group_by(&:confidence).transform_values(&:size)
      removable = @findings.select { |f| f.confidence == :unused }.sum { |f| f.tests&.size || 0 }
      "Summary: #{counts.fetch(:unused, 0)} unused, #{counts.fetch(:likely_unused, 0)} likely unused; " \
        "#{removable} test block(s) removable with the unused findings"
    end

    private

    # Test blocks that go away with the finding, indented under it.
    def print_tests(io, finding)
      (finding.tests || []).each do |t|
        notes = []
        notes << "entire file" if t.whole_file
        notes << "example calls it" if t.match == :calls
        io.puts "        #{t}#{dim(" (#{notes.join(", ")})") if notes.any?}"
      end
    end

    def route_summary
      return "route analysis skipped" unless @routes

      dynamic = @routes.dynamic ? ", dynamic :controller route found - every action treated as routed" : ""
      "#{@routes.size} controller#action routes from #{@routes.source}#{dynamic}"
    end

    def paint(code, text) = @color ? "\e[#{code}m#{text}\e[0m" : text
    def bold(text) = paint(1, text)
    def dim(text) = paint(2, text)
    def red(text) = paint(31, text)
    def yellow(text) = paint(33, text)
  end
end
