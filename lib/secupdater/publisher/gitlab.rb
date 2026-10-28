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

      # Added to every MR secupdater opens. Closing one declines that version of
      # that dependency; reopening it or removing the label undoes that.
      LABEL = "secupdater"

      def run
        Net::HTTP.start("gitlab.com", 443, use_ssl: true) do |http|
          merge_requests = find_merge_requests(http)
          open_merge_request = merge_requests.find { it["state"] == "opened" }

          if !open_merge_request && (previous = merge_requests.find { it["labels"].include?(LABEL) })
            return [:declined, "#{reference} was #{previous["state"]} in !#{previous["iid"]}, reopen it or remove its #{LABEL} label to have it updated again"]
          end

          if branch_exists?(http)
            others = other_authors(http)
            return [:skipped, "#{reference} has commits from #{others.join(", ")}, so it won't be updated"] if others.any?

            up_to_date = branch_has_changes?(http)
            commit(http, force: true) unless up_to_date
          else
            commit(http)
          end

          return [:up_to_date, nil] if open_merge_request && up_to_date

          create_merge_request(http) unless open_merge_request
          [:published, nil]
        end
      end

      private

      def commit(http, force: false)
        data = {
          branch: reference,
          start_sha: start_sha,
          commit_message: title,
          actions: changes.map { { action: it.type, file_path: it.filename, content: it.content }.compact }
        }
        data[:force] = true if force

        request(http, Net::HTTP::Post, "repository/commits", data)
      end

      def create_merge_request(http)
        data = {
          source_branch: reference,
          target_branch: target_branch,
          title: title,
          description: description,
          remove_source_branch: true,
          labels: [LABEL]
        }

        request(http, Net::HTTP::Post, "merge_requests", data)
      end

      def branch_exists?(http)
        !request(http, Net::HTTP::Get, "repository/branches/#{URI.encode_www_form_component(reference)}", allow_missing: true).nil?
      end

      def find_merge_requests(http)
        query = URI.encode_www_form(source_branch: reference, target_branch: target_branch)
        JSON.parse(request(http, Net::HTTP::Get, "merge_requests?#{query}").body)
      end

      # Authors of commits on the branch, other than whoever owns the access token
      def other_authors(http)
        query = URI.encode_www_form(from: target_branch, to: reference)
        commits = JSON.parse(request(http, Net::HTTP::Get, "repository/compare?#{query}").body)["commits"]

        commits.reject { own_emails(http).include?(it["author_email"]) }.map { it["author_name"] }.uniq
      end

      def own_emails(http)
        @own_emails ||= begin
          user = JSON.parse(api_request(http, Net::HTTP::Get, "user").body)
          user.values_at("email", "commit_email", "public_email").reject { it.nil? || it.empty? }
        end
      end

      def branch_has_changes?(http)
        changes.all? do |change|
          query = URI.encode_www_form(ref: reference)
          res = request(http, Net::HTTP::Get, "repository/files/#{URI.encode_www_form_component(change.filename)}/raw?#{query}", allow_missing: true)
          res&.body == change.content
        end
      end

      def request(http, type, path, data = nil, allow_missing: false)
        api_request(http, type, "projects/#{URI.encode_www_form_component(project_id)}/#{path}", data, allow_missing:)
      end

      def api_request(http, type, path, data = nil, allow_missing: false)
        req = type.new(
          "/api/v4/#{path}",
          "PRIVATE-TOKEN" => access_token,
          "Content-Type" => "application/json"
        )
        req.body = data.to_json if data

        res = http.request(req)

        return if allow_missing && res.is_a?(Net::HTTPNotFound)

        unless res.is_a?(Net::HTTPSuccess)
          raise Secupdater::PublishFailed, "GitLab #{req.method} #{req.path} returned #{res.code}: #{res.body}"
        end

        res
      end
    end
  end
end
