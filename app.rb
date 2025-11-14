require "roda"
require "sqlite3"
require "json"
require "erb"
require "digest"

class ConversationViewer < Roda
  plugin :render, engine: "erb", layout: false, views: "views", allowed_paths: %w[views]
  plugin :json
  plugin :public, root: "public"

  def self.db
    @db ||= begin
      db = SQLite3::Database.new("./datasources/unified.db")
      setup_stars_db(db)
      db
    end
  end

  def self.setup_stars_db(db)
    stars_db_path = "./datasources/stars.db"

    # Create stars database if it doesn't exist
    stars_db = SQLite3::Database.new(stars_db_path)
    stars_db.execute <<~SQL
      CREATE TABLE IF NOT EXISTS stars (
        file_path TEXT,
        original_id TEXT,
        starred_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (file_path, original_id)
      )
    SQL
    stars_db.close

    # Attach to unified database
    db.execute("ATTACH DATABASE '#{stars_db_path}' AS stars")
  end

  def asset_with_hash(filename)
    path = File.join("public", filename)
    if File.exist?(path)
      hash = Digest::MD5.hexdigest(File.read(path))
      "/#{filename}?#{hash}"
    else
      "/#{filename}"
    end
  end

  route do |r|
    # Serve static files from public directory
    r.public

    r.root do
      render("index.html")
    end

    r.post "import" do
      system("bin/import")
      { success: true }
    end

    r.get "titles" do
      starred_only = r.params["starred"] == "true"

      sql = if starred_only
        <<~SQL
          SELECT e.id, e.title, e.type, e.project, e.timestamp,
                 CASE WHEN s.file_path IS NOT NULL OR s.original_id IS NOT NULL THEN 1 ELSE 0 END as starred
          FROM entries e
          JOIN stars.stars s ON (e.file_path = s.file_path OR e.original_id = s.original_id)
          ORDER BY e.timestamp DESC
        SQL
      else
        <<~SQL
          SELECT e.id, e.title, e.type, e.project, e.timestamp,
                 CASE WHEN s.file_path IS NOT NULL OR s.original_id IS NOT NULL THEN 1 ELSE 0 END as starred
          FROM entries e
          LEFT JOIN stars.stars s ON (e.file_path = s.file_path OR e.original_id = s.original_id)
          ORDER BY e.timestamp DESC
        SQL
      end

      rows = self.class.db.execute(sql)
      rows.map do |id, title, type, project, timestamp, starred|
        symbol = type == "thread" ? "𝐀" : "𝐓"
        created_at = timestamp ? Time.parse(timestamp).iso8601 : nil
        {
          id: id,
          title: title,
          type: type,
          symbol: symbol,
          workspace: project || "",
          created_at: created_at,
          starred: starred == 1
        }
      end
    end

    r.get "search" do
      query = r.params["q"].to_s.strip
      return [] if query.empty?

      starred_only = r.params["starred"] == "true"

      sql = if starred_only
        <<~SQL
          SELECT e.id, e.title, e.type, e.project, e.timestamp,
                 CASE WHEN s.file_path IS NOT NULL OR s.original_id IS NOT NULL THEN 1 ELSE 0 END as starred
          FROM entries e
          JOIN entries_fts ON entries_fts.rowid = e.id
          JOIN stars.stars s ON (e.file_path = s.file_path OR e.original_id = s.original_id)
          WHERE entries_fts MATCH ?
          ORDER BY e.timestamp DESC
        SQL
      else
        <<~SQL
          SELECT e.id, e.title, e.type, e.project, e.timestamp,
                 CASE WHEN s.file_path IS NOT NULL OR s.original_id IS NOT NULL THEN 1 ELSE 0 END as starred
          FROM entries e
          JOIN entries_fts ON entries_fts.rowid = e.id
          LEFT JOIN stars.stars s ON (e.file_path = s.file_path OR e.original_id = s.original_id)
          WHERE entries_fts MATCH ?
          ORDER BY e.timestamp DESC
        SQL
      end

      rows = self.class.db.execute(sql, ["#{query}*"])
      rows.map do |id, title, type, project, timestamp, starred|
        symbol = type == "thread" ? "𝐀" : "𝐓"
        created_at = timestamp ? Time.parse(timestamp).iso8601 : nil
        {
          id: id,
          title: title,
          type: type,
          symbol: symbol,
          workspace: project || "",
          created_at: created_at,
          starred: starred == 1
        }
      end
    end

    r.on "star" do
      r.is Integer do |id|
        if r.post?
          row = self.class.db.execute(<<~SQL, [id]).first
            SELECT e.file_path, e.original_id,
                   CASE WHEN s.file_path IS NOT NULL OR s.original_id IS NOT NULL THEN 1 ELSE 0 END as starred
            FROM entries e
            LEFT JOIN stars.stars s ON (e.file_path = s.file_path OR e.original_id = s.original_id)
            WHERE e.id = ?
          SQL
          return { success: false, error: "Entry not found" } unless row

          file_path, original_id, currently_starred = row

          begin
            if currently_starred == 1
              # Unstar
              self.class.db.execute(
                "DELETE FROM stars.stars WHERE file_path = ? OR original_id = ?",
                [file_path, original_id]
              )
              { success: true, starred: false }
            else
              # Star
              self.class.db.execute(
                "INSERT OR REPLACE INTO stars.stars (file_path, original_id) VALUES (?, ?)",
                [file_path, original_id]
              )
              { success: true, starred: true }
            end
          rescue => e
            { success: false, error: e.message }
          end
        end
      end
    end

    r.get "content", Integer do |id|
      row = self.class.db.execute(<<~SQL, [id]).first
        SELECT e.title, e.content, e.type, e.full_json, e.file_path, e.original_id,
               CASE WHEN s.file_path IS NOT NULL OR s.original_id IS NOT NULL THEN 1 ELSE 0 END as starred
        FROM entries e
        LEFT JOIN stars.stars s ON (e.file_path = s.file_path OR e.original_id = s.original_id)
        WHERE e.id = ?
      SQL

      return "Not found" unless row

      title, content, type, full_json, file_path, original_id, starred = row

      response["Content-Type"] = "text/html; charset=utf-8"

      # Render markdown view
      require 'kramdown'
      require 'kramdown-parser-gfm'

      # Process slash command output sections and message roles
      processed_content = content.dup
      parsed_json = JSON.parse(full_json)

      all_ops = []

      # Process slash command output sections (only for conversations, not threads)
      if type == "conversation" && parsed_json["slash_command_output_sections"]
        sections = parsed_json["slash_command_output_sections"]
        unless sections.empty?
          # Group overlapping sections
          def ranges_overlap?(r1, r2)
            r1["start"] < r2["end"] && r2["start"] < r1["end"]
          end

          groups = []
          sections.each do |section|
            # Find existing group this section overlaps with
            group = groups.find { |g|
              g.any? { |existing| ranges_overlap?(section["range"], existing["range"]) }
            }

            if group
              group << section
            else
              groups << [section]
            end
          end

          # Convert slash groups to operations
          groups.each do |group|
            group_min = group.map { |s| s["range"]["start"] }.min
            group_max = group.map { |s| s["range"]["end"] }.max
            labels = group.map { |s| s["label"] || "Unknown" }.uniq
            combined_label = labels.join("+")

            all_ops << {
              'start' => group_min,
              'end' => group_max,
              'label' => combined_label,
              'type' => 'slash'
            }
          end
        end
      end

      # Process message roles (only for conversations, not threads)
      if type == "conversation" && parsed_json["messages"]
        parsed_json["messages"].each do |message|
          if message["start"] && message["metadata"] && message["metadata"]["role"]
            role = message["metadata"]["role"]
            next if role.nil? || role.empty?

            # Skip if start position is beyond content byte length
            start_pos = message["start"]
            next if start_pos >= processed_content.bytesize

            all_ops << {
              'start' => start_pos,
              'end' => start_pos, # Just insertion
              'label' => role,
              'type' => 'role'
            }
          end
        end
      end

      # Convert to binary for byte-based operations
      result = processed_content.b

      # Process all operations back to front to avoid position shifts
      all_ops.sort_by { |op| -op['start'] }.each do |op|
        pos = op['start']
        next if pos > result.bytesize  # Skip out of bounds

        if op['type'] == 'slash'
          replacement = "<span class=\"slash-command\">#{CGI.escapeHTML("/#{op['label']}")}</span>\n"
          result = result.byteslice(0, op['start']) + replacement + result.byteslice(op['end']..-1)
        else
          label = op['label'] || 'UNKNOWN'
          replacement = "\n<div class=\"role-label\">#{CGI.escapeHTML(label.upcase)}</div>\n"
          result = result.byteslice(0, pos) + replacement + result.byteslice(pos..-1)
        end
      end

      # Convert back to UTF-8
      processed_content = result.force_encoding('UTF-8')

      html_content = Kramdown::Document.new(processed_content, {
        input: 'GFM',
        syntax_highlighter: 'rouge',
        syntax_highlighter_opts: {
          css_class: 'highlight',
          span: {
            line_numbers: false
          }
        }
      }).to_html

      # Sanitize HTML to prevent script execution while preserving code blocks
      require 'loofah'
      html_content = Loofah.fragment(html_content).scrub!(:escape)

      render("content_markdown.html", locals: {
        title: title,
        type: type,
        id: id,
        html_content: html_content,
        toggle_url: "/content/#{id}/json",
        toggle_text: "Show JSON",
        starred: starred == 1
      })
    end

    r.get "content", Integer, "json" do |id|
      row = self.class.db.execute(<<~SQL, [id]).first
        SELECT e.title, e.content, e.type, e.full_json, e.file_path, e.original_id,
               CASE WHEN s.file_path IS NOT NULL OR s.original_id IS NOT NULL THEN 1 ELSE 0 END as starred
        FROM entries e
        LEFT JOIN stars.stars s ON (e.file_path = s.file_path OR e.original_id = s.original_id)
        WHERE e.id = ?
      SQL

      return "Not found" unless row

      title, content, type, full_json, file_path, original_id, starred = row

      response["Content-Type"] = "text/html; charset=utf-8"

      require 'cgi'

      def format_json_with_blocks(obj, indent = 0)
        spaces = "  " * indent
        case obj
        when Hash
          return "{}" if obj.empty?
          result = "{\n"
          obj.each_with_index do |(key, value), index|
            result += "#{spaces}  <span class=\"json-key\">\"#{CGI.escapeHTML(key)}\"</span>: "

            if value.is_a?(String) && value.length > 50
              # Format long strings as indented blocks
              decoded = value.gsub(/\\n/, "\n").gsub(/\\t/, "\t").gsub(/\\"/, '"')
              lines = decoded.split("\n")
              block_id = "block_#{Digest::MD5.hexdigest("#{key}_#{indent}")}"
              padding_left = (indent + 1) * 16 + 4  # Align under the key

              if lines.length > 6
                preview_lines = lines.first(6) + ["..."]
                full_content = CGI.escapeHTML(decoded)
                preview_content = CGI.escapeHTML(preview_lines.join("\n"))

                result += "\n<div class=\"json-string-block expandable-block\" style=\"margin-left: #{padding_left}px;\" onclick=\"toggleBlock('#{block_id}')\">"
                result += "<div class=\"block-preview\" id=\"#{block_id}_preview\">#{preview_content}<div class=\"fade-overlay\"></div></div>"
                result += "<div class=\"block-full\" id=\"#{block_id}_full\" style=\"display:none;\">#{full_content}</div>"
                result += "<button class=\"expand-btn\" id=\"#{block_id}_btn\" onclick=\"event.stopPropagation(); toggleBlock('#{block_id}')\">show more</button>"
                result += "</div>"
              else
                result += "\n<div class=\"json-string-block\" style=\"margin-left: #{padding_left}px;\">#{CGI.escapeHTML(decoded)}</div>"
              end
            else
              result += format_json_with_blocks(value, indent + 1)
            end

            result += index < obj.size - 1 ? ",\n" : "\n"
          end
          result += "#{spaces}}"
        when Array
          return "[]" if obj.empty?
          result = "[\n"
          obj.each_with_index do |item, index|
            result += "#{spaces}  #{format_json_with_blocks(item, indent + 1)}"
            result += index < obj.size - 1 ? ",\n" : "\n"
          end
          result += "#{spaces}]"
        when String
          if obj.length > 50
            decoded = obj.gsub(/\\n/, "\n").gsub(/\\t/, "\t").gsub(/\\"/, '"')
            lines = decoded.split("\n")
            block_id = "block_#{Digest::MD5.hexdigest("#{obj}_#{indent}")}"
            padding_left = indent * 16 + 4

            if lines.length > 6
              preview_lines = lines.first(6) + ["..."]
              full_content = CGI.escapeHTML(decoded)
              preview_content = CGI.escapeHTML(preview_lines.join("\n"))

              result = "<div class=\"json-string-block expandable-block\" style=\"margin-left: #{padding_left}px;\" onclick=\"toggleBlock('#{block_id}')\">"
              result += "<div class=\"block-preview\" id=\"#{block_id}_preview\">#{preview_content}<div class=\"fade-overlay\"></div></div>"
              result += "<div class=\"block-full\" id=\"#{block_id}_full\" style=\"display:none;\">#{full_content}</div>"
              result += "<button class=\"expand-btn\" id=\"#{block_id}_btn\" onclick=\"event.stopPropagation(); toggleBlock('#{block_id}')\">show more</button>"
              result += "</div>"
              result
            else
              "<div class=\"json-string-block\" style=\"margin-left: #{padding_left}px;\">#{CGI.escapeHTML(decoded)}</div>"
            end
          else
            "<span class=\"json-string\">\"#{CGI.escapeHTML(obj)}\"</span>"
          end
        when Numeric
          "<span class=\"json-number\">#{obj}</span>"
        when TrueClass, FalseClass, NilClass
          "<span class=\"json-boolean\">#{obj}</span>"
        else
          CGI.escapeHTML(obj.to_s)
        end
      end

      parsed_json = JSON.parse(full_json)
      highlighted_json = format_json_with_blocks(parsed_json)

      render("content_json.html", locals: {
        title: title,
        type: type,
        id: id,
        highlighted_json: highlighted_json,
        toggle_url: "/content/#{id}",
        toggle_text: "Show Content",
        starred: starred == 1
      })
    end
  end
end
