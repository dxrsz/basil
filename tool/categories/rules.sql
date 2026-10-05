-- Keyword rules: the instant guess (and the fallback when the shared cache
-- doesn't know an item). Whole words only, plural-tolerant, specific phrases
-- first so "peanut butter" isn't dairy and "eggplant" isn't eggs.
-- Mirrored in lib/util/categories.dart; both are checked against
-- test/fixtures/category_cases.json.
create or replace function public.categorize_item_rules(p_name text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    -- specific phrases first
    when n ~ '\m(hot dog|hamburger|burger|slider) buns?\M' then 'Bakery'
    when n ~ '\mbutter lettuce\M' then 'Produce'
    when n ~ '\m(bread ?crumbs|croutons|noodles?|ramen|soups?)\M' then 'Pantry'
    when n ~ '\m(powder|paste|sauce|extract|seasoning|spice blend|marinade|dressing|bouillon cubes?)\M' then 'Pantry'
    when n ~ '\m(lemon|lime) juice\M' then 'Pantry'
    when n ~ '\m(juices?|vinegar)\M' then case when n ~ '\mvinegar\M' then 'Pantry' else 'Drinks' end
    when n ~ '\m(peanut|almond|cashew|sunflower|nut|apple|cookie) butter\M' then 'Pantry'
    when n ~ '\m(broth|stock|bouillon|stocks)\M' then 'Pantry'
    when n ~ '\m(corn ?starch|cornmeal|corn ?flour|black pepper|white pepper|peppercorns?|pepper flakes|tortilla chips?|potato chips?|coconut milk|canned)\M' then 'Pantry'
    when n ~ '\m(ice cream|gelato|sorbet|popsicles?|frozen)\M' then 'Frozen'
    when n ~ '\m(almond|oat|soy|rice|cashew) ?milks?\M' then 'Dairy & Eggs'
    when n ~ '\m(eggplants?|butternut|bell peppers?|jalape(n|ñ)os?|chil(i|e|li)s?|chil(i|e) peppers?|green onions?|scallions?|spring onions?|tofu|tempeh|sweet potato(es)?)\M' then 'Produce'
    -- aisles
    when n ~ '\m(chicken|beef|steaks?|pork|bacon|sausages?|turkey|lamb|ham|salami|prosciutto|pepperoni|chorizo|brisket|ribs?|mince|ground meat|hot dogs?|meatballs?|veal|duck)\M' then 'Meat'
    when n ~ '\m(salmon|tuna|shrimps?|prawns?|cod|tilapia|fish|crabs?|lobsters?|scallops?|mussels?|clams?|halibut|anchov(y|ies)|sardines?|trout|oysters?)\M' then 'Seafood'
    when n ~ '\m(milk|cheeses?|cheddar|mozzarella|parmesan|feta|ricotta|brie|yogh?urts?|butter|cream|creamer|eggs?|ghee|kefir|half and half|buttermilk)\M' then 'Dairy & Eggs'
    when n ~ '\m(bread|buns?|bagels?|tortillas?|pitas?|naan|baguettes?|croissants?|rolls?|muffins?|sourdough|brioche|flatbreads?|wraps?|ciabatta)\M' then 'Bakery'
    when n ~ '\m(apples?|bananas?|lemons?|limes?|oranges?|berry|berries|strawberr(y|ies)|blueberr(y|ies)|raspberr(y|ies)|grapes?|avocados?|tomato(es)?|onions?|garlic|potato(es)?|lettuce|spinach|kale|arugula|carrots?|cucumbers?|broccoli|cauliflower|cilantro|parsley|basil|mint|dill|thyme|rosemary|ginger|celery|mushrooms?|zucchinis?|squash|corn|cabbage|edamame|mangos?|mangoes|peach(es)?|pears?|plums?|pineapples?|melons?|watermelons?|cherr(y|ies)|kiwis?|herbs|leeks?|shallots?|radish(es)?|beets?|asparagus|peas|green beans|bok choy|fennel|artichokes?|grapefruits?|clementines?|tangerines?)\M' then 'Produce'
    when n ~ '\m(rice|pasta|spaghetti|penne|noodles?|ramen|udon|quinoa|couscous|oats|oatmeal|flour|sugar|beans?|lentils?|chickpeas?|sauces?|oils?|vinegar|salt|spices?|cumin|paprika|cinnamon|oregano|soy sauce|honey|syrup|cereal|granola|nuts?|almonds|walnuts|pecans|cashews|peanuts|seeds?|salsa|mayo|mayonnaise|mustard|ketchup|sriracha|tahini|crackers?|chips|pretzels|popcorn|jam|jelly|olives?|pickles?|capers|baking soda|baking powder|yeast|vanilla|chocolate|cocoa|candy|cookies|breadcrumbs|panko|stuffing|bouillon|curry|miso|gochujang|harissa|pesto|hummus)\M' then 'Pantry'
    when n ~ '\m(water|juices?|soda|pop|coffee|tea|wine|beer|kombucha|seltzer|lemonade|cider|vodka|gin|rum|whiskey|tequila|sparkling)\M' then 'Drinks'
    when n ~ '\m(paper towels?|toilet paper|tissues?|napkins?|soap|detergent|foil|plastic wrap|cling film|bags?|sponges?|trash|garbage|bleach|cleaner|wipes|shampoo|conditioner|toothpaste|deodorant|batteries|light bulbs?|diapers?|litter|pet food|cat food|dog food|parchment)\M' then 'Household'
    else 'Other'
  end
  from (select lower(coalesce(p_name, '')) as n) s;
$$;
