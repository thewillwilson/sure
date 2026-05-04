# Migrates legacy PlaidItem / PlaidAccount rows into the new
# Provider::Connection / Provider::Account framework. Idempotent — re-running
# on already-migrated families is a no-op (lookup by metadata.plaid_item_id).
#
# Usage:
#   bundle exec rake "provider:migrate_plaid_to_framework[dry_run]"
#   bundle exec rake "provider:migrate_plaid_to_framework[live]"
#   bundle exec rake "provider:migrate_plaid_to_framework[live,repoint_webhooks]"
#
# Modes:
#   dry_run             — print proposed inserts/updates, write nothing
#   live                — perform the migration
#   live,repoint_webhooks — also call Plaid#item_webhook_update for each
#                           migrated item to point at the new endpoint
#
# Migration mapping:
#   plaid_items.access_token       → provider_connections.credentials["access_token"]
#                                    (decrypted from deterministic, re-encrypted JSONB
#                                    non-deterministic; spike confirmed roundtrip)
#   plaid_items.plaid_id           → metadata["plaid_item_id"]
#   plaid_items.plaid_region       → metadata["region"]  + provider_key suffix
#   plaid_items.next_cursor        → metadata["next_cursor"]
#   plaid_items.institution_*      → metadata["institution_*"]
#   plaid_items.available_products → metadata["available_products"]
#   plaid_items.billed_products    → metadata["billed_products"]
#   plaid_items.status             → status (good/requires_update map directly)
#
#   plaid_accounts.plaid_id        → provider_accounts.external_id
#   plaid_accounts.plaid_type      → external_type
#   plaid_accounts.plaid_subtype   → external_subtype
#   raw_*_payload                  → 1:1 (re-encrypted on write)
#
# Account linkage:
#   PlaidAccount → Account is currently expressed via either AccountProvider
#   (polymorphic, provider_type="PlaidAccount") OR legacy accounts.plaid_account_id.
#   Migration walks both — preferring AccountProvider, falling back to direct FK —
#   and points provider_accounts.account_id at the resolved Account.
namespace :provider do
  desc "Migrate legacy PlaidItem/PlaidAccount rows into Provider::Connection/Provider::Account"
  task :migrate_plaid_to_framework, [ :mode, :flag ] => :environment do |_, args|
    mode = (args[:mode] || "dry_run").to_s
    repoint_webhooks = args[:flag].to_s == "repoint_webhooks"

    raise "Unknown mode: #{mode} (expected dry_run or live)" unless %w[dry_run live].include?(mode)

    dry = mode == "dry_run"
    puts "==> Plaid → framework migration (#{mode}#{', repointing webhooks' if repoint_webhooks})"

    stats = { items_seen: 0, items_migrated: 0, items_skipped: 0,
              accounts_seen: 0, accounts_migrated: 0, accounts_skipped: 0,
              webhook_repoints: 0, errors: 0 }

    PlaidItem.find_each do |item|
      stats[:items_seen] += 1
      begin
        existing = Provider::Connection.where("metadata->>'plaid_item_id' = ?", item.plaid_id).first
        if existing
          puts "  - PlaidItem #{item.id} already migrated → Provider::Connection #{existing.id} (skipping)"
          stats[:items_skipped] += 1
          next
        end

        ActiveRecord::Base.transaction do
          conn = build_connection_from(item)
          if dry
            puts "  + WOULD CREATE Provider::Connection (family=#{item.family_id} provider_key=plaid_#{item.plaid_region})"
          else
            conn.save!
            puts "  + CREATED Provider::Connection #{conn.id} (family=#{item.family_id} provider_key=plaid_#{item.plaid_region})"
            stats[:items_migrated] += 1
          end

          item.plaid_accounts.each do |pa|
            stats[:accounts_seen] += 1
            account = resolve_account(pa)
            pa_record = build_provider_account_from(pa, conn, account: account)
            if dry
              puts "    + WOULD CREATE Provider::Account (external_id=#{pa.plaid_id} account_id=#{account&.id || 'unlinked'})"
            else
              pa_record.save!
              stats[:accounts_migrated] += 1
            end
          end

          if repoint_webhooks && !dry
            repoint_webhook_for(item)
            stats[:webhook_repoints] += 1
          end
        end
      rescue => e
        stats[:errors] += 1
        puts "  ! ERROR migrating PlaidItem #{item.id}: #{e.class}: #{e.message}"
      end
    end

    puts "==> Done. #{stats.inspect}"
  end

  def build_connection_from(item)
    Provider::Connection.new(
      family:        item.family,
      provider_key:  "plaid_#{item.plaid_region}",
      auth_type:     "embedded_link",
      credentials:   { "access_token" => item.access_token },
      status:        item.status, # good / requires_update map directly
      metadata: {
        "plaid_item_id"           => item.plaid_id,
        "region"                  => item.plaid_region,
        "next_cursor"             => item.next_cursor,
        "institution_id"          => item.institution_id,
        "institution_url"         => item.institution_url,
        "institution_color"       => item.institution_color,
        "institution_name"        => item.name,
        "available_products"      => item.available_products,
        "billed_products"         => item.billed_products,
        "raw_item_payload"        => item.raw_payload,
        "raw_institution_payload" => item.raw_institution_payload
      },
      sync_start_date: item.created_at.to_date,
      last_synced_at:  item.respond_to?(:last_synced_at) ? item.last_synced_at : nil
    )
  end

  def build_provider_account_from(plaid_account, connection, account:)
    Provider::Account.new(
      provider_connection:      connection,
      account:                  account,
      external_id:              plaid_account.plaid_id,
      external_name:            plaid_account.name,
      external_type:            plaid_account.plaid_type,
      external_subtype:         plaid_account.plaid_subtype,
      currency:                 plaid_account.currency,
      raw_payload:              plaid_account.raw_payload,
      raw_transactions_payload: plaid_account.raw_transactions_payload,
      raw_holdings_payload:     plaid_account.raw_holdings_payload,
      raw_liabilities_payload:  plaid_account.raw_liabilities_payload,
      last_synced_at:           plaid_account.respond_to?(:last_synced_at) ? plaid_account.last_synced_at : nil
    )
  end

  # Plaid accounts can link to Sure accounts via two legacy paths.
  # Prefer the polymorphic AccountProvider; fall back to the direct FK.
  def resolve_account(plaid_account)
    via_account_provider = AccountProvider.find_by(provider: plaid_account)&.account
    return via_account_provider if via_account_provider

    Account.find_by(plaid_account_id: plaid_account.id)
  end

  def repoint_webhook_for(plaid_item)
    region = plaid_item.plaid_region.to_sym
    new_url = Rails.application.routes.url_helpers.webhooks_provider_url(provider_key: "plaid_#{region}")
    Provider::Registry.plaid_provider_for_region(region).client.item_webhook_update(
      Plaid::ItemWebhookUpdateRequest.new(
        access_token: plaid_item.access_token,
        webhook:      new_url
      )
    )
    puts "    ↻ Repointed webhook for PlaidItem #{plaid_item.id} to #{new_url}"
  rescue => e
    puts "    ! Failed to repoint webhook for PlaidItem #{plaid_item.id}: #{e.message}"
  end
end
