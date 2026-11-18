# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Network
      # Retain the hash keys used by existing traffic assertions and JSON logs.
      class Exchange < Hash
        Request = Data.define(:url, :method) # rubocop:disable Lint/DataDefineOverride

        def initialize(params)
          super()
          merge!(request_id: params["requestId"], timestamp: params["timestamp"],
                 url: params.dig("request", "url"), method: params.dig("request", "method"), response: nil, error: nil)
          @finished = false
        end

        def request = Request.new(self[:url], self[:method])
        def url = self[:url]
        def response = self[:response]
        def error = self[:error]
        def finished? = @finished
        def pending? = !finished?

        def finish!
          @finished = true
        end
      end

      class Response < Hash
        def initialize(raw)
          super()
          raw ||= {}
          merge!(status: raw["status"], headers: raw["headers"] || {}, mime_type: raw["mimeType"])
        end

        def status = self[:status]
        def headers = self[:headers]
      end
    end
  end
end
