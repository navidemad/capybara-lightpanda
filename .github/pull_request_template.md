## Summary

<!-- What changed and why. Link any upstream Lightpanda issue/PR if relevant. -->

## Checklist

- [ ] `bundle exec rubocop` passes
- [ ] `bundle exec rake test:incremental` passes locally
- [ ] If driver behavior changed, `bundle exec rake spec:shared:parallel` passes locally (PR CI doesn't run the Capybara shared battery)
- [ ] If behavior against Lightpanda changed, `.claude/rules/lightpanda-io.md` (constraints / CDP tables) is updated
- [ ] If a workaround was added or removed, `CLAUDE.md` Architecture Rules reflect it
- [ ] If a peer-gem pattern was adopted or diverged from, `.claude/rules/ruby-cdp-peers.md` is updated

<!-- CI skips changes that only touch Markdown files or docs/ (paths-ignore in ci.yml). -->
