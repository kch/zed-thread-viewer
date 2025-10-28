#!/usr/bin/env ruby

require "sqlite3"
require "json"
require "zstd-ruby"
require "digest"
require "fileutils"

class ZedImporter
  def initialize(datasources_path = "./datasources", output_db = "./datasources/unified.db")
    @datasources_path = datasources_path
    @output_db        = output_db
    @conversations_path = File.join(@datasources_path, "conversations")
    @threads_path      = File.join(@datasources_path, "threads")
    
    setup_database
  end

  def setup_database
    File.delete(@output_db) if File.exist?(@output_db)
    
    @db = SQLite3::Database.new(@output_db)
    @db.execute <<~SQL
      CREATE TABLE entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        full_json TEXT NOT NULL,
        file_path TEXT,
        workspace_path TEXT,
        original_id TEXT,
        timestamp TEXT,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    SQL
    
    @db.execute "CREATE INDEX idx_type ON entries(type)"
    @db.execute "CREATE INDEX idx_title ON entries(title)"
    
    # Create FTS5 search index
    @db.execute <<~SQL
      CREATE VIRTUAL TABLE entries_fts USING fts5(
        title, 
        content,
        content=entries,
        content_rowid=id
      )
    SQL
    
    # Trigger to keep FTS in sync
    @db.execute <<~SQL
      CREATE TRIGGER entries_ai AFTER INSERT ON entries BEGIN
        INSERT INTO entries_fts(rowid, title, content) VALUES (new.id, new.title, new.content);
      END
    SQL
    
    @db.execute <<~SQL
      CREATE TRIGGER entries_ad AFTER DELETE ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, title, content) VALUES('delete', old.id, old.title, old.content);
      END
    SQL
    
    @db.execute <<~SQL
      CREATE TRIGGER entries_au AFTER UPDATE ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, title, content) VALUES('delete', old.id, old.title, old.content);
        INSERT INTO entries_fts(rowid, title, content) VALUES (new.id, new.title, new.content);
      END
    SQL
  end

  def import_conversations
    return unless Dir.exist?(@conversations_path)
    
    puts "Importing conversations..."
    pattern = File.join(@conversations_path, "*.zed.json")
    files = Dir[pattern]
    
    files.each do |file|
      begin
        content = File.read(file)
        data = JSON.parse(content)
        
        title = extract_conversation_title(data, file)
        text_content = data["text"] || ""
        timestamp = File.mtime(file).iso8601
        workspace_path = extract_conversation_path(data)
        
        @db.execute <<~SQL, ["conversation", title, text_content, content, file, workspace_path, nil, timestamp]
          INSERT INTO entries (type, title, content, full_json, file_path, workspace_path, original_id, timestamp)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        
        puts "  #{File.basename(file)}"
      rescue => e
        puts "  ERROR: #{File.basename(file)} - #{e.message}"
      end
    end
  end

  def import_threads
    threads_db_path = File.join(@threads_path, "threads.db")
    return unless File.exist?(threads_db_path)
    
    puts "Importing threads..."
    threads_db = SQLite3::Database.new(threads_db_path)
    
    threads_db.execute("SELECT id, summary, data, updated_at FROM threads") do |row|
      begin
        thread_id, summary, compressed_data, updated_at = row
        
        # Decompress the data
        json_data = Zstd.decompress(compressed_data)
        thread_data = JSON.parse(json_data)
        
        title = extract_thread_title(thread_data, summary)
        content = extract_thread_content(thread_data)
        workspace_path = extract_workspace_path(thread_data)
        
        @db.execute <<~SQL, ["thread", title, content, json_data, nil, workspace_path, thread_id, updated_at]
          INSERT INTO entries (type, title, content, full_json, file_path, workspace_path, original_id, timestamp)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        
        puts "  #{title}"
      rescue => e
        puts "  ERROR: Thread #{thread_id} - #{e.message}"
      end
    end
    
    threads_db.close
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
    puts "Starting import process..."
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
    
    # Populate FTS index
    puts "Populating search index..."
    @db.execute "INSERT INTO entries_fts(rowid, title, content) SELECT id, title, content FROM entries"
    
    @db.close
  end
end

# Run if called directly
if __FILE__ == $0
  datasources = ARGV[0] || "./datasources"
  output_db = ARGV[1] || "./datasources/unified.db"
  
  importer = ZedImporter.new(datasources, output_db)
  importer.run
end