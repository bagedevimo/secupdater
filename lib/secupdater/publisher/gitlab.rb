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
        @current_merge_requests = {}
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
            if others.any?
              explain_skipping(http, open_merge_request, others) if open_merge_request
              return [:skipped, "#{reference} has commits from #{others.join(", ")}, so it won't be updated"]
            end

            up_to_date = branch_has_changes?(http) && !target_manifests_moved_on?(http)
            commit(http, force: true) unless up_to_date
          else
            commit(http)
          end

          if open_merge_request
            remember(open_merge_request)

            # e.g. when this update has since absorbed another dependency's advisories
            described = open_merge_request["description"] == description
            request(http, Net::HTTP::Put, "merge_requests/#{open_merge_request["iid"]}", { description: description }) unless described

            return [:up_to_date, nil] if up_to_date && described
          else
            remember(JSON.parse(create_merge_request(http).body))
          end

          [:published, nil]
        end
      end

      # Closes open secupdater MRs for a dependency that this run opened or kept a
      # different MR for, or that no longer has any advisories. MRs for
      # dependencies this run couldn't update are left alone.
      def finish(vulnerable_names)
        Net::HTTP.start("gitlab.com", 443, use_ssl: true) do |http|
          find_open_secupdater_merge_requests(http).filter_map do |merge_request|
            name = merge_request["source_branch"][REFERENCE_PATTERN, :name]
            current = @current_merge_requests[name]

            reason = if current && current != merge_request["iid"]
              "Superseded by !#{current}."
            elsif name && !vulnerable_names.include?(name)
              "#{name} no longer has any security advisories on #{target_branch}, so this is no longer needed."
            end
            next unless reason

            close_merge_request(http, merge_request["iid"], reason)
            "closed !#{merge_request["iid"]} (#{merge_request["source_branch"]}): #{reason}"
          end
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

      # Against every dependency the MR fixes advisories for, so finish closes
      # their own MRs once another update has absorbed them
      def remember(merge_request)
        [bump.dependency.name, *advisories.map(&:name)].uniq.each do
          @current_merge_requests[it] = merge_request["iid"]
        end
      end

      def find_open_secupdater_merge_requests(http)
        query = URI.encode_www_form(state: "opened", labels: LABEL, target_branch: target_branch, per_page: 100)
        JSON.parse(request(http, Net::HTTP::Get, "merge_requests?#{query}").body)
      end

      # Hidden in the rendered comment; marks the comment so it's only posted once
      SKIPPING_MARKER = "<!-- secupdater:skipping -->"

      # Says on the MR, once, that secupdater has stopped updating it, so whoever
      # committed knows rebasing and refreshing it is now up to them
      def explain_skipping(http, merge_request, others)
        notes_path = "merge_requests/#{merge_request["iid"]}/notes"
        notes = JSON.parse(request(http, Net::HTTP::Get, "#{notes_path}?#{URI.encode_www_form(per_page: 100)}").body)
        return if notes.any? { it.dig("author", "id") == own_user(http)["id"] && it["body"].to_s.include?(SKIPPING_MARKER) }

        body = <<~BODY.chomp
          #{SKIPPING_MARKER}
          This branch has commits from #{others.join(", ")}, so secupdater won't update it any more, \
          including rebasing it when `#{target_branch}` changes.

          To hand it back, delete the branch, or force-push it without those commits, and secupdater will take it over on its next run.
        BODY
        request(http, Net::HTTP::Post, notes_path, { body: })
      end

      def close_merge_request(http, iid, reason)
        request(http, Net::HTTP::Post, "merge_requests/#{iid}/notes", { body: reason })
        request(http, Net::HTTP::Put, "merge_requests/#{iid}", { state_event: "close" })
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
        own_user(http).values_at("email", "commit_email", "public_email").reject { it.nil? || it.empty? }
      end

      # Whoever owns the access token
      def own_user(http)
        @own_user ||= JSON.parse(api_request(http, Net::HTTP::Get, "user").body)
      end

      def branch_has_changes?(http)
        changes.all? do |change|
          query = URI.encode_www_form(ref: reference)
          res = request(http, Net::HTTP::Get, "repository/files/#{URI.encode_www_form_component(change.filename)}/raw?#{query}", allow_missing: true)
          res&.body == change.content
        end
      end

      # Whether a manifest has changed on the target branch since the branch was
      # cut from it. The update can come out the same even then (e.g. when another
      # MR made some of the same bumps), but the branch would show changes the
      # target already has, and may conflict.
      def target_manifests_moved_on?(http)
        query = URI.encode_www_form(from: reference, to: start_sha)
        diffs = JSON.parse(request(http, Net::HTTP::Get, "repository/compare?#{query}").body)["diffs"]

        diffs.any? { ecosystem.manifest_paths.intersect?(it.values_at("old_path", "new_path")) }
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
