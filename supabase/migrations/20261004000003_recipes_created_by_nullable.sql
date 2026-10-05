-- recipes.created_by is ON DELETE SET NULL, but was also NOT NULL, so deleting
-- any user who had ever created a meal failed. Meals belong to the list, not
-- the person who typed them, so let the column go null.
alter table public.recipes alter column created_by drop not null;
