# frozen_string_literal: true

require "net/http"
require "nokogiri"
require "yaml"
require_relative "base"

class ImportScripts::DelphiImporter < ImportScripts::Base
  DATA_PATH = ENV["DELPHI_DATA_PATH"] || "/shared/import/data"
  PROFILES_PATH = ENV["DELPHI_PROFILES_PATH"] || "#{DATA_PATH}/profiles"
  THREADS_PATH = ENV["DELPHI_THREADS_PATH"] || "#{DATA_PATH}/threads"
  FILES_PATH = ENV["DELPHI_FILES_PATH"] || "#{DATA_PATH}/files"

  IMPORT_PREFIX = "delphi-"
  IMPORT_FORUM_PREFIX = "#{IMPORT_PREFIX}#{ENV['DELPHI_FORUM_NAME'] || 'forum'}-"
  EMAIL_DOMAIN = ENV["DELPHI_EMAIL_DOMAIN"] || "example.com"

  def initialize
    super
    @delphi_cookie = nil

    if ENV["DELPHI_USERNAME"].present? && ENV["DELPHI_PASSWORD"].present?
      @delphi_cookie = delphi_login(ENV["DELPHI_USERNAME"], ENV["DELPHI_PASSWORD"])
    end

    @exported_users = load_profiles(PROFILES_PATH)
    @exported_threads, @exported_categories = load_threads(THREADS_PATH)
    @skip_updates = true
  end

  def execute
    puts "=> Starting import from Delphi..."
    import_users
    import_categories
    import_posts
  end

  def load_yaml(path)
    unless File.exist?(path)
      puts "File doesn't exist: #{path}"
      return nil
    end

    YAML.safe_load(File.read(path), symbolize_names: false)
  end

  def load_profiles(path)
    profiles = []
    Dir.glob("#{path}/*.yaml").each do |file|
      # Skip erroneous profiles created by the export script
      next if file.end_with?("unread.yaml")
      profiles << load_yaml(file)
    end

    profiles
  end

  def load_threads(path)
    threads = []
    Dir.glob("#{path}/*.yaml").each do |file|
      threads << load_yaml(file)
    end

    # Infer the forum categories from the thread folders
    categories = threads.map { |t| t["metadata"]["folder"] }
    categories.uniq!

    [threads, categories]
  end

  def get_user_names(profile_id)
    parts = profile_id.match(/^(.*?)\s*(?:\((\w+)\))?$/)
    full_name = parts[1].strip unless parts[2].nil?
    username = parts[2] || parts[1].strip

    [username, full_name]
  end

  def get_email(username)
    # Construct a placeholder email in lieu of being able to get email addresses from Delphi
    "#{username}@#{EMAIL_DOMAIN}"
  end

  def get_category_id(folder_name)
    IMPORT_FORUM_PREFIX + folder_name.downcase.gsub(" ", "_")
  end

  def parse_profile_datetime(text)
    return nil if text.blank?
    if text.start_with?("Yesterday")
      d = Date.yesterday
      t = Time.strptime(text, "Yesterday at %l:%M %P")
      return DateTime.new(d.year, d.month, d.day, t.hour, t.min, t.sec)
    end
    DateTime.strptime(text, "%B %e, %Y %l:%M %P")
  end

  def parse_message_datetime(text)
    return nil if text.blank?
    DateTime.strptime(text, "%a %b %e %H:%M:%S %Y")
  end

  def import_users
    puts "=> Importing users"

    users = @exported_users.map do |user|
      username, full_name = get_user_names(user["profile_id"])
      user["id"] = IMPORT_PREFIX + username
      user["username"] = username
      user["name"] = full_name
      user["email"] = get_email(username)
      user
    end
    users.uniq!

    create_users(users) do |u|
      {
        id: u["id"],
        username: u["username"],
        email: u["email"],
        created_at: parse_profile_datetime(u["Member Since"]),
        last_seen_at: parse_profile_datetime(u["Last visit"]),
        location: u["Location"],
        bio_raw: u["Personal Quote"],
        post_create_action: proc { |user| import_avatar(user, u["username"]) },
      }
    end
  end

  def import_categories
    puts "", "=> Importing categories"

    categories = @exported_categories.map do |c|
      { id: get_category_id(c), name: c }
    end
    categories.uniq!

    create_categories(categories) do |c|
      { id: c[:id], user_id: Discourse::SYSTEM_USER_ID, name: c[:name] }
    end
  end

  def import_posts
    puts "", "=> Importing posts"

    @exported_threads.each do |t|
      topic_id = IMPORT_FORUM_PREFIX + t["thead_id"].to_s

      create_posts(t["messages"]) do |p|
        skip = false
        post_index = p["id"].split('.')[1].to_i

        username, _ = get_user_names(p["from"])
        user_id = @lookup.user_id_from_imported_user_id(IMPORT_PREFIX + username) || Discourse::SYSTEM_USER_ID

        body = HtmlToMarkdown.new(p["content"]).to_markdown
        body = process_images(body, p["images"], user_id)

        if p["attachments"].length > 0
          attachments = import_attachments(p["attachments"], user_id)
          body << "\n" << attachments.join("\n")
        end

        mapped = {}
        mapped[:id] = IMPORT_FORUM_PREFIX + p["id"]
        mapped[:user_id] = user_id
        mapped[:raw] = body
        mapped[:created_at] = parse_message_datetime(p["date"])

        if p["in_reply_to"].present?
          reply_to_post_id = @lookup.post_id_from_imported_post_id(IMPORT_FORUM_PREFIX + p["in_reply_to"])
          reply_to_post = reply_to_post_id.present? ? Post.find(reply_to_post_id) : nil
          if reply_to_post.present?
            mapped[:reply_to_post_number] = reply_to_post.post_number
          end
        end

        if post_index == 1
          # First post, create the topic
          mapped[:id] = topic_id
          mapped[:title] = t["metadata"]["topic"]
          mapped[:category] = @lookup.category_id_from_imported_category_id(
            get_category_id(t["metadata"]["folder"])
          )
        else
          parent = @lookup.topic_lookup_from_imported_post_id(topic_id)
          if parent
            mapped[:topic_id] = parent[:topic_id]
          else
            puts "Parent topic \"#{topic_id}\" doesn't exist. Skipping post \"#{p["id"]}\""
            skip = true
          end
        end

        skip ? nil : mapped
      end
    end
  end

  def process_images(body, images, user_id)
    result = body.dup

    images.each do |url|
      filename = File.basename(url)

      # Split the extension from the URL
      file_ext = File.extname(url)
      url_base = url.split(file_ext).first

      # Calculate SHA1 hash of url_base
      # This will be the filename of the downloaded image in the export
      sha1sum = Digest::SHA1.hexdigest(url_base)
      filepath = File.join(FILES_PATH, "#{sha1sum}#{file_ext}")

      if File.exist?(filepath)
        upload = @uploader.create_upload(user_id, filepath, filename)

        if upload.nil? || !upload.persisted?
          puts "Failed to upload #{filepath}"
          puts upload.errors.inspect if upload
        else
          image_html = html_for_upload(upload, filename)
          replace_regex = Regexp.new("!\\[.*?\\]\\(#{Regexp.escape(url)}\\)")
          result = result.sub(replace_regex, image_html)
        end
      else
        puts "Image not found in export: #{url}, expected location: #{filepath}"
      end
    end

    result
  end

  def import_attachments(attachments, user_id)
    result = []

    attachments.each do |a|
      # Calculate SHA1 hash of the attachment URL
      # This will be the filename of the downloaded file in the export
      filename = Digest::SHA1.hexdigest(a["href"])
      filepath = File.join(FILES_PATH, filename)

      if File.exist?(filepath)
        begin
          file_header = File.open(filepath) {|f| f.readline}
        rescue IOError => e
          puts "", "Failed to read attachment \"#{filepath}\": #{e}"
          next
        end

        if file_header.include?("<html>")
          if @delphi_cookie.blank?
            puts "", "Skipping attachment \"#{filename}\", not logged in to Delphi"
            next
          end

          # Delphi injected an advertisement, download the real file
          ad_html = File.read(filepath)
          document = Nokogiri::HTML(ad_html)
          file_frame = document.at_css("frame[name='attachframe']")

          if file_frame.blank?
            puts "", "Failed to parse \"#{filepath}\", skipping"
            next
          end

          file_uri = URI("https://forums.delphiforums.com" + file_frame['src'])

          begin
            file_data = delphi_get(file_uri)
          rescue StandardError => code
            puts "", "Failed to fetch attachment \"#{filepath}\" (status: #{code})"
            next
          end

          begin
            File.write(filepath, file_data, mode: "wb")
          rescue IOError => e
            puts "", "Failed to overwrite attachment \"#{filepath}\": #{e}"
            next
          end
        end

        upload = @uploader.create_upload(user_id, filepath, a["name"])

        if upload.nil? || !upload.persisted?
          puts "", "Failed to upload #{filepath}"
          puts upload.errors.inspect if upload
        else
          result << html_for_upload(upload, a["name"])
        end
      end
    end

    result
  end

  def import_avatar(user, username)
    return if @delphi_cookie.blank?

    # Fetch the user's profile page
    profile_uri = URI("https://profiles.delphiforums.com/#{username}")
    begin
      profile_page = delphi_get(profile_uri)
    rescue StandardError => code
      puts "Failed to fetch profile for user \"#{username}\" (status: #{code})"
      return
    end

    document = Nokogiri::HTML(profile_page)
    img_tag = document.at_css('img.os-img')

    if img_tag.blank?
      puts "Failed to parse profile for user \"#{username}\""
      return
    end

    img_url = img_tag['src']

    # User doesn't have an avatar
    return if img_url.end_with?("default.icon")

    begin
      UserAvatar.import_url_for_user(img_url, user)
    rescue StandardError
      puts "Failed to import avatar for user \"#{username}\""
    end
  end

  def delphi_login(username, password)
    uri = URI("https://forums.delphiforums.com/dflogin/api/v1/auth/authenticate")
    params = {
      sourceId: "lgnForm",
      fieldPrefix: "lgnForm",
      setCookie: true,
      getAlerts: true,
      pttv: 3,
      lgnForm_username: username,
      lgnForm_password: password,
      lgnForm_savePassword: false,
      method: "POST",
    }
    uri.query = URI.encode_www_form(params)
    res = Net::HTTP.get_response(uri)

    unless res.is_a?(Net::HTTPSuccess)
      panic "Failed to login to Delphi as \"#{username}\" (status: #{res.code})"
    end

    puts "=> Logged in to Delphi as #{username}"

    # Extract the cookies from the response and return as a Cookie header
    cookies = res.get_fields("Set-Cookie").map { |c| c.split("; ").first }
    cookies.join("; ")
  end

  def delphi_get(uri)
    req = Net::HTTP::Get.new(uri)
    req['Cookie'] = @delphi_cookie
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }

    unless res.is_a?(Net::HTTPSuccess)
      raise StandardError, res.code
    end

    res.body
  end
end

ImportScripts::DelphiImporter.new.perform if __FILE__ == $0
