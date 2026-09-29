# firefly-iii-multisource

**Unofficial fork of [Firefly III](https://github.com/firefly-iii/firefly-iii) – not supported by the upstream project.**
Please reproduce problems on an unmodified instance before reporting them upstream.

This fork was created with AI (Claude by Anthropic).

## What is different?
- Split **withdrawals** may have different **source accounts** (e.g. partly bank account, partly gift voucher).
- Split **deposits** may have different **destination accounts**.
- Transfers are unchanged (same source and destination for all splits).

Changed (see `multisource.patch`): validation on create/update, the silent account
unification on updates and in `correction:group-accounts`, and the split logic of the
transaction forms. Plus the regression test `MultiSourceSplitTest`.

## How releases are built
`.github/workflows/multisource-release.yml` checks daily for new upstream releases,
applies the patch, runs the regression test, builds the frontend and publishes
`FireflyIII-multisource-<tag>.zip`. If the patch, the guard check or the test fails,
**no** release is published.

## ⚠️ Operating notes
- **Never** run the upstream / community-scripts `update`: it installs original Firefly III, and
  `firefly-iii:upgrade-database` **silently** rebooks all splits with multiple source accounts onto one account.
- In the LXC use `firefly-update` instead (`.multisource/firefly-update.sh`, set up with `--install-guard`).
- **Returning to upstream:** first split all transaction groups with multiple source/destination accounts into separate transactions.

## Updating the patch
After changing the code: `git diff <upstream-tag> -- app resources tests > .multisource/multisource.patch`
