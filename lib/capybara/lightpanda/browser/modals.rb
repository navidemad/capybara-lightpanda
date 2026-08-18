# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Browser
      # JS dialog handling via Lightpanda's LP.handleJavaScriptDialog
      # pre-arm model (PR #2261): accept/dismiss are sent BEFORE the
      # triggering action; Page.javascriptDialogOpening supplies the text.
      module Modals
        # -- Modal/Dialog Support --
        # Lightpanda's JS dialogs (alert/confirm/prompt) are driven via the
        # `LP.handleJavaScriptDialog` pre-arm model (PR #2261, nightly ≥5900):
        # the client sends `LP.handleJavaScriptDialog {accept, promptText}`
        # BEFORE the action that triggers the dialog, and the response is
        # consumed when the dialog opens. `Page.javascriptDialogOpening` still
        # fires, so we capture the message text for `find_modal`. Single-shot:
        # `pending_dialog_response` is one slot, so a second pre-arm before
        # the first dialog opens overwrites the first.

        def prepare_modals
          return if @modal_handler_installed

          enable_page_events

          on("Page.javascriptDialogOpening") do |params|
            entry = { type: params["type"], message: params["message"] }
            @modal_messages_mutex.synchronize do
              @modal_messages << entry
              # The pre-arm slot is single-shot on both sides: Lightpanda
              # consumes its stashed response on this dialog, so we consume
              # ours. No pre-arm in flight means Lightpanda just applied its
              # silent default — remember it for the main thread; raising here
              # would only die inside the subscriber.
              if @modal_armed
                @modal_armed = false
              else
                @unhandled_modal ||= entry
              end
            end
          end

          @modal_handler_installed = true
        end

        def accept_modal(_type, text: nil)
          prepare_modals
          params = { accept: true }
          params[:promptText] = text if text
          arm_modal { page_command("LP.handleJavaScriptDialog", **params) }
        end

        def dismiss_modal(_type)
          prepare_modals
          arm_modal { page_command("LP.handleJavaScriptDialog", accept: false) }
        end

        # Surface a dialog that opened with no pre-arm. Called from the main
        # thread after every action that can open one (Browser#wait_for_idle,
        # #go_to). Warns by default; raises when the driver was built with
        # `raise_on_unhandled_modal: true` (Cuprite's option name). Either way
        # the dialog is already gone — Lightpanda's default resolved it.
        def check_unhandled_modal!
          entry = @modal_messages_mutex.synchronize do
            e = @unhandled_modal
            @unhandled_modal = nil
            e
          end
          return unless entry

          message = unhandled_modal_message(entry)
          raise UnhandledModalError, message if @options.raise_on_unhandled_modal

          warn "[capybara-lightpanda] #{message}"
        end

        # `type` is accepted for the error message only: like Selenium (where
        # alert/confirm are indistinguishable) and Cuprite (whose dialog handler
        # accepts whatever fires), we deliberately do NOT reject a dialog whose
        # reported type differs from the one Capybara asked for. Real suites
        # wrap `data-confirm` deletes in `accept_alert` (e.g. solidus admin) and
        # expect it to work; only the message text is matched.
        def find_modal(type, text: nil, wait: options.timeout)
          regexp = text.is_a?(Regexp) ? text : (text && Regexp.new(Regexp.escape(text.to_s)))
          last_seen_message = nil
          claimed = nil
          Utils::Wait.until(timeout: wait, interval: 0.05) do
            claimed = pop_modal_message(regexp)
            next true if claimed

            last_seen_message = peek_last_modal_message || last_seen_message
            false
          end
          claimed[:message]
        rescue TimeoutError
          raise_modal_not_found(type, text, last_seen_message)
        end

        private

        def arm_modal
          @modal_messages_mutex.synchronize { @modal_armed = true }
          yield
        end

        LIGHTPANDA_DIALOG_DEFAULTS = {
          "confirm" => "cancelled it",
          "prompt" => "answered null",
          "beforeunload" => "cancelled it",
        }.freeze
        private_constant :LIGHTPANDA_DIALOG_DEFAULTS

        def unhandled_modal_message(entry)
          with_text = entry[:message] ? " with text `#{entry[:message]}`" : ""
          default = LIGHTPANDA_DIALOG_DEFAULTS.fetch(entry[:type].to_s, "dismissed it")
          "A #{entry[:type]} dialog#{with_text} opened, but the action was not wrapped in " \
            "accept_alert / accept_confirm / dismiss_confirm / accept_prompt / dismiss_prompt " \
            "— Lightpanda #{default} by default"
        end

        # Pop the first queued dialog whose message matches the requested
        # pattern (any dialog when `regexp` is nil). Returns the entry or nil.
        # Serialized with the message-thread writer.
        def pop_modal_message(regexp)
          @modal_messages_mutex.synchronize do
            match = @modal_messages.find do |m|
              regexp.nil? || m[:message].to_s.match?(regexp)
            end
            @modal_messages.delete(match) if match
            match
          end
        end

        # Most recent dialog message of any type, for diagnostics.
        def peek_last_modal_message
          @modal_messages_mutex.synchronize { @modal_messages.last&.dig(:message) }
        end

        def raise_modal_not_found(type, text, last_seen_message)
          if last_seen_message
            raise Capybara::ModalNotFound,
                  "Unable to find #{type} modal with #{text} - found '#{last_seen_message}' instead."
          end
          raise Capybara::ModalNotFound, "Unable to find modal dialog#{" with #{text}" if text}"
        end

        private :prepare_modals
      end
    end
  end
end
