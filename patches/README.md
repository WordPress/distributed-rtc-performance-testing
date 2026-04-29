# RTC Storage Approach Patches

Each patch file transforms a clean WordPress 7.0-RC2 installation into one of the
alternative RTC storage implementations under evaluation. Approach 1 (post meta)
is the RC2 baseline and requires no patch.

| # | File | Approach | PR | Schema change |
|---|------|----------|----|---------------|
| 1 | *(none)* | Post meta — RC2 baseline | — | No |
| 2 | `02-custom-table.patch` | Custom table for all data | [#11256](https://github.com/WordPress/wordpress-develop/pull/11256) | Yes — adds `wp_collaboration` |
| 3 | `03-post-meta-transients.patch` | Post meta + transients for awareness | [#11348](https://github.com/WordPress/wordpress-develop/pull/11348) | No |
| 4 | `04-custom-table-with-transients.patch` | Custom table + object cache for awareness | [#11599](https://github.com/WordPress/wordpress-develop/pull/11599) | Yes — adds `wp_collaboration` |

## How patches were generated

```bash
gh pr diff <number> --repo WordPress/wordpress-develop | \
  awk '/^diff --git/ { skip = ($0 ~ /tests\/|version\.php/) } !skip { print }' \
  > patches/<file>.patch
```

Test files (`tests/`) and `version.php` are excluded — they are not needed for
performance testing and the version string must reflect the actual installed build.

## Applying a patch

```bash
# From the WordPress root (WP_PATH):
patch -p1 < /path/to/patches/02-custom-table.patch

# For patches that add the wp_collaboration table, run the DB upgrade after:
wp core update-db
```

## Reversing a patch

```bash
patch -R -p1 < /path/to/patches/02-custom-table.patch

# If the patch added the wp_collaboration table, drop it after reversing:
wp db query "DROP TABLE IF EXISTS $(wp db prefix)collaboration;"

# If the patch also added the wp_presence table (approach 5):
wp db query "DROP TABLE IF EXISTS $(wp db prefix)presence;"
```

## Regenerating patches

If the PR branches are updated, regenerate with the same command above and
commit the new patch files.
