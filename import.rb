#!/usr/bin/env ruby

require "sqlite3"
require "json"
require "zstd-ruby"
require "digest"
require "fileutils"

class ZedImporter
  def initialize(datasources_path = "./datasources", output_db = "./datasources/unified.db", full_import = false)
    @datasources_path = datasources_path
    @output_db        = output_db
    @conversations_path = File.join(@datasources_path, "conversations")
    @threads_path      = File.join(@datasources_path, "threads")
    @full_import = full_import

    # Check for schema changes and force full import if needed
    @full_import = true if needs_schema_migration?

    setup_database
  end

  def setup_database
    if @full_import
      File.delete(@output_db) if File.exist?(@output_db)
    end

    @db = SQLite3::Database.new(@output_db)

    # Create tables if they don't exist
    unless table_exists?("entries")
      @db.execute <<~SQL
        CREATE TABLE entries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          type TEXT NOT NULL,
          title TEXT NOT NULL,
          content TEXT NOT NULL,
          full_json TEXT NOT NULL,
          file_path TEXT,
          workspace_path TEXT,
          project TEXT,
          original_id TEXT,
          timestamp TEXT,
          file_mtime TEXT,
          created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
      SQL

      @db.execute "CREATE INDEX idx_type ON entries(type)"
      @db.execute "CREATE INDEX idx_title ON entries(title)"
      @db.execute "CREATE INDEX idx_file_path ON entries(file_path)"
      @db.execute "CREATE INDEX idx_original_id ON entries(original_id)"
      @db.execute "CREATE INDEX idx_project ON entries(project)"
    end

    # Add columns if they don't exist (migrations)
    unless column_exists?("entries", "file_mtime")
      @db.execute "ALTER TABLE entries ADD COLUMN file_mtime TEXT"
    end
    unless column_exists?("entries", "project")
      @db.execute "ALTER TABLE entries ADD COLUMN project TEXT"
      @db.execute "CREATE INDEX idx_project ON entries(project)"
    end

    # Create FTS5 search index if it doesn't exist
    unless table_exists?("entries_fts")
      @db.execute <<~SQL
        CREATE VIRTUAL TABLE entries_fts USING fts5(
          title,
          content,
          project,
          content=entries,
          content_rowid=id
        )
      SQL

      # Trigger to keep FTS in sync
      @db.execute <<~SQL
        CREATE TRIGGER entries_ai AFTER INSERT ON entries BEGIN
          INSERT INTO entries_fts(rowid, title, content, project) VALUES (new.id, new.title, new.content, COALESCE(new.project, ''));
        END
      SQL

      @db.execute <<~SQL
        CREATE TRIGGER entries_ad AFTER DELETE ON entries BEGIN
          INSERT INTO entries_fts(entries_fts, rowid, title, content, project) VALUES('delete', old.id, old.title, old.content, COALESCE(old.project, ''));
        END
      SQL

      @db.execute <<~SQL
        CREATE TRIGGER entries_au AFTER UPDATE ON entries BEGIN
          INSERT INTO entries_fts(entries_fts, rowid, title, content, project) VALUES('delete', old.id, old.title, old.content, COALESCE(old.project, ''));
          INSERT INTO entries_fts(rowid, title, content, project) VALUES (new.id, new.title, new.content, COALESCE(new.project, ''));
        END
      SQL
    end
  end

  def needs_schema_migration?
    return false unless File.exist?(@output_db)

    temp_db = SQLite3::Database.new(@output_db)

    # Check if project column exists
    has_project = begin
      pragma_result = temp_db.execute("PRAGMA table_info(entries)")
      pragma_result.any? { |row| row[1] == "project" }
    rescue
      false
    end

    temp_db.close
    !has_project
  end

  def table_exists?(table_name)
    result = @db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table_name])
    !result.empty?
  end

  def column_exists?(table_name, column_name)
    pragma_result = @db.execute("PRAGMA table_info(#{table_name})")
    pragma_result.any? { |row| row[1] == column_name }
  end

  def import_conversations
    return unless Dir.exist?(@conversations_path)

    puts "Importing conversations..."
    pattern = File.join(@conversations_path, "*.zed.json")
    files = Dir[pattern]

    # Get existing file info for incremental updates
    existing_files = {}
    unless @full_import
      @db.execute("SELECT file_path, file_mtime FROM entries WHERE type = 'conversation' AND file_path IS NOT NULL") do |row|
        existing_files[row[0]] = row[1]
      end
    end

    new_count = 0
    updated_count = 0

    files.each do |file|
      begin
        file_mtime = File.mtime(file).iso8601

        # Skip if file hasn't changed (incremental mode)
        if !@full_import && existing_files[file] == file_mtime
          next
        end

        content = File.read(file)
        data = JSON.parse(content)

        title = extract_conversation_title(data, file)
        text_content = data["text"] || ""
        timestamp = File.mtime(file).iso8601
        workspace_path = extract_conversation_path(data)
        project = workspace_path ? File.basename(workspace_path) : nil

        if existing_files.key?(file)
          # Update existing entry
          @db.execute <<~SQL, [title, text_content, content, workspace_path, project, timestamp, file_mtime, file]
            UPDATE entries SET title = ?, content = ?, full_json = ?, workspace_path = ?, project = ?, timestamp = ?, file_mtime = ?
            WHERE file_path = ?
          SQL
          updated_count += 1
          puts "  Updated: #{File.basename(file)}"
        else
          # Insert new entry
          @db.execute <<~SQL, ["conversation", title, text_content, content, file, workspace_path, project, nil, timestamp, file_mtime]
            INSERT INTO entries (type, title, content, full_json, file_path, workspace_path, project, original_id, timestamp, file_mtime)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          new_count += 1
          puts "  Added: #{File.basename(file)}"
        end
      rescue => e
        puts "  ERROR: #{File.basename(file)} - #{e.message}"
      end
    end

    # Remove entries for deleted files
    unless @full_import
      deleted_count = 0
      existing_files.each do |file_path, _|
        unless File.exist?(file_path)
          @db.execute("DELETE FROM entries WHERE file_path = ?", [file_path])
          deleted_count += 1
          puts "  Deleted: #{File.basename(file_path)}"
        end
      end
      puts "  Conversations: #{new_count} added, #{updated_count} updated, #{deleted_count} deleted"
    else
      puts "  Conversations: #{new_count} imported"
    end
  end

  def import_threads
    threads_db_path = File.join(@threads_path, "threads.db")
    return unless File.exist?(threads_db_path)

    puts "Importing threads..."
    threads_db = SQLite3::Database.new(threads_db_path)

    # Get existing threads for incremental updates
    existing_threads = {}
    unless @full_import
      @db.execute("SELECT original_id, timestamp FROM entries WHERE type = 'thread' AND original_id IS NOT NULL") do |row|
        existing_threads[row[0]] = row[1]
      end
    end

    new_count = 0
    updated_count = 0

    threads_db.execute("SELECT id, summary, data, updated_at FROM threads") do |row|
      begin
        thread_id, summary, compressed_data, updated_at = row

        # Skip if thread hasn't changed (incremental mode)
        if !@full_import && existing_threads[thread_id] == updated_at
          next
        end

        # Decompress the data
        json_data = Zstd.decompress(compressed_data)
        thread_data = JSON.parse(json_data)

        title = extract_thread_title(thread_data, summary)
        content = extract_thread_content(thread_data)
        workspace_path = extract_workspace_path(thread_data)
        project = workspace_path ? File.basename(workspace_path) : nil

        if existing_threads.key?(thread_id)
          # Update existing entry
          @db.execute <<~SQL, [title, content, json_data, workspace_path, project, updated_at, thread_id]
            UPDATE entries SET title = ?, content = ?, full_json = ?, workspace_path = ?, project = ?, timestamp = ?
            WHERE original_id = ?
          SQL
          updated_count += 1
          puts "  Updated: #{title}"
        else
          # Insert new entry
          @db.execute <<~SQL, ["thread", title, content, json_data, nil, workspace_path, project, thread_id, updated_at]
            INSERT INTO entries (type, title, content, full_json, file_path, workspace_path, project, original_id, timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          new_count += 1
          puts "  Added: #{title}"
        end
      rescue => e
        puts "  ERROR: Thread #{thread_id} - #{e.message}"
      end
    end

    threads_db.close

    # Remove entries for deleted threads
    unless @full_import
      deleted_count = 0
      existing_thread_ids = Set.new
      threads_db = SQLite3::Database.new(threads_db_path)
      threads_db.execute("SELECT id FROM threads") { |row| existing_thread_ids.add(row[0]) }
      threads_db.close

      existing_threads.each do |thread_id, _|
        unless existing_thread_ids.include?(thread_id)
          @db.execute("DELETE FROM entries WHERE original_id = ?", [thread_id])
          deleted_count += 1
          puts "  Deleted: Thread #{thread_id}"
        end
      end
      puts "  Threads: #{new_count} added, #{updated_count} updated, #{deleted_count} deleted"
    else
      puts "  Threads: #{new_count} imported"
    end
  end

  def extract_conversation_title(data, file)
    if data["summary"] && !data["summary"].empty?
      data["summary"]
    else
      File.basename(file, ".zed.json").gsub(/^\s*-\s*/, "").strip
    end
  end

  def extract_thread_title(data, summary)
    # Modern format (v0.3.0) uses 'title', legacy (v0.2.0) uses 'summary'
    title = data["title"] || summary || "Untitled Thread"
    title.empty? ? "Untitled Thread" : title
  end

  def extract_thread_content(data)
    content_parts = []
    messages = data["messages"] || []

    messages.each do |message|
      case data["version"]
      when "0.3.0"
        # Modern format with User/Agent structure
        if message["User"]
          user_content = extract_content_array(message["User"]["content"] || [])
          content_parts << "**User:** #{user_content}" unless user_content.empty?
        elsif message["Agent"]
          agent_content = extract_content_array(message["Agent"]["content"] || [])
          content_parts << "**Agent:** #{agent_content}" unless agent_content.empty?
        end
      when "0.2.0"
        # Legacy format with role-based structure
        role = message["role"] || "unknown"
        segments = message["segments"] || []
        text = segments.map { |s| s["text"] || "" }.join("").gsub("\\n", "\n")
        content_parts << "**#{role.capitalize}:** #{text}" unless text.empty?
      end
    end

    content_parts.join("\n\n")
  end

  def extract_content_array(content_array)
    content_array.map do |item|
      if item.is_a?(Hash)
        if item["Text"]
          item["Text"]
        elsif item["ToolUse"]
          tool_use = item["ToolUse"]
          tool_name = tool_use["name"] || "unknown"
          "`[Tool: #{tool_name}]`"
        else
          ""
        end
      else
        item.to_s
      end
    end.join(" ")
  end

  def extract_workspace_path(data)
    snapshot = data["initial_project_snapshot"]
    return nil unless snapshot

    worktree_snapshots = snapshot["worktree_snapshots"]
    return nil unless worktree_snapshots&.any?

    worktree_snapshots.first["worktree_path"]
  end

  def extract_conversation_path(data)
    sections = data["slash_command_output_sections"] || []
    paths = sections.filter_map { |section| section.dig("metadata", "path") }
    return nil if paths.empty?

    # Find common base path
    return paths.first if paths.length == 1

    common_parts = paths.first.split("/")
    paths[1..].each do |path|
      path_parts = path.split("/")
      common_parts = common_parts.zip(path_parts).take_while { |a, b| a == b }.map(&:first)
    end

    common_parts.empty? ? nil : common_parts.join("/")
  end

  def run
    puts "Starting #{@full_import ? 'full' : 'incremental'} import process..."
    puts "Datasources: #{@datasources_path}"
    puts "Output DB: #{@output_db}"

    import_conversations
    import_threads

    # Show summary
    counts = @db.execute("SELECT type, COUNT(*) FROM entries GROUP BY type")
    puts "\nImport complete:"
    counts.each { |type, count| puts "  #{type}: #{count}" }

    total = @db.execute("SELECT COUNT(*) FROM entries").first.first
    puts "  Total: #{total}"

    # Populate FTS index if it's a full import or if FTS is empty
    fts_count = @db.execute("SELECT COUNT(*) FROM entries_fts").first.first
    if @full_import || fts_count == 0
      puts "Populating search index..."
      @db.execute "DELETE FROM entries_fts" if fts_count > 0
      @db.execute "INSERT INTO entries_fts(rowid, title, content, project) SELECT id, title, content, COALESCE(project, '') FROM entries"
    end

    @db.close
  end
end

# Run if called directly
if __FILE__ == $0
  require 'optparse'
  require 'set'

  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: import.rb [options] [datasources_path] [output_db]"

    opts.on("--full", "Perform full import (delete and recreate database)") do |v|
      options[:full] = v
    end

    opts.on("-h", "--help", "Prints this help") do
      puts opts
      exit
    end
  end.parse!

  datasources = ARGV[0] || "./datasources"
  output_db = ARGV[1] || "./datasources/unified.db"
  full_import = options[:full] || false

  importer = ZedImporter.new(datasources, output_db, full_import)
  importer.run
end
