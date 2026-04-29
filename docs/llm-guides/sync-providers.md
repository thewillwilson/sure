# Sync Provider Conventions

This document defines the conventions all sync providers must follow when normalising data before writing to Sure's account model.

## Credit Card Balances

**Show debt owed, not available credit.**

The balance passed to `account.set_current_balance(...)` for credit card accounts must be the amount the user currently owes — a positive number representing their debt. Providers that return a negative current balance (debt convention) should call `.abs` before passing to `set_current_balance`.

```ruby
# Correct
result = account.set_current_balance(current.to_d.abs)

# Wrong — shows available credit instead of debt
result = account.set_current_balance(available.to_d)
```

Available credit from the provider (remaining spend capacity) should be stored separately on `credit_card.available_credit` when the API provides it, but must not be used as the account balance.

**Applies to:** TrueLayer, Plaid, Mercury, SimpleFIN, and any future provider.

> **Note:** `EnableBankingAccount::Processor` currently deviates from this convention by showing available credit as the balance. This should be corrected to align with the standard above.

## Loans

Show the outstanding balance as a positive number (debt owed).

## Debit / Savings Accounts

Pass `current` directly — positive means money in the account.
