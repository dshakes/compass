# cost-caps — spend caps as code

A cap in a web console rots; a cap in a PR is reviewed and drift-checked. Three layers:

| Layer | What | Where it lives |
|---|---|---|
| Hard caps | Stop spend | `COMPASS_MAX_USD_DAY` / `budget-gate` hook (agent sessions); provider-side limits below |
| Early warnings | Alert before the cap | `google_billing_budget` here (50/90/100%); the `cost-sentinel` skill (per-key spend, cache ratio, unknown keys) |
| Demand reduction | Spend less per task | prompt caching, `compass route` model tiering, distil |

## GCP budget

```bash
terraform init
terraform plan -var billing_account=<BILLING_ACCOUNT_ID> -var amount=<MONTHLY_AMOUNT>
```

A budget alerts (to billing admins by default); it does not stop spend. Thresholds are the
`thresholds` variable. No ids or amounts are committed.

## Anthropic and OpenAI

There is no terraform provider for either. Set their limits through the Admin API or the
provider console, and let `cost-sentinel` (`claude/skills/cost-sentinel/`) watch the result.
