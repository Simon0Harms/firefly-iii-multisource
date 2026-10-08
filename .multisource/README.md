# firefly-iii-multisource

> **Archived.** This fork is no longer maintained – see [gnubook](https://github.com/Simon0Harms/gnubook).

**Unofficial fork of [Firefly III](https://github.com/firefly-iii/firefly-iii) – not supported by the upstream project.**
Please reproduce problems on an unmodified instance before reporting them upstream.

This fork was created with AI (Claude by Anthropic) and reviewed by the repository owner.

## What is different?

The fork is a series of patches on top of each upstream release (`.multisource/patches/`, applied in order).

### 1. Splits with several source / destination accounts (`01-multisource-splits.patch`)
- Split **withdrawals** may have different **source accounts** (e.g. partly bank account, partly gift voucher).
- Split **deposits** may have different **destination accounts**.
- Transfers are unchanged (same source and destination for all splits).

Changed: validation on create/update, the silent account unification on updates and in
`correction:group-accounts`, and the split logic of the transaction forms.
Regression test: `MultiSourceSplitTest`.

### 2. Balance checkpoints (`02-balance-checkpoints.patch`)
Many German banks add their balance to the monthly closing posting, e.g.

```
ENTGELTABSCHLUSS **ENDSALDO**     1.328,49H STAND29.05.2026     1.328,49H
```

Every posting whose **description** contains such a line is a *checkpoint*. After every created,
changed or deleted transaction, Firefly compares the bank values with the booked balance of that
asset account:

| Bank value | Compared with |
|---|---|
| `STAND <date> <amount>` | balance at the end of `<date>`, without the closing posting itself |
| `ENDSALDO <amount>` | that balance plus the closing posting (e.g. after the account fee) |

`H` = credit (+), `S` = debit (−). Also recognised: `Kontostand am 30.09.2022 15,07 +` (DKB, older
statements) and manual entries such as `STAND 31.05.2026 1.234,56 H`.

The result is shown on the checkpoint posting itself:
- tag **`saldo-ok`**, **`saldo-abweichung`** (deviation) or **`saldo-akzeptiert`** (accepted),
- a short block at the end of the notes with bank value, Firefly value and difference (Firefly − bank).

The tag page `saldo-abweichung` therefore lists every month that needs a look.

**Accepting a known deviation** (e.g. a transfer between two banks that each booked on a different
day): add the tag `saldo-akzeptiert` to the checkpoint posting, or run
`php artisan multisource:check-balances --accept-open`. The difference is remembered; if it changes
later, the posting is flagged as `saldo-abweichung` again and the notes show the old accepted value.

**Report on the command line** (exit code 1 if deviations are open):

```
php artisan multisource:check-balances [--account=ID] [--show-all] [--dry-run] [--accept-open]
```

`firefly-update` runs this report after every update and installs a daily cron job as a safety net
(`/etc/cron.d/firefly-multisource-balance`).

**0.00 postings:** the bank sends most closing lines with amount 0.00. Upstream Firefly cannot store
a real 0.00 posting (source and destination are told apart by the sign of the amount; the upgrade
correction `correction:zero-amounts` deletes such postings). A 0.00 posting is therefore accepted
**only** when its description is a balance line, and it is stored with the smallest amount the
database can hold, **0.000000000001**. It is shown as 0.00 everywhere and does not change any
balance at two decimals. API clients see the tiny amount and should round to two decimals.

Settings (`.env`): `MULTISOURCE_BALANCE_CHECKS=false` switches the automatic check off;
`MULTISOURCE_BALANCE_TAG_OK`, `..._TAG_MISMATCH`, `..._TAG_ACCEPTED` rename the tags.

Bulk imports that use the API's `batch_submission` flag are checked once when the batch is finished.

Regression tests: `BalanceCheckpointTest`, `BalanceCheckpointParserTest`.
Only asset accounts are checked; the virtual balance is ignored (banks don't know it).

## How releases are built
`.github/workflows/multisource-release.yml` checks daily for new upstream releases, applies the
patches, runs the regression tests on MariaDB, builds the frontend and publishes
`FireflyIII-multisource-<tag>.zip`. If a patch, a guard check or a test fails, **no** release is published.

## ⚠️ Operating notes
- **Never** run the upstream / community-scripts `update`: it installs original Firefly III, and
  `firefly-iii:upgrade-database` **silently** rebooks all splits with multiple source accounts onto one account.
- In the LXC use `firefly-update` instead (`.multisource/firefly-update.sh`, set up with `--install-guard`).
- **Returning to upstream:** first split all transaction groups with multiple source/destination accounts
  into separate transactions. Balance checkpoints survive (they are normal postings of 0.00), only the
  automatic check, the tags' updates and the notes block stop.

## Updating a patch
Apply the patches in order on a clean checkout of the upstream tag, change the code, then regenerate
the patch you changed, e.g. for the last one:
`git diff <commit with patches 01..n-1 applied> -- app config resources tests > .multisource/patches/02-balance-checkpoints.patch`
