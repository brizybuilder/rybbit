DO $$
DECLARE
	duplicates bigint;
BEGIN
	IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sites_id_unique') THEN
		RETURN;
	END IF;

	-- The public id was six random bytes with nothing enforcing uniqueness, so an
	-- instance can already hold a collision. Adding the constraint would fail with
	-- a raw index error, and because docker-entrypoint.sh runs the
	-- migrations under `set -e` before the server starts, that turns a rare data
	-- problem into a container that will not boot. Say what is wrong instead.
	-- id is nullable and a unique constraint treats NULLs as distinct, so rows
	-- without a public id are not duplicates - GROUP BY would fold them into one
	-- group and report a collision that the constraint would have accepted.
	SELECT count(*) INTO duplicates
	FROM (SELECT id FROM sites WHERE id IS NOT NULL GROUP BY id HAVING count(*) > 1) d;

	IF duplicates > 0 THEN
		RAISE EXCEPTION
			'sites.id holds % duplicated value(s); sites_id_unique cannot be added until they are resolved. Find them with: SELECT id, count(*) FROM sites GROUP BY id HAVING count(*) > 1;',
			duplicates
			USING HINT = 'Each site id is baked into that site''s tracking snippet, so do not renumber one blindly - decide per site which row keeps the id.';
	END IF;

	ALTER TABLE "sites" ADD CONSTRAINT "sites_id_unique" UNIQUE("id");
END $$;
