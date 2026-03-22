# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Keyboard # rubocop:disable Metrics/ClassLength
      # Capybara symbol -> CDP key definition.
      KEYS = {
        cancel: { key: "Cancel", code: "Abort", keyCode: 3 },
        help: { key: "Help", code: "Help", keyCode: 6 },
        backspace: { key: "Backspace", code: "Backspace", keyCode: 8 },
        tab: { key: "Tab", code: "Tab", keyCode: 9 },
        clear: { key: "Clear", code: "NumLock", keyCode: 12 },
        return: { key: "Enter", code: "Enter", keyCode: 13, text: "\r" },
        enter: { key: "Enter", code: "Enter", keyCode: 13, text: "\r" },
        shift: { key: "Shift", code: "ShiftLeft", keyCode: 16 },
        control: { key: "Control", code: "ControlLeft", keyCode: 17 },
        alt: { key: "Alt", code: "AltLeft", keyCode: 18 },
        pause: { key: "Pause", code: "Pause", keyCode: 19 },
        escape: { key: "Escape", code: "Escape", keyCode: 27 },
        space: { key: " ", code: "Space", keyCode: 32, text: " " },
        page_up: { key: "PageUp", code: "PageUp", keyCode: 33 },
        page_down: { key: "PageDown", code: "PageDown", keyCode: 34 },
        end: { key: "End", code: "End", keyCode: 35 },
        home: { key: "Home", code: "Home", keyCode: 36 },
        left: { key: "ArrowLeft", code: "ArrowLeft", keyCode: 37 },
        up: { key: "ArrowUp", code: "ArrowUp", keyCode: 38 },
        right: { key: "ArrowRight", code: "ArrowRight", keyCode: 39 },
        down: { key: "ArrowDown", code: "ArrowDown", keyCode: 40 },
        insert: { key: "Insert", code: "Insert", keyCode: 45 },
        delete: { key: "Delete", code: "Delete", keyCode: 46 },
        semicolon: { key: ";", code: "Semicolon", keyCode: 186, text: ";" },
        equals: { key: "=", code: "Equal", keyCode: 187, text: "=" },
        numpad0: { key: "0", code: "Numpad0", keyCode: 96, text: "0" },
        numpad1: { key: "1", code: "Numpad1", keyCode: 97, text: "1" },
        numpad2: { key: "2", code: "Numpad2", keyCode: 98, text: "2" },
        numpad3: { key: "3", code: "Numpad3", keyCode: 99, text: "3" },
        numpad4: { key: "4", code: "Numpad4", keyCode: 100, text: "4" },
        numpad5: { key: "5", code: "Numpad5", keyCode: 101, text: "5" },
        numpad6: { key: "6", code: "Numpad6", keyCode: 102, text: "6" },
        numpad7: { key: "7", code: "Numpad7", keyCode: 103, text: "7" },
        numpad8: { key: "8", code: "Numpad8", keyCode: 104, text: "8" },
        numpad9: { key: "9", code: "Numpad9", keyCode: 105, text: "9" },
        multiply: { key: "*", code: "NumpadMultiply", keyCode: 106, text: "*" },
        add: { key: "+", code: "NumpadAdd", keyCode: 107, text: "+" },
        separator: { key: ".", code: "NumpadDecimal", keyCode: 110, text: "." },
        subtract: { key: "-", code: "NumpadSubtract", keyCode: 109, text: "-" },
        decimal: { key: ".", code: "NumpadDecimal", keyCode: 110, text: "." },
        divide: { key: "/", code: "NumpadDivide", keyCode: 111, text: "/" },
        f1: { key: "F1", code: "F1", keyCode: 112 },
        f2: { key: "F2", code: "F2", keyCode: 113 },
        f3: { key: "F3", code: "F3", keyCode: 114 },
        f4: { key: "F4", code: "F4", keyCode: 115 },
        f5: { key: "F5", code: "F5", keyCode: 116 },
        f6: { key: "F6", code: "F6", keyCode: 117 },
        f7: { key: "F7", code: "F7", keyCode: 118 },
        f8: { key: "F8", code: "F8", keyCode: 119 },
        f9: { key: "F9", code: "F9", keyCode: 120 },
        f10: { key: "F10", code: "F10", keyCode: 121 },
        f11: { key: "F11", code: "F11", keyCode: 122 },
        f12: { key: "F12", code: "F12", keyCode: 123 },
        meta: { key: "Meta", code: "MetaLeft", keyCode: 91 },
        command: { key: "Meta", code: "MetaLeft", keyCode: 91 },
      }.freeze

      MODIFIERS = {
        alt: 1,
        control: 2, ctrl: 2,
        meta: 4, command: 4,
        shift: 8,
      }.freeze

      def initialize(browser)
        @browser = browser
      end

      def type(*keys)
        keys.each do |key|
          case key
          when Symbol then dispatch_key(key)
          when String then key.each_char { |char| dispatch_char(char) }
          when Array  then type_with_modifiers(key)
          end
        end
      end

      private

      def dispatch_key(key)
        definition = KEYS.fetch(key) { raise ArgumentError, "Unknown key: #{key.inspect}" }
        raw_dispatch(definition)
      end

      def dispatch_char(char)
        @browser.page_command("Input.insertText", text: char)
      end

      def type_with_modifiers(keys)
        modifiers, chars = keys.partition { |k| k.is_a?(Symbol) && MODIFIERS.key?(k) }
        modifier_value = modifiers.sum { |m| MODIFIERS[m] }

        modifiers.each { |m| send_key_event("rawKeyDown", KEYS[m]) }
        chars.each { |key| dispatch_modified(key, modifier_value, modifiers) }
        modifiers.reverse_each { |m| send_key_event("keyUp", KEYS[m]) }
      end

      def dispatch_modified(key, modifier_value, modifiers)
        case key
        when Symbol
          definition = KEYS.fetch(key) { raise ArgumentError, "Unknown key: #{key.inspect}" }
          raw_dispatch(definition, modifiers: modifier_value)
        when String
          key.each_char { |char| dispatch_modified_char(char, modifier_value, modifiers) }
        end
      end

      def dispatch_modified_char(char, modifier_value, modifiers)
        text = modifiers.include?(:shift) ? char.upcase : char
        send_key_event("keyDown", { key: text, text: text, unmodifiedText: char }, modifiers: modifier_value)
        send_key_event("keyUp", { key: text }, modifiers: modifier_value)
      end

      def raw_dispatch(definition, modifiers: 0)
        type = definition[:text] ? "keyDown" : "rawKeyDown"
        send_key_event(type, definition, modifiers: modifiers)
        send_key_event("keyUp", definition, modifiers: modifiers)
      end

      def send_key_event(type, definition, modifiers: 0)
        params = {
          type: type,
          key: definition[:key],
          code: definition[:code],
        }
        params[:windowsVirtualKeyCode] = definition[:keyCode] if definition[:keyCode]
        params[:text] = definition[:text] if definition[:text]
        params[:unmodifiedText] = definition[:unmodifiedText] || definition[:text] if definition[:text]
        params[:modifiers] = modifiers if modifiers.positive?
        @browser.page_command("Input.dispatchKeyEvent", **params)
      end
    end
  end
end
