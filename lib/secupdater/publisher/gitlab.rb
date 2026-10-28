require "net/http"
require "json"

module Secupdater
  class Publisher
    class Gitlab < Secupdater::Publisher
      attr_reader :access_token, :project_id, :target_branch, :start_sha

      def initialize(access_token, project_id, target_branch, start_sha)
        @access_token = access_token
        @project_id = project_id
        @target_branch = target_branch
        @start_sha = start_sha
      end

      def run
        Net::HTTP.start("gitlab.com", 443, use_ssl: true) do |http|
          return if merge_request_exists?(http)

          data = {
            branch: reference,
            start_sha: start_sha,
            commit_message: title,
            actions: changes.map { { action: it.type, file_path: it.filename, content: it.content }.compact }
          }

          request(http, Net::HTTP::Post, "repository/commits", data)

          data = {
            source_branch: reference,
            target_branch: target_branch,
            title: title,
            description: description,
            remove_source_branch: true,
            labels: []
          }

          request(http, Net::HTTP::Post, "merge_requests", data)
        end
      end

      private

      def merge_request_exists?(http)
        query = URI.encode_www_form(source_branch: reference, state: "opened")
        res = request(http, Net::HTTP::Get, "merge_requests?#{query}")
        JSON.parse(res.body).any?
      end

      def request(http, type, path, data = nil)
        req = type.new(
          "/api/v4/projects/#{URI.encode_www_form_component(project_id)}/#{path}",
          "PRIVATE-TOKEN" => access_token,
          "Content-Type" => "application/json"
        )
        req.body = data.to_json if data

        res = http.request(req)

        unless res.is_a?(Net::HTTPSuccess)
          raise Secupdater::PublishFailed, "GitLab #{req.method} #{req.path} returned #{res.code}: #{res.body}"
        end

        res
      end
    end
  end
end
