# Direct port of PlaidAccount::Transactions::CategoryMatcher.
class Provider::Plaid::Transactions::CategoryMatcher
  include Provider::Plaid::Transactions::CategoryTaxonomy

  def initialize(user_categories = [])
    @user_categories = user_categories
  end

  def match(plaid_detailed_category)
    plaid_category_details = get_plaid_category_details(plaid_detailed_category)
    return nil unless plaid_category_details

    exact_match = normalized_user_categories.find { |c| c[:name] == plaid_category_details[:key].to_s }
    return user_categories.find { |c| c.id == exact_match[:id] } if exact_match

    alias_match = normalized_user_categories.find do |category|
      name = category[:name]
      plaid_category_details[:aliases].any? { |a| matches_alias?(name, a.to_s) }
    end
    return user_categories.find { |c| c.id == alias_match[:id] } if alias_match

    parent_match = normalized_user_categories.find do |category|
      name = category[:name]
      plaid_category_details[:parent_aliases].any? { |a| matches_alias?(name, a.to_s) }
    end
    return user_categories.find { |c| c.id == parent_match[:id] } if parent_match

    nil
  end

  private
    attr_reader :user_categories

    def matches_alias?(name, alias_str)
      return true if name == alias_str
      return true if name.singularize == alias_str || name.pluralize == alias_str
      return true if alias_str.singularize == name || alias_str.pluralize == name
      normalized_name  = name.gsub(/(and|&|\s+)/, "").strip
      normalized_alias = alias_str.gsub(/(and|&|\s+)/, "").strip
      normalized_name == normalized_alias
    end

    def get_plaid_category_details(plaid_category_name)
      detailed_plaid_categories.find { |c| c[:key] == plaid_category_name.downcase.to_sym }
    end

    def detailed_plaid_categories
      CATEGORIES_MAP.flat_map do |parent_key, parent_data|
        parent_data[:detailed_categories].map do |child_key, child_data|
          { key: child_key, classification: child_data[:classification],
            aliases: child_data[:aliases], parent_key: parent_key,
            parent_aliases: parent_data[:aliases] }
        end
      end
    end

    def normalized_user_categories
      user_categories.map do |c|
        { id: c.id, name: normalize_user_category_name(c.name) }
      end
    end

    def normalize_user_category_name(name)
      name.to_s.downcase.gsub(/[^a-z0-9]/, " ").strip
    end
end
