require "faraday"
require "json"

module Blade::SauceLabsPlugin::Client
  extend self

  ALIASES = {
    "ie" => "Internet Explorer",
    "IE" => "Internet Explorer"
  }

  MOBILE_PATTERN = /iphone|ipad|android/i

  delegate :config, :username, :access_key, :debug?, to: Blade::SauceLabsPlugin

  def request(method, path, params = {})
    connection.send(method) do |req|
      req.url path
      req.headers["Content-Type"] = "application/json"
      req.body = params.to_json
    end
  end

  def get_jobs(options = {})
    JSON.parse(request(:get, "/rest/v1/#{username}/jobs?#{options.to_query}").body)
  end

  def update_job(id, params = {})
    request(:put, "/rest/v1/#{username}/jobs/#{id}", params)
  end

  def stop_job(id)
    request(:put, "/rest/v1/#{username}/jobs/#{id}/stop")
  end

  def delete_job(id)
    request(:delete, "/rest/v1/#{username}/jobs/#{id}")
  end

  def get_available_vm_count
    data = JSON.parse(request(:get, "/rest/v1/users/#{username}/concurrency").body)
    data["concurrency"][username]["remaining"]["overall"]
  end

  def platforms
    [].tap do |platforms|
      config.browsers.each do |name, config|
        browser =
          case config
          when String, Numeric
            { version: config }
          when Hash
            config.symbolize_keys
          else
            {}
          end.merge(name: name)

        browser[:os] =
          if browser[:os].is_a?(String)
            browser[:os].split(",").map(&:strip)
          else
            Array(browser[:os])
          end

        platforms.concat platforms_for_browser(browser)
      end
    end
  end

  def platforms_for_browser(browser)
    long_name = find_browser_long_name(browser[:name])
    platforms = available_platforms_by_browser[long_name]

    versions_by_os = {}
    platforms.each do |os, details|
      versions_by_os[os] = details[:versions].uniq.sort_by(&:to_f).reverse
    end

    if browser[:os].any?
      browser[:os].flat_map do |browser_os|
        versions =
          if browser[:version].is_a?(Numeric) && browser[:version] < 0
            versions_by_os[browser_os].select { |v| v =~ /^\d/ }.first(browser[:version].abs.to_i)
          elsif browser[:version].present?
            Array(browser[:version]).map(&:to_s)
          else
            versions_by_os[browser_os].first(1)
          end

        versions.map do |version|
          os = platforms.keys.detect { |os| os =~ Regexp.new(browser_os, Regexp::IGNORECASE) }
          platform = platforms[os][:api][version].first
          { platform: platform[0], browserName: platform[1], version: platform[2] }
        end
      end
    else
      all_versions = versions_by_os.values.flatten.uniq
      versions =
        if browser[:version].is_a?(Numeric) && browser[:version] < 0
          all_versions.select { |v| v =~ /^\d/ }.first(browser[:version].abs.to_i)
        elsif browser[:version].present?
          Array(browser[:version]).map(&:to_s)
        else
          all_versions.first(1)
        end

      versions.map do |version|
        os = platforms.detect { |os, details| details[:api][version].any? }.first
        platform = platforms[os][:api][version].first
        { platform: platform[0], browserName: platform[1], version: platform[2] }
      end
    end
  end

  def find_browser_long_name(name)
    if match = ALIASES[name.to_s]
      match
    else
      available_platforms_by_browser.keys.detect do |long_name|
        long_name =~ Regexp.new(name, Regexp::IGNORECASE)
      end
    end
  end

  def available_platforms_by_browser
    @available_platforms_by_browser ||= {}.tap do |by_browser|
      available_platforms.group_by { |p| p[:api_name] }.each do |api_name, platforms|
        long_name = platforms.first[:long_name]
        by_browser[long_name] = {}

        platforms.group_by { |p| p[:os].split(" ").first }.each do |os, platforms|
          by_browser[long_name][os] = {}
          by_browser[long_name][os][:versions] = []
          by_browser[long_name][os][:api] = {}

          versions = platforms.map { |p| p[:short_version] }.uniq.sort_by(&:to_f).reverse

          versions.each do |version|
            by_browser[long_name][os][:versions] << version

            by_browser[long_name][os][:api][version] = platforms.map do |platform|
              if platform[:short_version] == version
                platform.values_at(:os, :api_name, :short_version)
              end
            end.compact
          end
        end
      end
    end
  end

  private
    def connection
      @connnection ||= Faraday.new("https://#{username}:#{access_key}@saucelabs.com/") do |faraday|
        faraday.adapter Faraday.default_adapter
        faraday.request :url_encoded
        faraday.response :logger if debug?
      end
    end

    def available_platforms
      @available_platforms ||= JSON.parse(connection.get("/rest/v1/info/platforms/webdriver").body).map(&:symbolize_keys)
    end
end
