-- Drop existing foreign key constraints
alter table cars drop constraint if exists cars_brand_id_fkey;
alter table cars drop constraint if exists cars_make_fkey;
alter table private_listings drop constraint if exists private_listings_brand_id_fkey;
alter table private_listings drop constraint if exists private_listings_make_fkey;

-- Add brand_id and make columns with proper constraints
alter table cars 
  add column if not exists brand_id uuid not null references brands(id) on delete restrict,
  add column if not exists make text generated always as (
    (select name from brands where id = brand_id)
  ) stored;

alter table private_listings 
  add column if not exists brand_id uuid not null references brands(id) on delete restrict,
  add column if not exists make text generated always as (
    (select name from brands where id = brand_id)
  ) stored;

-- Create indexes for better performance
create index if not exists idx_cars_brand_id on cars(brand_id);
create index if not exists idx_cars_make on cars(make);
create index if not exists idx_private_listings_brand_id on private_listings(brand_id);
create index if not exists idx_private_listings_make on private_listings(make);

-- Create function to get brand details
create or replace function get_brand_details(p_brand_id uuid)
returns jsonb as $$
  select jsonb_build_object(
    'id', id,
    'name', name,
    'logo_url', logo_url
  )
  from brands
  where id = p_brand_id;
$$ language sql stable;

-- Update process_private_listing function
create or replace function process_private_listing(
  p_listing_id uuid,
  p_status text
) returns jsonb as $$
declare
  v_listing private_listings;
  v_car_id uuid;
  v_result jsonb;
begin
  -- Validate status
  if p_status not in ('approved', 'rejected') then
    raise exception 'Invalid status. Must be either approved or rejected.';
  end if;

  -- Get and lock the listing
  select * into v_listing
  from private_listings
  where id = p_listing_id
  for update;

  if not found then
    raise exception 'Listing not found';
  end if;

  if v_listing.status != 'pending' then
    raise exception 'Listing has already been processed';
  end if;

  -- Update listing status
  update private_listings
  set 
    status = p_status,
    updated_at = now()
  where id = p_listing_id;

  -- If approved, create car listing
  if p_status = 'approved' then
    insert into cars (
      brand_id, model, year, price, image,
      video_url, condition, mileage, fuel_type,
      transmission, body_type, exterior_color,
      interior_color, number_of_owners, savings,
      is_sold
    )
    values (
      v_listing.brand_id, v_listing.model,
      v_listing.year, v_listing.price, v_listing.image,
      v_listing.video_url, v_listing.condition, v_listing.mileage,
      v_listing.fuel_type, v_listing.transmission, v_listing.body_type,
      v_listing.exterior_color, v_listing.interior_color,
      v_listing.number_of_owners, floor(v_listing.price * 0.1),
      false
    )
    returning id into v_car_id;

    -- Copy features to car
    insert into car_features (car_id, feature_id)
    select v_car_id, feature_id
    from private_listing_features
    where listing_id = p_listing_id;
  end if;

  -- Prepare result
  v_result := jsonb_build_object(
    'success', true,
    'listing_id', p_listing_id,
    'car_id', v_car_id,
    'status', p_status
  );

  return v_result;
exception
  when others then
    raise exception '%', sqlerrm;
end;
$$ language plpgsql security definer;

-- Grant execute permissions
grant execute on function get_brand_details(uuid) to authenticated;
grant execute on function process_private_listing(uuid, text) to authenticated;

-- Refresh schema cache
notify pgrst, 'reload schema';